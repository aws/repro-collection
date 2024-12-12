# ReproMark common functions and settings
# source this file, don't run it

set -a
shopt -s dotglob expand_aliases extglob globstar nullglob xpg_echo
(return 0 2>/dev/null) || { echo "This file is meant to be sourced by individual repros. Please run one of the repro.sh scripts instead."; exit 1; }
[ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && { echo "Please use bash version 5 or higher."; exit 1; }

# ReproMark runtime parameters
: ${REPROMARK_LOGLEVEL:=INFO} # 0=FATAL, 1=ERROR, 2=WARN, 3=INFO, 4+=DEBUG
: ${REPROMARK_DYRUN:=false}
: ${REPROMARK_CLEANUP:=true} # whether to automatically run cleanup at the end
: ${REPROMARK_SUT:=localhost}
: ${REPROMARK_LOADGEN:=localhost}
: ${REPROMARK_SUPPORT:=""}
: ${REPROMARK_PORT:=31337}
# this shouldn't normally need manual tweaking
: ${REPROMARK_ROOT:=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")}

# Standard parameters for all benchmarks
: ${BENCHMARK_RESULTS_FILE:=~/results.json} # where the benchmark writes the parsed results
: ${BENCHMARK_RESULTS_FORMAT:=json} # json, csv, txt (as supported by the benchmark)
: ${BENCHMARK_SCHED_POLICY:=other} # other, batch, idle, fifo, rr
: ${BENCHMARK_SCHED_PRIORITY:=1}
[ "$BENCHMARK_SCHED_POLICY" != "fifo" -a "$BENCHMARK_SCHED_POLICY" != "rr" ] && BENCHMARK_SCHED_PRIORITY=0

# logging
exec 3>&1
function repro:log:single() {
    local i level="${1^^}" maxlevel=${REPROMARK_LOGLEVEL}
    local level_names=( FATAL ERROR WARN INFO DEBUG )
    local level_colors=( $'\033[1;31m' $'\033[31m' $'\033[33m' '' $'\033[36m' $'\033[m' )
    for i in "${!level_names[@]}"; do
        [ "${level}" = "${level_names[$i]}" ] && level=$i
        [ "${REPROMARK_LOGLEVEL}" = "${level_names[$i]}" ] && maxlevel=$i
    done
    [ $level -ge 0 ] || level=0
    [ $level -gt $maxlevel ] && return 0
    [ $level -ge ${#level_names[@]} ] && level=$i
    shift
    echo >&3 "${level_colors[$level]}[$(date '+%Y%m%d.%H%M%S')] [${level_names[$level]}] $*${level_colors[-1]}"
}
function repro:log() {
    if [ $# -lt 2 ]; then
        while read -r line; do
            repro:log:single "${1:-info}" "$line"
        done
    else
        repro:log:single "$@"
    fi
}
function repro:log_stderr() {
    while read -r line; do
        [[ "${line,,}" =~ error|fail|fatal ]] && repro:error "$line" || repro:warn "$line"
    done
}
function repro:debug() {
    repro:log debug "$@"
}
function repro:info() {
    repro:log info "$@"
}
function repro:warn() {
    repro:log warn "$@"
}
function repro:error() {
    repro:log error "$@"
}
function repro:fatal() {
    repro:log fatal "$@"
    exit 1
}

# print general and repro specific help
function repro:help() {
    echo "Usage: $0 <benchmark_name> SUT|loadgen|support [--dry-run] [--sut=<hostname>] [--loadgen|--support=<hostname> [...]] [install|configure|run|results|cleanup [...]]"
    echo "Default: --sut=localhost --loadgen=localhost (this is usually not what you want)"
    echo "Standard operations: install, configure, run, results, cleanup"
    echo
    [ -n "$1" ] && {
        echo "Benchmark: $1"
        declare -F "$1:help" &>/dev/null && "$1:help" "$@"
    }
    echo
    echo "Environment settings:"
    set | sed -n '/^REPROMARK_/p'
    set | sed -n '/^BENCHMARK_/p'
    [ -n "$1" ] && set | sed -n '/^'"$1"'_/p'
    echo
    repro:check_dependencies
}

# run an arbitrary command, from stdin or args
# the command is executed in an isolated subshell, don't rely on variables being passed on between invocations
# --force overrides the dry-run setting
function repro:cmd:single() {
    local force=false
    [ "$1" = "--force" ] && force=true && shift
    repro:debug "Running command: $@"
    $REPROMARK_DYRUN && ! $force && return 0
    eval "$@" 2> >(repro:log_stderr) | repro:log # Note: the pipe executes the command in a subshell
    local ret=${PIPESTATUS[0]}
    [ $ret -ne 0 ] && repro:error "Command returned $ret" || repro:info "Command returned $ret"
    return $ret
}
function repro:cmd() {
    local force
    [ "$1" = "--force" ] && force="--force" && shift
    if [ $# -eq 0 ]; then
        local tmpfile=$(mktemp /tmp/repro_cmd.XXXXXX)
        [ -z "$tmpfile" ] && repro:fatal "Could not create temporary file"
        read -r line
        [[ "$line" = \#!* ]] || echo "#!/usr/bin/env bash\nset -x" >$tmpfile
        echo "$line" >>$tmpfile
        cat >>$tmpfile
        chmod +x $tmpfile
        repro:log debug "Running command block:"
        cat $tmpfile | repro:log debug
        repro:cmd:single $force $tmpfile
        rm -f $tmpfile
    else
        repro:cmd:single $force "$@"
    fi
}

# install system packages
function repro:package:install() {
    local pkg_cmd
    if type -t apt-get >/dev/null; then pkg_cmd="apt-get install -y"
    elif type -t dpkg >/dev/null; then pkg_cmd="dpkg --install"
    elif type -t dnf >/dev/null; then pkg_cmd="dnf install -y"
    elif type -t yum >/dev/null; then pkg_cmd="yum install -y"
    elif type -t rpm >/dev/null; then pkg_cmd="rpm --install -v"
    elif type -t pkg >/dev/null; then pkg_cmd="pkg install"
    elif type -t pacman >/dev/null; then pkg_cmd="pacman -S --noconfirm"
    elif type -t brew >/dev/null; then pkg_cmd="brew install"
    elif type -t emerge >/dev/null; then pkg_cmd="emerge"
    elif type -t zypper >/dev/null; then pkg_cmd="zypper install -y"
    elif type -t nix >/dev/null; then pkg_cmd="nix-env -i"
    elif type -t flatpak >/dev/null; then pkg_cmd="flatpak install -y"
    elif type -t snap >/dev/null; then pkg_cmd="snap install"
    elif type -t apk >/dev/null; then pkg_cmd="apk add"
    else repro:fatal "Could not determine package manager for installs"; fi
    repro:debug "Installing packages: $@"
    $REPROMARK_DYRUN && return 0
    repro:cmd sudo $pkg_cmd "$@"
}

# update system packages
function repro:package:update() {
    local pkg_cmd
    if type -t apt-get >/dev/null; then pkg_cmd="apt-get update -y; apt-get upgrade -y; apt-get dist-upgrade -y"
    elif type -t dnf >/dev/null; then pkg_cmd="dnf upgrade --refresh -y"
    elif type -t yum >/dev/null; then pkg_cmd="yum update -y; yum upgrade -y"
    elif type -t pkg >/dev/null; then pkg_cmd="pkg update"
    elif type -t pacman >/dev/null; then pkg_cmd="pacman -Syu --noconfirm"
    elif type -t brew >/dev/null; then pkg_cmd="brew update; brew upgrade"
    elif type -t emerge >/dev/null; then pkg_cmd="emerge --sync"
    elif type -t zypper >/dev/null; then pkg_cmd="zypper update -y; zypper dup -y"
    elif type -t nix >/dev/null; then pkg_cmd="nix-channel --update"
    elif type -t flatpak >/dev/null; then pkg_cmd="flatpak update -y"
    elif type -t snap >/dev/null; then pkg_cmd="snap refresh"
    elif type -t apk >/dev/null; then pkg_cmd="apk update; apk upgrade"
    else repro:fatal "Could not determine package manager for updates"; fi
    repro:debug "Updating packages $@"
    $REPROMARK_DYRUN && return 0
    repro:cmd $(sed <<<"$pkg_cmd" 's/^/sudo /;s/;/; sudo /g')
}

# install repromark dependencies
function repro:check_dependencies() {
    repro:debug "Checking ReproMark dependencies"
    for cmd in realpath dirname sed nc sudo chmod cat rm; do
        type -t $cmd &>/dev/null && repro:debug "  OK: $cmd" || repro:error "  NOT FOUND: $cmd"
    done
}

# simple mustache templating: replace all "{{ var }}" instances in stdin with the value of "var"
# only simple variable substitution is supported (no arrays, conditionals, recursion, nesting, operators, etc)
# usage: repro:template [var[=<value>][:-<default_value>] [...]]
#   if no value is given for a variable, the value is taken from the env
#   if no variables are given at all, all env variables are accessible
#   the "var:-<default_value>" syntax is valid both on the command line and in the template file
function repro:template() {
    local minus_x=${-//[^x]}
    set +x
    local line token var default
    while read -r line; do
        while [ -n "$line" ]; do
            [[ $line =~ \{\{.*}} ]] || break
            token="${line%%{{*}"
            [ "$token" = "$line" ] && break
            echo -n "$token"
            line="${line#*{{}"
            [[ ! $line =~ ^[[:space:]]*[[:alnum:]_]+(:-.*)?[[:space:]]*}} ]] && echo -n '{{' && continue
            token=${line%%\}\}*}
            [[ $token =~ :- ]] && default="${token#*:-}" && token=${token%%:-*} || default=''
            token=${token// /}
            line="${line#*\}\}}"
            [ $# = 0 ] && echo -n "${!token:-$default}" && continue
            for var in "$@"; do
                [ "${var%%=*}" = "$token" -o "${var%%:-*}" = "$token" ] || continue
                [[ $var =~ :- ]] && default="${var#*:-}" && var=${var%%:-*}
                [[ $var =~ = ]] && echo -n "${var#*=}" || echo -n "${!token:-$default}"
                break
            done
        done
        echo "$line"
    done
    [ -n "$minus_x" ] && set -x || true
}

# wait for a file to appear; args: <file> [timeout_secs]
function repro:wait_for_file() {
    local minus_x=${-//[^x]}
    set +x
    repro:debug "Waiting for $1 to appear"
    $REPROMARK_DYRUN && return 0
    local count=0 retval=0
    while [ ! -e "$1" ]; do
        [ -n "$2" ] && [ $count -ge "$2" ] && repro:error "Timeout waiting for $1 to appear" && retval=1 && break
        sleep 1
        let count++
    done
    [ $retval -eq 0 ] && repro:debug "$1 took $count seconds to appear"
    [ -n "$minus_x" ] && set -x
    return $retval
}

# wait for a TCP port to open on the SUT and send a message; args: [message [timeout]]
# bash must be compiled with --enable-net-redirections
function repro:wait_for_sut() {
    local count=0 msg="$1" timeout="${2:-86400}"
    repro:debug "Waiting for SUT port ${REPROMARK_PORT} to be open"
    $REPROMARK_DYRUN && return 0
    while ! (echo "$msg" >/dev/tcp/${REPROMARK_SUT}/${REPROMARK_PORT}) &>/dev/null; do
        [ $count -ge $timeout ] && repro:error "Timeout waiting for SUT to be ready" && return 1
        sleep 1
        let count++
    done
}

# wait for loadgen to connect to our port and send a string; args: [message]
function repro:wait_for_ldg() {
    repro:debug "Waiting for loadgen to send signal"
    while true; do
        read -r line < <(nc -l -p ${REPROMARK_PORT}) || {
            repro:error "Could not read from port ${REPROMARK_PORT}"
            return 1
        }
        [ -z "$1" -o "$line" = "$1" ] && return 0
        repro:warn "Unexpected loadgen message: $line"
    done
}

# return default steps depending on repro and mode
function repro:default_steps() {
    local default_ops="install configure run results"
    $REPROMARK_CLEANUP && default_ops+=" cleanup"
    local opsub oplist op
    declare -F "$REPRO_NAME:default_steps:$REPRO_MODE" &>/dev/null && opsub=":$REPRO_MODE"
    declare -F "$REPRO_NAME:default_steps$opsub" &>/dev/null && "$REPRO_NAME:default_steps$opsub" && return
    for op in $default_ops; do
        for opsub in "" ":$REPRO_MODE"; do
            declare -F "$REPRO_NAME:$op$opsub" &>/dev/null && oplist+="$op " && break
        done
    done
    echo $oplist
}

function repro:main() {
    # support "<benchmark> --help" and "--help <benchmark>"
    [ "${1:---help}" = --help ] && { repro:help "$2"; return; }
    [ "${2:---help}" = --help ] && { repro:help "$1"; return; }

    REPRO_NAME="${1,,}"
    REPRO_MODE="${2,,}"
    REPRO_ROOT=$(realpath "$REPROMARK_ROOT/benchmarks/$REPRO_NAME")
    local loadgen_default=true support_default=true ops opargs=()
    shift 2

    case "$REPRO_MODE" in
        sut) ;;
        loadgen|ldg|driver|drv) REPRO_MODE=loadgen;;
        support|sup) REPRO_MODE=support;;
        *) repro:fatal "Unknown mode: '$REPRO_MODE'; use one of SUT, LDG|loadgen, SUP|support" ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) REPROMARK_DYRUN=true ;;
            --sut=*) REPROMARK_SUT="${1#*=}" ;;
            --loadgen=*|--ldg=*) $loadgen_default && REPROMARK_LOADGEN="" && loadgen_default=false; REPROMARK_LOADGEN+="${1#*=} " ;;
            --support=*|--sup=*) $support_default && REPROMARK_SUPPORT="" && support_default=false; REPROMARK_SUPPORT+="${1#*=} " ;;
            --*) opargs+=("$1") ;;
            -*) repro:fatal "Unknown option: $1" ;;
            *) break ;;
        esac
        shift
    done
    [ $# -gt 0 ] && ops=("$@") || ops=( $(repro:default_steps) )

    [ ${#ops[@]} -eq 0 ] && repro:fatal "No default operations found for repro $REPRO_NAME and mode $REPRO_MODE"
    for op in "${ops[@]}"; do
        [[ "$op" = --* ]] && opargs+=("$op") && continue
        declare -F "$REPRO_NAME:$op:$REPRO_MODE" &>/dev/null || declare -F "$REPRO_NAME:$op" &>/dev/null || repro:fatal "Repro '$REPRO_NAME' does not support operation '$op'"
    done

    repro:info "Repro: $REPRO_NAME"
    $REPROMARK_DYRUN && repro:info "Dry mode ON"
    repro:debug "Mode: $REPRO_MODE"
    repro:debug "SUT: $REPROMARK_SUT"
    [ -n "${REPROMARK_LOADGEN}" ] && repro:debug "Loadgen: ${REPROMARK_LOADGEN}"
    [ -n "${REPROMARK_SUPPORT}" ] && repro:debug "Support: ${REPROMARK_SUPPORT}"
    repro:debug "Operations: ${ops[*]}"

    repro:check_dependencies

    repro:debug ">>> cd $REPRO_ROOT"
    cd "$REPRO_ROOT"
    local opsub
    for op in "${ops[@]}"; do
        [[ "$op" = --* ]] && continue
        repro:info "Operation: $op"
        declare -F "$REPRO_NAME:$op:$REPRO_MODE" &>/dev/null && opsub=":$REPRO_MODE" || opsub=''
        repro:cmd --force "$REPRO_NAME:$op$opsub" "${opargs[@]}"  # the --force arg will run through each op regardless of dry mode; the dry setting will still be respected inside the op, if all commands are repro: friendly
    done
}
