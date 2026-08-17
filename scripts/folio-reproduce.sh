#!/usr/bin/env bash
#
# folio-reproduce.sh — End-to-end dirty-folio regression reproduction.
# Launches DRV + SUT, builds a custom kernel on SUT, syncs workload files
# to both hosts, then drives N pgbench iterations on the same persistent cluster.
#
# Usage:
#   ./scripts/folio-reproduce.sh <ID> [--patch=<path>] [--keep]
#
# Arguments:
#   ID              Unique run identifier appended to experiment names.
#   --patch=<path>  Optional kernel patch file to apply on the SUT.
#   --no-perf       Skip building/installing perf from the kernel tree.
#   --keep          Do NOT terminate instances after the run.
#
# Overridable env vars:
#   AWS_PROFILE     AWS CLI profile          (default: default)
#   KEY             SSH identity file        (default: ~/.ssh/dipiets.pem)
#   KEYPAIR         EC2 key pair name        (default: dipiets)
#   PLACEMENT_GROUP EC2 placement group name (default: pg-test)
#   ITERS           Benchmark iterations     (default: 5)
#   KERNEL_BRANCH   Kernel branch/tag        (default: v6.18)
#
set -euo pipefail

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
ID="${1:?Usage: $0 <ID> [--patch=<path>] [--keep]}"
KERNEL_PATCH=""
KEEP=false
NO_PERF=false
for arg in "${@:2}"; do
    case "$arg" in
        --patch=*) KERNEL_PATCH="${arg#*=}" ;;
        --no-perf) NO_PERF=true ;;
        --keep)    KEEP=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# --------------------------------------------------------------------------
# Config (override via env)
# --------------------------------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-default}"
KEY="${KEY:-$HOME/.ssh/id_rsa}"
KEYPAIR="${KEYPAIR:-default}"
PLACEMENT_GROUP="${PLACEMENT_GROUP:-pg-test}"
ITERS="${ITERS:-5}"
KERNEL_BRANCH="${KERNEL_BRANCH:-v6.18}"

DRV_EXPNAME="DRV_${ID}"
SUT_EXPNAME="SUT_${ID}"
DRV_RESOURCE="repro-results/${DRV_EXPNAME}.resources.json"
SUT_RESOURCE="repro-results/${SUT_EXPNAME}.resources.json"

# --------------------------------------------------------------------------
# Cleanup: terminate both instances (skipped with --keep)
# Registered as a trap so it also fires on error or Ctrl-C after launch.
# Instance IDs are populated once the resource JSONs exist.
# --------------------------------------------------------------------------
terminate_instances() {
    [ "${KEEP}" = "true" ] && return 0
    local ids=()
    for f in "${DRV_RESOURCE}" "${SUT_RESOURCE}"; do
        [ -f "${f}" ] || continue
        local id; id="$(jq -r '.instances[-1].instance_id // empty' "${f}" 2>/dev/null || true)"
        [ -n "${id}" ] && ids+=("${id}")
    done
    [ "${#ids[@]}" -eq 0 ] && return 0
    echo "=== Terminating instances: ${ids[*]} ==="
    AWS_PROFILE="${AWS_PROFILE}" aws --profile "${AWS_PROFILE}" --no-cli-pager \
        ec2 terminate-instances --instance-ids "${ids[@]}" \
        --query 'TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}' \
        --output table
}
trap terminate_instances EXIT

# --------------------------------------------------------------------------
# [1/5] Launch DRV (Ubuntu 22.04, no data disks)
# --------------------------------------------------------------------------
echo "=== [1/5] Launching DRV (${DRV_EXPNAME}) ==="
AWS_PROFILE="${AWS_PROFILE}" \
    EXPNAME="${DRV_EXPNAME}" \
    INSTANCE_TYPE=m8g.24xlarge \
    KEYPAIR="${KEYPAIR}" \
    AMI=UBUNTU2204 \
    ROOT_DISK_SIZE=256 \
    ROOT_DISK_TYPE=gp3 \
    PLACEMENT_GROUP_NAME="${PLACEMENT_GROUP}" \
    scripts/aws_create_instance.sh

