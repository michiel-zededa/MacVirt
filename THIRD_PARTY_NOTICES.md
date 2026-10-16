# Third-party components

MacVirt.app bundles unmodified binaries of the following projects, built by
[Homebrew](https://brew.sh) for macOS arm64. Each remains under its own license;
license texts are in `MacVirt.app/Contents/Resources/licenses/`.

| Component | License | Source |
|-----------|---------|--------|
| libvirt (library, `virtqemud`, `virsh`, QEMU driver) | LGPL-2.1-or-later | https://libvirt.org/sources/ |
| QEMU (`qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-img`) | GPL-2.0 | https://www.qemu.org/download/ |
| SwiftTerm 1.11.2 (terminal emulator, statically linked) | MIT | https://github.com/migueldeicaza/SwiftTerm |
| EDK2 / OVMF firmware | BSD-2-Clause-Patent | https://github.com/tianocore/edk2 |
| SeaBIOS, SeaVGABIOS, iPXE ROMs (shipped with QEMU) | LGPL-3.0 / GPL-2.0 | https://www.qemu.org/download/ |
| GLib, gettext, GnuTLS, Nettle, GMP, libtasn1, p11-kit, libidn2, libunistring, json-c, libssh2, cyrus-sasl, pixman, libslirp, zstd, snappy, lzo, libpng, jpeg-turbo, capstone, dtc, vde, libusb, ncurses, and their dependencies | Various (LGPL, GPL, BSD, MIT, Zlib) | https://formulae.brew.sh |

The exact versions of the bundled libraries are listed below (generated at build
time). Corresponding source code is available from the upstream projects and the
Homebrew formula pages linked above. On request the MacVirt maintainers will
provide the corresponding source for any binary in a given release.

## Bundled versions
