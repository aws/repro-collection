#!/usr/bin/env bash
#
# build_kernel.sh - Download, patch, build and install a Linux kernel on the
# current machine, then (optionally) reboot into it. Targets throw-away EC2
# repro/benchmark instances running Amazon Linux 2023 or Ubuntu.
#
# It clones a kernel tree, checks out a branch/tag, seeds .config from the
# running kernel, tweaks it for EC2/ENA (and blanks the distro signing keys so
# the build does not need vendor certs), applies any number of patches, builds
# the kernel + modules + perf, installs them, wires up the bootloader, and
# prompts to reboot.
#
# Distro handling is auto-detected:
#   * AL2023 (dnf)   -> dracut for initramfs, grubby for the boot entry/default.
#   * Ubuntu (apt)   -> `make install` hooks build the initramfs + update grub;
#                       we run update-grub as a belt-and-braces step.
#
# Examples
# --------
#   # linux-next @ next-20260707, two fixes, auto-reboot, all defaults:
#   scripts/build_kernel.sh -p fix1.patch -p fix2.patch --yes
#
#   # Amazon Linux kernel tag, custom source dir, do not reboot:
#   scripts/build_kernel.sh \
#     --repo https://github.com/amazonlinux/linux.git \
#     --branch kernel6.12-6.12.68-92.122.amzn2023 \
#     --dir ~/amzn-linux -p my-fix.patch --no-reboot
#
#   # Remote execution on EC2 instance with custom key:
#   SSH_OPTIONS="-i ~/.ssh/my-key.pem" scripts/build_kernel.sh \
#     -c ec2-user@192.168.1.100 -p fix.patch --yes
#
# Options
# -------
#   -p, --patch FILE     Patch to apply (repeatable, applied in the given order,
#                        via `git apply`). Paths are resolved before we cd into
#                        the source tree, so relative paths work.
#   -c, --connect USER@HOST  Execute on a remote system via SSH. Uploads patches
#                        and the script itself, runs remotely, streams output to
#                        local terminal, and saves log to ~/build_kernel_<timestamp>.log
#                        on the remote. Use SSH_OPTIONS env var for custom SSH flags.
#   -r, --repo URL       Kernel git repo to clone
#                        (default: git://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git)
#   -b, --branch REF     Branch/tag/commit to check out (default: next-20260707)
#   -d, --dir PATH       Kernel source directory (default: ~/linux-next).
#                        Reused if it already exists (fetch + checkout).
#   -j, --jobs N         Parallel build jobs (default: nproc)
#   -l, --localversion S LOCALVERSION suffix (default: -<short-commit-id>)
#       --config-only    Configure only; stop before compiling (dry-ish run)
#       --skip-deps      Do not install build dependencies
#       --no-perf        Do not build/install perf from the tree
#   -y, --yes            Reboot at the end without prompting
#       --no-reboot      Never reboot; just print the instruction
#   -h, --help           Show this help and exit
#
# Environment (advanced)
# ----------------------
#   SSH_OPTIONS          SSH options for remote execution (e.g., "-i /path/to/key.pem")
#   BOOT_DIR             Boot directory to read the running config from and to
#                        install the image/initramfs into (default: /boot).
#                        Useful for alt-boot/chroot builds and for testing.
#   PERF_DEST            Destination path for the built perf binary
#                        (default: /usr/local/bin/perf).
#
set -euo pipefail

