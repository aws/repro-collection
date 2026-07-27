#!/usr/bin/env bash
#
# aws_create_instance_integration.sh - REAL-AWS end-to-end test for
# scripts/aws_create_instance.sh.
#
# For each test case it:
#   1. (pre-flight) validates the request with the script's own DRYRUN=true,
#   2. launches a real instance,
#   3. reads the launched instance id from the resource JSON the script writes,
#   4. queries AWS (describe-instances / describe-volumes) and asserts the
#      settings that actually landed match what was requested,
#   5. terminates the instance (always), then moves to the next case.
#
# This spends real money and creates real resources. It therefore:
#   - refuses to run without explicit confirmation (--yes or CONFIRM=yes),
#   - prints the target account/region up front,
#   - forces cheap, broadly-available instance types and Tenancy=default,
#   - installs an EXIT/INT/TERM trap that terminates every instance it launched
#     and deletes any placement group / temp key pair it created, even on
#     failure or Ctrl-C. Cleanup runs whether or not assertions passed, so a
#     failed check can never leave a billed instance behind.
#
# Usage:
#   AWS_PROFILE=databases AWS_REGION=us-west-2 \
#     tests/integration/aws_create_instance_integration.sh --yes
#
# Options / env:
#   --yes | CONFIRM=yes   Required to actually run.
#   --keep                Do NOT terminate on success (debugging). Cleanup trap
#                         still fires on failure/interrupt. Off by default.
#   --filter <substr>     Only run test cases whose name contains <substr>.
#   AWS_PROFILE           AWS CLI profile (recommended).
#   AWS_REGION            AWS region (default: from profile/config).
#   KEYPAIR               Existing key pair to use. If unset, a temporary one is
#                         created and deleted at the end.
#   SUBNET_ID / SG_ID     Optional; passed through to the script and asserted.
#   ARM_TYPE / X86_TYPE   Override the instance types (default t4g.micro / t3.micro).
#   PG_TYPE               Instance type for the placement-group case; must be a
#                         non-burstable type (burstable t2/t3/t4g cannot join a
#                         cluster placement group). Default c6g.medium.
#
set -uo pipefail

# --------------------------------------------------------------------------
# Locate the script under test.
# --------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$(cd "${HERE}/../.." && pwd)/scripts/aws_create_instance.sh"
[ -f "${SUT}" ] || { echo "cannot find ${SUT}" >&2; exit 2; }

WORK="$(mktemp -d)"
ARM_TYPE="${ARM_TYPE:-t4g.micro}"
X86_TYPE="${X86_TYPE:-t3.micro}"
# Burstable types (t2/t3/t4g) cannot join a cluster placement group, so the PG
# case needs a current-gen non-burstable type. c6g.medium is the cheapest ARM
# one that qualifies; override with PG_TYPE if it's unavailable in your region.
PG_TYPE="${PG_TYPE:-c6g.medium}"

# --------------------------------------------------------------------------
# Options.
# --------------------------------------------------------------------------
CONFIRM="${CONFIRM:-}"
KEEP="false"
FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes)    CONFIRM="yes" ;;
        --keep)   KEEP="true" ;;
        --filter) FILTER="${2:-}"; shift ;;
        -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/d; s/^#\( \|$\)//; p}' "$0"; exit 0 ;;
        *) echo "unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
info() { printf '%s[intg]%s %s\n' "${CYN}" "${RST}" "$*"; }
warn() { printf '%s[intg]%s %s\n' "${YEL}" "${RST}" "$*"; }
err()  { printf '%s[intg]%s %s\n' "${RED}" "${RST}" "$*" >&2; }

command -v aws >/dev/null 2>&1 || { err "aws CLI not found in PATH"; exit 2; }
command -v jq  >/dev/null 2>&1 || { err "jq not found in PATH (required)"; exit 2; }

# aws wrapper mirroring the script: inject --region/--profile when set.
aws_q() {
    local extra=()
    [ -n "${AWS_REGION:-}"  ] && extra+=(--region  "${AWS_REGION}")
    [ -n "${AWS_PROFILE:-}" ] && extra+=(--profile "${AWS_PROFILE}")
    command aws "${extra[@]}" --no-cli-pager "$@"
}

