#!/usr/bin/env bash
#
# aws_create_instance.sh - Launch an EC2 instance for repro/benchmark work, driven
# entirely by environment variables. Anything not provided is discovered from
# the target AWS account (AMI, subnet, security group) when possible.
# Run with --help to print this documentation.
#
# Example:
#   AWS_PROFILE=database AWS_REGION=us-west-2 INSTANCE_TYPE=m8g.2xlarge \
#   EBS_DISKS_NUMBER=12 EBS_DISKS_SIZE=1024 EBS_DISKS_TYPE=IO2 EBS_DISKS_IOPS=32000 \
#   KEYPAIR="mykey" AMI=AL2023_K6.12 EXPNAME=test1 \
#   scripts/aws_create_instance.sh
#
# Environment variables
# ---------------------
# Required:
#   INSTANCE_TYPE       EC2 instance type, e.g. m8g.2xlarge
#   KEYPAIR             Name of the EC2 key pair to attach (SSH login)
#   EXPNAME             Experiment name; used in the instance Name tag
#
# AMI selection (one of):
#   AMI                 Either an "ami-..." id (used verbatim) or an alias:
#                         AL2023_K6.12  AL2023_K6.1  AL2023 (latest)
#                         UBUNTU2604 UBUNTU2404 UBUNTU2204 UBUNTU2004
#                       If unset, defaults to the latest AL2023 for the arch.
#                       The alias also selects the SSH login user (Ubuntu ->
#                       ubuntu, otherwise ec2-user); the root volume device
#                       name is read from the AMI itself.
#
# EBS data disks (all optional; no data disks if EBS_DISKS_NUMBER unset/0):
#   EBS_DISKS_NUMBER    Number of extra data volumes, 0..25 (default 0)
#   EBS_DISKS_SIZE      Size in GiB of each data volume (default 1024)
#   EBS_DISKS_TYPE      gp3 | gp2 | io1 | io2 | st1 | sc1 (default gp3)
#   EBS_DISKS_IOPS      Provisioned IOPS, io1/io2/gp3 (default 3000 gp3, 16000 io*)
#   EBS_DISKS_THROUGHPUT  gp3 only, MiB/s (optional)
#   ROOT_DISK_SIZE      Root volume size in GiB (default 256)
#   ROOT_DISK_TYPE      Root volume type (default gp3)
#   ROOT_DISK_IOPS      Provisioned IOPS for the root volume (default 16000 for
#                       an io1/io2 root; otherwise the EC2 default applies)
#
# Networking / placement (auto-discovered from the default VPC if unset):
#   AWS_REGION          AWS region (falls back to profile/default config)
#   AWS_PROFILE         AWS CLI profile
#   SUBNET_ID           Subnet to launch in (default: a subnet in the default VPC)
#   SG_ID               Security group id (default: the default SG of the VPC
#                       that owns SUBNET_ID, or the default VPC's default SG
#                       when no SUBNET_ID is given). NOTE: a VPC default SG
#                       normally has no tcp/22 ingress, so SSH will not work
#                       until the SG allows it; prefer an explicit SG_ID that
#                       permits SSH if you need to log in.
#   TENANCY             default | dedicated | host (default dedicated)
#   ARCH                arm64 | x86_64 (default: inferred from instance type)
#   ASSOCIATE_PUBLIC_IP true | false (default true)
#   PLACEMENT_GROUP_NAME  If set, the instance is launched into this placement
#                       group. If the group does not exist it is created first
#                       (strategy PLACEMENT_GROUP_STRATEGY, default cluster). A
#                       cluster group pins all members to one subnet/AZ: the
#                       subnet is reused from the resource JSON when known, and
#                       the chosen subnet/AZ is recorded on the first launch.
#   PLACEMENT_GROUP_STRATEGY  cluster | partition | spread (default cluster);
#                       only used when the group has to be created.
#   PLACEMENT_GROUP_PARTITION_COUNT  partitions when creating a partition group
#                       (default 2)
#
# Tagging:
#   OWNER_TAG           Value of the Owner tag on the instance and any created
#                       placement group (default: output of whoami)
#
# Resource tracking (default on):
#   SAVE_RESOURCES      true | false (default true) - record the launched instance
#                       (id, type, subnet/AZ, IPs, placement group) to JSON so a
#                       follow-up run can query and reuse the values.
#   RESOURCE_FILE       JSON path (default repro-results/${EXPNAME}.resources.json)
#
# Repo bootstrap (clones repro-collection into the login user's home at boot):
#   CLONE_REPO          true | false (default true)
#   REPO_URL            git URL (default https://github.com/aws/repro-collection.git).
#                       Must be anonymously clonable: the instance clones with no
#                       credentials, and a failed clone is only visible in
#                       /var/log/cloud-init-output.log on the instance.
#   REPO_DEST_NAME      clone directory name under ~ (default repro-collection)
#   REPO_BRANCH         optional branch/tag to check out (default: repo default)
#
# Behaviour:
#   DRYRUN=true         Print/validate the run-instances call without launching
#                       (nothing is created, including a missing placement group)
#   NO_WAIT=true        Do not wait for the instance to reach "running"
#
set -euo pipefail

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m[INFO ]\033[0m %s\n'  "$*" >&2; }
warn() { printf '\033[33m[WARN ]\033[0m %s\n'  "$*" >&2; }
die()  { err "$*"; exit 1; }

# aws wrapper: injects --region/--profile only when set, and never uses a pager.
aws_cli() {
    local extra=()
    [ -n "${AWS_REGION:-}"  ] && extra+=(--region  "${AWS_REGION}")
    [ -n "${AWS_PROFILE:-}" ] && extra+=(--profile "${AWS_PROFILE}")
    command aws "${extra[@]}" --no-cli-pager "$@"
}

# require_aws_value <value> <error message> - reject empty output and the
# "None" sentinel that `--output text` emits for a missing field.
require_aws_value() {
    [ -n "$1" ] && [ "$1" != "None" ] || die "$2"
}

json_get() {  # $1 = jq filter; echoes "" if file/key absent
    [ -f "${RESOURCE_FILE}" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local v; v="$(jq -r "$1 // empty" "${RESOURCE_FILE}" 2>/dev/null || true)"
    printf '%s' "${v}"
}

# Merge a jq expression into RESOURCE_FILE (creating it as {} if needed). The
# jq program in $1 receives the current doc as '.'; extra args after $1 are
# passed through to jq verbatim (e.g. --arg name value).
json_merge() {
    [ "${SAVE_RESOURCES}" = "true" ] || return 0
    local prog="$1"; shift
    local f="${RESOURCE_FILE}" tmp
    mkdir -p "$(dirname "${f}")"
    [ -f "${f}" ] || printf '{}\n' > "${f}"
    tmp="$(mktemp)"
    if jq "$@" "${prog}" "${f}" > "${tmp}" 2>/dev/null; then
        mv "${tmp}" "${f}"
    else
        rm -f "${tmp}"; warn "Failed to update resource JSON ${f}"; return 1
    fi
}

# --------------------------------------------------------------------------
# Arguments: this script is configured via environment variables; the only
# accepted argument is -h/--help, which prints the header documentation.
# --------------------------------------------------------------------------
# Print the header doc block: every comment line after the shebang, stopping at
# the first non-comment line. Depends only on comment structure, not on the
# exact text of any code line below.
usage() {
    local line
    while IFS= read -r line; do
        case "${line}" in
            '#!'*) continue ;;      # shebang
            '#') printf '\n' ;;     # blank comment line
            '# '*) printf '%s\n' "${line#\# }" ;;
            '#'*)  printf '%s\n' "${line#\#}" ;;
            *) break ;;             # first non-comment line ends the header
        esac
    done < "$0"
}
case "${1:-}" in
    "")        ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unexpected argument '$1'. This script is configured via environment variables; run --help." ;;
