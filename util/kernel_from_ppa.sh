#!/usr/bin/env bash
# Install and activate a kernel from PPA, like 6.5.0-1024-aws or 6.8.0-1019-aws

[ -z "$1" -o "$1" = "--help" ] && {
    echo "Usage: $0 <version> [PPA]"
    echo "Example: $0 6.5.0-1024-aws \"deb http://ports.ubuntu.com/ubuntu-ports jammy-proposed main\""
    exit 0
}

[ $(id -u) = 0 ] || {
    echo Please run this as root.
    exit 1
}

new_kernel_version="$1"
kernel_ppa_repo="$2"
[ "$(uname -r)" = "$new_kernel_version" ] && echo "Kernel version is already $new_kernel_version, nothing to do" && exit 0

echo Existing kernel: $(uname -r)

[ $CPU = aarch64 -o $HOSTTYPE = aarch64 ] && arch=arm64 || arch=x86

[ -z $kernel_ppa_repo ] && {
    . /etc/os-release
    if [ $arch = aarch64 ]; then
        kernel_ppa_repo="deb http://ports.ubuntu.com/ubuntu-ports ${VERSION_CODENAME}-proposed main"
    else
        kernel_ppa_repo="deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-proposed main"
    fi
}

grep -q "^${kernel_ppa_repo}" /etc/apt/sources.list || echo "${kernel_ppa_repo}" >>/etc/apt/sources.list
apt update -y
apt install -y "linux-image-${new_kernel_version}" || exit 1

SUBMENU_LINE=$(($(grub-mkconfig | grep '^menuentry \|^submenu ' | grep -n gnulinux-advanced | cut -d: -f1) - 1))
KERNEL_LINE=$(($(grub-mkconfig | sed -n '/^submenu .*gnulinux-advanced/,/^}/{/menuentry /p}' | grep -n "gnulinux-${new_kernel_version}-" | grep -v recovery | cut -d: -f1) - 1))
sed -i '/^GRUB_DEFAULT=/s/\(.*=\).*/\1"'"${SUBMENU_LINE}>${KERNEL_LINE}"'"/' /etc/default/grub
update-grub

echo Done, please reboot.
