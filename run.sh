#!/usr/bin/env bash
# ReproMark main entry file
#
# Example usage: run.sh mysql SUT --sut=foo.example.com --loadgen=bar.example.com 2>&1 | tee -a ~/run.log | less -R

. "$(dirname "${BASH_SOURCE[0]}")/common/repromark.sh" "$1"
repro:run "$@"
