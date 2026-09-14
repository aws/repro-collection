#!/usr/bin/env bash
#
# Launch a DRV + SUT pair, build a kernel on the SUT, push this tree to both, and
# run the repro-postgresql-dirty-folios scenario for ITERS iterations. Results,
# logs and manifest.env land in local_files/<ID>/; on failure, diagnostics from
# both hosts are collected there before the instances are terminated.
#
# Usage: $0 <ID> [options]
#   --patch=<path>  kernel patch to apply on the SUT (git am, else git apply)
#   --perf          build perf from the kernel tree (off by default)
#   --metrics       sample dirty/writeback state on the SUT during the run
#   --keep          do not terminate the instances afterwards
#   --reuse-hosts   reuse the instances recorded for <ID> (implies --keep)
#   --skip-kernel   also skip the kernel build, taking the running kernel as the
#                   one under test (implies --reuse-hosts)
#
# Env: AWS_PROFILE KEY KEYPAIR PLACEMENT_GROUP ITERS KERNEL_BRANCH KERNEL_REPO
#      REPO_DIR METRICS_INTERVAL PGBENCH_DURATION ITER_DEADLINE_SECS
#      SUBNET_ID SG_ID (SG_ID must allow tcp/22 from here: the run is driven over
#      public SSH and a default VPC SG has no such rule)
#
set -euo pipefail

ID="${1:?Usage: $0 <ID> [--patch=<path>] [--perf|--no-perf] [--metrics] [--keep] [--reuse-hosts] [--skip-kernel]}"
KERNEL_PATCH=""
KEEP=false
NO_PERF=true
METRICS=false
REUSE_HOSTS=false
SKIP_KERNEL=false
for arg in "${@:2}"; do
    case "$arg" in
        --patch=*) KERNEL_PATCH="${arg#*=}" ;;
        --perf)    NO_PERF=false ;;
        --no-perf) NO_PERF=true ;;
        --metrics) METRICS=true ;;
        --keep)    KEEP=true ;;
        --reuse-hosts)  REUSE_HOSTS=true ;;
        --skip-kernel)  SKIP_KERNEL=true; REUSE_HOSTS=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
# Reused hosts must survive for the next attempt.
${REUSE_HOSTS} && KEEP=true

AWS_PROFILE="${AWS_PROFILE:-default}"
KEY="${KEY:-$HOME/.ssh/id_rsa}"
KEYPAIR="${KEYPAIR:-default}"
PLACEMENT_GROUP="${PLACEMENT_GROUP:-pg-test}"
ITERS="${ITERS:-5}"
KERNEL_BRANCH="${KERNEL_BRANCH:-v6.18}"
KERNEL_REPO="${KERNEL_REPO:-}"              # empty -> kernel_from_src.sh default
REPO_DIR="${REPO_DIR:-~/repro-collection}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-20}"        # let the SUT listen before the LDG connects
METRICS_INTERVAL="${METRICS_INTERVAL:-5}"
PGBENCH_DURATION="${PGBENCH_DURATION:-600}" # must match the scenario default
ITER_DEADLINE_SECS="${ITER_DEADLINE_SECS:-$(( (PGBENCH_DURATION + 3600) * 2 ))}"

INSTANCE_TYPE="${INSTANCE_TYPE:-m8g.24xlarge}"
ROOT_DISK_SIZE="${ROOT_DISK_SIZE:-256}"
ROOT_DISK_TYPE="${ROOT_DISK_TYPE:-gp3}"
SUT_DATA_DISKS="${SUT_DATA_DISKS:-12}"      # RAID0'd by the postgresql workload
SUT_DATA_DISK_SIZE="${SUT_DATA_DISK_SIZE:-1024}"
SUT_DATA_DISK_TYPE="${SUT_DATA_DISK_TYPE:-io2}"
SUT_DATA_DISK_IOPS="${SUT_DATA_DISK_IOPS:-32000}"

SUT_AMI="${SUT_AMI:-AL2023_K6.12}"
DRV_AMI="${DRV_AMI:-UBUNTU2204}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
AWS_CREATE="${ROOT}/util/aws_create_instance.sh"
KERNEL_BUILD="${ROOT}/util/kernel_from_src.sh"
[ -f "${AWS_CREATE}" ]   || { echo "cannot find ${AWS_CREATE}" >&2; exit 2; }
[ -f "${KERNEL_BUILD}" ] || { echo "cannot find ${KERNEL_BUILD}" >&2; exit 2; }

