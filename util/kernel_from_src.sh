#!/bin/bash

[ "$1" = "--help" ] && {
    echo "Usage: $0 [--install] [--version=<kernel_tag>] [--path=<linux_dir>] [--repo=<git_repo>] [<config_option>=<value> [...]]"
    echo "Build the Linux kernel (optionally download from repo and activate it after building)"
    echo "E.g.: $0 --install --version=v6.12 CONFIG_SCHED_DEBUG=y CONFIG_PROC_SYSCTL=y CONFIG_SYSCTL=y 2>&1 | tee build.log"
    exit 0
}
: ${install_kernel:=false} # default: just build the kernel, don't install it
: ${use_suse_repo:=false}  # default: use mainline Linux repo, not SUSE (only for SUSE hosts)

while [ $# -gt 0 ]; do
    case "$1" in
        --install) install_kernel=true;;
        --path=*) LINUX_DIR="${1#*=}";;
        --repo=*) LINUX_REPO="${1#*=}";;
        --version=*) LINUX_TAG="${1#*=}";;
        --) shift; break;;
        --*) echo "Unknown argument: $1"; exit 1;;
        *) break;;
    esac
    shift
done

if type -t apt-get >/dev/null; then
    sudo apt-get update -y
    sudo apt-get upgrade -y
    sudo apt-get -y install build-essential flex bison fakeroot ncurses-dev xz-utils libssl-dev bc libelf-dev
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
    echo >&2 "Unknown package manager"; exit 1
fi

[ -z "$LINUX_DIR" ] && for LINUX_DIR in . linux-next linux; do
    [ -f $LINUX_DIR/Kconfig ] && break
done
echo "Linux dir: $LINUX_DIR"
[ -f "$LINUX_DIR/Kconfig" ] || {
    [ -z "$LINUX_REPO" ] && {
        $use_suse_repo && [ -f /etc/os-release ] && grep -q SUSE /etc/os-release && LINUX_REPO=https://github.com/SUSE/kernel || \
        LINUX_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
    }
    echo "Linux repo: $LINUX_REPO"
    git clone "$LINUX_REPO" "$LINUX_DIR"
    [ -f "$LINUX_DIR/Kconfig" ] || { echo >&2 "Could not clone Linux repo"; exit 1; }
}
cd "$LINUX_DIR"
[ -n "$LINUX_TAG" ] && {
    echo "Linux tag: $LINUX_TAG"
    git fetch origin "$LINUX_TAG" || { echo >&2 "Linux version not found: $LINUX_TAG"; exit 1; }
    git reset --hard FETCH_HEAD
}

cp -v /boot/config-$(uname -r) .config
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

make olddefconfig
time make -j $(nproc) LOCALVERSION=-$(git rev-parse --short HEAD)
[ $CPU = aarch64 -o $HOSTTYPE = aarch64 ] && arch=arm64 || arch=x86
ls -l arch/$arch/boot/*Image*

$install_kernel && {
    echo "Installing kernel..."
    sudo make modules_install -j $(nproc)
    sudo make install -j $(nproc)
    gitrev=$(git rev-parse --short HEAD)
    shopt -s nullglob
    ls -l /boot/*-$gitrev*
    for kernel in /boot/vmlinu*-$gitrev /boot/vmlinu*-${gitrev}.gz /boot/Image*-$gitrev /boot/Image*-$gitrev.gz; do break; done
    [ -z "$kernel" ] && {
        echo >&2 "Can't find /boot/vmlinu*-$gitrev, copying manually"
        version_name=${LINUX_TAG:-default}-$gitrev
        [ -f arch/$arch/config-*-$gitrev ] && { version_name=arch/$arch/Sytem.map-*-$gitrev; version_name=${version_name##*/config-}; }
        kernel=/boot/vmlinux-${version_name}.gz
        [ -f arch/$arch/Image.gz ] && sudo cp arch/$arch/Image.gz $kernel || exit 1
        [ -f /boot/System.map-$version_name ] || sudo cp -v System.map /boot/System.map-$version_name
        ls -l /boot/*-${version_name}*

        sudo dracut --regenerate-all -f || exit 1
        echo >&2 "Check that the entry in /boot/loader/entries/ matches the initramfs file name!"
    }
    sudo chmod +x $kernel
    if [ -n "$(sudo bash -c 'type -t grub2-mkconfig')" ]; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
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
                cd "$grbdir"
                make grubby
                sudo cp -v grubby /usr/sbin/
                rm -rf "$grbdir"
            )
        }
        sudo grubby $grbarg --add-kernel=$kernel --make-default --title=$(basename $kernel)
        #sudo grubby --set-default "$kernel"
    else
        KERNELPATHSTRING=$(basename "$kernel")
        KERNELVER=${KERNELPATHSTRING##vmlinuz-}
        MID=$(sudo awk '/Advanced options for Ubuntu/{print $(NF-1)}' /boot/grub/grub.cfg | cut -d\' -f2)
        KID=$(sudo awk "/with Linux $KERNELVER/"'{print $(NF-1)}' /boot/grub/grub.cfg | cut -d\' -f2 | head -n1)
        sudo sed -i '/^GRUB_DEFAULT=/s/\(.*=\).*/\1"'"${MID}>${KID}"'"/' /etc/default/grub
        sudo update-grub
    fi
    echo "Kernel: $(ls -l $kernel)"
}
