#!/usr/bin/env bats
#
# build_kernel.bats - Unit tests for scripts/build_kernel.sh
#
# Strategy: NO real kernel is ever built and NOTHING is installed or rebooted.
# Every external command the script shells out to (git, make, sudo, dracut,
# grubby, update-grub, update-initramfs, reboot, dnf/apt-get, ssh, scp) is
# shadowed by a fake first on PATH (tests/unit/helpers/fake_kernel.bash); the
# script runs under `env -i` for full isolation and each fake logs its argv so
# we assert on the exact command sequence. The package manager is chosen by
# which of dnf/apt-get is on PATH, so the SAME harness exercises both the AL2023
# (dracut+grubby) and Ubuntu (update-grub) paths. This is a port of the two
# hand-rolled suites tests/scripts/build_kernel.sh (local build) and
# tests/scripts/build_kernel_remote.sh (remote -c mode) into one bats file.
#
# Run:  bats tests/unit/scripts/build_kernel.bats
#       bats --filter "remote" tests/unit/scripts/build_kernel.bats

setup_file() {
    export SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/build_kernel.sh"
    [ -f "${SCRIPT}" ] || { echo "cannot find ${SCRIPT}" >&2; return 1; }
    make_fake_kernel_env
}

setup() {
    bats_load_library bats-support
    bats_load_library bats-assert
    fake_kernel_reset
}

load '../helpers/fake_kernel'

# Substring assertions on arbitrary strings (OUTPUT / OPS / SSHLOG / REMOTECMD).
assert_contains() { # <haystack> <needle>
    case "$1" in *"$2"*) return 0 ;; esac
    fail "expected to contain [$2]"$'\n'"in: $1"
}
assert_not_contains() { # <haystack> <needle>
    case "$1" in *"$2"*) fail "should NOT contain [$2]"$'\n'"in: $1" ;; esac
}

# require_tty: skip a PTY-dependent test when no script(1) is available. Gated
# on HAVE_SCRIPT (known at load time) so it can run *before* the invocation.
require_tty() { [ "${HAVE_SCRIPT:-0}" = "1" ] || skip "no PTY tool (script(1)) available"; }

# ==========================================================================
# 0. Static checks
# ==========================================================================

@test "static: script passes bash -n" {
    bash -n "${SCRIPT}"
}

@test "args: --help exits 0 and shows the synopsis" {
    run_script -- --help
    assert_equal "$RC" 0
    assert_contains "$OUTPUT" "build_kernel.sh - Download, patch, build"
    assert_contains "$OUTPUT" "--patch"
}

# ==========================================================================
# 1. Argument validation
# ==========================================================================

@test "args: unknown argument fails and names it" {
    run_script -- --bogus
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "Unknown argument"
}

@test "args: missing patch file fails early" {
    run_script -- -p "${BATS_TEST_TMPDIR}/does-not-exist.patch" --dir "$(freshdir 1)"
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "Patch file not found"
}

@test "args: no dnf/apt-get on PATH -> clean die (empty PATCHES[@] safe)" {
    # Drop both package managers so detection finds neither.
    rm -f "${FAKEBIN}/dnf" "${FAKEBIN}/apt-get"
    run_script -- --dir "$(freshdir 0)"
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "No supported package manager"
}

# ==========================================================================
# 2. AL2023 (dnf) config-only flow
# ==========================================================================

@test "dnf: --config-only clones, checks out, seeds config and stops before compile" {
    run_script -- --skip-deps --config-only --dir "$(freshdir 2)"
    assert_equal "$RC" 0
    assert_contains "$OPS" "git clone"
    assert_contains "$OPS" "checkout -f next-20260707"
    assert_contains "$OUTPUT" "Seeding .config"
    assert_contains "$OPS" 'scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS'
    assert_contains "$OPS" 'scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS'
    assert_contains "$OPS" "make olddefconfig"
    assert_not_contains "$OUTPUT" "Compiling kernel"
    assert_not_contains "$OPS" "dnf install"
}