# The framework runs commands that trip errexit/nounset at source time.
set +eu
. "${ROOT}/repro.sh" --init-only 2>/dev/null
set -eu
command -v repro:resource:get >/dev/null 2>&1 \
    || { echo "ERROR: could not load the Repro Framework (${ROOT}/repro.sh)" >&2; exit 2; }

# tps_from / manifest_kv / kernel_ok / repo_dir_ok
. "${HERE}/files/folio-lib.sh"

[ -f "${KEY}" ] || { echo "ERROR: SSH key not found at ${KEY} (set KEY=<path>)" >&2; exit 2; }
repo_dir_ok "${REPO_DIR}" \
    || { echo "ERROR: refusing REPO_DIR='${REPO_DIR}' (must match [A-Za-z0-9._/~-]+ and not be ~, / or contain ..)" >&2; exit 2; }

DRV_EXPNAME="DRV_${ID}"
SUT_EXPNAME="SUT_${ID}"
DRV_RESOURCE="${ROOT}/local_files/${DRV_EXPNAME}.resources.env"
SUT_RESOURCE="${ROOT}/local_files/${SUT_EXPNAME}.resources.env"
LOCAL_RESULTS="${ROOT}/local_files/${ID}"
mkdir -p "${LOCAL_RESULTS}"

# args: <file> <KEY>
res_get() { repro:resource:get "$1" "$2"; }
# args: <file> <SUFFIX>  -> INSTANCE_<count>_<SUFFIX>, i.e. the last instance recorded
res_field() { local f="$1" n; n="$(res_get "$f" INSTANCE_COUNT)"; res_get "$f" "INSTANCE_${n:-1}_$2"; }

terminate_instances() {
    [ "${KEEP}" = "true" ] && return 0
    local ids=() f id n count
    for f in "${DRV_RESOURCE}" "${SUT_RESOURCE}"; do
        [ -f "${f}" ] || continue
        count="$(res_get "${f}" INSTANCE_COUNT)"
        for (( n = 1; n <= ${count:-0}; n++ )); do
            id="$(res_get "${f}" "INSTANCE_${n}_ID")"
            [ -n "${id}" ] && ids+=("${id}")
        done
    done
    [ "${#ids[@]}" -eq 0 ] && return 0
    echo "=== Terminating instances: ${ids[*]} ==="
    local region
    region="$(res_get "${SUT_RESOURCE}" REGION)"
    : "${region:=$(res_get "${DRV_RESOURCE}" REGION)}"
    aws --profile "${AWS_PROFILE}" ${region:+--region "${region}"} --no-cli-pager \
        ec2 terminate-instances --instance-ids "${ids[@]}" \
        --query 'TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}' \
        --output table || true   # "already shutting-down" is fine
}

# A kernel build costs ~1h, so pull everything needed to diagnose a failure off
# both hosts before they are terminated.
collect_diagnostics() {
    declare -F sut_ssh >/dev/null || return 0
    [ -n "${SUT_PUB:-}" ] || return 0
    local dir="${LOCAL_RESULTS}/diagnostics"
    mkdir -p "${dir}" || return 0
    echo "=== Collecting diagnostics into ${dir} ==="
    sut_ssh 'sudo journalctl -u postgresql --no-pager -n 2000' >"${dir}/sut_journal_postgresql.log" 2>&1 || true
    sut_ssh 'sudo tail -n 2000 /var/lib/pgsql/data/log/* 2>/dev/null' >"${dir}/sut_pg_server.log" 2>&1 || true
    sut_ssh 'sudo tail -n 500 /var/log/cloud-init-output.log' >"${dir}/sut_cloud_init.log" 2>&1 || true
    sut_ssh 'cat ~/.repro_state.* 2>/dev/null' >"${dir}/sut_repro_state.txt" 2>&1 || true
    sut_ssh 'tail -n 2000 /tmp/kernel_from_src.*/build.log 2>/dev/null' >"${dir}/sut_kernel_build.log" 2>&1 || true
    sut_ssh 'uname -a; free -g; df -h; cat /proc/meminfo | head -20' >"${dir}/sut_state.txt" 2>&1 || true
    [ -n "${DRV_PUB:-}" ] && {
        ldg_ssh 'tail -n 500 /var/log/cloud-init-output.log' >"${dir}/ldg_cloud_init.log" 2>&1 || true
        ldg_ssh 'cat ~/.repro_state.* 2>/dev/null' >"${dir}/ldg_repro_state.txt" 2>&1 || true
        # PGBENCH_LOG defaults under REPROCFG_TMP, i.e. <repo>/tmp.
        # shellcheck disable=SC2029
        ldg_ssh "tail -n 500 ${REPO_DIR}/tmp/pgbench_run.log 2>/dev/null" >"${dir}/ldg_pgbench.log" 2>&1 || true
    }
    return 0
}