esac

command -v aws >/dev/null 2>&1 || die "aws CLI not found in PATH"

# --------------------------------------------------------------------------
# Required inputs
# --------------------------------------------------------------------------
: "${INSTANCE_TYPE:?Set INSTANCE_TYPE (e.g. m8g.2xlarge)}"
: "${KEYPAIR:?Set KEYPAIR (EC2 key pair name)}"
: "${EXPNAME:?Set EXPNAME (experiment name used in the Name tag)}"

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
EBS_DISKS_NUMBER="${EBS_DISKS_NUMBER:-0}"
EBS_DISKS_SIZE="${EBS_DISKS_SIZE:-1024}"
EBS_DISKS_TYPE="${EBS_DISKS_TYPE:-gp3}"
EBS_DISKS_IOPS="${EBS_DISKS_IOPS:-}"
EBS_DISKS_THROUGHPUT="${EBS_DISKS_THROUGHPUT:-}"
ROOT_DISK_SIZE="${ROOT_DISK_SIZE:-256}"
ROOT_DISK_TYPE="${ROOT_DISK_TYPE:-gp3}"
ROOT_DISK_IOPS="${ROOT_DISK_IOPS:-}"
TENANCY="${TENANCY:-dedicated}"
ASSOCIATE_PUBLIC_IP="${ASSOCIATE_PUBLIC_IP:-true}"
OWNER_TAG="${OWNER_TAG:-$(whoami)}"
CLONE_REPO="${CLONE_REPO:-true}"
REPO_URL="${REPO_URL:-https://github.com/aws/repro-collection.git}"
REPO_DEST_NAME="${REPO_DEST_NAME:-repro-collection}"
REPO_BRANCH="${REPO_BRANCH:-}"
PLACEMENT_GROUP_NAME="${PLACEMENT_GROUP_NAME:-}"
PLACEMENT_GROUP_STRATEGY="${PLACEMENT_GROUP_STRATEGY:-cluster}"
PLACEMENT_GROUP_PARTITION_COUNT="${PLACEMENT_GROUP_PARTITION_COUNT:-2}"
SAVE_RESOURCES="${SAVE_RESOURCES:-true}"
RESOURCE_FILE="${RESOURCE_FILE:-repro-results/${EXPNAME}.resources.json}"
DRYRUN="${DRYRUN:-false}"

# --------------------------------------------------------------------------
# Input validation
# --------------------------------------------------------------------------
# Data-disk device names run /dev/sdb../dev/sdz, so at most 25 extra disks.
[[ "${EBS_DISKS_NUMBER}" =~ ^[0-9]+$ ]] && [ "${EBS_DISKS_NUMBER}" -le 25 ] \
    || die "EBS_DISKS_NUMBER must be an integer 0..25 (device names /dev/sdb../dev/sdz), got '${EBS_DISKS_NUMBER}'"

case "${ASSOCIATE_PUBLIC_IP}" in
    true|false) ;;
    *) die "ASSOCIATE_PUBLIC_IP must be 'true' or 'false', got '${ASSOCIATE_PUBLIC_IP}'" ;;
esac

