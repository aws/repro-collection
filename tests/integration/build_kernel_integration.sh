#!/usr/bin/env bash
#
# build_kernel_integration.sh - REAL end-to-end test for the remote-execution
# mode of scripts/build_kernel.sh (`build_kernel.sh -c USER@HOST ...`), run
# against an EXISTING host whose SSH details you pass on the command line.
#
# You bring the box (any reachable AL2023/dnf or Ubuntu/apt machine -- an EC2
# instance, a VM, bare metal, whatever); this test does NOT create or destroy
# any cloud resources. It drives build_kernel.sh's remote mode against your host
# in two phases -- the same "cheap pre-flight, then the expensive real thing"
# shape as the aws_create_instance integration test:
#
#   Phase 1 (pre-flight, cheap-ish): build_kernel.sh -c ... --config-only
#     Uploads the script + a patch, installs deps, clones the kernel tree,
#     applies the patch and seeds/tweaks .config on the REMOTE, then stops
#     before the compile. We then SSH in and assert the plumbing actually
#     landed (patch file present in the tree, EC2/ENA tweaks in .config).
#     No compile, no reboot -- so a broken flag/upload path is caught before
#     paying for a full build.
#
#   Phase 2 (the real thing, expensive): build_kernel.sh -c ... --yes
#     Full build + install + grub + reboot. build_kernel waits for the host to
#     come back; we then INDEPENDENTLY SSH in and assert the box actually
#     rebooted into the freshly built kernel: `uname -r` changed from the
#     baseline AND carries our LOCALVERSION suffix, and perf was installed.
#
# Both phases run against the SAME host (phase 2 reuses phase 1's cloned tree
# via `git fetch`).
#
# This is destructive to the TARGET host: Phase 2 builds+installs a kernel,
# makes it the default boot entry, and REBOOTS the machine. It therefore refuses
# to run without explicit confirmation (--yes or CONFIRM=yes) and prints the
# target up front. It does not touch any host but the one you point it at.
#
# Usage:
#   tests/integration/build_kernel_integration.sh --yes \
#     -c ec2-user@1.2.3.4 -i ~/.ssh/my-key.pem
#
#   # Quick, cheaper smoke: pre-flight (config-only) phase only, no compile/reboot:
#   tests/integration/build_kernel_integration.sh --yes \
#     -c ec2-user@1.2.3.4 -i ~/.ssh/my-key.pem --config-only
#
# Options / env:
#   -c, --connect USER@HOST   SSH target (required). Same form build_kernel takes.
#   -i, --key FILE            SSH private key; prepended to the SSH options.
#       --ssh-options "..."   Extra raw SSH options (merged with -i and the
#                             non-interactive defaults). Also read from the
#                             SSH_OPTIONS env var, like build_kernel itself.
#   --config-only             Run only Phase 1 (no compile, no reboot). Cheaper.
#   --yes | CONFIRM=yes       Required to actually run (Phase 2 reboots the box).
#   KERNEL_REPO               Kernel git repo to build (default: the Amazon Linux
#                             tree, so the built kernel boots on an AL2023 host).
#   KERNEL_BRANCH             Branch/tag to check out. MUST exist in KERNEL_REPO
#                             and should match the target's kernel line so the
#                             built kernel boots. Default is an AL2023 6.12 tag.
#   KERNEL_LOCALVERSION       LOCALVERSION suffix for the build (default -inttest).
#                             Phase 2 asserts the booted `uname -r` carries it.
#   JOBS                      Parallel build jobs (default: chosen remotely by
#                             build_kernel.sh -- the box's nproc -- when unset).
#   NO_PERF=true              Pass --no-perf (skip building perf; skips that check).
#
set -uo pipefail

# --------------------------------------------------------------------------
# Locate the script under test.
# --------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SUT="${ROOT}/scripts/build_kernel.sh"                 # script under test
[ -f "${SUT}" ] || { echo "cannot find ${SUT}" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Tunables (see header).
KERNEL_REPO="${KERNEL_REPO:-https://github.com/amazonlinux/linux.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-kernel6.12-6.12.68-92.122.amzn2023}"
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:--inttest}"
JOBS="${JOBS:-}"
NO_PERF="${NO_PERF:-false}"

