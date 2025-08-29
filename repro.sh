#!/usr/bin/env bash
# Repro Framework main entry file for repro scenarios
#
# Example usage: repro.sh repro-mysql-EEVDF-regression SUT --sut=foo.example.com --loadgen=bar.example.com 2>&1 | tee -a ~/run.log | less -R

# default definitions
function scenario:help()
{
    echo "Repro scenario: ${SCENARIO_NAME} does not include a help function"
}
function scenario:workloads()
{
    : no dependencies by default
}
function scenario:install() {
    scenario:run_workload_step install
}
function scenario:configure() {
    scenario:run_workload_step configure
}
function scenario:run() {
    scenario:run_workload_step run
}
function scenario:results() {
    scenario:run_workload_step results
}
function scenario:cleanup() {
    scenario:run_workload_step cleanup
}

REPROMODE_INIT_ONLY=false
[ "$1" = "--init-only" ] && {
    REPROMODE_INIT_ONLY=true  # init only: don't run the repro, don't react to include errors
    shift
}

. "$(dirname "${BASH_SOURCE[0]}")/common/repromain.sh" ""
REPROCFG_SCENARIO_MODE=true
SCENARIO_PATH="${REPROCFG_ROOT}/repros/$1"
SCENARIO_NAME=$(basename "${SCENARIO_PATH}")
[ "$1" != "--help" ] && . "${SCENARIO_PATH}/main.sh" && repro:include_workloads $(scenario:workloads)
REPRO_INIT_OK=$?
$REPROMODE_INIT_ONLY && return $REPRO_INIT_OK
[ $REPRO_INIT_OK = 0 ] || {
    repro:help
    exit 1
}

shift
repro:scenario "$@"