TESTS=0 PASS=0 FAIL=0
CUR=""            # current test name, for assertion labels
check() {         # check <label> <expected> <actual>
    TESTS=$((TESTS+1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf '    %s✓%s %s\n' "${GRN}" "${RST}" "$1"
    else
        FAIL=$((FAIL+1)); printf '    %s✗%s %s  (expected [%s] got [%s])\n' "${RED}" "${RST}" "$1" "$2" "$3"
    fi
}
check_ge() {      # check_ge <label> <min> <actual>
    TESTS=$((TESTS+1))
    if [ "$3" -ge "$2" ] 2>/dev/null; then
        PASS=$((PASS+1)); printf '    %s✓%s %s\n' "${GRN}" "${RST}" "$1"
    else
        FAIL=$((FAIL+1)); printf '    %s✗%s %s  (expected >=[%s] got [%s])\n' "${RED}" "${RST}" "$1" "$2" "$3"
    fi
}

# --------------------------------------------------------------------------
# Resource tracking + cleanup (safety net; always runs).
# --------------------------------------------------------------------------
declare -a CREATED_INSTANCES=()
declare -a CREATED_VOLUMES=()   # EBS volumes attached to launched instances
declare -a CREATED_PGS=()
TEMP_KEYPAIR=""

# reap_volumes: for every tracked EBS volume, ensure it is gone. The script
# sets DeleteOnTermination=true so volumes normally vanish with the instance;
# this verifies that and force-deletes any straggler (e.g. a volume that was
# not marked delete-on-termination). Drops reaped ids from CREATED_VOLUMES;
# leaves only ones it could not remove.
reap_volumes() {
    [ "${#CREATED_VOLUMES[@]}" -gt 0 ] || { CREATED_VOLUMES=(); return 0; }
    local remaining=() v state
    for v in "${CREATED_VOLUMES[@]}"; do
        [ -n "${v}" ] || continue
        state="$(aws_q ec2 describe-volumes --volume-ids "${v}" --query 'Volumes[0].State' --output text 2>/dev/null || true)"
        if [ -z "${state}" ] || [ "${state}" = "None" ]; then
            continue                                   # already gone
        fi
        if [ "${state}" = "deleting" ]; then
            aws_q ec2 wait volume-deleted --volume-ids "${v}" 2>/dev/null || true
        else
            # in-use/available: it survived termination -> detach + delete it.
            aws_q ec2 wait volume-available --volume-ids "${v}" 2>/dev/null || true
            info "Force-deleting leftover volume ${v} (state ${state})"
            aws_q ec2 delete-volume --volume-id "${v}" >/dev/null 2>&1 || true
            aws_q ec2 wait volume-deleted --volume-ids "${v}" 2>/dev/null || true
        fi
        state="$(aws_q ec2 describe-volumes --volume-ids "${v}" --query 'Volumes[0].State' --output text 2>/dev/null || true)"
        if [ -n "${state}" ] && [ "${state}" != "None" ]; then
            warn "volume ${v} still present (state ${state})"; remaining+=("${v}")
        fi
    done
    CREATED_VOLUMES=("${remaining[@]}")
}

# delete_pg <name>: delete a placement group (must be empty first) and verify it
# is gone. Drops it from CREATED_PGS on success; keeps it for the safety net if
# deletion failed. Returns 1 if the group is still present afterwards.
delete_pg() {
    local name="$1" exists
    [ -n "${name}" ] || return 0
    info "Deleting placement group ${name} ..."
    aws_q ec2 delete-placement-group --group-name "${name}" >/dev/null 2>&1 || warn "delete-placement-group call failed for ${name}"
    exists="$(aws_q ec2 describe-placement-groups --group-names "${name}" \
        --query 'PlacementGroups[0].GroupName' --output text 2>/dev/null || true)"
    local kept=() x
    for x in "${CREATED_PGS[@]}"; do [ "${x}" = "${name}" ] || kept+=("${x}"); done
    CREATED_PGS=("${kept[@]}")
    if [ -z "${exists}" ] || [ "${exists}" = "None" ]; then
        info "Placement group ${name} deleted"; return 0
    fi
    warn "placement group ${name} still present after delete"; CREATED_PGS+=("${name}"); return 1
}

terminate_instance() {   # terminate <id>, wait, then reap its EBS volumes
    local id="$1"
    [ -n "${id}" ] && [ "${id}" != "None" ] || return 0
    info "Terminating ${id} ..."
    aws_q ec2 terminate-instances --instance-ids "${id}" >/dev/null 2>&1 || warn "terminate call failed for ${id}"
    aws_q ec2 wait instance-terminated --instance-ids "${id}" 2>/dev/null || warn "wait-terminated failed for ${id}"
    # Drop it from the tracking array once gone.
    local kept=() x
    for x in "${CREATED_INSTANCES[@]}"; do [ "${x}" = "${id}" ] || kept+=("${x}"); done
    CREATED_INSTANCES=("${kept[@]}")
    # EBS disks: confirm they were removed (DeleteOnTermination) / force-delete.
    reap_volumes
    check "EBS volume(s) deleted after termination" "0" "${#CREATED_VOLUMES[@]}"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    info "Cleanup ..."
    local id
    for id in "${CREATED_INSTANCES[@]}"; do
        [ -n "${id}" ] || continue
        warn "Terminating leftover instance ${id}"
        aws_q ec2 terminate-instances --instance-ids "${id}" >/dev/null 2>&1 || true
        aws_q ec2 wait instance-terminated --instance-ids "${id}" 2>/dev/null || true
    done
    CREATED_INSTANCES=()
    # EBS disks (safety net): remove any tracked volume still around.
    reap_volumes
    [ "${#CREATED_VOLUMES[@]}" -eq 0 ] || warn "leftover volumes not deleted: ${CREATED_VOLUMES[*]}"
    # Placement groups (safety net): now that members are gone, delete them.
    local pg
    for pg in "${CREATED_PGS[@]}"; do
        [ -n "${pg}" ] || continue
        aws_q ec2 delete-placement-group --group-name "${pg}" >/dev/null 2>&1 \
            || warn "could not delete PG ${pg} (may still have members)"
    done
    if [ -n "${TEMP_KEYPAIR}" ]; then
        info "Deleting temporary key pair ${TEMP_KEYPAIR}"
        aws_q ec2 delete-key-pair --key-name "${TEMP_KEYPAIR}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Confirmation gate + account banner.
# --------------------------------------------------------------------------
if [ -z "${AWS_REGION:-}" ]; then
    AWS_REGION="$(command aws configure get region ${AWS_PROFILE:+--profile "$AWS_PROFILE"} 2>/dev/null || true)"
fi
[ -n "${AWS_REGION:-}" ] || { err "AWS_REGION not set and no default region configured"; exit 2; }

ACCOUNT="$(aws_q sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)"
ARN="$(aws_q sts get-caller-identity --query 'Arn' --output text 2>/dev/null || true)"
[ -n "${ACCOUNT}" ] && [ "${ACCOUNT}" != "None" ] || { err "cannot authenticate to AWS (profile='${AWS_PROFILE:-default}')"; exit 2; }

cat <<BANNER

${YEL}==================== REAL AWS integration test ====================${RST}
  Account : ${ACCOUNT}
  Region  : ${AWS_REGION}
  Profile : ${AWS_PROFILE:-default}
  Identity: ${ARN}
  Types   : ${ARM_TYPE} (arm64) / ${X86_TYPE} (x86_64) / ${PG_TYPE} (placement group)
  This WILL create and terminate real EC2 instances (Tenancy=default).
${YEL}===================================================================${RST}

BANNER

if [ "${CONFIRM}" != "yes" ]; then
    err "Refusing to run without confirmation. Re-run with --yes (or CONFIRM=yes) once you've checked the account above."
    exit 3
fi

# --------------------------------------------------------------------------
# Key pair: use KEYPAIR if given, else create a temporary one.
# --------------------------------------------------------------------------
if [ -z "${KEYPAIR:-}" ]; then
    TEMP_KEYPAIR="repro-inttest-$$-${RANDOM}"
    info "Creating temporary key pair ${TEMP_KEYPAIR}"
    aws_q ec2 create-key-pair --key-name "${TEMP_KEYPAIR}" --query 'KeyName' --output text >/dev/null \
        || { err "could not create temporary key pair"; exit 2; }
    KEYPAIR="${TEMP_KEYPAIR}"
fi
export KEYPAIR

# --------------------------------------------------------------------------
# launch_case <name> <resource-file> KEY=VAL ...
#   Pre-flight dry-run, then launch. On success sets globals:
#     IID   - launched instance id (from the resource JSON)
#     INFO  - describe-instances JSON for that instance
#   Returns 1 (and records a failure) if the launch or JSON read fails.
# --------------------------------------------------------------------------
launch_case() {
    local name="$1" rfile="$2"; shift 2
    CUR="${name}"
    IID=""; INFO=""   # clear so a failed launch can't carry over the last id
    printf '\n%s== %s ==%s\n' "${CYN}" "${name}" "${RST}"

    # Forced-safe env for every case: cheap tenancy, no repo clone, save JSON.
    local base=(TENANCY=default CLONE_REPO=false SAVE_RESOURCES=true
                "RESOURCE_FILE=${rfile}" "AWS_REGION=${AWS_REGION}" "KEYPAIR=${KEYPAIR}")
    [ -n "${AWS_PROFILE:-}" ] && base+=("AWS_PROFILE=${AWS_PROFILE}")
    [ -n "${SUBNET_ID:-}" ]   && base+=("SUBNET_ID=${SUBNET_ID}")
    [ -n "${SG_ID:-}" ]       && base+=("SG_ID=${SG_ID}")

    # 1. Pre-flight: the script's own dry-run must accept the request (free).
    info "Pre-flight dry-run ..."
    if ! env "${base[@]}" DRYRUN=true "$@" bash "${SUT}" >"${WORK}/dryrun.log" 2>&1; then
        err "dry-run rejected the request:"; sed 's/^/      /' "${WORK}/dryrun.log" >&2
        TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); return 1
    fi
    # EC2 confirms an authorized, well-formed request by failing --dry-run with
    # DryRunOperation; the script surfaces that. Assert on the real marker, not
    # merely on the exit code.
    check "dry-run authorized by EC2 (DryRunOperation)" "yes" \
        "$(grep -q 'DryRunOperation' "${WORK}/dryrun.log" && echo yes || echo no)"

    # 2. Real launch.
    info "Launching ..."
    if ! env "${base[@]}" "$@" bash "${SUT}" >"${WORK}/launch.log" 2>&1; then
        err "launch failed:"; tail -n 15 "${WORK}/launch.log" | sed 's/^/      /' >&2
        TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); return 1
    fi

    # 3. Instance id from the resource JSON the script wrote.
    [ -f "${rfile}" ] || { err "resource JSON ${rfile} not written"; TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); return 1; }
    IID="$(jq -r '.instances[-1].instance_id // empty' "${rfile}")"
    [ -n "${IID}" ] || { err "no instance_id in ${rfile}"; TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); return 1; }
    CREATED_INSTANCES+=("${IID}")
    info "Launched ${IID}; querying AWS ..."

    # Cross-check: the id in the JSON must be a real instance AWS returns when
    # looked up by its Name tag (proves the recorded id is findable on AWS, not
    # just a string the script printed). EXPNAME drives the Name tag.
    local expname aws_iid
    expname="$(for kv in "$@"; do case "${kv}" in EXPNAME=*) printf '%s' "${kv#EXPNAME=}" ;; esac; done)"
    aws_iid="$(aws_q ec2 describe-instances \
        --filters "Name=tag:Name,Values=repro-${expname}-sut" "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[-1].Instances[-1].InstanceId' --output text 2>/dev/null || true)"
    check "JSON instance id matches the one AWS returns for the Name tag" "${IID}" "${aws_iid}"

    # 4. Fetch the live description once for the caller's assertions.
    INFO="$(aws_q ec2 describe-instances --instance-ids "${IID}" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)"
    [ -n "${INFO}" ] && [ "${INFO}" != "null" ] || { err "describe-instances returned nothing for ${IID}"; TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); return 1; }

    # Track every attached EBS volume NOW, so terminate_instance/cleanup can
    # confirm they are deleted even if an assertion below fails or aborts.
    local vid
    while IFS= read -r vid; do
        [ -n "${vid}" ] && [ "${vid}" != "null" ] && CREATED_VOLUMES+=("${vid}")
    done < <(jq -r '.BlockDeviceMappings[].Ebs.VolumeId' <<<"${INFO}" 2>/dev/null)
    return 0
}