# --------------------------------------------------------------------------
# Options.
# --------------------------------------------------------------------------
CONFIRM="${CONFIRM:-}"
CONFIG_ONLY="false"
REMOTE=""
KEY_FILE=""
EXTRA_SSH="${SSH_OPTIONS:-}"     # honour SSH_OPTIONS env, like build_kernel does
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--connect)  REMOTE="${2:-}"; shift ;;
        -i|--key)      KEY_FILE="${2:-}"; shift ;;
        --ssh-options) EXTRA_SSH="${2:-}"; shift ;;
        --config-only) CONFIG_ONLY="true" ;;
        --yes)         CONFIRM="yes" ;;
        -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/d; s/^#\( \|$\)//; p}' "$0"; exit 0 ;;
        *) echo "unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
info() { printf '%s[intg]%s %s\n' "${CYN}" "${RST}" "$*"; }
warn() { printf '%s[intg]%s %s\n' "${YEL}" "${RST}" "$*"; }
err()  { printf '%s[intg]%s %s\n' "${RED}" "${RST}" "$*" >&2; }

command -v ssh >/dev/null 2>&1 || { err "ssh not found in PATH (required)"; exit 2; }

TESTS=0 PASS=0 FAIL=0
check() {         # check <label> <expected> <actual>
    TESTS=$((TESTS+1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf '    %s✓%s %s\n' "${GRN}" "${RST}" "$1"
    else
        FAIL=$((FAIL+1)); printf '    %s✗%s %s  (expected [%s] got [%s])\n' "${RED}" "${RST}" "$1" "$2" "$3"
    fi
}
check_yes() {     # check_yes <label> <actual: yes|no>
    check "$1" "yes" "$2"
}
fail_now() {      # fail_now <label> -- record a failed assertion with a message
    TESTS=$((TESTS+1)); FAIL=$((FAIL+1)); printf '    %s✗%s %s\n' "${RED}" "${RST}" "$1"
}

# --------------------------------------------------------------------------
# Validate inputs.
# --------------------------------------------------------------------------
[ -n "${REMOTE}" ] || { err "no SSH target; pass -c USER@HOST (see --help)"; exit 2; }
case "${REMOTE}" in *@*) : ;; *) warn "target '${REMOTE}' has no user@; ssh will use your default user" ;; esac
if [ -n "${KEY_FILE}" ]; then
    [ -f "${KEY_FILE}" ] || { err "key file not found: ${KEY_FILE}"; exit 2; }
fi

# Build the SSH option string used BOTH for our own verification ssh and, via
# SSH_OPTIONS, for build_kernel's remote calls -- so both sides authenticate the
# same way. -i (if given) first, then the caller extras, then non-interactive
# defaults (no host-key prompts / known_hosts churn against throw-away boxes).
SSH_OPTS=""
[ -n "${KEY_FILE}" ] && SSH_OPTS="-i ${KEY_FILE}"
[ -n "${EXTRA_SSH}" ] && SSH_OPTS="${SSH_OPTS:+${SSH_OPTS} }${EXTRA_SSH}"
SSH_OPTS="${SSH_OPTS:+${SSH_OPTS} }-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

rssh() { command ssh ${SSH_OPTS} -o ConnectTimeout=10 "${REMOTE}" "$@"; }

# --------------------------------------------------------------------------
# Confirmation gate + target banner.
# --------------------------------------------------------------------------
PHASES="Phase 1 (config-only) + Phase 2 (full build + reboot)"
[ "${CONFIG_ONLY}" = "true" ] && PHASES="Phase 1 (config-only) ONLY"

cat <<BANNER

${YEL}============== REAL build_kernel integration test ==============${RST}
  Target  : ${REMOTE}
  Key     : ${KEY_FILE:-(none / from agent or default)}
  Kernel  : ${KERNEL_REPO} @ ${KERNEL_BRANCH}  (LOCALVERSION=${KERNEL_LOCALVERSION})
  Running : ${PHASES}
  This is DESTRUCTIVE to the target: Phase 2 builds+installs a kernel, makes it
  the default boot entry, and REBOOTS the machine (can take tens of minutes).