# --------------------------------------------------------------------------
# Helpers (same style as aws_create_instance.sh)
# --------------------------------------------------------------------------
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m[INFO ]\033[0m %s\n'  "$*" >&2; }
warn() { printf '\033[33m[WARN ]\033[0m %s\n'  "$*" >&2; }
step() { printf '\033[32m[STEP ]\033[0m %s\n'  "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//; /^set -euo/d'; }

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
KERNEL_REPO="git://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git"
KERNEL_BRANCH="next-20260707"
KERNEL_DIR="${HOME}/linux-next"
JOBS="$(nproc)"
LOCALVERSION=""            # defaults to -<commit> once we know the commit id
CONFIG_ONLY=false
SKIP_DEPS=false
BUILD_PERF=true
REBOOT_MODE="prompt"       # prompt | yes | never
BOOT_DIR="${BOOT_DIR:-/boot}"   # overridable for chroot/alt-boot builds + tests
PERF_DEST="${PERF_DEST:-/usr/local/bin/perf}"   # where the built perf lands
REMOTE_HOST=""             # set via -c/--connect for remote execution
SSH_OPTIONS="${SSH_OPTIONS:-}"  # custom SSH flags (e.g., "-i key.pem")
PATCHES=()

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--patch)        PATCHES+=("$2"); shift 2 ;;
        -c|--connect)      REMOTE_HOST="$2"; shift 2 ;;
        -r|--repo)         KERNEL_REPO="$2"; shift 2 ;;
        -b|--branch)       KERNEL_BRANCH="$2"; shift 2 ;;
        -d|--dir)          KERNEL_DIR="$2"; shift 2 ;;
        -j|--jobs)         JOBS="$2"; shift 2 ;;
        -l|--localversion) LOCALVERSION="$2"; shift 2 ;;
        --config-only)     CONFIG_ONLY=true; shift ;;
        --skip-deps)       SKIP_DEPS=true; shift ;;
        --no-perf)         BUILD_PERF=false; shift ;;
        -y|--yes)          REBOOT_MODE="yes"; shift ;;
        --no-reboot)       REBOOT_MODE="never"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "Unknown argument: $1 (use --help)" ;;
    esac
done

# Resolve patch paths to absolute now, before we cd into the source tree.
PATCHES_ABS=()
for p in "${PATCHES[@]:-}"; do
    [ -z "${p}" ] && continue
    [ -f "${p}" ] || die "Patch file not found: ${p}"
    PATCHES_ABS+=("$(readlink -f "${p}")")
done