# Numeric disk fields are interpolated unquoted into the block-device JSON, so a
# non-numeric value would inject/corrupt the request. Required ones must be
# integers; optional ones (may be empty) must be integers when set.
require_int()  { [[ "$2" =~ ^[0-9]+$ ]]     || die "$1 must be a non-negative integer, got '$2'"; }
optional_int() { [ -z "$2" ] || [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer when set, got '$2'"; }
require_int  EBS_DISKS_SIZE       "${EBS_DISKS_SIZE}"
require_int  ROOT_DISK_SIZE       "${ROOT_DISK_SIZE}"
optional_int EBS_DISKS_IOPS       "${EBS_DISKS_IOPS}"
optional_int EBS_DISKS_THROUGHPUT "${EBS_DISKS_THROUGHPUT}"
optional_int ROOT_DISK_IOPS       "${ROOT_DISK_IOPS}"

# EXPNAME feeds both the instance Name tag and the RESOURCE_FILE path, so keep
# it free of path separators / shell/JSON metacharacters.
[[ "${EXPNAME}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "EXPNAME must match ^[A-Za-z0-9._-]+$ (used in a tag and a file path), got '${EXPNAME}'"

# OWNER_TAG and PLACEMENT_GROUP_NAME are interpolated into the tag/placement
# shorthand strings; restrict them so a value cannot inject extra tag key/values.
# (The OWNER_TAG pattern allows spaces, so keep it in a variable: an inline
# regex with a literal space is mis-tokenized by [[ =~ ]].)
_owner_re='^[A-Za-z0-9._@ -]+$'
[[ "${OWNER_TAG}" =~ $_owner_re ]] \
    || die "OWNER_TAG may contain only letters, digits, space, and . _ @ - ; got '${OWNER_TAG}'"
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    [[ "${PLACEMENT_GROUP_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "PLACEMENT_GROUP_NAME must match ^[A-Za-z0-9._-]+$, got '${PLACEMENT_GROUP_NAME}'"
fi

# When SUBNET_ID/SG_ID are supplied they go verbatim into the network-interface
# JSON; require the canonical id shapes so a crafted value cannot break it.
[ -z "${SUBNET_ID:-}" ] || [[ "${SUBNET_ID}" =~ ^subnet-[0-9a-f]+$ ]] \
    || die "SUBNET_ID must look like 'subnet-...', got '${SUBNET_ID}'"
[ -z "${SG_ID:-}" ] || [[ "${SG_ID}" =~ ^sg-[0-9a-f]+$ ]] \
    || die "SG_ID must look like 'sg-...', got '${SG_ID}'"

# REPO_* values are interpolated into user-data that runs as root on the
# instance, so restrict them to a strict character allowlist.
if [ "${CLONE_REPO}" = "true" ]; then
    [[ "${REPO_URL}" =~ ^[A-Za-z0-9._:/@+-]+$ ]] \
        || die "REPO_URL contains characters not allowed in boot user-data: '${REPO_URL}'"
    { [[ "${REPO_DEST_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${REPO_DEST_NAME}" != "." ] && [ "${REPO_DEST_NAME}" != ".." ]; } \
        || die "REPO_DEST_NAME must match ^[A-Za-z0-9._-]+$ and not be '.' or '..' (no path traversal), got '${REPO_DEST_NAME}'"
    if [ -n "${REPO_BRANCH}" ]; then
        [[ "${REPO_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]] \
            || die "REPO_BRANCH must match ^[A-Za-z0-9._/-]+$, got '${REPO_BRANCH}'"
    fi
fi

# Resource JSON needs jq; degrade gracefully if it is missing.
if [ "${SAVE_RESOURCES}" = "true" ] && ! command -v jq >/dev/null 2>&1; then
    warn "jq not found; disabling resource JSON tracking (SAVE_RESOURCES=false)"
    SAVE_RESOURCES="false"
fi

if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    case "${PLACEMENT_GROUP_STRATEGY}" in
        cluster|partition|spread) ;;
        *) die "Invalid PLACEMENT_GROUP_STRATEGY='${PLACEMENT_GROUP_STRATEGY}'. Use one of: cluster partition spread" ;;
    esac
fi

# EBS type -> lowercase for the API (accept IO2, io2, GP3, ...)
EBS_DISKS_TYPE="$(printf '%s' "${EBS_DISKS_TYPE}" | tr '[:upper:]' '[:lower:]')"
ROOT_DISK_TYPE="$(printf '%s' "${ROOT_DISK_TYPE}" | tr '[:upper:]' '[:lower:]')"

# Normalize Iops/Throughput per volume type once, here: after this a non-empty
# value is always valid for its type, so ebs_json emits fields purely on
# non-emptiness and needs no per-type logic of its own.
case "${EBS_DISKS_TYPE}" in
    io1|io2)
        EBS_DISKS_IOPS="${EBS_DISKS_IOPS:-16000}"
        [ -n "${EBS_DISKS_THROUGHPUT}" ] && { warn "EBS_DISKS_THROUGHPUT applies only to gp3; ignoring for ${EBS_DISKS_TYPE}"; EBS_DISKS_THROUGHPUT=""; } ;;
    gp3)
        EBS_DISKS_IOPS="${EBS_DISKS_IOPS:-3000}" ;;
    *)
        [ -n "${EBS_DISKS_IOPS}" ] && warn "EBS_DISKS_IOPS does not apply to ${EBS_DISKS_TYPE}; ignoring it"
        EBS_DISKS_IOPS=""
        [ -n "${EBS_DISKS_THROUGHPUT}" ] && { warn "EBS_DISKS_THROUGHPUT applies only to gp3; ignoring for ${EBS_DISKS_TYPE}"; EBS_DISKS_THROUGHPUT=""; } ;;
esac
# Root disk: only io1/io2/gp3 accept Iops; anything else rejects the field.
case "${ROOT_DISK_TYPE}" in
    io1|io2)
        # io1 caps at 50 IOPS/GiB; default within that so a default-size io1 root
        # does not fail the ratio check (io2 tolerates it, but capping is safe).
        if [ -z "${ROOT_DISK_IOPS}" ]; then
            ROOT_DISK_IOPS=16000
            [ "${ROOT_DISK_TYPE}" = "io1" ] && [ $(( 50 * ROOT_DISK_SIZE )) -lt "${ROOT_DISK_IOPS}" ] \
                && ROOT_DISK_IOPS=$(( 50 * ROOT_DISK_SIZE ))
        fi ;;
    gp3) ;;   # optional Iops; keep a user-supplied value, no default
    *)
        [ -n "${ROOT_DISK_IOPS}" ] && warn "ROOT_DISK_IOPS does not apply to ${ROOT_DISK_TYPE}; ignoring it"
        ROOT_DISK_IOPS="" ;;
esac

# --------------------------------------------------------------------------
# Architecture: infer from instance type unless ARCH is set.
# Graviton families end in 'g' before the size (m8g, r8g, c7g, i4g, ...).
# --------------------------------------------------------------------------
if [ -z "${ARCH:-}" ]; then
    family="${INSTANCE_TYPE%%.*}"      # e.g. m8g from m8g.24xlarge
    if [[ "${family}" =~ g[a-z]*$ ]]; then
        ARCH="arm64"
    else
        ARCH="x86_64"
    fi
fi
info "Architecture: ${ARCH} (instance type ${INSTANCE_TYPE})"

# --------------------------------------------------------------------------
# Resolve region/account context for the summary.
# --------------------------------------------------------------------------
if [ -z "${AWS_REGION:-}" ]; then
    AWS_REGION="$(command aws configure get region ${AWS_PROFILE:+--profile "$AWS_PROFILE"} 2>/dev/null || true)"
fi
[ -n "${AWS_REGION:-}" ] || die "AWS_REGION is not set and no default region is configured"

info "Verifying credentials ..."
CALLER_ARN="$(aws_cli sts get-caller-identity --query 'Arn' --output text)" \
    || die "Unable to authenticate with AWS (profile='${AWS_PROFILE:-default}', region='${AWS_REGION}')"
info "Authenticated as: ${CALLER_ARN}"

# --------------------------------------------------------------------------
# AMI resolution. Each alias arm also owns its login user, so a new distro
# alias only needs to be added here (no separate LOGIN_USER case to keep in
# sync).
# --------------------------------------------------------------------------
resolve_ami() {
    local alias="$1" owners filter
    LOGIN_USER="ec2-user"
    case "${alias}" in
        ami-*) AMI_ID="${alias}"; return 0 ;;
    esac
    alias="${alias^^}"     # aliases are case-insensitive
    case "${alias}" in
        AL2023_K6.12)
            owners="137112412989"; filter="al2023-ami-2023*-kernel-6.12-*" ;;
        AL2023_K6.1)
            owners="137112412989"; filter="al2023-ami-2023*-kernel-6.1-*" ;;
        AL2023|"")
            owners="137112412989"; filter="al2023-ami-2023*-kernel-*" ;;
        UBUNTU2604)
            owners="099720109477"; filter="ubuntu/images/hvm-ssd*/ubuntu-*-26.04-*-server-*"; LOGIN_USER="ubuntu" ;;
        UBUNTU2404)
            owners="099720109477"; filter="ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-*-server-*"; LOGIN_USER="ubuntu" ;;
        UBUNTU2204)
            owners="099720109477"; filter="ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-*-server-*"; LOGIN_USER="ubuntu" ;;
        UBUNTU2004)
            owners="099720109477"; filter="ubuntu/images/hvm-ssd/ubuntu-focal-20.04-*-server-*"; LOGIN_USER="ubuntu" ;;
        *)
            die "Unknown AMI alias '$1'. Use an ami-... id or one of: AL2023_K6.12 AL2023_K6.1 AL2023 UBUNTU2604 UBUNTU2404 UBUNTU2204 UBUNTU2004" ;;
    esac

    info "Resolving AMI: alias='${alias}' owners='${owners}' arch='${ARCH}'"
    AMI_ID="$(aws_cli ec2 describe-images \
        --owners ${owners} \
        --filters "Name=name,Values=${filter}" \
                  "Name=architecture,Values=${ARCH}" \
                  "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)"
    require_aws_value "${AMI_ID}" "No AMI found for alias '$1' (arch ${ARCH}) in ${AWS_REGION}"
}
resolve_ami "${AMI:-}"
info "AMI: ${AMI_ID} (login user ${LOGIN_USER})"