# ii <jq-filter> -> value from the current INFO json
ii() { jq -r "$1 // empty" <<<"${INFO}"; }

# Assert the root and data volumes actually attached to $IID. Args:
#   verify_volumes <expected-root-size> <expected-root-type> <expected-data-count>
verify_volumes() {
    local exp_root_size="$1" exp_root_type="$2" exp_data_count="$3"
    local root_dev vids ndev
    root_dev="$(ii '.RootDeviceName')"
    ndev="$(jq '.BlockDeviceMappings | length' <<<"${INFO}")"
    check "block-device count = root + ${exp_data_count} data" "$(( exp_data_count + 1 ))" "${ndev}"

    # Map every attached volume to its size/type.
    vids="$(jq -r '.BlockDeviceMappings[].Ebs.VolumeId' <<<"${INFO}" | tr '\n' ' ')"
    local vols
    vols="$(aws_q ec2 describe-volumes --volume-ids ${vids} \
        --query 'Volumes[].{id:VolumeId,size:Size,type:VolumeType,att:Attachments[0].Device}' \
        --output json 2>/dev/null)"
    # Root volume is the one attached at RootDeviceName.
    local rsize rtype
    rsize="$(jq -r --arg d "${root_dev}" '.[] | select(.att==$d) | .size' <<<"${vols}")"
    rtype="$(jq -r --arg d "${root_dev}" '.[] | select(.att==$d) | .type' <<<"${vols}")"
    check "root volume size = ${exp_root_size} GiB" "${exp_root_size}" "${rsize}"
    check "root volume type = ${exp_root_type}" "${exp_root_type}" "${rtype}"
}

