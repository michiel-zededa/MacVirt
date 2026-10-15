# MacVirt

A native macOS virtual machine manager for [libvirt](https://libvirt.org), inspired by
[virt-manager](https://github.com/virt-manager/virt-manager) and written from scratch
in Swift and SwiftUI.

MacVirt ships with everything it needs: libvirt and QEMU are bundled inside the app,
so there is nothing to install with Homebrew.

## Features

- **Local VMs** on Apple Silicon through the bundled QEMU, accelerated by Apple's
  Hypervisor framework (ARM64 guests run natively; x86_64 guests are emulated).
- **Remote KVM hosts** over SSH (`qemu+ssh://user@host/system`), like virt-manager.
  Passwords and host-key prompts appear as native dialogs.
- VM list with live state and CPU usage; run, pause, resume, shut down, reboot, force off.
- Built-in **VNC console** (no external viewer needed), including Ctrl+Alt+Del.
- **New VM wizard**: ISO, architecture, memory, vCPUs and disk; creates the disk
  image locally or in a storage pool on the remote host.
- Domain details and an **XML editor** for everything the UI does not cover yet.
- Delete VMs with or without their disk images.

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
| libvirt daemon for local VMs | `Contents/MacOS/virtqemud`, started by the app |
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