on_exit() {
    local rc=$?
    [ "${rc}" -ne 0 ] && collect_diagnostics
    terminate_instances
}
# Exit rather than terminate here, so the EXIT trap does it exactly once.
on_signal() {
    trap - INT TERM EXIT
    echo "" >&2
    echo "=== Interrupted (signal) — collecting diagnostics, then terminating ===" >&2
    jobs -p | xargs -r kill 2>/dev/null || true
    collect_diagnostics
    terminate_instances
    exit 130
}
trap on_exit EXIT
trap on_signal INT TERM

# args: <expname> <resource_file> <ami> [EXTRA=value ...]
# `env` is required: bash would parse the spliced-in EXTRA=value words as the
# command name, not as assignments.
launch_instance() {
    local expname="$1" resource_file="$2" ami="$3"
    shift 3
    env AWS_PROFILE="${AWS_PROFILE}" \
        EXPNAME="${expname}" \
        RESOURCE_FILE="${resource_file}" \
        AMI="${ami}" \
        INSTANCE_TYPE="${INSTANCE_TYPE}" \
        KEYPAIR="${KEYPAIR}" \
        ROOT_DISK_SIZE="${ROOT_DISK_SIZE}" \
        ROOT_DISK_TYPE="${ROOT_DISK_TYPE}" \
        ASSOCIATE_PUBLIC_IP=true \
        SUBNET_ID="${SUBNET_ID:-}" \
        SG_ID="${SG_ID:-}" \
        PLACEMENT_GROUP_NAME="${PLACEMENT_GROUP}" \
        CLONE_REPO=false \
        "$@" \
        bash "${AWS_CREATE}"
}

# aws_create_instance.sh appends, so start from empty resource files -- but reap
# what is recorded first, so truncating cannot orphan a live instance. Under
# --keep the files stay: dropping them would lose the IDs of the instances the
# user asked to keep.
if ${REUSE_HOSTS}; then
    for _f in "${DRV_RESOURCE}" "${SUT_RESOURCE}"; do
        [ -f "${_f}" ] || { echo "ERROR: --reuse-hosts but ${_f} does not exist; run without it first." >&2; exit 2; }
    done
    echo "=== [1-2/5] Reusing the instances recorded for ${ID} ==="
else
    [ "${KEEP}" = "true" ] || { terminate_instances; rm -f "${DRV_RESOURCE}" "${SUT_RESOURCE}"; }

    echo "=== [1/5] Launching DRV (${DRV_EXPNAME}) ==="
    launch_instance "${DRV_EXPNAME}" "${DRV_RESOURCE}" "${DRV_AMI}"

    echo "=== [2/5] Launching SUT (${SUT_EXPNAME}) ==="
    launch_instance "${SUT_EXPNAME}" "${SUT_RESOURCE}" "${SUT_AMI}" \
        EBS_DISKS_NUMBER="${SUT_DATA_DISKS}" \
        EBS_DISKS_SIZE="${SUT_DATA_DISK_SIZE}" \
        EBS_DISKS_TYPE="${SUT_DATA_DISK_TYPE}" \
        EBS_DISKS_IOPS="${SUT_DATA_DISK_IOPS}"
fi

DRV_PUB="$(res_field "${DRV_RESOURCE}" PUBLIC_IP)"
DRV_PRIV="$(res_field "${DRV_RESOURCE}" PRIVATE_IP)"
SUT_PUB="$(res_field "${SUT_RESOURCE}" PUBLIC_IP)"
SUT_PRIV="$(res_field "${SUT_RESOURCE}" PRIVATE_IP)"
DRV_USER="$(res_field "${DRV_RESOURCE}" LOGIN_USER)"
SUT_USER="$(res_field "${SUT_RESOURCE}" LOGIN_USER)"
[ -n "${DRV_USER}" ] && [ -n "${SUT_USER}" ] \
    || { echo "ERROR: could not read the login user from the resource files" >&2; exit 1; }