# Root device name differs per AMI (AL2023 /dev/xvda, Ubuntu /dev/sda1). Using
# the wrong name makes EC2 attach an EXTRA volume and leave the real root at
# the AMI default size, so read the actual root device from the AMI.
ROOT_DEVICE="$(aws_cli ec2 describe-images --image-ids "${AMI_ID}" \
    --query 'Images[0].RootDeviceName' --output text 2>/dev/null || true)"
if [ -z "${ROOT_DEVICE}" ] || [ "${ROOT_DEVICE}" = "None" ]; then
    warn "Could not read RootDeviceName of ${AMI_ID}; assuming /dev/xvda"
    ROOT_DEVICE="/dev/xvda"
fi
info "Root device: ${ROOT_DEVICE}"

# --------------------------------------------------------------------------
# Placement group: ensure it exists (create if missing) and, for a cluster
# group, keep every member in one subnet/AZ.
#   1. If the group is missing, create it (default strategy: cluster) - unless
#      DRYRUN=true, in which case nothing is created.
#   2. Pick the subnet the group must use, in priority order:
#        a. explicit SUBNET_ID (validated against any existing members' AZ),
#        b. the AZ of instances already running in the group (live account),
#        c. the subnet recorded in the resource JSON (same region only),
#        d. otherwise the normal discovery below picks one, recorded afterwards.
# --------------------------------------------------------------------------
PG_GROUP_ID=""             # set when a placement group is used (for the resource JSON)
PG_CREATED="false"
PG_DRYRUN_MISSING="false"  # true when DRYRUN skipped creating a missing group
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    PG_GROUP_ID="$(aws_cli ec2 describe-placement-groups \
        --filters "Name=group-name,Values=${PLACEMENT_GROUP_NAME}" \
        --query 'PlacementGroups[0].GroupId' --output text 2>/dev/null || true)"

    if [ -z "${PG_GROUP_ID}" ] || [ "${PG_GROUP_ID}" = "None" ]; then
        if [ "${DRYRUN}" = "true" ]; then
            # A dry run must not mutate the account.
            info "DRYRUN=true: placement group '${PLACEMENT_GROUP_NAME}' does not exist and would be created (${PLACEMENT_GROUP_STRATEGY}); skipping creation"
            PG_GROUP_ID=""
            PG_DRYRUN_MISSING="true"
        else
            info "Placement group '${PLACEMENT_GROUP_NAME}' not found; creating (${PLACEMENT_GROUP_STRATEGY}) ..."
            _pg_create=(ec2 create-placement-group
                --group-name "${PLACEMENT_GROUP_NAME}"
                --strategy "${PLACEMENT_GROUP_STRATEGY}"
                --tag-specifications "ResourceType=placement-group,Tags=[{Key=Name,Value=${PLACEMENT_GROUP_NAME}},{Key=Owner,Value=${OWNER_TAG}}]")
            [ "${PLACEMENT_GROUP_STRATEGY}" = "partition" ] \
                && _pg_create+=(--partition-count "${PLACEMENT_GROUP_PARTITION_COUNT}")
            PG_GROUP_ID="$(aws_cli "${_pg_create[@]}" \
                --query 'PlacementGroup.GroupId' --output text)"
            require_aws_value "${PG_GROUP_ID}" "Failed to create placement group '${PLACEMENT_GROUP_NAME}'"
            info "Created placement group '${PLACEMENT_GROUP_NAME}' (${PG_GROUP_ID})"
            PG_CREATED="true"
        fi
    else
        info "Placement group '${PLACEMENT_GROUP_NAME}' exists (${PG_GROUP_ID}); reusing"
    fi

    # Subnet of instances already in the group (so new members share the AZ).
    PG_MEMBER_SUBNET="$(aws_cli ec2 describe-instances \
        --filters "Name=placement-group-name,Values=${PLACEMENT_GROUP_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].SubnetId' --output text 2>/dev/null || true)"
    [ "${PG_MEMBER_SUBNET}" = "None" ] && PG_MEMBER_SUBNET=""

    if [ -z "${SUBNET_ID:-}" ]; then
        if [ -n "${PG_MEMBER_SUBNET}" ]; then
            SUBNET_ID="${PG_MEMBER_SUBNET}"
            info "Reusing subnet ${SUBNET_ID} from existing members of '${PLACEMENT_GROUP_NAME}'"
        else
            _pg_subnet="$(json_get '.placement_group.subnet_id')"
            _pg_az="$(json_get '.placement_group.availability_zone')"
            _rec_region="$(json_get '.region')"
            # A subnet recorded in another region is useless in this one.
            if [ -n "${_pg_subnet}" ] && [ -n "${_rec_region}" ] && [ "${_rec_region}" != "${AWS_REGION}" ]; then
                warn "Resource JSON ${RESOURCE_FILE} was recorded in region ${_rec_region}, not ${AWS_REGION}; ignoring its recorded subnet ${_pg_subnet}"
                _pg_subnet=""
            fi
            if [ -n "${_pg_subnet}" ]; then
                SUBNET_ID="${_pg_subnet}"
                info "Reusing subnet ${SUBNET_ID}${_pg_az:+ (AZ ${_pg_az})} recorded for placement group '${PLACEMENT_GROUP_NAME}'"
            else
                info "No subnet recorded yet for '${PLACEMENT_GROUP_NAME}'; the chosen subnet/AZ will be recorded for follow-up launches"
            fi
        fi
    elif [ -n "${PG_MEMBER_SUBNET}" ] && [ "${SUBNET_ID}" != "${PG_MEMBER_SUBNET}" ]; then
        warn "SUBNET_ID=${SUBNET_ID} differs from existing members' subnet ${PG_MEMBER_SUBNET} of '${PLACEMENT_GROUP_NAME}'; a cluster group requires one AZ and the launch may fail"
    fi
