# Repro: PostgreSQL/pgbench huge-pages dirty-folio regression
# source this file, don't run it
#
# Provision the cluster ONCE, then loop N iterations of
#   restart PG -> load (DROP/CREATE DB + pgbench -i) -> restart PG -> run
# on the SAME cluster, so dirty-page / free-space / writeback-throttling state
# accumulates across iterations. That accumulation is the regression; a full
# install/configure/cleanup cycle per iteration would reset it.

: ${SCENARIO_ITERATIONS:=5}                # load+run iterations on the persistent cluster
: ${SCENARIO_RESTART_PG:=true}             # restart PG before each phase to flush shared_buffers
: ${SCENARIO_PHASE_TIMEOUT:=7200}
: ${SCENARIO_METRICS_PHASE_FILE:=${HOME}/.folio_metrics_phase}   # must match phase_file in files/dirty_metrics.sh

: ${PG_VERSION:=17}
: ${PG_HUGE_PAGES:=on}
: ${PG_SYSTEM_NR_HUGEPAGES:=on}
: ${PG_HUGEPAGE_PAD_PERCENT:=15}
: ${SYSTEM_TRANSPARENT_HUGE_PAGES:=never}

: ${PGBENCH_SCALE:=8470}
: ${PGBENCH_INIT_EXTRA_ARGS:=--fillfactor=90}
: ${PGBENCH_CLIENTS:=1024}
: ${PGBENCH_THREADS:=96}
: ${PGBENCH_DURATION:=600}
: ${PGBENCH_BUILTIN:=simple-update}
: ${PGBENCH_PROTOCOL:=prepared}

function scenario:help() {
    echo "Repro scenario: PostgreSQL/pgbench huge-pages dirty-folio regression."
    echo "Provisions a PostgreSQL cluster once, then loops ${SCENARIO_ITERATIONS} iterations of"
    echo "restart -> load -> restart -> run on the SAME persistent cluster so the"
    echo "writeback/dirty-page state accumulates (that accumulation is the regression)."
    echo
    echo "Requires a kernel with writeback throttling (verify wbt_lat_usec on the DB disk)."
    echo "Hosts: 1 SUT (database) + 1 LDG (pgbench). Run in parallel:"
    echo "  On the SUT: repro.sh ${SCENARIO_NAME} SUT --ldg=<LDG_address>"
    echo "  On the LDG: repro.sh ${SCENARIO_NAME} LDG --sut=<SUT_address>"
    echo "Per-iteration results are written to \${SCENARIO_RESULTS_PATH}/results-<i>.json on the LDG."
    echo "NOT resumable: an interrupted run must be restarted with --restart, because"
    echo "install/configure re-run and wipe the accumulated state being measured."
    echo "Knobs: SCENARIO_ITERATIONS (${SCENARIO_ITERATIONS}), SCENARIO_RESTART_PG (${SCENARIO_RESTART_PG}),"
    echo "       SCENARIO_PHASE_TIMEOUT (${SCENARIO_PHASE_TIMEOUT})."
}

function scenario:workloads() {
    echo "postgresql"
}

function scenario:restart_pg() {
    [ "${SCENARIO_RESTART_PG}" = "true" ] || return 0

    repro:cmd sudo systemctl restart postgresql || {
        repro:error "systemctl restart postgresql failed"
        return 1
    }
    postgresql:wait_ready local
}

function scenario:pre:run:sut() {
    local left
    left="$(repro:get_persistent_var "${SCENARIO_NAME}" PERSISTENT_STEP_COUNTER 0)"
    [ "${left:-0}" -eq 0 ] && return 0
    repro:error "Leftover state from an interrupted run (completed steps: ${left})."
    repro:error "This scenario cannot resume: install/configure re-ran and wiped the"
    repro:error "accumulated dirty/writeback state that the regression consists of."
    repro:fatal "Re-run with --restart to start from iteration 1."
}

# Provision via the default step flow, then loop on the persistent cluster.
function scenario:run:sut() {
    {
        local i
        for ((i = 1; i <= SCENARIO_ITERATIONS; i++)); do
            echo "repro:info \"Iteration ${i}/${SCENARIO_ITERATIONS}\""
            echo "scenario:restart_pg && scenario:start_phase ${i} load && repro:run postgresql SUT load"
            echo "scenario:restart_pg && scenario:start_phase ${i} run && repro:run postgresql SUT run"
        done
        echo "scenario:end_phases"
    } | repro:persistent_steps "${SCENARIO_NAME}"
}

# Release the LDG into <iter>:<phase> once PostgreSQL on this host is up.
function scenario:start_phase() {
    local iter="$1" phase="$2"

    echo "${iter}:${phase}" > "${SCENARIO_METRICS_PHASE_FILE}"
    repro:info "Releasing LDG into iteration ${iter} phase ${phase}"
    repro:wait_for_ldg "READY" "${iter}:${phase}"
}

# Tell the LDG the run is over so its loop can exit.
function scenario:end_phases() {
    repro:info "All iterations done; releasing the LDG"
    repro:wait_for_ldg "READY" "DONE"
}

function scenario:run:loadgen() {
    local label iter phase
    while true; do
        label="$(repro:wait_for_sut "READY" "${SCENARIO_PHASE_TIMEOUT}")" \
            || repro:fatal "SUT did not announce the next phase within ${SCENARIO_PHASE_TIMEOUT}s"
        [ "${label:-DONE}" = "DONE" ] && break
        iter="${label%%:*}"
        phase="${label#*:}"
        repro:info "Iteration ${iter}: phase ${phase}"
        case "${phase}" in
            load) repro:run postgresql LDG load ;;
            run)  WORKLOAD_RESULTS_FILE="${SCENARIO_RESULTS_PATH}/results-${iter}.json" \
                      repro:run postgresql LDG run results
                  [ -f "${SCENARIO_RESULTS_PATH}/results-${iter}.json" ] \
                      || repro:fatal "Iteration ${iter} produced no results-${iter}.json" ;;
            *) repro:fatal "Unknown phase '${phase}' in SUT label '${label}'" ;;
        esac
    done
}
