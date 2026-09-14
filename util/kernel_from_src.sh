#!/bin/bash

[ "$1" = "--help" ] && {
    echo "Usage: $0 [--install] [--version=<kernel_tag>] [--path=<linux_dir>] [--repo=<git_repo>] [--reuse-build] [--offline-mode] [<config_option>=<value> [...]]"
    echo "       $0 --setup-only"
    echo "       $0 --help"
    echo "Build the Linux kernel (optionally download from repo and activate it after building)."
    echo "In offline mode, no packages are installed, and the git repo is not refreshed before building."
    echo "In setup only mode, packages are installed and the repo is cloned / updated, but nothing is built."
    echo "E.g.: $0 --install --version=v6.12 CONFIG_SCHED_DEBUG=y CONFIG_PROC_SYSCTL=y CONFIG_SYSCTL=y 2>&1 | tee build.log"
    exit 0
}
: ${setup_only:=false}     # default: don't quit after installing dependencies and cloning/updating repo
: ${offline_mode:=false}   # default: install packages and update repo before building
: ${install_kernel:=false} # default: just build the kernel, don't install it
: ${use_suse_repo:=false}  # default: use mainline Linux repo, not SUSE (only for SUSE hosts)
: ${reuse_build:=false}    # default: if the given tag is already built, assume the config hasn't changed and reuse the kernel
: ${BOOT_DIR:=/boot}       # where kernel configs/images live and get installed (override for chroot/alt-boot builds and tests)
# Bootloader paths, overridable like BOOT_DIR (also keeps a test run from
# touching the real /etc/default/grub or grub.cfg).
: ${GRUB_DEFAULT_FILE:=/etc/default/grub}   # distro grub defaults (GRUB_DEFAULT=...)
: ${GRUB2_CFG:=${BOOT_DIR}/grub2/grub.cfg}  # RPM/SUSE generated menu
: ${GRUB_CFG:=${BOOT_DIR}/grub/grub.cfg}    # Debian/Ubuntu generated menu
: ${PERF_DIR:=/usr/local/bin} # where the built perf binary is installed

function err_exit() {
    echo "FATAL: $@" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --setup-only) setup_only=true; offline_mode=false;;
        --offline-mode) offline_mode=true; setup_only=false;;
        --install) install_kernel=true; setup_only=false;;
        --path=*) LINUX_DIR="${1#*=}";;
        --repo=*) LINUX_REPO="${1#*=}";;
        --version=*) LINUX_TAG="${1#*=}";;
        --patch-dir=*) LINUX_PATCHDIR="${1#*=}";;
        --reuse-build) reuse_build=true;;
        --) shift; break;;
        --*) err_exit "Unknown argument: $1";;
        *) break;;
    esac
    shift
done

$offline_mode || {
    if type -t apt-get >/dev/null; then
        sudo apt-get update -y
        sudo apt-get upgrade -y
        sudo apt-get -y install build-essential flex bison fakeroot ncurses-dev xz-utils libssl-dev bc libelf-dev python3 python3-dev pkg-config
        sudo apt-get -y install dwarves libdwarf-dev libdw-dev binutils-dev libcap-dev libelf-dev libnuma-dev libssl-dev libunwind-dev zlib1g-dev liblzma-dev libaio-dev libtraceevent-dev debuginfod libpfm4-dev libslang2-dev systemtap-sdt-dev libperl-dev libbabeltrace-dev libiberty-dev libzstd-dev libzstd1
    elif type -t zypper >/dev/null; then
        sudo zypper --non-interactive update
        sudo zypper --non-interactive install -y -t pattern devel_basis  && \
        sudo zypper --non-interactive install -y -t pattern devel_kernel || \
        sudo zypper --non-interactive install -y -t pattern Basis-Devel
        #sudo zypper --non-interactive install -y git gcc flex bison ncurses-devel openssl-devel make  # TODO: fix build on older SUSE hosts
    elif type -t yum >/dev/null; then
        sudo yum update -y
        sudo yum upgrade -y
        sudo yum -y groupinstall 'Development Tools'
        sudo yum -y install flex bison ncurses-devel elfutils-libelf-devel openssl-devel dwarves
    else
        err_exit "Unknown package manager"
    fi
}