@test "dnf: EC2/ENA tweaks land in the generated .config (upstream tree -> ENA forced on)" {
    # No downstream ENA driver in the tree (upstream / linux-next): the mainline
    # CONFIG_ENA_ETHERNET=m must be forced on so the box can network.
    run_script -- --skip-deps --config-only --dir "$(freshdir 2b)"
    CFG="$(cat "$(freshdir 2b)/.config" 2>/dev/null)"
    assert_contains "$CFG" "CONFIG_ENA_ETHERNET=m"
    assert_contains "$CFG" "CONFIG_NET_VENDOR_AMAZON=y"
    assert_contains "$CFG" "CONFIG_DEBUG_INFO_BTF=n"
}

@test "dnf: Amazon tree with downstream ENA -> CONFIG_ENA_ETHERNET not forced (avoids ena.ko clash)" {
    # When the tree already ships a downstream ENA driver (drivers/amazon/net/ena),
    # forcing the mainline CONFIG_ENA_ETHERNET=m too makes `make modules_check`
    # abort on a duplicate ena.ko. The script must NOT append it in that case, but
    # the other tweaks still apply.
    run_script FAKE_DOWNSTREAM_ENA=1 -- --skip-deps --config-only --dir "$(freshdir 2c)"
    assert_equal "$RC" 0
    CFG="$(cat "$(freshdir 2c)/.config" 2>/dev/null)"
    assert_not_contains "$CFG" "CONFIG_ENA_ETHERNET=m"
    assert_contains "$CFG" "CONFIG_NET_VENDOR_AMAZON=y"
    assert_contains "$CFG" "CONFIG_DEBUG_INFO_BTF=n"
    assert_contains "$OUTPUT" "Downstream Amazon ENA driver present"
}

# ==========================================================================
# 3. AL2023 (dnf) full build + install + grub
# ==========================================================================

@test "dnf: full flow compiles, installs modules+kernel, builds perf, wires grub" {
    run_tty FAKE_STDIN="n" -- --skip-deps --dir "$(freshdir 3)"
    assert_equal "$RC" 0
    assert_contains "$OUTPUT" "Compiling kernel"
    assert_contains "$OPS" "make INSTALL_MOD_STRIP=1 modules_install"
    assert_contains "$OPS" "make install"
    assert_contains "$OUTPUT" "Building + installing perf"
    assert_contains "$OPS" "dracut --force"
    assert_contains "$OPS" "grubby --add-kernel"
    assert_contains "$OPS" "--make-default"
    assert_contains "$OPS" "grubby --info=ALL"
}

@test "dnf: reboot prompt shown and declining with 'n' skips reboot" {
    require_tty
    run_tty FAKE_STDIN="n" -- --skip-deps --dir "$(freshdir 3p)"
    assert_contains "$OUTPUT" "Reboot now into"
    assert_contains "$OUTPUT" "Reboot skipped"
    assert_not_contains "$OPS" "sudo reboot"
}

@test "safety: non-interactive stdin never auto-reboots" {
    run_script -- --skip-deps --dir "$(freshdir 3n)"
    assert_equal "$RC" 0
    assert_contains "$OUTPUT" "Non-interactive shell"
    assert_not_contains "$OPS" "sudo reboot"
}

@test "dnf: existing grub entry -> set-default, not add-kernel" {
    run_script FAKE_GRUB_EXISTS=1 -- --skip-deps --dir "$(freshdir 3b)"
    assert_contains "$OPS" "grubby --set-default"
    assert_not_contains "$OPS" "grubby --add-kernel"
}

# ==========================================================================
# 4. Reboot modes
# ==========================================================================

@test "reboot: --yes reboots without a prompt" {
    run_script -- --skip-deps --yes --dir "$(freshdir 4a)"
    assert_equal "$RC" 0
    assert_contains "$OPS" "sudo reboot"
    assert_not_contains "$OUTPUT" "Reboot now into"
}

@test "reboot: --no-reboot prints the instruction and does not reboot" {
    run_script -- --skip-deps --no-reboot --dir "$(freshdir 4b)"
    assert_contains "$OUTPUT" "Not rebooting"
    assert_not_contains "$OPS" "sudo reboot"
}

@test "reboot: prompt + Enter (default yes) reboots" {
    require_tty
    run_tty FAKE_STDIN="" -- --skip-deps --dir "$(freshdir 4c)"
    assert_contains "$OPS" "sudo reboot"
}

@test "reboot: prompt + 'y' reboots" {
    require_tty
    run_tty FAKE_STDIN="y" -- --skip-deps --dir "$(freshdir 4d)"
    assert_contains "$OPS" "sudo reboot"
}

