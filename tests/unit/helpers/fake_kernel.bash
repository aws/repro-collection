# fake_kernel.bash - shared Bats helper: hermetic fakes + runner for
# scripts/build_kernel.sh.
#
# Strategy (same spirit as fake_aws.bash): NO real kernel is ever built and
# NOTHING is installed or rebooted. Every external command build_kernel.sh
# shells out to (git, make, sudo, dracut, grubby, update-grub,
# update-initramfs, reboot, dnf/apt-get, ssh, scp, ...) is shadowed by a fake
# placed first on PATH. Each fake logs its full argv so a test can assert on the
# exact command sequence. The script runs under `env -i` for full isolation,
# with a curated "toolbox" of the real coreutils it needs as the only other
# thing on PATH -- so package-manager detection (dnf vs apt) is deterministic
# regardless of the host distro.
#
# Provides:
#   make_fake_kernel_env  - build the fake bin + toolbox (call from setup_file)
#   fake_kernel_reset     - per-test capture/scratch files (call from setup)
#   set_pkg dnf|apt       - choose which package manager the script detects
#   run_script ...        - run non-interactively (piped stdin)
#   run_tty ...           - run on a real PTY (exercises the reboot prompt)
#   freshdir N            - a fresh per-test --dir target
#
# run_script / run_tty set globals: RC, OUTPUT (combined), OPS (build oplog),
# SSHLOG (ssh/scp calls), REMOTECMD (extracted remote command).
#
# Usage in a .bats file:
#   load '../helpers/fake_kernel'
#   setup_file() { make_fake_kernel_env; }
#   setup()      { ...; fake_kernel_reset; }

# uname -r is faked to a fixed string so the config-seed path is deterministic.
FAKE_UNAME_R="6.6.0-fake"

make_fake_kernel_env() {
    export FAKEBIN="${BATS_FILE_TMPDIR}/bin"
    export TOOLBOX="${BATS_FILE_TMPDIR}/toolbox"
    export BOOT="${BATS_FILE_TMPDIR}/boot"
    mkdir -p "${FAKEBIN}" "${TOOLBOX}" "${BOOT}"

    # Seed a running-kernel config so step 3 (cp $BOOT/config-$(uname -r)) works.
    printf 'CONFIG_LOCALVERSION=""\n' > "${BOOT}/config-${FAKE_UNAME_R}"

    # --- git: clone creates a tree with scripts/config + tools/perf; rev-parse
    # prints a fixed short commit; checkout/fetch/apply are recorded no-ops
    # (apply --check fails when FAKE_PATCH_BAD=1 to exercise the reject path).
    cat > "${FAKEBIN}/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >> "${OPLOG}"
sub="${1:-}"
# support "git -C <dir> <sub> ..."
if [ "${sub}" = "-C" ]; then shift 2; sub="${1:-}"; fi
case "${sub}" in
    clone)
        dest="${@: -1}"
        mkdir -p "${dest}/scripts" "${dest}/tools/perf" "${dest}/.git"
        # FAKE_DOWNSTREAM_ENA=1 simulates the Amazon Linux tree, which ships a
        # downstream ENA driver here (in addition to the mainline one). The
        # script uses this dir's presence to decide whether to force
        # CONFIG_ENA_ETHERNET=m (skipped when present, to avoid an ena.ko clash).
        [ "${FAKE_DOWNSTREAM_ENA:-0}" = "1" ] && mkdir -p "${dest}/drivers/amazon/net/ena"
        # stub perf binary so `cp tools/perf/perf $PERF_DEST` (step 9) succeeds
        printf '#!/bin/sh\n' > "${dest}/tools/perf/perf"; chmod +x "${dest}/tools/perf/perf"
        # a minimal `scripts/config` the script calls with --set-str
        cat > "${dest}/scripts/config" <<'CFG'
#!/usr/bin/env bash
echo "scripts/config $*" >> "${OPLOG}"
CFG
        chmod +x "${dest}/scripts/config"
        ;;
    rev-parse) printf '%s\n' "${FAKE_COMMIT:-abc1234}" ;;
    apply)
        # forms: git apply --stat F | git apply --check F | git apply F
        if [ "${2:-}" = "--check" ] && [ "${FAKE_PATCH_BAD:-0}" = "1" ]; then
            echo "error: patch does not apply" >&2; exit 1
        fi
        ;;
    checkout)
        if [ "${FAKE_CHECKOUT_BAD:-0}" = "1" ]; then
            echo "error: pathspec not found" >&2; exit 1
        fi
        ;;
    fetch) : ;;
    *) : ;;
esac
FAKE

    # --- make: emulate the handful of invocations the script makes.
    # `kernelrelease` prints a deterministic version and pre-creates the matching
    # vmlinuz so version-detection's primary branch is taken. Everything else is
    # a recorded no-op. modules_install/install run via sudo (see below).
    cat > "${FAKEBIN}/make" <<'FAKE'
