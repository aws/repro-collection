#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_multiple_times.sh — drive the PostgreSQL/pgbench huge-pages regression
# Provision the cluster ONCE, then loop the benchmark N times against that
# PERSISTENT cluster so dirty-page / free-space / WBT state accumulates
# iteration-over-iteration. That accumulation is the regression.
#
# WHY THIS DIFFERS FROM A NAIVE `run.sh ... ` PER ITERATION:
#   The stock default step list is `install configure run results cleanup`. Running
#   the WHOLE list every iteration makes configure:sut wipe the datadir + re-`initdb`
#   a pristine cluster, and cleanup:sut drop the DB + stop PG — i.e. every iteration
#   starts from a clean filesystem/WBT state. That RESETS exactly the state that
#   needs to build up, so the collapse only shows up sporadically instead of every run.
#
#   The correct approach provisions once and the inner loop only re-loads the DB +
#   re-runs pgbench on the SAME cluster. We do that by splitting the steps:
#     ONCE  : SUT `install configure`   + LDG `install configure`   (fresh initdb, hugepages, PG up)
#     N x   : SUT `load run`            + LDG `load run`            (pgbench -i reload + benchmark)
#     END   : SUT `cleanup`             + LDG `cleanup`             (optional; drop DB, stop PG)
#   No `cleanup` between iterations => the cluster and its filesystem persist.
#
# REQUIRED ENVIRONMENT (set up the SUT first — NOT done by this script):
#   * kernel with writeback throttling enabled (Linux v6.18, WBT commit 8f5845e0743b;
#     verify: cat /sys/block/<dev>/queue/wbt_lat_usec == 2000).
#   * repro-collection checked out at the same path on BOTH SUT and LDG.
#   * key-based SSH from this controller to both hosts.
#
# The regression config (huge_pages=on + static 2MB pool sized to shared_buffers ~25% RAM,
# THP=never, heavy simple-update workload 1024 clients / large scale) is baked in as the
# SUT_ENV / LDG_ENV defaults below; override via --sut-env / --ldg-env if needed.
#
# Usage:
#   ./run_multiple_times.sh --ssh-sut=<pub_ip> --ssh-ldg=<pub_ip> --sut=<priv_ip> --ldg=<priv_ip> [--iters=5]
#
# SSH login users: --ssh-user=<u> sets BOTH hosts; override per host with --ssh-sut-user / --ssh-ldg-user
#   (e.g. AL2023 SUT=ec2-user, Ubuntu driver=ubuntu ->
#         --ssh-sut-user=ec2-user --ssh-ldg-user=ubuntu). Add --ssh-key=<path> for a non-default identity.
# ---------------------------------------------------------------------------
set -uo pipefail

SSH_USER="${SSH_USER:-ec2-user}"        # default login user for BOTH hosts (back-compat)
SSH_SUT_USER="${SSH_SUT_USER:-}"        # per-host override for the SUT  (falls back to SSH_USER)
SSH_LDG_USER="${SSH_LDG_USER:-}"        # per-host override for the LDG  (falls back to SSH_USER;
                                        #   e.g. AL2023 SUT=ec2-user, Ubuntu driver=ubuntu)
SSH_KEY="${SSH_KEY:-}"                  # optional identity file (adds -i <key> to every ssh)
ITERS=5
SSH_SUT="" SSH_LDG="" SUT="" LDG=""
REPRO_PATH="${REPRO_PATH:-~/repro-collection}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-20}"   # seconds to let the SUT side start listening before the LDG side connects
RESTART_PG="${RESTART_PG:-true}"       # restart PG before each iteration (flushes shared_buffers)
DO_CLEANUP="${DO_CLEANUP:-true}"       # drop DB + stop PG at the very end

