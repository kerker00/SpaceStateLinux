#!/bin/bash
# Run as root in a fresh Arch Linux container, from a checkout: builds swift-bin from the AUR,
# builds the package from the checkout's content, installs it, and runs it without Swift.
set -euo pipefail
version=$(sed -n 's/^pkgver=//p' packaging/aur/PKGBUILD)

useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
mkdir /home/builder/pkg
git config --global --add safe.directory "$PWD"
git archive --format=tar.gz --prefix="SpaceStateLinux-$version/" -o "/home/builder/pkg/spacestate-desktop-$version.tar.gz" HEAD
sed "s|^source=.*|source=(\"spacestate-desktop-$version.tar.gz\")|" packaging/aur/PKGBUILD > /home/builder/pkg/PKGBUILD
chown -R builder /home/builder

su builder -c 'cd ~ && git clone --depth 1 https://aur.archlinux.org/swift-bin.git && cd swift-bin && makepkg --noconfirm --syncdeps --install --needed'
su builder -c 'swift --version'
su builder -c 'cd ~/pkg && makepkg --noconfirm --syncdeps --needed'
pacman -U --noconfirm /home/builder/pkg/spacestate-desktop-*.pkg.tar.zst
pacman -Ql spacestate-desktop | cut -d' ' -f2 | grep -v '/$'
pacman -Qi spacestate-desktop | grep -E '^(Depends On|Installed Size)'

# What the package really needs shows once the toolchain is gone.
pacman -Rdd --noconfirm swift-bin
if ldd /usr/bin/spacestate-desktop /usr/bin/spacestate-settings | grep -E 'not found|swift'; then
    echo 'The programs still need a library the package does not provide.' >&2
    exit 1
fi
spacestate-desktop --help | grep -- --no-tray
spacestate-settings --help > /dev/null
test -s /usr/share/locale/de/LC_MESSAGES/spacestate.mo
echo 'The package installs and runs.'