[ -n "${DRV_PUB}" ] && [ -n "${SUT_PUB}" ] || { echo "ERROR: could not read instance IPs from resource files" >&2; exit 1; }

echo "DRV: ${DRV_USER}@${DRV_PUB}  (private ${DRV_PRIV})"
echo "SUT: ${SUT_USER}@${SUT_PUB}  (private ${SUT_PRIV})"

# Keepalive: the scenario runs for many minutes over a single ssh.
SSH_BASE="-i ${KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes"
sut_ssh() { ssh ${SSH_BASE} -o ConnectTimeout=10 "${SUT_USER}@${SUT_PUB}" "$@"; }
ldg_ssh() { ssh ${SSH_BASE} -o ConnectTimeout=10 "${DRV_USER}@${DRV_PUB}" "$@"; }

if ${SKIP_KERNEL}; then
    echo "=== [3/5] Skipping the kernel build (--skip-kernel) ==="
    RUNNING_KVER="$(sut_ssh 'uname -r' 2>/dev/null | tr -d '[:space:]')"
    [ -n "${RUNNING_KVER}" ] || { echo "ERROR: cannot read uname -r from the SUT" >&2; exit 1; }
    BUILT_KVER="${RUNNING_KVER}"
    PREV_KVER="${RUNNING_KVER}"
    echo "SUT kernel (assumed under test): ${RUNNING_KVER}"
else
    echo "=== [3/5] Building kernel ${KERNEL_BRANCH} on SUT ==="
    BUILD_ARGS=(--connect="${SUT_USER}@${SUT_PUB}" --version="${KERNEL_BRANCH}" --install --reboot)
    [ -n "${KERNEL_REPO}" ]   && BUILD_ARGS+=(--repo="${KERNEL_REPO}")
    [ "${NO_PERF}" = "true" ] && BUILD_ARGS+=(--no-perf)
    # kernel_from_src.sh takes patches as <patch-dir>/<tag>/*.patch.
    PATCH_STAGE=""
    if [ -n "${KERNEL_PATCH}" ]; then
        [ -f "${KERNEL_PATCH}" ] || { echo "ERROR: patch not found: ${KERNEL_PATCH}" >&2; exit 1; }
        PATCH_STAGE="$(mktemp -d)"
        mkdir -p "${PATCH_STAGE}/${KERNEL_BRANCH}"
        cp "${KERNEL_PATCH}" "${PATCH_STAGE}/${KERNEL_BRANCH}/"
        BUILD_ARGS+=(--patch-dir="${PATCH_STAGE}")
    fi

    PREV_KVER="$(sut_ssh 'uname -r' 2>/dev/null | tr -d '[:space:]')"
    echo "SUT kernel before build: ${PREV_KVER}"

    SSH_OPTIONS="${SSH_BASE}" bash "${KERNEL_BUILD}" "${BUILD_ARGS[@]}" 2>&1 \
        | tee "${LOCAL_RESULTS}/kernel_build.log"
    [ -n "${PATCH_STAGE}" ] && rm -rf "${PATCH_STAGE}"

    BUILT_KVER="$(sed -n 's/^KERNEL_FROM_SRC_RELEASE=//p' "${LOCAL_RESULTS}/kernel_build.log" | tail -n1 | tr -d '[:space:]')"
    [ -n "${BUILT_KVER}" ] || { echo "ERROR: the kernel build did not report a release (KERNEL_FROM_SRC_RELEASE); see ${LOCAL_RESULTS}/kernel_build.log" >&2; exit 1; }
    echo "Built kernel release: ${BUILT_KVER}"

    RUNNING_KVER="$(sut_ssh 'uname -r' 2>/dev/null | tr -d '[:space:]')"
    echo "SUT is back. Kernel: ${RUNNING_KVER}"
fi

kernel_ok "${RUNNING_KVER}" "${BUILT_KVER}" "${PREV_KVER}" "${SKIP_KERNEL}" || exit 1
${SKIP_KERNEL} || echo "OK: SUT booted the built kernel (${RUNNING_KVER}, was ${PREV_KVER})"

