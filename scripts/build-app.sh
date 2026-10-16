#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds build/MacVirt.app with libvirt and QEMU (from Homebrew) bundled inside.
#
# Environment:
#   VERSION  app version (default: 0.0.0-dev)
#   SCRATCH  SwiftPM scratch path (default: .build)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=${VERSION:-0.0.0-dev}
SCRATCH=${SCRATCH:-$ROOT/.build}
APP=$ROOT/build/MacVirt.app
C=$APP/Contents

LIBVIRT=$(brew --prefix libvirt)
QEMU=$(brew --prefix qemu)
export PKG_CONFIG_PATH="$LIBVIRT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "==> Compiling MacVirt $VERSION"
swift build -c release --arch arm64 --scratch-path "$SCRATCH"
BIN=$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/MacVirt

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/share/qemu"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/${GITHUB_RUN_NUMBER:-1}/" Resources/Info.plist > "$C/Info.plist"
cp Resources/AppIcon.icns Resources/askpass.sh "$C/Resources/"
cp LICENSE "$C/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$C/Resources/"
mkdir -p "$C/Resources/licenses"
cp "$LIBVIRT/COPYING.LESSER" "$C/Resources/licenses/libvirt-COPYING.LESSER"
cp "$QEMU/COPYING" "$C/Resources/licenses/qemu-COPYING"
cp "$QEMU/LICENSE" "$C/Resources/licenses/qemu-LICENSE"

echo "==> Bundling libvirt and QEMU"
python3 scripts/bundle_deps.py "$APP" \
    "$BIN=MacOS/MacVirt" \
    "$LIBVIRT/sbin/libvirtd=MacOS/libvirtd" \
    "$LIBVIRT/bin/virsh=MacOS/virsh" \
    "$LIBVIRT/lib/libvirt/connection-driver/libvirt_driver_qemu.dylib=Frameworks/libvirt/connection-driver/libvirt_driver_qemu.dylib" \
    "$LIBVIRT/lib/libvirt/connection-driver/libvirt_driver_storage.dylib=Frameworks/libvirt/connection-driver/libvirt_driver_storage.dylib" \
    "$LIBVIRT/lib/libvirt/connection-driver/libvirt_driver_secret.dylib=Frameworks/libvirt/connection-driver/libvirt_driver_secret.dylib" \
    "$LIBVIRT/lib/libvirt/storage-backend/libvirt_storage_backend_fs.dylib=Frameworks/libvirt/storage-backend/libvirt_storage_backend_fs.dylib" \
    "$QEMU/bin/qemu-system-aarch64=MacOS/qemu-system-aarch64" \
    "$QEMU/bin/qemu-system-x86_64=MacOS/qemu-system-x86_64" \
    "$QEMU/bin/qemu-img=MacOS/qemu-img"

# QEMU locates its data relative to the binary: MacOS/../share/qemu
# UEFI firmware as qcow2: internal snapshots of UEFI VMs need qcow2 NVRAM,
# and libvirt cannot convert a raw vars template. Also much smaller.
for fw in edk2-aarch64-code edk2-arm-vars edk2-x86_64-code edk2-i386-vars; do
    "$QEMU/bin/qemu-img" convert -q -f raw -O qcow2 "$QEMU/share/qemu/$fw.fd" "$C/share/qemu/$fw.qcow2"
done
# Raw images stay for VMs created by MacVirt 0.1.
( cd "$QEMU/share/qemu" && cp -R \
    edk2-aarch64-code.fd edk2-arm-vars.fd edk2-x86_64-code.fd edk2-i386-vars.fd edk2-licenses.txt \
    bios.bin bios-256k.bin vgabios*.bin efi-*.rom kvmvapic.bin linuxboot_dma.bin multiboot_dma.bin pvh.bin \
    keymaps "$C/share/qemu/" )

{
    echo
    echo "| Library | Origin |"
    echo "|---------|--------|"
    for lib in "$C"/Frameworks/*.dylib; do
        origin=$(cd "$(brew --prefix)" && find Cellar -name "$(basename "$lib")" -print -quit 2>/dev/null | cut -d/ -f2,3)
        echo "| $(basename "$lib") | ${origin:-?} |"
    done
} >> "$C/Resources/THIRD_PARTY_NOTICES.md"

echo "==> Signing (ad-hoc)"
find "$C/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} +
for exe in "$C"/MacOS/*; do
    [ "$(basename "$exe")" = MacVirt ] && continue
    case "$exe" in
        *qemu-system-*) codesign --force --sign - --entitlements Resources/qemu.entitlements "$exe" ;;
        *) codesign --force --sign - "$exe" ;;
    esac
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