#!/usr/bin/env bash
echo "make $*" >> "${OPLOG}"
for a in "$@"; do
    case "$a" in
        kernelrelease)
            printf '%s\n' "${FAKE_KVER:-6.6.0-fake-abc1234}"
            touch "${BOOT_DIR:-/tmp}/vmlinuz-${FAKE_KVER:-6.6.0-fake-abc1234}" 2>/dev/null || true
            exit 0 ;;
    esac
done
exit 0
FAKE

    # --- sudo: strip the leading "sudo" (+ any -E / VAR=val) and exec the rest,
    # so `sudo make install` hits our fake make, `sudo dracut` our fake dracut,
    # etc. Record it too.
    cat > "${FAKEBIN}/sudo" <<'FAKE'
#!/usr/bin/env bash
echo "sudo $*" >> "${OPLOG}"
while [ $# -gt 0 ]; do
    case "$1" in
        -*) shift ;;
        *=*) shift ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] && exec "$@"
FAKE

    # --- simple recorders. sleep is a no-op so the remote reboot-wait loop is
    # instant. (dnf/apt-get are created on demand by set_pkg.)
    for cmd in dracut update-grub update-initramfs reboot sleep; do
        cat > "${FAKEBIN}/${cmd}" <<FAKE
#!/usr/bin/env bash
echo "${cmd} \$*" >> "\${OPLOG}"
FAKE
    done

    # --- grubby: --info=<path> fails unless FAKE_GRUB_EXISTS=1 (so we can test
    # both the add-kernel and the set-default branch); --info=ALL /
    # --default-kernel succeed quietly.
    cat > "${FAKEBIN}/grubby" <<'FAKE'
#!/usr/bin/env bash
echo "grubby $*" >> "${OPLOG}"
for a in "$@"; do
    case "$a" in
        --info=ALL|--default-kernel) exit 0 ;;
        --info=*) [ "${FAKE_GRUB_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;
    esac
done
exit 0
FAKE

    # --- ssh/scp: capture calls for the remote-execution tests. ssh also
    # extracts the remote command from `bash -c '<CMD> 2>&1 | tee <LOG>'` and
    # answers the post-reboot verification queries (uname/grep).
    cat > "${FAKEBIN}/ssh" <<'FAKE'
#!/usr/bin/env bash
echo "SSH: $*" >> "${SSH_LOG:-/dev/null}"
if [[ "$*" == *"bash -c"* ]]; then
    cmd=$(echo "$*" | sed -n "s/.*bash -c '\(.*\) 2>&1 | tee.*/\1/p")
    echo "REMOTE_CMD: ${cmd}" >> "${SSH_REMOTECMD:-/dev/null}"
fi
if [[ "$*" == *"uname -r"* ]]; then
    printf '%s\n' "${FAKE_REMOTE_KERNEL:-6.12.0-test}"
elif [[ "$*" == *"uname -v"* ]]; then
    printf '%s\n' "#1 SMP"
elif [[ "$*" == *"grep -E"* ]]; then
    printf '  Commit        : %s\n' "${FAKE_COMMIT:-abc1234}"
fi
exit 0
FAKE
    cat > "${FAKEBIN}/scp" <<'FAKE'
#!/usr/bin/env bash
echo "SCP: $*" >> "${SSH_LOG:-/dev/null}"
exit 0
FAKE

    # --- uname -r must be deterministic to match the seeded config file.
    cat > "${FAKEBIN}/uname" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "-r" ]; then printf '%s\n' "${FAKE_UNAME_R}"; else command uname "\$@"; fi