# --------------------------------------------------------------------------
# Remote execution mode
# --------------------------------------------------------------------------
if [ -n "${REMOTE_HOST}" ]; then
    info "Remote execution mode: uploading patches and script to ${REMOTE_HOST}"

    # Build SSH command with optional custom flags
    SSH_CMD="ssh ${SSH_OPTIONS}"
    SCP_CMD="scp ${SSH_OPTIONS}"

    # Create remote patch directory
    REMOTE_PATCH_DIR="/tmp/build_kernel_patches"
    ${SSH_CMD} "${REMOTE_HOST}" "mkdir -p ${REMOTE_PATCH_DIR}" || die "Failed to create remote patch directory"

    # Upload patches if any
    REMOTE_PATCHES_ABS=()
    if [ "${#PATCHES_ABS[@]}" -gt 0 ]; then
        for patch in "${PATCHES_ABS[@]}"; do
            patch_name="$(basename "${patch}")"
            info "Uploading patch: ${patch_name}"
            ${SCP_CMD} "${patch}" "${REMOTE_HOST}:${REMOTE_PATCH_DIR}/${patch_name}" || die "Failed to upload patch: ${patch}"
            REMOTE_PATCHES_ABS+=("${REMOTE_PATCH_DIR}/${patch_name}")
        done
    else
        info "No patches to upload"
    fi

    # Upload this script to remote home
    REMOTE_SCRIPT="/tmp/build_kernel_remote_$$.sh"
    info "Uploading script to ${REMOTE_HOST}:${REMOTE_SCRIPT}"
    ${SCP_CMD} "$0" "${REMOTE_HOST}:${REMOTE_SCRIPT}" || die "Failed to upload script"
    ${SSH_CMD} "${REMOTE_HOST}" "chmod +x ${REMOTE_SCRIPT}" || die "Failed to chmod script"

    # Build remote command (all flags except -c, with remote patch paths)
    REMOTE_CMD="${REMOTE_SCRIPT}"
    if [ "${#REMOTE_PATCHES_ABS[@]}" -gt 0 ]; then
        for patch in "${REMOTE_PATCHES_ABS[@]}"; do
            REMOTE_CMD+=" -p ${patch}"
        done
    fi
    [ -n "${KERNEL_REPO}" ] && REMOTE_CMD+=" -r ${KERNEL_REPO}"
    [ -n "${KERNEL_BRANCH}" ] && REMOTE_CMD+=" -b ${KERNEL_BRANCH}"
    [ "${KERNEL_DIR}" != "${HOME}/linux-next" ] && REMOTE_CMD+=" -d ${KERNEL_DIR}"
    [ "${JOBS}" != "$(nproc)" ] && REMOTE_CMD+=" -j ${JOBS}"
    [ -n "${LOCALVERSION}" ] && REMOTE_CMD+=" -l ${LOCALVERSION}"
    [ "${CONFIG_ONLY}" = "true" ] && REMOTE_CMD+=" --config-only"
    [ "${SKIP_DEPS}" = "true" ] && REMOTE_CMD+=" --skip-deps"
    [ "${BUILD_PERF}" = "false" ] && REMOTE_CMD+=" --no-perf"
    case "${REBOOT_MODE}" in
        yes)   REMOTE_CMD+=" --yes" ;;
        never) REMOTE_CMD+=" --no-reboot" ;;
    esac

    # Generate timestamp for log file
    LOG_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    REMOTE_LOG="\${HOME}/build_kernel_${LOG_TIMESTAMP}.log"

    # Execute remotely: stream to terminal + save log
    info "Executing remotely (log saved to ${REMOTE_LOG}):"
    info "Command: ${REMOTE_CMD}"
    # pipefail is essential here: without it the pipe's status is tee's (always
    # 0), so a remote build failure would be masked and we'd wrongly proceed.
    _ssh_rc=0
    ${SSH_CMD} "${REMOTE_HOST}" "bash -c 'set -o pipefail; ${REMOTE_CMD} 2>&1 | tee ${REMOTE_LOG}'" || _ssh_rc=$?
    # Exit 255 = SSH connection lost; acceptable only when --yes triggered a reboot.
    # Any other non-zero exit is a genuine build failure.
    if [ "${_ssh_rc}" -ne 0 ]; then
        [ "${REBOOT_MODE}" = "yes" ] && [ "${_ssh_rc}" -eq 255 ] \
            || die "Remote execution failed (exit ${_ssh_rc})"
    fi

    info "Build complete. Log saved on remote: ${REMOTE_LOG}"

    # If --yes was specified, wait for reboot and verify new kernel
    if [ "${REBOOT_MODE}" = "yes" ]; then
        info "Waiting for remote host to reboot (this may take 1-2 minutes)..."
        sleep 10  # Give the reboot command time to execute

        # Wait for SSH to become unavailable (host is rebooting)
        WAIT_DOWN=0
        while ${SSH_CMD} -o ConnectTimeout=2 "${REMOTE_HOST}" "true" >/dev/null 2>&1; do
            sleep 2
            WAIT_DOWN=$((WAIT_DOWN + 1))
            if [ "$WAIT_DOWN" -gt 30 ]; then
                warn "Remote host did not go down after 60s. It may have already rebooted."
                break
            fi
        done

        # Wait for SSH to become available again (host is back up)
        info "Waiting for remote host to come back online..."
        WAIT_UP=0
        while ! ${SSH_CMD} -o ConnectTimeout=5 "${REMOTE_HOST}" "true" >/dev/null 2>&1; do
            sleep 5
            WAIT_UP=$((WAIT_UP + 1))
            if [ "$WAIT_UP" -gt 60 ]; then
                die "Remote host did not come back online after 5 minutes"
            fi
            printf "." >&2
        done
        echo "" >&2

        # Fetch and display new kernel info
        info "Remote host is back online. Fetching kernel information..."

        NEW_KERNEL=$(${SSH_CMD} "${REMOTE_HOST}" "uname -r" 2>/dev/null || echo "unknown")
        KERNEL_VERSION=$(${SSH_CMD} "${REMOTE_HOST}" "uname -v" 2>/dev/null || echo "")

        # Try to extract build info from the remote log
        BUILD_INFO=$(${SSH_CMD} "${REMOTE_HOST}" "grep -E 'Commit:|Kernel version:|Image path:' ${REMOTE_LOG} 2>/dev/null" || true)

        cat >&2 <<REBOOT_SUMMARY

===================== Remote Kernel Verification =====================
  Remote host    : ${REMOTE_HOST}
  New kernel     : ${NEW_KERNEL}
  Build details  : ${REMOTE_LOG}

${BUILD_INFO}
======================================================================

REBOOT_SUMMARY
    else
        info "Remote build complete (reboot skipped)."
    fi

    exit 0
fi

# --------------------------------------------------------------------------
# Detect the package manager / distro family.
# --------------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v apt-get >/dev/null 2>&1; then
    PKG="apt"
else
    die "No supported package manager found (need dnf on AL2023 or apt on Ubuntu)"
fi
info "Package manager: ${PKG}"