# workload config that reproduces the regression (override via env if needed)
SUT_ENV="${SUT_ENV:-PG_VERSION=17 PG_HUGE_PAGES=on PG_SYSTEM_NR_HUGEPAGES=on PG_HUGEPAGE_PAD_PERCENT=15 SYSTEM_TRANSPARENT_HUGE_PAGES=never PG_SSL=on PG_JIT=on PG_MAX_PREPARED_TRANSACTIONS=0 PG_AUTOVACUUM_NAPTIME=15s PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.1 PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.05 PG_AUTOVACUUM_VACUUM_COST_LIMIT=1200 PG_LOG_AUTOVACUUM_MIN_DURATION=10s PG_VACUUM_COST_PAGE_MISS=5 PG_SHARED_PRELOAD_LIBRARIES=pg_stat_statements}"
LDG_ENV="${LDG_ENV:-PGBENCH_SCALE=8470 PGBENCH_INIT_EXTRA_ARGS='--fillfactor=90' PGBENCH_CLIENTS=1024 PGBENCH_THREADS=96 PGBENCH_DURATION=600 PGBENCH_BUILTIN=simple-update PGBENCH_PROTOCOL=prepared}"

for arg in "$@"; do case "$arg" in
    --ssh-sut=*) SSH_SUT="${arg#*=}";;
    --ssh-ldg=*) SSH_LDG="${arg#*=}";;
    --sut=*)     SUT="${arg#*=}";;
    --ldg=*)     LDG="${arg#*=}";;
    --iters=*)   ITERS="${arg#*=}";;
    --ssh-user=*) SSH_USER="${arg#*=}";;
    --ssh-sut-user=*) SSH_SUT_USER="${arg#*=}";;
    --ssh-ldg-user=*) SSH_LDG_USER="${arg#*=}";;
    --ssh-key=*) SSH_KEY="${arg#*=}";;
    --repro-path=*) REPRO_PATH="${arg#*=}";;
    --sut-env=*) SUT_ENV="${arg#*=}";;
    --ldg-env=*) LDG_ENV="${arg#*=}";;
    --no-restart-pg) RESTART_PG=false;;
    --no-cleanup) DO_CLEANUP=false;;
    -h|--help) sed -n '2,/^# ---/p' "$0"; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
esac; done
: "${SSH_SUT:=$SUT}"; : "${SSH_LDG:=$LDG}"
# per-host login users fall back to the shared SSH_USER when not overridden
: "${SSH_SUT_USER:=$SSH_USER}"; : "${SSH_LDG_USER:=$SSH_USER}"
[ -z "$SUT" ] || [ -z "$LDG" ] && { echo "ERROR: --sut and --ldg (private IPs) are required" >&2; exit 1; }

# Single-instance lock: a second concurrent controller would issue overlapping PG
# restarts and abort the in-flight benchmark. Refuse to start if another run holds it.
LOCKFILE="${LOCKFILE:-/tmp/run_multiple_times.sh.lock}"
exec 9>"$LOCKFILE" || { echo "ERROR: cannot open lock $LOCKFILE" >&2; exit 1; }
if ! flock -n 9; then
    echo "ERROR: another run_multiple_times.sh holds $LOCKFILE (pid $(cat "$LOCKFILE" 2>/dev/null)) — refusing to run concurrently" >&2
    exit 1
fi
echo $$ >&9

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30"
[ -n "$SSH_KEY" ] && SSH_OPTS="-i $SSH_KEY $SSH_OPTS"
sutssh(){ ssh $SSH_OPTS "${SSH_SUT_USER}@${SSH_SUT}" "$@"; }
ldgssh(){ ssh $SSH_OPTS "${SSH_LDG_USER}@${SSH_LDG}" "$@"; }

echo "=== reproduction: $ITERS iterations, SUT=${SSH_SUT_USER}@$SUT LDG=${SSH_LDG_USER}@$LDG ==="
echo "SUT kernel: $(sutssh 'uname -r')  wbt: $(sutssh 'cat /sys/block/$(lsblk -dno NAME|grep -m1 -E "nvme|xvd")/queue/wbt_lat_usec 2>/dev/null')"