fi

# --------------------------------------------------------------------------
# Networking discovery. The VPC is resolved in priority order:
#   1. from SUBNET_ID when one is provided (works even with no default VPC),
#   2. otherwise the account's default VPC.
# The subnet's own VPC also owns its default security group, so a provided
# SUBNET_ID is enough to fill in a missing SG_ID without any default VPC.
# --------------------------------------------------------------------------
VPC_ID=""
get_vpc() {
    [ -n "${VPC_ID}" ] && return 0
    if [ -n "${SUBNET_ID:-}" ]; then
        VPC_ID="$(aws_cli ec2 describe-subnets \
            --subnet-ids "${SUBNET_ID}" \
            --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
        require_aws_value "${VPC_ID}" "Could not resolve VPC for SUBNET_ID=${SUBNET_ID} (check the id and region ${AWS_REGION})"
        return 0
    fi
    VPC_ID="$(aws_cli ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' --output text)"
    require_aws_value "${VPC_ID}" "No default VPC in ${AWS_REGION}; set SUBNET_ID (and optionally SG_ID) explicitly"
}

if [ -z "${SUBNET_ID:-}" ]; then
    get_vpc   # default VPC, since no subnet was provided
    # Pick a random available subnet. Spreading across AZs avoids repeatedly
    # landing on one AZ that may not offer the requested instance type.
    mapfile -t _subnets < <(aws_cli ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
        --query 'Subnets[].SubnetId' --output text | tr '\t' '\n' | grep -v '^$')
    [ "${#_subnets[@]}" -gt 0 ] \
        || die "No available subnet found in default VPC ${VPC_ID}"
    SUBNET_ID="${_subnets[$(( RANDOM % ${#_subnets[@]} ))]}"
    info "Discovered subnet: ${SUBNET_ID} (random of ${#_subnets[@]} in default VPC ${VPC_ID})"