# --------------------------------------------------------------------------
# 1. Requirements
# --------------------------------------------------------------------------
install_deps() {
    if [ "${SKIP_DEPS}" = "true" ]; then
        info "Skipping dependency install (--skip-deps)"
        return 0
    fi
    step "1. Installing build dependencies"
    if [ "${PKG}" = "dnf" ]; then
        # Wait for cloud-init to finish so its dnf transaction releases the RPM db lock.
        sudo cloud-init status --wait 2>/dev/null || true
        sudo dnf clean packages
        sudo dnf install -y \
            libdwarf-devel binutils-devel libcap-devel numactl-libs \
            libunwind-devel zlib-devel xz-devel libaio-devel \
            libtraceevent-devel libpfm-devel slang-devel systemtap-sdt-devel \
            perl-ExtUtils-Embed python-devel git libbabeltrace-devel \
            libzstd-devel libzstd gcc-c++ flex bison openssl-devel \
            elfutils-libelf-devel elfutils-devel numactl-devel \
            capstone-devel llvm-devel rust cargo make bc kmod cpio dracut grubby
    else
        sudo apt-get update -y
        # Ubuntu equivalents of the AL2023 list + core kernel-build deps.
        sudo apt-get install -y \
            build-essential flex bison libssl-dev libelf-dev libdw-dev \
            bc kmod cpio rsync git make g++ \
            libdwarf-dev binutils-dev libcap-dev libnuma-dev \
            libunwind-dev zlib1g-dev liblzma-dev libaio-dev \
            libtraceevent-dev libpfm4-dev libslang2-dev systemtap-sdt-dev \
            libperl-dev python3-dev libbabeltrace-dev libzstd-dev \
            libcapstone-dev llvm-dev clang rustc cargo \
            libncurses-dev initramfs-tools
    fi

    # dnf/apt can report success even when a package failed to land (e.g. a
    # dnf cache miss prints "[Errno 2] No such file..." yet still exits 0).
    # Verify the tools we actually depend on are on PATH before continuing.
    local missing=()
    for tool in git make gcc flex bison bc cpio; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    [ "${BUILD_PERF}" = "true" ] && { command -v cargo >/dev/null 2>&1 || missing+=("cargo"); }
    [ "${#missing[@]}" -eq 0 ] \
        || die "Build dependencies missing after install: ${missing[*]} (dependency install may have partially failed)"
}
install_deps

# --------------------------------------------------------------------------
# 2. Kernel code
# --------------------------------------------------------------------------
step "2. Fetching kernel source into ${KERNEL_DIR}"
if [ -d "${KERNEL_DIR}/.git" ]; then
    info "Reusing existing tree; fetching latest refs"
    git -C "${KERNEL_DIR}" fetch --tags --prune origin
elif [ -e "${KERNEL_DIR}" ]; then
    die "${KERNEL_DIR} exists but is not a git repo; move it aside or pass --dir"
else
    info "Cloning ${KERNEL_REPO}"
    git clone "${KERNEL_REPO}" "${KERNEL_DIR}"
fi

cd "${KERNEL_DIR}"
info "Checking out ${KERNEL_BRANCH}"
git checkout -f "${KERNEL_BRANCH}"

COMMIT_ID="$(git rev-parse --short HEAD)"
[ -n "${LOCALVERSION}" ] || LOCALVERSION="-${COMMIT_ID}"
info "Commit: ${COMMIT_ID}  LOCALVERSION: ${LOCALVERSION}"

# --------------------------------------------------------------------------
# 3. Config (seed from the running kernel, with fallbacks)
# --------------------------------------------------------------------------
step "3. Seeding .config"
RUNNING_CFG="${BOOT_DIR}/config-$(uname -r)"
if [ -f "${RUNNING_CFG}" ]; then
    info "Using ${RUNNING_CFG}"
    cp "${RUNNING_CFG}" "${KERNEL_DIR}/.config"
elif [ -f /proc/config.gz ]; then
    info "${RUNNING_CFG} not found; extracting /proc/config.gz"
    zcat /proc/config.gz > "${KERNEL_DIR}/.config"
elif [ -f "${KERNEL_DIR}/.config" ]; then
    info "${RUNNING_CFG} not found; reusing existing .config in source tree"
else
    # Last resort: pick the newest /boot/config-* available.
    FALLBACK_CFG="$(ls -t "${BOOT_DIR}"/config-* 2>/dev/null | head -n1 || true)"
    if [ -n "${FALLBACK_CFG}" ]; then
        info "${RUNNING_CFG} not found; falling back to ${FALLBACK_CFG}"
        cp "${FALLBACK_CFG}" "${KERNEL_DIR}/.config"
    else
        die "Cannot find any kernel config (tried ${RUNNING_CFG}, /proc/config.gz, ${BOOT_DIR}/config-*)"
    fi