# ---------------------------------------------------------------------------
# ONE-TIME provisioning: install + configure on both hosts (fresh initdb + hugepages + PG up).
# These two invocations handshake via the framework's `configure` nproc exchange.
# ---------------------------------------------------------------------------
echo "======== PROVISION (once) ========"
sutssh "cd ${REPRO_PATH} && ${SUT_ENV} ./run.sh postgresql SUT --ldg=${LDG} install configure" >/tmp/repro_provision_sut.log 2>&1 &
sleep "$SLEEP_BETWEEN"
ldgssh "cd ${REPRO_PATH} && ${LDG_ENV} ./run.sh postgresql LDG --sut=${SUT} install configure" >/tmp/repro_provision_ldg.log 2>&1
wait 2>/dev/null
echo "provision done (SUT: /tmp/repro_provision_sut.log, LDG: /tmp/repro_provision_ldg.log)"

# ---------------------------------------------------------------------------
# PER-ITERATION loop on the SAME persistent cluster with TWO restarts per iteration:
#   restart #1  -> then `load` step  (DROP/CREATE DB + pgbench -i reload = write flood)
#   restart #2  -> then `run`  step  (benchmark on COLD shared_buffers)
# Each step invocation handshakes via the framework's DONE exchange.
# ---------------------------------------------------------------------------
: >/tmp/repro_summary.txt
pg_restart(){ sutssh "sudo -n systemctl restart postgresql" >/dev/null 2>&1; }
for i in $(seq 1 "$ITERS"); do
  echo "======== ITER $i / $ITERS ========"

  # --- restart #1 (pre-load) + load step ---
  [ "$RESTART_PG" = true ] && pg_restart
  sutssh "cd ${REPRO_PATH} && ${SUT_ENV} ./run.sh postgresql SUT --ldg=${LDG} load" >/tmp/repro_sut_load_$i.log 2>&1 &
  sleep "$SLEEP_BETWEEN"
  ldgssh "cd ${REPRO_PATH} && ${LDG_ENV} ./run.sh postgresql LDG --sut=${SUT} load" >/tmp/repro_ldg_load_$i.log 2>&1
  wait 2>/dev/null

  # --- restart #2 (post-load, pre-benchmark -> cold buffers) + run step ---
  [ "$RESTART_PG" = true ] && pg_restart
  sutssh "cd ${REPRO_PATH} && ${SUT_ENV} ./run.sh postgresql SUT --ldg=${LDG} run" >/tmp/repro_sut_$i.log 2>&1 &
  sleep "$SLEEP_BETWEEN"
  ldgssh "cd ${REPRO_PATH} && ${LDG_ENV} ./run.sh postgresql LDG --sut=${SUT} run" >/tmp/repro_ldg_$i.log 2>&1
  wait 2>/dev/null

  tps=$(grep -oP 'tps = \K[0-9.]+(?= \((?:without|excluding))' /tmp/repro_ldg_$i.log | tail -1)
  echo "iter=$i tps=${tps:-<none>}"
  echo "iter=$i tps=${tps:-NA}" >> /tmp/repro_summary.txt
done

# ---------------------------------------------------------------------------
# END: optional cleanup (drop DB + stop PG).
# ---------------------------------------------------------------------------
if [ "$DO_CLEANUP" = true ]; then
  echo "======== CLEANUP ========"
  sutssh "cd ${REPRO_PATH} && ${SUT_ENV} ./run.sh postgresql SUT --ldg=${LDG} cleanup" >/tmp/repro_cleanup_sut.log 2>&1 || true
  ldgssh "cd ${REPRO_PATH} && ${LDG_ENV} ./run.sh postgresql LDG --sut=${SUT} cleanup" >/tmp/repro_cleanup_ldg.log 2>&1 || true
fi

echo "=== SUMMARY ==="; cat /tmp/repro_summary.txt