else
    info "Using provided subnet: ${SUBNET_ID}"
fi

SG_IS_DEFAULT="false"   # true when SG was auto-discovered (VPC default SG)
if [ -z "${SG_ID:-}" ]; then
    get_vpc   # VPC derived from SUBNET_ID (above) or the default VPC
    SG_ID="$(aws_cli ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
        --query 'SecurityGroups[0].GroupId' --output text)"
    require_aws_value "${SG_ID}" "No default security group found in VPC ${VPC_ID}"
    SG_IS_DEFAULT="true"
    info "Discovered security group: ${SG_ID} (default SG of ${VPC_ID})"
    warn "Using the VPC default SG (${SG_ID}), which normally allows inbound traffic only from itself: SSH to the instance will not work unless it has tcp/22 ingress. Set SG_ID to a group that permits SSH if you need to log in."
else
    info "Using provided security group: ${SG_ID}"
fi

# --------------------------------------------------------------------------
# Build block device mappings JSON. Iops/Throughput were already normalized
# per volume type above, so a non-empty value simply means "emit the field".
# --------------------------------------------------------------------------
ebs_json() {  # emit one {"DeviceName":...,"Ebs":{...}} object
    local device="$1" size="$2" type="$3" iops="$4" throughput="$5"
    local ebs="\"VolumeSize\":${size},\"VolumeType\":\"${type}\",\"DeleteOnTermination\":true"
    [ -n "${iops}" ]       && ebs="${ebs},\"Iops\":${iops}"
    [ -n "${throughput}" ] && ebs="${ebs},\"Throughput\":${throughput}"
    printf '{"DeviceName":"%s","Ebs":{%s}}' "${device}" "${ebs}"
}

# Data disks use device names /dev/sdb, /dev/sdc, ... (count validated <= 25).
DISK_LETTERS="bcdefghijklmnopqrstuvwxyz"
BDM="[$(ebs_json "${ROOT_DEVICE}" "${ROOT_DISK_SIZE}" "${ROOT_DISK_TYPE}" "${ROOT_DISK_IOPS}" "")"
for (( i = 0; i < EBS_DISKS_NUMBER; i++ )); do
    dev="/dev/sd${DISK_LETTERS:i:1}"
    BDM="${BDM},$(ebs_json "${dev}" "${EBS_DISKS_SIZE}" "${EBS_DISKS_TYPE}" "${EBS_DISKS_IOPS}" "${EBS_DISKS_THROUGHPUT}")"
done
BDM="${BDM}]"

# --------------------------------------------------------------------------
# Network interface + user data + tags.
# --------------------------------------------------------------------------
NET_IFACE="[{\"DeviceIndex\":0,\"SubnetId\":\"${SUBNET_ID}\",\"Groups\":[\"${SG_ID}\"],\"AssociatePublicIpAddress\":${ASSOCIATE_PUBLIC_IP}}]"

# Base user-data: disable SSM, install common tooling (+git for the repo clone).
# Quoted heredoc -> nothing here is expanded by this script; it runs on the instance.
USER_DATA="$(cat <<'EOF'
#!/bin/bash
sudo systemctl disable --now snap.amazon-ssm-agent.amazon-ssm-agent || sudo systemctl disable --now amazon-ssm-agent
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y git nmap-ncat tmux htop mdadm xfsprogs
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y git netcat-openbsd tmux htop mdadm xfsprogs
fi
EOF
)"

# Optionally clone the repro-collection repo into the login user's home dir.
# Only REPO_* vars expand here (each validated against an allowlist above, since
# this block runs as root on the instance); instance-side vars ($_d, $(...))
# stay literal. REPO_URL/REPO_BRANCH are single-quoted in the emitted script,
# and the allowlist already forbids quotes, so no value can break out. The clone
# always fetches the default branch first (so a wrong/missing REPO_BRANCH never
# leaves the repo un-cloned), then best-effort checks out REPO_BRANCH.
if [ "${CLONE_REPO}" = "true" ]; then
    CLONE_BLOCK="$(cat <<EOF

