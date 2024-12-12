#!/usr/bin/env bash
# ReproMark main entry file
#
# Example usage: run.sh mysql SUT --sut=foo.example.com --loadgen=bar.example.com 2>&1 | tee ~/run.log | less -R

: ${REPROMARK_LOGLEVEL:=DEBUG}
: ${REPROMARK_ROOT:=$(realpath "$(dirname "${BASH_SOURCE[0]}")")}

. "${REPROMARK_ROOT}/common/repromark.sh"
[ -e "${REPROMARK_ROOT}/benchmarks/$1/main.sh" ] && . "${REPROMARK_ROOT}/benchmarks/$1/main.sh"

repro:main "$@"