# Push the local tree so the instances run exactly what is checked out here.
echo "=== [4/5] Pushing the local tree to both hosts ==="
sync_to() {
    local dest="$1"
    # shellcheck disable=SC2086
    ssh ${SSH_BASE} -o ConnectTimeout=10 "${dest}" \
        "rm -rf ${REPO_DIR} && mkdir -p ${REPO_DIR}" || return 1
    # shellcheck disable=SC2086
    tar -C "${ROOT}" -cz \
        --exclude=.git --exclude=local_files \
        . 2>/dev/null \
        | ssh ${SSH_BASE} -o ConnectTimeout=10 "${dest}" "tar -C ${REPO_DIR} -xz" || return 1
}
sync_to "${SUT_USER}@${SUT_PUB}" || { echo "ERROR: pushing the tree to the SUT failed" >&2; exit 1; }
sync_to "${DRV_USER}@${DRV_PUB}" || { echo "ERROR: pushing the tree to the LDG failed" >&2; exit 1; }

REPO_COMMIT="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
git -C "${ROOT}" diff --quiet HEAD 2>/dev/null && REPO_DIRTY=false || REPO_DIRTY=true
echo "Pushed ${REPO_COMMIT}${REPO_DIRTY:+ (dirty=${REPO_DIRTY})} to both hosts"

# The scenario provisions once, then loops restart -> load -> restart -> run on
# the persistent cluster.
echo "=== [5/5] Running reproduction (${ITERS} iterations) ==="
SCEN="repro-postgresql-dirty-folios"
REMOTE_RESULTS="local_files"
SUT_LOG="${LOCAL_RESULTS}/repro_sut.log"
LDG_LOG="${LOCAL_RESULTS}/repro_ldg.log"

# Start fresh so the progress watcher only sees results from THIS run.
ldg_ssh "rm -f ~/${REMOTE_RESULTS}/results-*.json" 2>/dev/null || true

echo "  writing ${LOCAL_RESULTS}/manifest.env"
{
    manifest_kv RUN_ID "${ID}"
    manifest_kv RUN_STARTED_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    manifest_kv REPRO_COMMIT "${REPO_COMMIT}"
    manifest_kv REPRO_TREE_DIRTY "${REPO_DIRTY}"
    manifest_kv KERNEL_BRANCH "${KERNEL_BRANCH}"
    manifest_kv KERNEL_REPO "${KERNEL_REPO:-default}"
    manifest_kv KERNEL_BUILT_RELEASE "${BUILT_KVER}"
    manifest_kv KERNEL_RUNNING_RELEASE "${RUNNING_KVER}"
    manifest_kv KERNEL_PREV_RELEASE "${PREV_KVER}"
    # The patch hash, not just its name: this is what tells the patched arm from
    # the baseline arm.
    manifest_kv KERNEL_PATCH "${KERNEL_PATCH:+$(basename "${KERNEL_PATCH}")}"
    manifest_kv KERNEL_PATCH_SHA256 "${KERNEL_PATCH:+$(sha256sum "${KERNEL_PATCH}" | cut -d' ' -f1)}"
    manifest_kv ITERATIONS "${ITERS}"
    manifest_kv PGBENCH_DURATION "${PGBENCH_DURATION}"
    for _role in SUT DRV; do
        _f="${SUT_RESOURCE}"; [ "${_role}" = DRV ] && _f="${DRV_RESOURCE}"
        for _k in ID TYPE AMI AZ SUBNET PLACEMENT_GROUP PRIVATE_IP LOGIN_USER; do
            manifest_kv "${_role}_${_k}" "$(res_field "${_f}" "${_k}")"
        done
    done
    manifest_kv AWS_REGION "$(res_get "${SUT_RESOURCE}" REGION)"
    # Collected from the hosts, so this records what ran rather than what was asked for.
    manifest_kv SUT_OS "$(sut_ssh '. /etc/os-release && echo "${ID}-${VERSION_ID}"' 2>/dev/null | tr -d '[:space:]')"
    manifest_kv LDG_OS "$(ldg_ssh '. /etc/os-release && echo "${ID}-${VERSION_ID}"' 2>/dev/null | tr -d '[:space:]')"
    manifest_kv SUT_PG_VERSION "$(sut_ssh 'postgres --version 2>/dev/null || /usr/pgsql-*/bin/postgres --version 2>/dev/null' 2>/dev/null | head -n1 | tr -s '[:space:]' '_')"
    manifest_kv LDG_PGBENCH_VERSION "$(ldg_ssh 'pgbench --version' 2>/dev/null | head -n1 | tr -s '[:space:]' '_')"
    manifest_kv SUT_THP "$(sut_ssh 'cat /sys/kernel/mm/transparent_hugepage/enabled' 2>/dev/null | tr -d '[:space:]')"
    manifest_kv SUT_NR_HUGEPAGES "$(sut_ssh 'cat /proc/sys/vm/nr_hugepages' 2>/dev/null | tr -d '[:space:]')"
    # A "no regression" result means nothing if writeback throttling was off.
    manifest_kv SUT_WBT_LAT_USEC "$(sut_ssh 'for q in /sys/block/md*/queue/wbt_lat_usec /sys/block/[nvs]*/queue/wbt_lat_usec; do [ -e "$q" ] && echo "$(basename $(dirname $(dirname $q)))=$(cat $q)"; done' 2>/dev/null | tr '\n' ',' )"
    manifest_kv SUT_DISK_LAYOUT "$(sut_ssh 'lsblk -nro NAME,TYPE,SIZE,MOUNTPOINT | tr "\n" ";"' 2>/dev/null)"
    manifest_kv SUT_MEM_TOTAL_KB "$(sut_ssh "awk '/MemTotal/{print \$2}' /proc/meminfo" 2>/dev/null | tr -d '[:space:]')"
    manifest_kv SUT_NPROC "$(sut_ssh nproc 2>/dev/null | tr -d '[:space:]')"
} > "${LOCAL_RESULTS}/manifest.env"

