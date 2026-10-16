# MacVirt

A native macOS virtual machine manager for [libvirt](https://libvirt.org).

MacVirt is based on the functionality of
[virt-manager](https://github.com/virt-manager/virt-manager), but written from scratch
for macOS in Swift (SwiftUI and AppKit). It aims for feature parity with virt-manager
while looking and behaving like a native Mac app; no virt-manager code is used.

MacVirt ships with everything it needs: libvirt and QEMU are bundled inside the app,
so there is nothing to install with Homebrew.

## Features

- **Local VMs** on Apple Silicon through the bundled QEMU, accelerated by Apple's
  Hypervisor framework (ARM64 guests run natively; x86_64 guests are emulated).
- **Remote KVM hosts** over SSH (`qemu+ssh://user@host/system`), like virt-manager.
  Passwords and host-key prompts appear as native dialogs.
- **Manager window**: connections and VMs with live state and CPU graphs; run, pause,
  resume, reboot, shut down, force reset, force off, save; clone, migrate, delete.
- **VM window** with Console, Details and Snapshots, as in virt-manager:
  - **Hardware details** for every device virt-manager shows (Overview, OS information,
    Performance graphs, CPUs, Memory, Boot Options, disks, NICs, input, graphics, sound,
    serial/parallel/console/channel, video, watchdog, controllers, filesystem, smartcard,
    TPM, RNG, panic, VSOCK, host devices, USB redirection), each with a Details and XML tab.
  - **Add Hardware** with all virt-manager categories, including storage volume creation,
    USB/PCI host devices, and hot-plug into running VMs.
  - **Snapshots**: internal and external, with run/revert, delete, descriptions and screenshots.
  - **Consoles**: built-in VNC (with raw scancodes, so the guest's keyboard layout applies),
    the Send Key menu, scaling, fullscreen, screenshots, and **serial/text consoles** with a
    full terminal emulator.
- **Connection Details**: host overview with CPU/memory graphs, **virtual networks** (create
  NAT/routed/open/isolated networks, start/stop/autostart/delete) and **storage pools and
  volumes** (all libvirt pool types, create/delete volumes, choose storage).
- **New VM wizard**: install from ISO, network boot (PXE), import an existing disk or manual
  install; OS profiles (incl. Windows with TPM 2.0/UEFI), BIOS/UEFI/Secure Boot, memory, CPUs,
  storage, network and "Customize configuration before install".
- **Clone**, **Migrate** (direct or tunnelled) and **Delete** (with per-disk storage choice).
- **Preferences** for polling, console scaling and confirmations; a domain XML editor for
  everything else.

See [docs/virt-manager-parity.md](docs/virt-manager-parity.md) for the virt-manager
behaviour MacVirt follows, and [docs/ROADMAP.md](docs/ROADMAP.md) for what is next.

## Install

1. Download `MacVirt-<version>-arm64.dmg` from the
   [latest release](https://github.com/michiel-zededa/MacVirt/releases/latest).
2. Drag **MacVirt** to **Applications**.
3. MacVirt is ad-hoc signed, not notarized. The first time, Control-click the app
   and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacVirt.app
   ```

Requirements: macOS 26 or later on Apple Silicon.

## How it works

| Piece | Where |
|-------|-------|
| App (SwiftUI) | `Contents/MacOS/MacVirt` |
| libvirt daemon for local VMs (QEMU + storage drivers) | `Contents/MacOS/libvirtd`, started by the app |
| QEMU, qemu-img | `Contents/MacOS/qemu-*`, firmware in `Contents/share/qemu` |
| Libraries | `Contents/Frameworks` (all relinked to `@rpath`) |
| libvirt state (sockets, configs, NVRAM) | `~/.macvirt` |
| Local disk images | `~/Library/Application Support/MacVirt/Images` |

Local VMs use the `qemu:///session` URI of the bundled daemon. Their XML refers to
QEMU through `~/.macvirt/app`, a symlink the app updates on every launch, so VMs
keep working when you move or update the app. The bundled `virsh` can be used from
a terminal:

```bash
XDG_CONFIG_HOME=~/.macvirt/config XDG_RUNTIME_DIR=~/.macvirt/run LIBVIRT_AUTOSTART=0 \
  /Applications/MacVirt.app/Contents/MacOS/virsh -c qemu:///session list --all
```

## Building

Requirements: macOS 26, Swift 6 (Xcode or the Command Line Tools), Homebrew.

```bash
brew install libvirt qemu pkgconf
VERSION=0.1.0 ./scripts/build-app.sh   # -> build/MacVirt.app
VERSION=0.1.0 ./scripts/make-dmg.sh    # -> dist/MacVirt-0.1.0-arm64.dmg
```

`scripts/bundle_deps.py` copies every non-system dylib into the bundle and rewrites
install names; `scripts/build-app.sh` then ad-hoc signs everything (QEMU gets the
`com.apple.security.hypervisor` entitlement).

## Releasing

Releases are cut from `main` without pull requests:

```bash
git commit -am "…"
git tag v0.2.0
git push origin main v0.2.0
```

The [Release workflow](.github/workflows/release.yml) builds the app on a macOS
runner and attaches the DMG, a zipped app and SHA-256 checksums to the GitHub release.

## License

MacVirt is licensed under the [GNU General Public License v2.0 or later](LICENSE).
Bundled third-party components keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