${YEL}================================================================${RST}

BANNER

if [ "${CONFIRM}" != "yes" ]; then
    err "Refusing to run without confirmation. Re-run with --yes (or CONFIRM=yes) once you've checked the target above."
    exit 3
fi

# --------------------------------------------------------------------------
# SSH reachability + baseline.
# --------------------------------------------------------------------------
wait_for_ssh() {         # wait until sshd answers (boot / reboot); ~5 min cap
    local n=0
    info "Waiting for SSH on ${REMOTE} ..."
    while ! rssh true >/dev/null 2>&1; do
        n=$((n+1))
        if [ "${n}" -gt 60 ]; then err "SSH never came up on ${REMOTE}"; return 1; fi
        sleep 5
    done
    info "SSH is up."
    return 0
}

if ! wait_for_ssh; then
    fail_now "target reachable over SSH"
    printf '\n%s%d CHECK(S) FAILED%s\n' "${RED}" "$((FAIL))" "${RST}"
    exit 1
fi
check_yes "target reachable over SSH" "yes"

# Baseline kernel (what the box currently boots) -- Phase 2 must change this.
BASELINE_KVER="$(rssh 'uname -r' 2>/dev/null | tr -d '[:space:]' || true)"
info "Baseline kernel on the box: ${BASELINE_KVER:-<unknown>}"

# build_kernel.sh's default remote KERNEL_DIR is ~/linux-next, evaluated as the
# SSH user's home ON THE REMOTE. Query it rather than guessing /home/<user>.
REMOTE_HOME="$(rssh 'printf %s "$HOME"' 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "${REMOTE_HOME}" ] || REMOTE_HOME="/home/${REMOTE%@*}"
REMOTE_KDIR="${REMOTE_HOME}/linux-next"
info "Remote kernel tree will be: ${REMOTE_KDIR}"

# --------------------------------------------------------------------------
# A pure-addition patch (creates a new file) applies cleanly to ANY kernel tree
# with `git apply`, so we can prove the patch upload+apply path without needing
# a context-matching diff against an unknown source tree.
# --------------------------------------------------------------------------
MARKER="bk_inttest_marker_$$.txt"
PATCH="${WORK}/marker.patch"
cat > "${PATCH}" <<PATCHEOF
--- /dev/null
+++ b/${MARKER}
@@ -0,0 +1,1 @@
+build_kernel integration test marker
PATCHEOF

# --------------------------------------------------------------------------
# Phase 1: remote --config-only. Cheap-ish gate on the whole remote pipeline.
# --------------------------------------------------------------------------
printf '\n%s== Phase 1: remote config-only (upload + deps + clone + patch + config) ==%s\n' "${CYN}" "${RST}"
info "Running build_kernel.sh -c ${REMOTE} --config-only ..."
if SSH_OPTIONS="${SSH_OPTS}" bash "${SUT}" \
        -c "${REMOTE}" \
        -r "${KERNEL_REPO}" -b "${KERNEL_BRANCH}" \
        -p "${PATCH}" \
        --config-only \
        >"${WORK}/phase1.log" 2>&1; then
    check_yes "config-only remote run exits 0" "yes"
else
    fail_now "config-only remote run exits 0"
    err "phase 1 output (tail):"; tail -n 25 "${WORK}/phase1.log" | sed 's/^/      /' >&2
fi

# The remote log build_kernel saves must exist.
check_yes "remote build log saved (~/build_kernel_*.log)" \
    "$(rssh 'ls -1 ~/build_kernel_*.log >/dev/null 2>&1 && echo yes || echo no')"

# The patch we uploaded must have been applied into the remote tree.
check_yes "uploaded patch applied on remote (marker file in tree)" \
    "$(rssh "test -f '${REMOTE_KDIR}/${MARKER}' && echo yes || echo no")"