REMOTE_METRICS_DIR="folio-metrics"
if [ "${METRICS}" = "true" ]; then
    echo "  --metrics: starting dirty/writeback sampler on the SUT (every ${METRICS_INTERVAL}s)"
    SAMPLER_REMOTE="${REPO_DIR}/repros/${SCEN}/files/dirty_metrics.sh"
    sut_ssh "rm -rf ~/${REMOTE_METRICS_DIR}; rm -f ~/.folio_metrics_phase ~/.folio_metrics_stop; \
             nohup bash ${SAMPLER_REMOTE} ${METRICS_INTERVAL} >~/folio_metrics_sampler.out 2>&1 &" \
        || echo "  WARN: failed to start metrics sampler"
fi

# shellcheck disable=SC2029,SC2086
ssh ${SSH_BASE} "${SUT_USER}@${SUT_PUB}" \
    "cd ${REPO_DIR} && SCENARIO_ITERATIONS=${ITERS} PGBENCH_DURATION=${PGBENCH_DURATION} SCENARIO_RESULTS_PATH=~/${REMOTE_RESULTS} ./repro.sh ${SCEN} SUT --ldg=${DRV_PRIV}" \
    >"${SUT_LOG}" 2>&1 &
_sut_pid=$!
sleep "${SLEEP_BETWEEN}"
# shellcheck disable=SC2029,SC2086
ssh ${SSH_BASE} "${DRV_USER}@${DRV_PUB}" \
    "cd ${REPO_DIR} && SCENARIO_ITERATIONS=${ITERS} PGBENCH_DURATION=${PGBENCH_DURATION} SCENARIO_RESULTS_PATH=~/${REMOTE_RESULTS} ./repro.sh ${SCEN} LDG --sut=${SUT_PRIV}" \
    >"${LDG_LOG}" 2>&1 &
_ldg_pid=$!

_iter_result_exists() { ldg_ssh "test -f ~/${REMOTE_RESULTS}/results-${1}.json" 2>/dev/null; }