# --------------------------------------------------------------------------
# Test cases.
# --------------------------------------------------------------------------
want() { [ -z "${FILTER}" ] || case "$1" in *"${FILTER}"*) return 0 ;; *) return 1 ;; esac; }

# 1. Minimal arm64 instance, default root disk.
if want "arm64-minimal"; then
    if launch_case "arm64-minimal" "${WORK}/t1.json" INSTANCE_TYPE="${ARM_TYPE}" EXPNAME="intg-arm-min"; then
        check "instance type"      "${ARM_TYPE}"          "$(ii '.InstanceType')"
        check "architecture arm64" "arm64"                "$(ii '.Architecture')"
        check "tenancy default"    "default"              "$(ii '.Placement.Tenancy')"
        check "Name tag"           "repro-intg-arm-min-sut" "$(ii '.Tags[] | select(.Key=="Name") | .Value')"
        check "no placement group" ""                     "$(ii '.Placement.GroupName')"
        verify_volumes 256 gp3 0
    fi
    terminate_instance "${IID:-}"
fi

# 2. x86_64 instance with a custom small root disk.
if want "x86-custom-root"; then
    if launch_case "x86-custom-root" "${WORK}/t2.json" \
        INSTANCE_TYPE="${X86_TYPE}" ARCH=x86_64 ROOT_DISK_SIZE=30 ROOT_DISK_TYPE=gp3 EXPNAME="intg-x86-root"; then
        check "instance type"        "${X86_TYPE}" "$(ii '.InstanceType')"
        check "architecture x86_64"  "x86_64"      "$(ii '.Architecture')"
        verify_volumes 30 gp3 0
    fi
    terminate_instance "${IID:-}"