# --- Clone repro-collection into ${LOGIN_USER}'s home (user-data runs as root) ---
_d="/home/${LOGIN_USER}/${REPO_DEST_NAME}"
if [ ! -d "\$_d" ]; then
  echo "[create_instance] cloning ${REPO_URL} -> \$_d"
  if sudo -u ${LOGIN_USER} git clone -- '${REPO_URL}' "\$_d"; then
    if [ -n "${REPO_BRANCH}" ]; then
      sudo -u ${LOGIN_USER} git -C "\$_d" checkout '${REPO_BRANCH}' \
        || echo "[create_instance] WARNING: branch '${REPO_BRANCH}' not found on remote; staying on default branch"
    fi
  else
    echo "[create_instance] ERROR: git clone failed"
  fi
fi
EOF
)"
    USER_DATA="${USER_DATA}${CLONE_BLOCK}"
    info "Repo clone enabled: ${REPO_URL}${REPO_BRANCH:+ (branch ${REPO_BRANCH})} -> ~/${REPO_DEST_NAME}"
else
    info "Repo clone disabled (CLONE_REPO=false)"
fi

INSTANCE_NAME="repro-${EXPNAME}-sut"
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Owner,Value=${OWNER_TAG}}]"

# Placement string: tenancy always, group name only when requested. Placement
# groups accept default and dedicated tenancy; only Dedicated Hosts (host
# tenancy) cannot launch into one.
PLACEMENT="Tenancy=${TENANCY}"
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    [ "${TENANCY}" != "host" ] \
        || warn "Placement group '${PLACEMENT_GROUP_NAME}' with Tenancy=host: EC2 does not allow Dedicated Hosts in placement groups; the launch will fail"
    if [ "${PG_DRYRUN_MISSING}" = "true" ]; then
        # The group was not created (dry run); referencing it would fail with a
        # spurious not-found error instead of validating the rest of the request.
        info "DRYRUN=true: omitting GroupName=${PLACEMENT_GROUP_NAME} from the validated request (group not created)"
    else
        PLACEMENT="${PLACEMENT},GroupName=${PLACEMENT_GROUP_NAME}"
    fi
fi

# Display strings shared by the launch plan and the final summary (computed
# once so the two blocks cannot drift).
if [ -n "${PLACEMENT_GROUP_NAME}" ]; then
    if   [ "${PG_DRYRUN_MISSING}" = "true" ]; then _pg_state="would be created"
    elif [ "${PG_CREATED}" = "true" ];        then _pg_state="created"
    else                                           _pg_state="existing"; fi
    PG_DISPLAY="${PLACEMENT_GROUP_NAME} (${PLACEMENT_GROUP_STRATEGY}, ${_pg_state})"
else
    PG_DISPLAY="(none)"
fi
DATA_DISKS_DISPLAY="${EBS_DISKS_NUMBER} x ${EBS_DISKS_SIZE} GiB ${EBS_DISKS_TYPE}${EBS_DISKS_IOPS:+ (IOPS ${EBS_DISKS_IOPS})}"

# --------------------------------------------------------------------------
# Summary of what we're about to launch.
# --------------------------------------------------------------------------
cat >&2 <<SUMMARY

============================ Launch plan ============================
  Region / profile : ${AWS_REGION} / ${AWS_PROFILE:-default}
  Instance type    : ${INSTANCE_TYPE}  (arch ${ARCH})
  AMI              : ${AMI_ID}
  Key pair         : ${KEYPAIR}
  Tenancy          : ${TENANCY}
  Subnet / SG      : ${SUBNET_ID} / ${SG_ID}
  Placement group  : ${PG_DISPLAY}
  Public IP        : ${ASSOCIATE_PUBLIC_IP}
  Root disk        : ${ROOT_DISK_SIZE} GiB ${ROOT_DISK_TYPE} (${ROOT_DEVICE})
  Data disks       : ${DATA_DISKS_DISPLAY}
  Name tag         : ${INSTANCE_NAME}  (Owner=${OWNER_TAG})
  Clone repo       : $( [ "${CLONE_REPO}" = "true" ] && printf '%s -> ~/%s%s' "${REPO_URL}" "${REPO_DEST_NAME}" "${REPO_BRANCH:+ (${REPO_BRANCH})}" || printf 'no' )
====================================================================

SUMMARY

RUN_ARGS=(
    ec2 run-instances
    --image-id "${AMI_ID}"
    --instance-type "${INSTANCE_TYPE}"
    --key-name "${KEYPAIR}"
    --network-interfaces "${NET_IFACE}"
    --placement "${PLACEMENT}"
    --block-device-mappings "${BDM}"
    --user-data "${USER_DATA}"
    --tag-specifications "${TAGS}"
)

if [ "${DRYRUN}" = "true" ]; then
    warn "DRYRUN=true: validating with EC2 --dry-run (no instance will be created)"
    _dryrun_out="$(mktemp)"
    if aws_cli "${RUN_ARGS[@]}" --dry-run 2>"${_dryrun_out}"; then
        info "Dry run reported success"
    elif grep -q "DryRunOperation" "${_dryrun_out}"; then
        info "Dry run OK: request is well-formed and authorized (DryRunOperation)"
    else
        cat "${_dryrun_out}" >&2
        rm -f "${_dryrun_out}"
        die "Dry run failed"
    fi
    rm -f "${_dryrun_out}"
    info "Block device mappings that would be used:"
    printf '%s\n' "${BDM}" >&2
    exit 0
