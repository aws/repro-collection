#!/usr/bin/env bash
# Repro Framework main entry file for workloads
#
# Example usage: run.sh mysql SUT --sut=foo.example.com --loadgen=bar.example.com 2>&1 | tee -a ~/run.log | less -R

. "$(dirname "${BASH_SOURCE[0]}")/common/repromain.sh" "$1"
repro:run "$@"