# --------------------------------------------------------------------------
# [2/5] Launch SUT (AL2023 with 6.12 kernel + 12 io2 data disks)
# --------------------------------------------------------------------------
echo "=== [2/5] Launching SUT (${SUT_EXPNAME}) ==="
AWS_PROFILE="${AWS_PROFILE}" \
    EXPNAME="${SUT_EXPNAME}" \
    INSTANCE_TYPE=m8g.24xlarge \
    KEYPAIR="${KEYPAIR}" \
    AMI=AL2023_K6.12 \
    EBS_DISKS_NUMBER=12 \
    EBS_DISKS_SIZE=1024 \
    EBS_DISKS_TYPE=io2 \
    EBS_DISKS_IOPS=32000 \
    ROOT_DISK_SIZE=256 \
    ROOT_DISK_TYPE=gp3 \
    PLACEMENT_GROUP_NAME="${PLACEMENT_GROUP}" \
    scripts/aws_create_instance.sh

# --------------------------------------------------------------------------
# Parse IPs from resource JSON files written by aws_create_instance.sh
# --------------------------------------------------------------------------
DRV_PUB="$(jq -r  '.instances[-1].public_ip'  "${DRV_RESOURCE}")"
DRV_PRIV="$(jq -r '.instances[-1].private_ip' "${DRV_RESOURCE}")"
SUT_PUB="$(jq -r  '.instances[-1].public_ip'  "${SUT_RESOURCE}")"
SUT_PRIV="$(jq -r '.instances[-1].private_ip' "${SUT_RESOURCE}")"
DRV_USER="ubuntu"    # UBUNTU2204
SUT_USER="ec2-user"  # AL2023_K6.12

echo "DRV: ${DRV_USER}@${DRV_PUB}  (private ${DRV_PRIV})"
echo "SUT: ${SUT_USER}@${SUT_PUB}  (private ${SUT_PRIV})"

# --------------------------------------------------------------------------
# [3/5] Build kernel on SUT — reboots at the end; SSH disconnect is expected
# --------------------------------------------------------------------------
echo "=== [3/5] Building kernel ${KERNEL_BRANCH} on SUT ==="
BUILD_ARGS=(-c "${SUT_USER}@${SUT_PUB}" -b "${KERNEL_BRANCH}" --yes)
[ -n "${KERNEL_PATCH}" ] && BUILD_ARGS+=(-p "${KERNEL_PATCH}")
[ "${NO_PERF}" = "true" ] && BUILD_ARGS+=(--no-perf)
# build_kernel.sh uses SSH_OPTIONS for the identity file in remote mode.
SSH_OPTIONS="-i ${KEY}" ./scripts/build_kernel.sh "${BUILD_ARGS[@]}"

echo "=== Waiting for SUT to come back after reboot (up to 6 min) ==="
sleep 30
for attempt in $(seq 1 36); do
    if ssh -i "${KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           "${SUT_USER}@${SUT_PUB}" exit 0 2>/dev/null; then
        break
    fi
    echo "  attempt ${attempt}/36 — SSH not ready, retrying in 10s ..."
    [ "${attempt}" -eq 36 ] && { echo "ERROR: SUT did not come back after reboot" >&2; exit 1; }
    sleep 10
done
NEW_KERNEL="$(ssh -i "${KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "${SUT_USER}@${SUT_PUB}" 'uname -r')"
echo "SUT is back. Kernel: ${NEW_KERNEL}"

# --------------------------------------------------------------------------
# [4/5] Sync workload files to both hosts
# --------------------------------------------------------------------------
echo "=== [4/5] Syncing workload files ==="
SCP_OPTS="-i ${KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# shellcheck disable=SC2086
timeout 60 scp ${SCP_OPTS} workloads/postgresql/main.sh \
    "${SUT_USER}@${SUT_PUB}":~/repro-collection/workloads/postgresql/main.sh
# shellcheck disable=SC2086
timeout 60 scp ${SCP_OPTS} workloads/postgresql/main.sh \
    "${DRV_USER}@${DRV_PUB}":~/repro-collection/workloads/postgresql/main.sh

# --------------------------------------------------------------------------
# [5/5] Run the reproduction
# --------------------------------------------------------------------------
echo "=== [5/5] Running reproduction (${ITERS} iterations) ==="
./repros/repro-postgresql-dirty-folios/run_multiple_times.sh \
    --ssh-sut="${SUT_PUB}" \
    --ssh-ldg="${DRV_PUB}" \
    --sut="${SUT_PRIV}" \
    --ldg="${DRV_PRIV}" \
    --ssh-sut-user="${SUT_USER}" \
    --ssh-ldg-user="${DRV_USER}" \
    --ssh-key="${KEY}" \
    --iters="${ITERS}"