FAKE

    chmod +x "${FAKEBIN}"/*

    # --- toolbox: the REAL coreutils the script needs, so the runner PATH is
    # exactly FAKEBIN:TOOLBOX -- nothing else. This is what makes pkg-manager
    # detection deterministic (the host's real dnf/apt is never on PATH; only
    # the fake dropped by set_pkg is). `date` is here for the remote path.
    # NOTE: git/make/sudo/dracut/grubby/dnf/apt-get/reboot/ssh/scp/update-* are
    # deliberately EXCLUDED -- they come from FAKEBIN. cp/zcat stay REAL so the
    # config seed actually copies.
    local t src
    for t in bash sh env sed grep egrep cat ls head tail tr sort awk gawk \
             basename dirname readlink realpath uname nproc mkdir rmdir rm \
             chmod touch printf cut wc find test true false cp date gzip zcat; do
        src="$(type -P "$t" 2>/dev/null || true)"
        [ -n "${src}" ] && ln -sf "${src}" "${TOOLBOX}/$t"
    done
    export RUNNER_PATH="${FAKEBIN}:${TOOLBOX}"
}

# Per-test capture/scratch files live in the test's own tmpdir.
fake_kernel_reset() {
    export OPLOG="${BATS_TEST_TMPDIR}/oplog"
    export SSH_LOG="${BATS_TEST_TMPDIR}/ssh_log"
    export SSH_REMOTECMD="${BATS_TEST_TMPDIR}/ssh_remotecmd"
    export SRCROOT="${BATS_TEST_TMPDIR}/src"
    export PERF="${BATS_TEST_TMPDIR}/perf"
    : > "${OPLOG}"; : > "${SSH_LOG}"; : > "${SSH_REMOTECMD}"
    mkdir -p "${SRCROOT}"
    # Default to dnf; tests that need apt call `set_pkg apt` explicitly.
    set_pkg dnf
}

# Choose which package manager the script detects by dropping ONLY that binary
# on PATH. $1 = "dnf" | "apt".
set_pkg() {
    rm -f "${FAKEBIN}/dnf" "${FAKEBIN}/apt-get"
    if [ "$1" = "dnf" ]; then
        printf '#!/usr/bin/env bash\necho "dnf $*" >> "${OPLOG}"\n' > "${FAKEBIN}/dnf"
        chmod +x "${FAKEBIN}/dnf"
    else
        printf '#!/usr/bin/env bash\necho "apt-get $*" >> "${OPLOG}"\n' > "${FAKEBIN}/apt-get"
        chmod +x "${FAKEBIN}/apt-get"
    fi
}

# A fresh per-test source dir for --dir.
freshdir() { echo "${SRCROOT}/k$1"; }

# _invoke <tty:0|1> [FAKE_STDIN=...] [KEY=VAL ...] -- [script args ...]
# Everything before `--` is env for the target script (except FAKE_STDIN, which
# is harness-local: what we "type" at the reboot prompt); everything after is
# argv. With tty=1 a real PTY is allocated via script(1) so the interactive
# prompt is exercised; TTY_ACTIVE reflects whether that succeeded.
HAVE_SCRIPT="$(command -v script >/dev/null 2>&1 && echo 1 || echo 0)"
_invoke() {
    local tty="$1"; shift
    : > "${OPLOG}"; : > "${SSH_LOG}"; : > "${SSH_REMOTECMD}"
    local env_kv=() args=() seen_dd=0 a stdin_answer=""
    for a in "$@"; do
        if [ "${seen_dd}" = "0" ] && [ "$a" = "--" ]; then seen_dd=1; continue; fi
        if [ "${seen_dd}" = "0" ]; then
            case "$a" in
                FAKE_STDIN=*) stdin_answer="${a#FAKE_STDIN=}" ;;
                *)            env_kv+=("$a") ;;
            esac
        else
            args+=("$a")
        fi
    done
    # Write a self-contained runner so env/args survive the `script -c` string.
    # BASH_ENV / BASH_XTRACEFD / KCOV_BASH_XTRACEFD are forwarded through the
    # `env -i` barrier so kcov (make coverage) can instrument the script under
    # test -- without them the wiped environment hides it from the tracer.
    local runner="${BATS_TEST_TMPDIR}/runner.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec env -i PATH=%q HOME=%q OPLOG=%q BOOT_DIR=%q PERF_DEST=%q SSH_LOG=%q SSH_REMOTECMD=%q \\\n' \
            "${RUNNER_PATH}" "${HOME}" "${OPLOG}" "${BOOT}" "${PERF}" "${SSH_LOG}" "${SSH_REMOTECMD}"
        printf '  BASH_ENV=%q BASH_XTRACEFD=%q KCOV_BASH_XTRACEFD=%q \\\n' \
            "${BASH_ENV:-}" "${BASH_XTRACEFD:-}" "${KCOV_BASH_XTRACEFD:-}"
        for a in "${env_kv[@]:-}"; do [ -n "$a" ] && printf '  %q \\\n' "$a"; done
        printf '  bash %q' "${SCRIPT}"
        for a in "${args[@]:-}"; do printf ' %q' "$a"; done
        printf '\n'
    } > "${runner}"
    chmod +x "${runner}"
    RC=0; TTY_ACTIVE=0
    if [ "${tty}" = "1" ] && [ "${HAVE_SCRIPT}" = "1" ]; then
        TTY_ACTIVE=1
        OUTPUT="$(printf '%s\n' "${stdin_answer}" | script -qec "${runner}" /dev/null 2>&1 | tr -d '\r')" || RC=$?
    else
        OUTPUT="$(printf '%s\n' "${stdin_answer}" | "${runner}" 2>&1)" || RC=$?
    fi
    OPS="$(cat "${OPLOG}" 2>/dev/null)"
    SSHLOG="$(cat "${SSH_LOG}" 2>/dev/null)"
    REMOTECMD="$(cat "${SSH_REMOTECMD}" 2>/dev/null)"
}

# run_script: non-interactive (piped stdin). run_tty: real PTY for prompt tests.
run_script() { _invoke 0 "$@"; }
run_tty()    { _invoke 1 "$@"; }