fi

# --------------------------------------------------------------------------
# 4. Tweak config for EC2/ENA and drop distro signing keys
# --------------------------------------------------------------------------
step "4. Applying EC2/ENA + signing-key config tweaks"
cat >> .config << 'EOF'
CONFIG_NET_VENDOR_AMAZON=y
CONFIG_DEBUG_INFO_BTF=n
EOF

# ENA driver: mainline lives at drivers/net/ethernet/amazon/ena (CONFIG_ENA_ETHERNET).
# The Amazon Linux tree ALSO ships a downstream copy at drivers/amazon/net/ena,
# and both produce ena.ko -- enabling the mainline one on top of the downstream
# one makes `make modules_check` abort with a module-name conflict. So only force
# the mainline driver on when the tree has no downstream ENA (e.g. upstream /
# linux-next, where it's the only ENA and must be enabled for the box to network).
if [ -d "drivers/amazon/net/ena" ]; then
    info "Downstream Amazon ENA driver present; leaving CONFIG_ENA_ETHERNET as seeded (avoids ena.ko conflict)"
else
    printf 'CONFIG_ENA_ETHERNET=m\n' >> .config
fi

# Blank the trusted/revocation key lists so the build does not require the
# distro's vendor certificates (Ubuntu configs point these at canonical paths).
./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# --------------------------------------------------------------------------
# 5. Apply patches (in order), via git apply
# --------------------------------------------------------------------------
if [ "${#PATCHES_ABS[@]}" -gt 0 ]; then
    step "5. Applying ${#PATCHES_ABS[@]} patch(es)"
    for patch in "${PATCHES_ABS[@]}"; do
        info "Patch: ${patch}"
        git apply --stat "${patch}"
        git apply --check "${patch}" || die "Patch does not apply cleanly: ${patch}"
        git apply "${patch}"
        info "Applied: ${patch}"
    done
else
    info "5. No patches to apply"
fi

# --------------------------------------------------------------------------
# 6. Finalize config
# --------------------------------------------------------------------------
step "6. make olddefconfig"
make olddefconfig

if [ "${CONFIG_ONLY}" = "true" ]; then
    info "--config-only set: configuration complete, stopping before compile."
    info "Source tree: ${KERNEL_DIR}  (LOCALVERSION=${LOCALVERSION})"
    exit 0
fi

# --------------------------------------------------------------------------
# 7. Compile
# --------------------------------------------------------------------------
step "7. Compiling kernel (-j ${JOBS}, LOCALVERSION=${LOCALVERSION})"
make -j "${JOBS}" LOCALVERSION="${LOCALVERSION}"

# --------------------------------------------------------------------------
# 8. Install modules and kernel
# --------------------------------------------------------------------------
step "8. Installing modules + kernel"
sudo make INSTALL_MOD_STRIP=1 modules_install -j "${JOBS}" LOCALVERSION="${LOCALVERSION}"
sudo make install -j "${JOBS}" LOCALVERSION="${LOCALVERSION}"

# --------------------------------------------------------------------------
# 8b. Save .config to /boot so subsequent builds can find it after reboot
# --------------------------------------------------------------------------
_installed_rel="$(make -s kernelrelease LOCALVERSION="${LOCALVERSION}" 2>/dev/null || true)"
if [ -n "${_installed_rel}" ]; then
    sudo cp "${KERNEL_DIR}/.config" "${BOOT_DIR}/config-${_installed_rel}"
    info "Saved config to ${BOOT_DIR}/config-${_installed_rel}"
fi

# --------------------------------------------------------------------------
# 9. Perf
# --------------------------------------------------------------------------
if [ "${BUILD_PERF}" = "true" ]; then
    step "9. Building + installing perf"
    make -C "${KERNEL_DIR}/tools/perf" -j "${JOBS}"
    sudo cp "${KERNEL_DIR}/tools/perf/perf" "${PERF_DEST}"
    info "perf installed to ${PERF_DEST}"
else
    info "9. Skipping perf build (--no-perf)"
fi

# --------------------------------------------------------------------------
# 10. Determine the installed kernel release + vmlinuz path
# --------------------------------------------------------------------------
step "10. Resolving installed kernel version"
# `make kernelrelease` is the authoritative release string for this tree.
NEW_KERNEL_VER="$(make -s kernelrelease LOCALVERSION="${LOCALVERSION}" 2>/dev/null || true)"
if [ -n "${NEW_KERNEL_VER}" ] && [ -f "${BOOT_DIR}/vmlinuz-${NEW_KERNEL_VER}" ]; then
    NEW_KERNEL_PATH="${BOOT_DIR}/vmlinuz-${NEW_KERNEL_VER}"