fi

# 3. arm64 with two extra gp3 data disks.
if want "arm64-data-disks"; then
    if launch_case "arm64-data-disks" "${WORK}/t3.json" \
        INSTANCE_TYPE="${ARM_TYPE}" EBS_DISKS_NUMBER=2 EBS_DISKS_SIZE=10 EBS_DISKS_TYPE=gp3 EXPNAME="intg-data"; then
        check "instance type" "${ARM_TYPE}" "$(ii '.InstanceType')"
        verify_volumes 256 gp3 2
        # Assert the expected extra device names are present.
        DEVS="$(jq -r '.BlockDeviceMappings[].DeviceName' <<<"${INFO}" | sort | tr '\n' ',')"
        check "data device /dev/sdb present" "yes" "$(case "${DEVS}" in *"/dev/sdb"*) echo yes ;; *) echo no ;; esac)"
        check "data device /dev/sdc present" "yes" "$(case "${DEVS}" in *"/dev/sdc"*) echo yes ;; *) echo no ;; esac)"
    fi
    terminate_instance "${IID:-}"
fi

# 4. Ubuntu AMI -> root device /dev/sda1 (the bug the RootDeviceName fix addresses).
if want "ubuntu-root-device"; then
    if launch_case "ubuntu-root-device" "${WORK}/t4.json" \
        INSTANCE_TYPE="${ARM_TYPE}" AMI=UBUNTU2204 ROOT_DISK_SIZE=20 EXPNAME="intg-ubuntu"; then
        check "root device is /dev/sda1" "/dev/sda1" "$(ii '.RootDeviceName')"
        verify_volumes 20 gp3 0    # size override must land on the REAL root
    fi
    terminate_instance "${IID:-}"