# Report each iteration and copy its results back as soon as the LDG writes them.
SUMMARY=""
i=1
COLLECTED=0
while [ "${i}" -le "${ITERS}" ]; do
    printf '======== ITER %d / %d ========\n' "${i}" "${ITERS}"
    echo "loading"
    _waited=0

    while ! _iter_result_exists "${i}"; do
        # The LDG is the only producer of results-<i>.json, and the SUT drives the
        # phases, so either one gone means no result can still arrive. (Waiting for
        # both meant a dead LDG plus a SUT parked in repro:wait_for_ldg hung here.)
        if ! kill -0 "${_ldg_pid}" 2>/dev/null; then
            _iter_result_exists "${i}" && break
            echo "  (the load generator exited before iteration ${i} produced a result)" >&2
            break 2
        fi
        if ! kill -0 "${_sut_pid}" 2>/dev/null; then
            _iter_result_exists "${i}" && break
            echo "  (the SUT scenario exited before iteration ${i} produced a result)" >&2
            break 2
        fi
        # The LDG skips results-<i>.json when pgbench produced no tps and moves on,
        # so a later file appearing means this iteration will never arrive.
        if ldg_ssh "ls ~/${REMOTE_RESULTS}/results-*.json 2>/dev/null | grep -qv 'results-${i}\.json'" 2>/dev/null \
            && ldg_ssh "test -f ~/${REMOTE_RESULTS}/results-$((i+1)).json" 2>/dev/null; then
            echo "  (iteration ${i} produced no result but iteration $((i+1)) has one; treating ${i} as failed)" >&2
            break
        fi
        if [ "${_waited}" -ge "${ITER_DEADLINE_SECS}" ]; then
            echo "  (iteration ${i} exceeded its ${ITER_DEADLINE_SECS}s deadline; aborting the run)" >&2
            break 2
        fi
        sleep 10
        _waited=$(( _waited + 10 ))
    done
    _tps=""
    timeout 30 scp ${SSH_BASE} "${DRV_USER}@${DRV_PUB}:~/${REMOTE_RESULTS}/results-${i}.json" \
        "${LOCAL_RESULTS}/results-${i}.json" >/dev/null 2>&1 \
        && _tps="$(tps_from "${LOCAL_RESULTS}/results-${i}.json")" || true
    [ -n "${_tps}" ] && COLLECTED=$(( COLLECTED + 1 )) || _tps=NA
    printf 'iter=%d tps=%s\n' "${i}" "${_tps}"
    SUMMARY="${SUMMARY}iter=${i} tps=${_tps}"$'\n'

    # Pull this iteration's metrics while the SUT is still up.
    if [ "${METRICS}" = "true" ]; then
        timeout 30 scp ${SSH_BASE} \
            "${SUT_USER}@${SUT_PUB}:~/${REMOTE_METRICS_DIR}/dirty_metrics_iter_${i}_*.log" \
            "${LOCAL_RESULTS}/" >/dev/null 2>&1 || true
    fi
    i=$((i+1))
done

SUT_RC=0; LDG_RC=0
wait "${_sut_pid}" 2>/dev/null || SUT_RC=$?
wait "${_ldg_pid}" 2>/dev/null || LDG_RC=$?

if [ "${METRICS}" = "true" ]; then
    sut_ssh "touch ~/.folio_metrics_stop" 2>/dev/null || true
    sleep "$(( METRICS_INTERVAL + 2 ))"   # let the sampler finish its current tick
    timeout 60 scp ${SSH_BASE} "${SUT_USER}@${SUT_PUB}:~/${REMOTE_METRICS_DIR}/dirty_metrics_iter_*.log" \
        "${LOCAL_RESULTS}/" >/dev/null 2>&1 || true
    shopt -s nullglob; _mfiles=( "${LOCAL_RESULTS}"/dirty_metrics_iter_*.log ); shopt -u nullglob
    if [ "${#_mfiles[@]}" -gt 0 ]; then
        echo "=== METRICS: dirty/writeback samples copied to ${LOCAL_RESULTS}/ ==="
        printf '  %s\n' "${_mfiles[@]##*/}"
    else
        echo "WARN: no metrics files found (sampler may not have run)" >&2
    fi
fi

printf '\n=== SUMMARY ===\n%s' "${SUMMARY}"
echo "=== Done. Logs: ${SUT_LOG}, ${LDG_LOG} ==="
echo "Results, logs and manifest.env: ${LOCAL_RESULTS}/"

[ "${COLLECTED}" -ge "${ITERS}" ] \
    || { echo "FAILED: ${COLLECTED}/${ITERS} iterations produced a tps (SUT rc=${SUT_RC}, LDG rc=${LDG_RC})" >&2; exit 1; }
[ "${SUT_RC}" -eq 0 ] && [ "${LDG_RC}" -eq 0 ] \
    || { echo "FAILED: all ${ITERS} iterations produced a tps, but a scenario exited non-zero (SUT rc=${SUT_RC}, LDG rc=${LDG_RC})" >&2; exit 1; }
echo "OK: ${COLLECTED}/${ITERS} iterations produced a tps"
exit 0