else
    # Fallback: newest freshly-installed vmlinuz carrying our commit id.
    NEW_KERNEL_PATH="$(ls -t "${BOOT_DIR}"/vmlinu* 2>/dev/null | grep -v '\.old$' | grep "${COMMIT_ID}" | head -n1 || true)"
    [ -n "${NEW_KERNEL_PATH}" ] || NEW_KERNEL_PATH="$(realpath "${BOOT_DIR}/vmlinuz" 2>/dev/null || true)"
    NEW_KERNEL_VER="$(basename "${NEW_KERNEL_PATH}" | sed 's/^vmlinuz-//')"
fi
[ -n "${NEW_KERNEL_PATH}" ] && [ -e "${NEW_KERNEL_PATH}" ] \
    || die "Could not locate the installed kernel image under /boot"
info "New kernel: ${NEW_KERNEL_VER}"
info "Image path: ${NEW_KERNEL_PATH}"

# --------------------------------------------------------------------------
# 11-13. Bootloader wiring (distro-specific)
# --------------------------------------------------------------------------
if [ "${PKG}" = "dnf" ]; then
    step "11. Generating initramfs (make install does not on AL2023)"
    sudo dracut --force "${BOOT_DIR}/initramfs-${NEW_KERNEL_VER}.img" "${NEW_KERNEL_VER}"

    step "12. Adding grub entry and making it the default"
    # grubby --set-default fails if the entry is missing, so add it first.
    if sudo grubby --info="${NEW_KERNEL_PATH}" >/dev/null 2>&1; then
        info "Boot entry already exists; setting it as default"
        sudo grubby --set-default="${NEW_KERNEL_PATH}"
    else
        sudo grubby --add-kernel="${NEW_KERNEL_PATH}" \
            --initrd="${BOOT_DIR}/initramfs-${NEW_KERNEL_VER}.img" \
            --title="Custom Kernel ${NEW_KERNEL_VER}" \
            --copy-default --make-default
    fi

    step "13. Boot entries"
    sudo grubby --info=ALL || true
    sudo grubby --default-kernel || true
else
    # Ubuntu: `make install` runs the /etc/kernel/postinst.d hooks which build
    # the initramfs and refresh grub; update-grub again is a safe no-op resync.
    step "11-12. Refreshing grub (Ubuntu initramfs/grub handled by make install)"
    if [ ! -f "${BOOT_DIR}/initrd.img-${NEW_KERNEL_VER}" ]; then
        warn "initrd not found; generating it explicitly"
        sudo update-initramfs -c -k "${NEW_KERNEL_VER}"
    fi
    sudo update-grub

    step "13. Installed kernels"
    ls -1 "${BOOT_DIR}"/vmlinuz-* 2>/dev/null || true
    warn "Ubuntu grub boots the newest kernel by default. To pin a specific one,"
    warn "set GRUB_DEFAULT in /etc/default/grub and re-run 'sudo update-grub'."
fi

# --------------------------------------------------------------------------
# 14. Reboot
# --------------------------------------------------------------------------
cat >&2 <<SUMMARY

===================== Build complete =====================
  Source tree   : ${KERNEL_DIR}
  Commit        : ${COMMIT_ID}
  Kernel version: ${NEW_KERNEL_VER}
  Image         : ${NEW_KERNEL_PATH}
  perf          : $( [ "${BUILD_PERF}" = "true" ] && echo "${PERF_DEST}" || echo "not built" )
==========================================================

SUMMARY

do_reboot() { info "Rebooting now ..."; sudo reboot; }

case "${REBOOT_MODE}" in
    yes)
        do_reboot ;;
    never)
        info "Not rebooting (--no-reboot). Reboot into the new kernel with: sudo reboot" ;;
    prompt)
        # Default is YES; only an explicit 'n'/'no' declines.
        if [ -t 0 ]; then
            read -r -p "Reboot now into ${NEW_KERNEL_VER}? [Y/n] " ans || ans=""
            case "${ans}" in
                [Nn]|[Nn][Oo]) info "Reboot skipped. Run 'sudo reboot' when ready." ;;
                *)             do_reboot ;;
            esac
        else
            warn "Non-interactive shell; not rebooting. Run 'sudo reboot' when ready."
        fi
        ;;
esac