fi

# 5. Cluster placement group (created if missing), instance lands in it.
if want "placement-group"; then
    PG="repro-inttest-pg-$$-${RANDOM}"
    CREATED_PGS+=("${PG}")
    if launch_case "placement-group" "${WORK}/t5.json" \
        INSTANCE_TYPE="${PG_TYPE}" PLACEMENT_GROUP_NAME="${PG}" PLACEMENT_GROUP_STRATEGY=cluster EXPNAME="intg-pg"; then
        check "instance is in the placement group" "${PG}" "$(ii '.Placement.GroupName')"
        check "resource JSON records the PG name"  "${PG}" "$(jq -r '.placement_group.name // empty' "${WORK}/t5.json")"
    fi
    # Terminate the member first (a PG with members cannot be deleted), then
    # delete the group we created and verify it is gone.
    terminate_instance "${IID:-}"
    delete_pg "${PG}"
    check "placement group deleted" "0" "$( [ -z "${CREATED_PGS[*]:-}" ] && echo 0 || echo 1 )"
fi

# --------------------------------------------------------------------------
# Summary.
# --------------------------------------------------------------------------
printf '\n%s==================== Results ====================%s\n' "${CYN}" "${RST}"
printf '  assertions: %d   passed: %s%d%s   failed: %s%d%s\n' \
    "${TESTS}" "${GRN}" "${PASS}" "${RST}" "${RED}" "${FAIL}" "${RST}"
if [ "${KEEP}" = "true" ] && [ "${#CREATED_INSTANCES[@]}" -gt 0 ]; then
    warn "--keep set: leaving ${#CREATED_INSTANCES[@]} instance(s) running: ${CREATED_INSTANCES[*]}"
fi
if [ "${FAIL}" -eq 0 ]; then
    printf '  %sALL CHECKS PASSED%s\n' "${GRN}" "${RST}"
    exit 0
else
    printf '  %s%d CHECK(S) FAILED%s\n' "${RED}" "${FAIL}" "${RST}"
    exit 1
fi