# ==========================================================================
# 5. Patches (repeatable -p, applied in order)
# ==========================================================================

@test "patches: two patches applied in the given order (P1 before P2)" {
    P1="${BATS_TEST_TMPDIR}/fix1.patch"; P2="${BATS_TEST_TMPDIR}/fix2.patch"
    : > "$P1"; : > "$P2"
    run_script -- --skip-deps --config-only -p "$P1" -p "$P2" --dir "$(freshdir 5)"
    assert_equal "$RC" 0
    assert_contains "$OPS" "git apply --stat ${P1}"
    assert_contains "$OPS" "git apply --check ${P1}"
    assert_contains "$OPS" "git apply ${P1}"
    assert_contains "$OPS" "git apply ${P2}"
    ORDER_OK=$(awk -v p1="git apply ${P1}" -v p2="git apply ${P2}" '
        $0==p1 && !seen2 {seen1=NR} $0==p2 {seen2=NR}
        END{ print (seen1 && seen2 && seen1<seen2) ? "yes" : "no" }' "${OPLOG}")
    assert_equal "$ORDER_OK" "yes"
}

@test "patches: an unappliable patch (--check fails) aborts with a clear message" {
    P1="${BATS_TEST_TMPDIR}/fix1.patch"; : > "$P1"
    run_script FAKE_PATCH_BAD=1 -- --skip-deps --config-only -p "$P1" --dir "$(freshdir 5b)"
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "does not apply cleanly"
}

# ==========================================================================
# 6. Ubuntu (apt) flow
# ==========================================================================

@test "apt: uses update-grub, not dracut/grubby, and warns about newest-by-default" {
    set_pkg apt
    run_script -- --skip-deps --dir "$(freshdir 6)"
    assert_equal "$RC" 0
    assert_contains "$OPS" "update-grub"
    assert_not_contains "$OPS" "dracut --force"
    assert_not_contains "$OPS" "grubby --add-kernel"
    assert_contains "$OUTPUT" "boots the newest kernel"
}

# ==========================================================================
# 7. Flag plumbing (repo/branch/jobs/localversion/no-perf)
# ==========================================================================

@test "flags: custom --repo/--branch/--localversion threaded through" {
    run_script -- --skip-deps --config-only \
        --repo https://example.com/linux.git --branch mytag \
        --dir "$(freshdir 7)" --localversion -custom
    assert_contains "$OPS" "git clone https://example.com/linux.git"
    assert_contains "$OPS" "checkout -f mytag"
    assert_contains "$OUTPUT" "LOCALVERSION: -custom"
}

@test "flags: custom --jobs threaded into make" {
    run_script -- --skip-deps --jobs 3 --dir "$(freshdir 7b)"
    assert_contains "$OPS" "make -j 3"
}

@test "flags: --no-perf skips the perf build" {
    run_script -- --skip-deps --no-perf --dir "$(freshdir 7d)"
    assert_not_contains "$OUTPUT" "Building + installing perf"
    assert_contains "$OUTPUT" "Skipping perf build"
}

@test "flags: perf lands at PERF_DEST on a normal run" {
    run_script -- --skip-deps --dir "$(freshdir 7e)"
    assert_contains "$OPS" "cp ${SRCROOT}/k7e/tools/perf/perf ${PERF}"
}

# ==========================================================================
# 8. Dependency install (recorders assert the step fires + names a package)
# ==========================================================================

@test "deps: dnf install invoked when deps not skipped, lists key packages" {
    run_script -- --config-only --dir "$(freshdir 8a)"
    assert_contains "$OPS" "dnf install -y"
    assert_contains "$OPS" "flex"
    assert_contains "$OPS" "grubby"
}

@test "deps: apt-get update+install invoked, lists key packages" {
    set_pkg apt
    run_script -- --config-only --dir "$(freshdir 8b)"
    assert_contains "$OPS" "apt-get update"
    assert_contains "$OPS" "apt-get install -y"
    assert_contains "$OPS" "build-essential"
    assert_contains "$OPS" "initramfs-tools"
}

# ==========================================================================
# 9. Existing-tree reuse + non-git dir rejection
# ==========================================================================

@test "tree: existing git tree -> fetch, not clone" {
    REUSE="$(freshdir 9)"; mkdir -p "${REUSE}/.git"
    run_script -- --skip-deps --config-only --dir "${REUSE}"
    assert_contains "$OPS" "fetch"
    assert_not_contains "$OPS" "git clone"
}

@test "tree: non-git existing dir rejected" {
    NOTGIT="${BATS_TEST_TMPDIR}/notgit"; mkdir -p "${NOTGIT}"; : > "${NOTGIT}/somefile"
    run_script -- --skip-deps --config-only --dir "${NOTGIT}"
    assert_equal "$RC" 1
    assert_contains "$OUTPUT" "not a git repo"
}

# ==========================================================================
# 10. Remote execution mode (-c USER@HOST): mocks ssh/scp, asserts on the
#     uploaded files and the constructed remote command.
# ==========================================================================

@test "remote: basic run uploads patch + script and runs bash -c remotely" {
    P="${BATS_TEST_TMPDIR}/test.patch"; echo "dummy patch" > "$P"
    run_script -- -c ec2-user@192.168.1.1 -p "$P" --yes
    assert_contains "$SSHLOG" "mkdir -p /tmp/build_kernel_patches"
    assert_contains "$SSHLOG" "test.patch ec2-user@192.168.1.1:/tmp/build_kernel_patches"
    assert_contains "$SSHLOG" "build_kernel.sh ec2-user@192.168.1.1:/tmp/build_kernel_remote"
    assert_contains "$SSHLOG" "bash -c"
}

@test "remote: multiple patches all uploaded" {
    P1="${BATS_TEST_TMPDIR}/fix1.patch"; P2="${BATS_TEST_TMPDIR}/fix2.patch"
    echo "patch 1" > "$P1"; echo "patch 2" > "$P2"
    run_script -- -c user@host -p "$P1" -p "$P2"
    assert_contains "$SSHLOG" "fix1.patch"
    assert_contains "$SSHLOG" "fix2.patch"
    N="$(grep -c "\.patch user@host:/tmp/build_kernel_patches" "${SSH_LOG}")"
    assert_equal "$N" 2
}

@test "remote: all flags passed through to the remote command" {
    P="${BATS_TEST_TMPDIR}/test.patch"; echo "patch" > "$P"
    run_script -- -c user@host -p "$P" \
        -r https://example.com/linux.git -b test-branch --no-perf --skip-deps --yes
    assert_contains "$REMOTECMD" "-p /tmp/build_kernel_patches/test.patch"
    assert_contains "$REMOTECMD" "-r https://example.com/linux.git"
    assert_contains "$REMOTECMD" "-b test-branch"
    assert_contains "$REMOTECMD" "--no-perf"
    assert_contains "$REMOTECMD" "--skip-deps"
    assert_contains "$REMOTECMD" "--yes"
}

@test "remote: SSH_OPTIONS are honored on the ssh/scp calls" {
    P="${BATS_TEST_TMPDIR}/test.patch"; echo "patch" > "$P"
    run_script SSH_OPTIONS="-i /path/to/key.pem -o StrictHostKeyChecking=no" \
        -- -c user@host -p "$P"
    assert_contains "$SSHLOG" "SSH: -i /path/to/key.pem -o StrictHostKeyChecking=no"
}

@test "remote: log file carries a YYYYMMDD_HHMMSS timestamp" {
    P="${BATS_TEST_TMPDIR}/test.patch"; echo "patch" > "$P"
    run_script -- -c user@host -p "$P"
    run grep -q "tee.*build_kernel_[0-9]\{8\}_[0-9]\{6\}\.log" "${SSH_LOG}"
    assert_equal "$status" 0
}

@test "remote: no patches -> uploads none but still uploads+runs the script" {
    run_script -- -c user@host --yes
    assert_not_contains "$SSHLOG" ".patch user@host"
    assert_contains "$SSHLOG" "build_kernel.sh user@host:/tmp/build_kernel_remote"
    assert_contains "$SSHLOG" "bash -c"
}

@test "remote: --yes triggers post-reboot verification" {
    run_script -- -c user@host --yes
    assert_contains "$OUTPUT" "Waiting for remote host to reboot"
    assert_contains "$OUTPUT" "Remote Kernel Verification"
    assert_contains "$OUTPUT" "New kernel"
}