[ -z "$LINUX_DIR" ] && for LINUX_DIR in . linux-next linux; do
    [ -f $LINUX_DIR/Kconfig ] && break
done
echo "Linux dir: $LINUX_DIR"
[ -f "$LINUX_DIR/Kconfig" ] || {
    $offline_mode && err_exit "Offline mode: can't use git clone and Linux repo not found. Consider using --path to specify existing repo location."
    [ -z "$LINUX_REPO" ] && {
        $use_suse_repo && [ -f /etc/os-release ] && grep -q SUSE /etc/os-release && LINUX_REPO=https://github.com/SUSE/kernel || \
        LINUX_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
    }
    echo "Linux repo: $LINUX_REPO"
    git clone "$LINUX_REPO" "$LINUX_DIR"
    [ -f "$LINUX_DIR/Kconfig" ] || err_exit "Could not clone Linux repo"
}
cd "$LINUX_DIR"
$offline_mode || git fetch origin

$setup_only && {
    echo "Skipping build due to --setup-only mode."
    exit 0
}

[ -n "$LINUX_TAG" ] && {
    echo "Linux tag: $LINUX_TAG"
    git rev-parse "$LINUX_TAG" || err_exit "Linux version not found: $LINUX_TAG"
    git checkout --force "$LINUX_TAG"; git reset --hard; git clean --force -d
}
[ -n "$LINUX_PATCHDIR" ] && {
    echo "Linux patch dir: $LINUX_PATCHDIR"
    for patch in "$LINUX_PATCHDIR/$LINUX_TAG"/*.patch; do
        echo
        echo "Applying patch: $patch"
        git am -3 --ignore-space-change --ignore-whitespace --committer-date-is-author-date "$patch" || git am --abort
    done
}

cp -v "$BOOT_DIR/config-$(uname -r)" .config
type -t ec2metadata >/dev/null || type -t ec2-metadata >/dev/null && {
    echo "CONFIG_NET_VENDOR_AMAZON=y" >> .config
    echo "CONFIG_ENA_ETHERNET=m" >> .config
}
if type -t apt-get >/dev/null; then
    ./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
    ./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
elif type -t zypper >/dev/null; then
    ./scripts/config --set-str CONFIG_MODULE_SIG_KEY ""
fi
for opt in "$@"; do
    echo "$opt" >> .config
done

function find_kernel() {
    local kernel gitrev="${1:-$(git rev-parse --short HEAD)}"
    shift
    shopt -s nullglob
    for kernel in $BOOT_DIR/vmlinu*-$gitrev $BOOT_DIR/vmlinu*-${gitrev}.gz $BOOT_DIR/Image*-$gitrev $BOOT_DIR/Image*-$gitrev.gz "$@"; do
        [ -e "$kernel" ] && echo "$kernel" && break
    done
}

gitrev=$(git rev-parse --short HEAD)
[ $reuse_build -a -n "$(find_kernel $gitrev)" ] && echo "Reusing previously built kernel $gitrev" || {
    echo "Building kernel $LINUX_TAG $gitrev..."
    make olddefconfig
    time make -j $(nproc) LOCALVERSION=-$gitrev
}
[ -x $PERF_DIR/perf-${LINUX_TAG}-${gitrev} ] || {
    echo "Building perf..."
    make EXTRA_CFLAGS=-Wno-maybe-uninitialized clean all -j $(nproc) -C tools/perf
    sudo cp tools/perf/perf $PERF_DIR/perf-${LINUX_TAG}-${gitrev} || err_exit "Perf tool failed to build."
}
[ "$CPU" = aarch64 -o "$HOSTTYPE" = aarch64 ] && arch=arm64 || arch=x86
ls -l arch/$arch/boot/*Image*

$install_kernel && {
    echo "Installing kernel..."
    sudo make modules_install -j $(nproc)
    sudo make install -j $(nproc)
    [ -x $PERF_DIR/perf-${LINUX_TAG}-${gitrev} ] && sudo ln -sf $PERF_DIR/perf-${LINUX_TAG}-${gitrev} $PERF_DIR/perf
    perf --version
    ls -l $PERF_DIR/perf $BOOT_DIR/*-$gitrev*
    kernel="$(find_kernel $gitrev $(realpath $BOOT_DIR/vmlinuz))"
    [ -z "$kernel" ] && {
        echo >&2 "Can't find $BOOT_DIR/vmlinu*-$gitrev, copying manually"
        version_name=${LINUX_TAG:-default}-$gitrev
        [ -f arch/$arch/config-*-$gitrev ] && { version_name=arch/$arch/Sytem.map-*-$gitrev; version_name=${version_name##*/config-}; }
        kernel=$BOOT_DIR/vmlinux-${version_name}.gz
        [ -f arch/$arch/Image.gz ] && sudo cp arch/$arch/Image.gz $kernel || exit 1
        [ -f $BOOT_DIR/System.map-$version_name ] || sudo cp -v System.map $BOOT_DIR/System.map-$version_name
        ls -l $BOOT_DIR/*-${version_name}*

        sudo dracut --regenerate-all -f || exit 1
        echo >&2 "Check that the entry in /boot/loader/entries/ matches the initramfs file name!"
    }
    sudo chmod +x $kernel
    ls -l $kernel

    # make install may not build an initramfs; without one the boot entry below is
    # unbootable and the host stops at the grub prompt.
    kver=${kernel##*/vmlinuz-}
    kver=${kver##*/vmlinux-}
    if type -t dracut >/dev/null && [ -d "/lib/modules/$kver" ] && [ ! -s "$BOOT_DIR/initramfs-${kver}.img" ]; then
        echo "No initramfs for $kver; generating one"
        sudo dracut --force --kver "$kver" "$BOOT_DIR/initramfs-${kver}.img" || exit 1
    fi
    if [ -n "$(sudo bash -c 'type -t grub2-mkconfig')" ]; then
        sudo grub2-mkconfig -o "$GRUB2_CFG"
        [ -z "$(sudo bash -c 'type -t grubby')" ] && {
            grbarg='--grub2'
            . /etc/os-release
            {
                sudo zypper addrepo https://download.opensuse.org/repositories/Virtualization/$VERSION_ID/Virtualization.repo
                sudo zypper --non-interactive --gpg-auto-import-keys refresh
                sudo zypper --non-interactive install grubby && grbarg=''
            } || (
                echo "Building grubby..."  # TODO: using this results in a non-bootable instance, fix it
                sudo zypper --non-interactive install -y popt-devel
                grbdir=/tmp/grubby.$$
                git clone https://github.com/rhboot/grubby "$grbdir"
                pushd "$grbdir"
                make grubby
                sudo cp -v grubby /usr/sbin/
                popd
                rm -rf "$grbdir"
            )
        }
        # --add-kernel appends a duplicate entry on every re-run.
        if sudo grubby --info="$kernel" >/dev/null 2>&1; then
            sudo grubby $grbarg --set-default="$kernel"
        else
            sudo grubby $grbarg --add-kernel=$kernel --make-default --copy-default --title=$(basename $kernel) \
                ${kver:+--initrd="$BOOT_DIR/initramfs-${kver}.img"}
        fi
        #sudo grubby --set-default "$kernel"
    else
        KERNELVER=${kernel#*-}
        MID=$(sudo awk '/Advanced options for Ubuntu/{print $(NF-1)}' "$GRUB_CFG" | cut -d\' -f2)
        KID=$(sudo awk "/with Linux $KERNELVER/"'{print $(NF-1)}' "$GRUB_CFG" | grep -v recovery | cut -d\' -f2 | head -n1)
        sudo sed -i '/^GRUB_DEFAULT=/s/=.*/="'"${MID}>${KID}"'"/' "$GRUB_DEFAULT_FILE"
        grep ^GRUB_DEFAULT "$GRUB_DEFAULT_FILE"
        sudo update-grub
    fi
    echo "Kernel: $(ls -l $kernel)"
}