fi

# --------------------------------------------------------------------------
# Launch.
# --------------------------------------------------------------------------
info "Launching instance ..."
INSTANCE_ID="$(aws_cli "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)"
require_aws_value "${INSTANCE_ID}" "run-instances did not return an instance id"
info "Launched: ${INSTANCE_ID}"

# Record the id immediately, before waiting/describing: if anything below fails
# (wait interrupted, describe throttled) the running, billed instance must not
# be left untracked in the resource JSON.
if json_merge '
    .expname = $exp | .region = $region
    | (if $profile == "" then . else .profile = $profile end)
    | .instances += [{
        instance_id: $iid, name: $name, instance_type: $itype,
        arch: $arch, ami: $ami
      }]' \
    --arg exp "${EXPNAME}" --arg region "${AWS_REGION}" --arg profile "${AWS_PROFILE:-}" \
    --arg iid "${INSTANCE_ID}" --arg name "${INSTANCE_NAME}" --arg itype "${INSTANCE_TYPE}" \
    --arg arch "${ARCH}" --arg ami "${AMI_ID}"
then
    [ "${SAVE_RESOURCES}" = "true" ] && info "Recorded instance id in ${RESOURCE_FILE}"
fi

if [ "${NO_WAIT:-false}" != "true" ]; then
    info "Waiting for instance to reach 'running' ..."
    aws_cli ec2 wait instance-running --instance-ids "${INSTANCE_ID}" \
        || warn "wait failed; the instance may still be initialising"
fi

# --------------------------------------------------------------------------
# Final summary with IP addresses. A failed describe must not abort the script
# (the instance is already running); it only leaves the detail fields empty.
# --------------------------------------------------------------------------
STATE="" AZ="" PRIV_IP="" PUB_IP=""
read -r STATE AZ PRIV_IP PUB_IP < <(aws_cli ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].[State.Name,Placement.AvailabilityZone,PrivateIpAddress,PublicIpAddress]' \
    --output text) \
    || warn "describe-instances failed; instance details in the summary may be empty"

[ "${PUB_IP}" = "None" ] && PUB_IP=""
PUB_IP_DISPLAY="${PUB_IP:-(none)}"

# --------------------------------------------------------------------------
# Enrich the resource record so follow-up runs can query/reuse it. The
# placement group entry stores the subnet/AZ this instance landed in, which is
# exactly what the next launch into the same (cluster) group must reuse.
# --------------------------------------------------------------------------
if json_merge '
    .instances[-1] += {
        availability_zone: $az, subnet_id: $subnet, security_group_id: $sg,
        private_ip: $priv, public_ip: $pub,
        placement_group: (if $pg == "" then null else $pg end)
    }
    | (if $pg == "" then . else
        .placement_group.name = $pg
        | .placement_group.strategy = $pgstrat
        | (if $pgid == "" then . else .placement_group.group_id = $pgid end)
        | .placement_group.subnet_id = $subnet
        | .placement_group.availability_zone = $az
      end)
    ' \
    --arg az "${AZ}" --arg subnet "${SUBNET_ID}" --arg sg "${SG_ID}" \
    --arg priv "${PRIV_IP}" --arg pub "${PUB_IP}" \
    --arg pg "${PLACEMENT_GROUP_NAME}" --arg pgstrat "${PLACEMENT_GROUP_STRATEGY}" \
    --arg pgid "${PG_GROUP_ID}"
then
    [ "${SAVE_RESOURCES}" = "true" ] && info "Recorded resources in ${RESOURCE_FILE}"
fi

cat <<SUMMARY

======================= Instance summary =======================
  Instance ID   : ${INSTANCE_ID}
  Name          : ${INSTANCE_NAME}
  State         : ${STATE}
  Type / arch   : ${INSTANCE_TYPE} / ${ARCH}
  AMI           : ${AMI_ID}
  Region / AZ   : ${AWS_REGION} / ${AZ}
  Subnet / SG   : ${SUBNET_ID} / ${SG_ID}
  Tenancy       : ${TENANCY}
  Placement grp : ${PG_DISPLAY}
  Private IP    : ${PRIV_IP}
  Public  IP    : ${PUB_IP_DISPLAY}
  Data disks    : ${DATA_DISKS_DISPLAY}
  Repo          : $( [ "${CLONE_REPO}" = "true" ] && printf '~/%s (%s)' "${REPO_DEST_NAME}" "${REPO_URL}" || printf 'not cloned' )
  Resource JSON : $( [ "${SAVE_RESOURCES}" = "true" ] && printf '%s' "${RESOURCE_FILE}" || printf 'disabled' )
================================================================

  SSH:  ssh ${LOGIN_USER}@${PUB_IP_DISPLAY}$( [ "${SG_IS_DEFAULT}" = "true" ] && printf '   (WARNING: SG %s is the VPC default and likely has no tcp/22 ingress; SSH may fail)' "${SG_ID}" )
  Tail cloud-init:  ssh ${LOGIN_USER}@${PUB_IP_DISPLAY} 'sudo tail -f /var/log/cloud-init-output.log'
  Terminate:  aws ${AWS_PROFILE:+--profile ${AWS_PROFILE}} --region ${AWS_REGION} ec2 terminate-instances --instance-ids ${INSTANCE_ID}

SUMMARY
