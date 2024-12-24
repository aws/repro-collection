#!/usr/bin/env bash
# ReproMark main entry file for repro scenarios
#
# Example usage: repro.sh repro-mysql-EEVDF-regression SUT --sut=foo.example.com --loadgen=bar.example.com 2>&1 | tee -a ~/run.log | less -R

# default definitions
function scenario:help()
{
    echo "Repro scenario: ${SCENARIO_NAME} does not include a help function"
}
function scenario:benchmarks()
{
    : no dependencies by default
}

. "$(dirname "${BASH_SOURCE[0]}")/common/repromark.sh" ""
REPROMARK_SCENARIO_MODE=true
SCENARIO_PATH="${REPROMARK_ROOT}/repros/$1"
SCENARIO_NAME=$(basename "${SCENARIO_PATH}")
[ "$1" != "--help" ] && . "${SCENARIO_PATH}/main.sh" && repro:include_benchmarks $(scenario:benchmarks) || {
    repro:help
    exit 1
}

shift
repro:scenario "$@"
