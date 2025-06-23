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

. "$(dirname "${BASH_SOURCE[0]}")/common/repromain.sh" ""
REPROCFG_SCENARIO_MODE=true
SCENARIO_PATH="${REPROCFG_ROOT}/repros/$1"
SCENARIO_NAME=$(basename "${SCENARIO_PATH}")
[ "$1" != "--help" ] && . "${SCENARIO_PATH}/main.sh" && repro:include_workloads $(scenario:workloads) || {
    repro:help
    exit 1
}

shift
repro:scenario "$@"