# The EC2/ENA config tweaks must be in the generated .config on the remote.
# Assert CONFIG_NET_VENDOR_AMAZON=y: it is ALWAYS appended (unlike
# CONFIG_ENA_ETHERNET=m, which the script deliberately omits on the Amazon Linux
# tree, where a downstream ENA driver already builds ena.ko).
check_yes "EC2/ENA tweak present in remote .config (CONFIG_NET_VENDOR_AMAZON=y)" \
    "$(rssh "grep -q '^CONFIG_NET_VENDOR_AMAZON=y' '${REMOTE_KDIR}/.config' && echo yes || echo no")"

# --------------------------------------------------------------------------
# Phase 2: full build + reboot into the new kernel. The expensive real test.
# --------------------------------------------------------------------------
if [ "${CONFIG_ONLY}" = "true" ]; then
    warn "--config-only set: skipping the full build + reboot phase."
else
    printf '\n%s== Phase 2: full remote build + reboot (this can take a while) ==%s\n' "${CYN}" "${RST}"
    PERF_FLAG=(); [ "${NO_PERF}" = "true" ] && PERF_FLAG=(--no-perf)
    JOBS_FLAG=(); [ -n "${JOBS}" ] && JOBS_FLAG=(-j "${JOBS}")
    info "Running build_kernel.sh -c ${REMOTE} --yes (build + install + reboot) ..."
    if SSH_OPTIONS="${SSH_OPTS}" bash "${SUT}" \
            -c "${REMOTE}" \
            -r "${KERNEL_REPO}" -b "${KERNEL_BRANCH}" \
            -l "${KERNEL_LOCALVERSION}" \
            "${JOBS_FLAG[@]}" "${PERF_FLAG[@]}" \
            --yes \
            >"${WORK}/phase2.log" 2>&1; then
        check_yes "full remote build + reboot exits 0" "yes"
    else
        fail_now "full remote build + reboot exits 0"
        err "phase 2 output (tail):"; tail -n 30 "${WORK}/phase2.log" | sed 's/^/      /' >&2
    fi

    # build_kernel --yes already waited for the box to come back; re-confirm SSH
    # ourselves, then INDEPENDENTLY verify the running kernel.
    if wait_for_ssh; then
        NEW_KVER="$(rssh 'uname -r' 2>/dev/null | tr -d '[:space:]' || true)"
        info "Kernel after reboot: ${NEW_KVER:-<unknown>}"
        # It must have changed from what the box booted before ...
        check_yes "running kernel changed after reboot" \
            "$( [ -n "${NEW_KVER}" ] && [ "${NEW_KVER}" != "${BASELINE_KVER}" ] && echo yes || echo no )"
        # ... and it must carry the LOCALVERSION suffix we asked build_kernel for.
        check_yes "running kernel carries LOCALVERSION '${KERNEL_LOCALVERSION}'" \
            "$( case "${NEW_KVER}" in *"${KERNEL_LOCALVERSION}"*) echo yes ;; *) echo no ;; esac )"

        # perf built + installed on the box (unless we asked to skip it).
        if [ "${NO_PERF}" != "true" ]; then
            check_yes "perf installed on remote (/usr/local/bin/perf runs)" \
                "$(rssh '/usr/local/bin/perf --version >/dev/null 2>&1 && echo yes || echo no')"
        fi
    else
        fail_now "target reachable over SSH after reboot"
    fi
fi

# --------------------------------------------------------------------------
# Summary.
# --------------------------------------------------------------------------
printf '\n%s==================== Results ====================%s\n' "${CYN}" "${RST}"
printf '  assertions: %d   passed: %s%d%s   failed: %s%d%s\n' \
    "${TESTS}" "${GRN}" "${PASS}" "${RST}" "${RED}" "${FAIL}" "${RST}"
if [ "${FAIL}" -eq 0 ]; then
    printf '  %sALL CHECKS PASSED%s\n' "${GRN}" "${RST}"
    exit 0
else
    printf '  %s%d CHECK(S) FAILED%s\n' "${RED}" "${FAIL}" "${RST}"
    exit 1
fi
