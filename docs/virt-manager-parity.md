# virt-manager feature reference

Behavioural reference for MacVirt's feature parity, extracted from virt-manager (commit bac5379, GPL-2.0-or-later). MacVirt is written from scratch; this file documents *what* virt-manager does, not how MacVirt implements it.

# A. Details window: hardware list + VM-level pages

Source: `virtManager/details/details.py` (abbrev `details:`), `virtManager/addhardware.py` (`addhw:`), `virtManager/object/domain.py` (`domain:`), `virtinst/*`, `ui/details.ui`, `ui/xmleditor.ui`.
`_()` strings are quoted exactly; `_` in UI labels = GTK mnemonic (drop on macOS).

---

## 1. Details window hardware list

### 1.1 Layout / widgets
- Left: `GtkTreeView#hw-list`, single column header `"Hardware"`, min width 165, icon (LARGE_TOOLBAR) + text.
- Below list: button `"A_dd Hardware"` (`#add-hardware-button`) → opens Add Hardware wizard (`vmmAddHardware(vm)`, one instance reused).
- Right-click on a row: selects row, pops menu `"_Add Hardware"`, `"_Remove Hardware"` (remove item mirrors visibility + sensitivity of the Remove button). `details:_popup_addhw_menu_cb`
- Bottom bar: `"_Remove"` (`#config-remove`), `"_Cancel"` (`#config-cancel`), `"_Apply"` (`#config-apply`, initially insensitive).
- Model row: `[label, icon_name, hw_type(int), devobj, key]`; key = devobj or title.

### 1.2 Fixed top items (`details:_init_hw_list`)
| Order | Label | Page type | Icon |
|---|---|---|---|
| 0 | `"Overview"` | GENERAL | `computer` |
| 1 | `"OS information"` | OS | `computer` |
| 2 | `"Performance"` | STATS | `utilities-system-monitor` (fallback `system-run` if missing in theme) — **omitted in "customize before install" dialog** |
| 3 | `"CPUs"` | CPU | `device_cpu` |
| 4 | `"Memory"` | MEMORY | `device_mem` |
| 5 | `"Boot Options"` | BOOT | `system-run` |

Initial selection: row 0 (Overview).

### 1.3 Device ordering
- Rows sorted by page-type enum, then XML document order within type. Insert position = count of rows with `type <= hwtype` (`details:_repopulate_hw_list`).
- Type enum order (= sidebar order): DISK, NIC, INPUT, GRAPHICS, SOUND, CHAR, HOSTDEV, VIDEO, WATCHDOG, CONTROLLER, FILESYSTEM, SMARTCARD, REDIRDEV, TPM, RNG, PANIC, VSOCK.
- CHAR group order (iteration): all `serial`, then `parallel`, then `console`, then `channel`.
- Note: REDIRDEV is iterated before VIDEO but sorts after SMARTCARD (enum wins).
- Refresh: existing rows matched by identity or `get_xml_id()` (abs xpath e.g. `./devices/disk[2]`) and label/icon updated in place; vanished devices removed; never re-sorted otherwise.

### 1.4 Hidden / filtered devices
- Never listed (not iterated at all): `memballoon`, `audio`, `shmem`, `memory` (DIMM), `iommu`, `pstore`, `emulator`.
- Controllers skipped: model in `ich9-uhci1`, `ich9-uhci2`, `ich9-uhci3` (USB2 companions); model in `pcie-root-port`, `dmi-to-pci-bridge`, `pci-bridge` (condensed into the single PCIe root listing).
- Console de-dup: if `serials` and `consoles` non-empty and `consoles[0]` duplicates `serials[0]` (`DeviceConsole.get_console_duplicate`: `console.type == serial.type` and `console.target_type in (None, "serial")`), the first console is not listed.

### 1.5 Label formula per device (`details:_label_for_device`)
| DEVICE_TYPE | Formula | Examples |
|---|---|---|
| disk, `device=floppy` | `"Floppy %(index)d"` | `Floppy 1` |
| disk, `device=cdrom` | `"%(bus)s CDROM %(index)d"` | `SATA CDROM 1`, `IDE CDROM 2` |
| disk, `device=disk` | `"%(bus)s Disk %(index)d"` | `VirtIO Disk 1`, `SCSI Disk 2`; bus unset → `" Disk 1"` (leading space) |
| disk, other (`lun`) | `"%(bus)s %(device)s %(index)d"`, device `.capitalize()` | `SCSI Lun 1` |
| interface | `"NIC %(mac)s"`, mac = `macaddr[-9:]` (last 9 chars) or `""` | `NIC :7b:8b:b1` |
| input | `type=tablet` → `"Tablet"`; `mouse` → `"Mouse"`; `keyboard` → `"Keyboard"`; else `"Input"` (bus NOT shown) | `Tablet` |
| serial | `"Serial %(num)d"`, num = `(target_port or 0) + 1` | `Serial 1` |
| parallel | `"Parallel %(num)d"`, same | `Parallel 1` |
| console | `"Console %(num)d"`, same | `Console 1` |
| channel | name = pretty channel name(target_name); if name and `type != "qemu-vdagent"` → `"Channel (%(name)s)"`; else `"Channel %(type)s"` with pretty char type | `Channel (qemu-ga)`, `Channel (spice)`, `Channel QEMU vdagent`, `Channel UNIX socket` |
| graphics | `"Display %s"` % `graphics_pretty_type_simple(type)`: `vnc/sdl/rdp` → upper, else `.capitalize()` | `Display VNC`, `Display Spice`, `Display Dbus`, `Display Egl-headless` |
| redirdev | `"%(bus)s Redirector %(index)d"`, bus via `disk_pretty_bus`, index = `get_xml_idx()+1` (position among `<redirdev>`) | `USB Redirector 1` |
| hostdev | `hostdev_pretty_name` (below) | `USB 1234:5678`, `USB 001:002`, `PCI 0000:00:1f.2` |
| sound | `"Sound %s"` % raw `model` (not prettified) | `Sound ich9`, `Sound ac97` |
| video | `"Video %s"` % `video_pretty_model` | `Video Virtio`, `Video QXL` |
| filesystem | `"Filesystem %(path)s"`, path = `target[:8]` (`./target/@dir`, truncated to 8 chars) | `Filesystem /tag`, `Filesystem mount_ta` |
| controller, `index` set | `"Controller %(controller)s %(index)s"` | `Controller USB 0`, `Controller VirtIO SCSI 0`, `Controller PCIe 0` |
| controller, no index | `"Controller %(controller)s"` | `Controller SATA` |
| rng | `device` (`./backend[@model='random']` text) set → `"RNG %(device)s"`; else `"RNG"` | `RNG /dev/urandom`, `RNG` (egd/builtin) |
| tpm | `device_path` (`./backend/device/@path`) → `"TPM %(device)s"`; elif `version` (`./backend/@version`) → `"TPM v%(version)s"`; else `"TPM"` | `TPM /dev/tpm0`, `TPM v2.0` |
| panic | `"Panic Notifier"` | |
| smartcard | `"Smartcard"` | |
| vsock | `"VirtIO VSOCK"` | |
| watchdog | `"Watchdog"` | |

#### Disk index (`details:_calculate_disk_bus_index`)
- Counter keyed by `device + (bus or "")` (e.g. `"diskvirtio"`, `"cdromsata"`, `"floppyfdc"`), starts at 1, increments in XML order.
- Independent per (device-kind, bus) pair; NOT derived from target dev (`vda`/`sdb`).

#### Bus pretty names (`addhw:disk_pretty_bus`) — unmapped values pass through raw
| bus | label |
|---|---|
| `ide` | `IDE` |
| `nvme` | `NVMe` |
| `sata` | `SATA` |
| `scsi` | `SCSI` |
| `sd` | `SD` |
| `usb` | `USB` |
| `virtio` | `VirtIO` |
| `xen` | `Xen` |
| `fdc` | (unmapped → `fdc`; irrelevant, floppies use `Floppy N`) |

#### Channel name map (`addhw:char_pretty_channel_name`; else None)
| target_name | label |
|---|---|
| `com.redhat.spice.0` | `spice` |
| `org.qemu.guest_agent.0` | `qemu-ga` |
| `org.libguestfs.channel.0` | `libguestfs` |
| `org.spice-space.webdav.0` | `spice-webdav` |

#### Char type pretty (`addhw:char_pretty_type`; else raw)
`pty`→`"Pseudo TTY"`, `file`→`"Output to a file"`, `tcp`→`"TCP net console"`, `udp`→`"UDP net console"`, `unix`→`"UNIX socket"`, `spicevmc`→`"Spice agent"`, `spiceport`→`"Spice port"`, `qemu-vdagent`→`"QEMU vdagent"`.

#### Video pretty (`addhw:video_pretty_model`)
- `qxl`, `vmvga`, `vga` → upper (`QXL`, `VMVGA`, `VGA`); else `.capitalize()` (`Virtio`, `Bochs`, `Ramfb`, `Cirrus`, `None`, `Xen`).

#### Controller pretty (`addhw:controller_pretty_desc`)
- `scsi` + model `virtio-scsi` → `"VirtIO SCSI"`; `pci` + model `pcie-root` → `"PCIe"`; else by type:
- `ide`→`"IDE"`, `fdc`→`"Floppy"`, `nvme`→`"NVMe"`, `scsi`→`"SCSI"`, `sata`→`"SATA"`, `virtio-serial`→`"VirtIO Serial"`, `usb`→`"USB"`, `pci`→`"PCI"`, `ccid`→`"CCID"`, `xenbus`→`"xenbus"`; else raw type.

#### Hostdev label (`addhw:hostdev_pretty_name`)
- Prefix `type.upper()` (`USB`, `PCI`, `SCSI`, `MDEV`).
- First match wins:
  1. vendor & product → `" %s:%s"` with `0x` stripped (`USB 046d:c52b`). **No product name.**
  2. bus & device → `" %s:%s"` zero-padded `%.3d` (`USB 001:004`).
  3. bus & slot & function & domain → `" dom:bus:slot.func"`, `0x` stripped (`PCI 0000:00:1f.2`).
  4. uuid → `" <uuid>"` (mdev).
  5. else prefix only.

### 1.6 Icons (`details:_icon_for_device`)
| Device | Icon |
|---|---|
| disk cdrom / floppy / other | `media-optical` / `media-floppy` / `drive-harddisk` |
| input keyboard / tablet / other | `input-keyboard` / `input-tablet` / `input-mouse` |
| redirdev | `device_usb` |
| hostdev usb / other | `device_usb` / `device_pci` |
| interface | `network-idle` |
| graphics | `video-display` |
| serial, parallel, console, channel | `device_serial` |
| video | `video-display` |
| watchdog | `device_pci` |
| sound | `audio-card` |
| rng | `system-run` |
| tpm | `device_cpu` |
| smartcard | `device_serial` |
| filesystem | `folder` |
| controller | `device_pci` |
| panic | `system-run` |
| vsock | `network-idle` |

### 1.7 Remove button
- Visible iff page type ∈ device types (all device pages; never the 6 fixed items). `details:_refresh_page` / `remove_pages`.
- Default: sensitive, tooltip `"Remove this device from the virtual machine"`.
- Disabled (insensitive + tooltip) by `_disable_device_remove`:
  | Condition | Tooltip |
  |---|---|
  | input `mouse`/`keyboard` with bus `xen` or `ps2` | `"Hypervisor does not support removing this device"` |
  | video, guest has ≥1 graphics and `len(video) <= 1` | `"Cannot remove last video device while Graphics/Display is attached."` |
  | controller `usb` on x86 guest | `"Hypervisor does not support removing this device"` |
  | controller `pci` (any) | `"Hypervisor does not support removing this device"` |
  | controller `nvme/scsi/sata/ide/fdc` with attached disks | `"Cannot remove controller while devices are attached."` |
  | controller `virtio-serial` with attached devices | `"Cannot remove controller while devices are attached."` |
- Remove flow:
  - Disk → `vmmDeleteStorage` dialog, title `"Remove Disk Device"`, text `"Remove disk device '%(target)s'"`, optional storage deletion.
  - Other → confirm `"Are you sure you want to remove this device?"` (with don't-ask-again; pref `confirm/removedev`).
  - Then: remove from persistent (inactive) XML, then try live `detachDevice`. On detach failure: info dialog `"Device could not be removed from the running machine"`, text2 `"This change will take effect after the next guest shutdown."` (+ `" Storage will not be deleted."` when deleting storage). `delete.py:remove_devobj_internal`

### 1.8 Apply/cancel mechanics (shared by all pages)
- Any edit → Apply + Cancel sensitive, edit kind recorded (`_active_edits`); only edited fields are written.
- Cancel → re-read page from XML.
- Switching row with pending edits → `"There are unapplied changes. Would you like to apply them now?"` + `"Don't warn me again."` (pref `confirm/unapplied`); if apply fails, selection reverts.
- VM state refresh does not overwrite page while Apply is sensitive.
- All edits go to the **inactive** XML (`_make_xmlobj_to_define` → redefine). Then if VM active:
  - page passes `hotplug_args` → `vm.hotplug(...)`; success → silent.
  - else, or hotplug error → dialog `"These changes will take effect after the next guest shutdown."` (INFO if nothing hotplugged; WARNING + error details if hotplug failed). `addhw:change_config_helper`
- Persistent define error → `"Error changing VM configuration: %s"`; any other → `"Error applying changes: %s"`.

### 1.9 XML tab (every page incl. fixed items)
- Each page wrapped in notebook with tabs `"_Details"` and `"_XML"`.
- Top items: full domain **inactive** XML (`get_xml_to_define`). Device rows: device XML (`unindent_device_xml`).
- Editable only if pref `xmleditor-enabled` (default `false`); otherwise read-only + warning `"XML editing is disabled in 'Preferences'. Only enable it if you know what you are doing."`
- Apply: domain → `vm.define_xml(newxml)`; device → `vm.replace_device_xml` (never hotplugged).
- Leaving tab with unsaved edits: `"There are unapplied changes."` / `"Your XML changes will be lost if you leave this tab. Really leave this tab?"` (details→XML: `"Your changes will be lost if you leave this tab. Really leave this tab?"`).

---

## 2a. Details pages

### Overview (`details:_refresh_overview_page`, `_apply_overview`, `domain:define_overview`)
Frame `"Basic Details"`:
| Field (label) | Widget | XML / source | Edit / live |
|---|---|---|---|
| `"_Name:"` | entry | `<name>` | editable only when VM **not active** (`set_editable(not active)`). Apply → `rename_domain` synchronously, before other fields |
| `"UUID:"` | label | `UUIDString()` | read-only |
| `"Status:"` | icon + text | run state | `"<status> (<reason>)"` or `"<status>"` |
| `"T_itle:"` | entry | `<title>` (empty → removed) | hotplug: `setMetadata(TITLE, LIVE\|CONFIG)` → live |
| `"D_escription:"` | multiline text | `<description>` (empty → removed) | hotplug: `setMetadata(DESCRIPTION, LIVE\|CONFIG)` → live |

- Rename rules: `Guest.validate_name` → non-empty (`"A name must be specified for the Guest"`), no `/`, not already used (`"Guest name '%s' is already in use."`). Implemented as **undefine + define with new name** (`connection:rename_object`), restores autostart, rolls back on failure. If VM has NVRAM (UEFI): copies NVRAM volume to `<dir>/<newname>_VARS<ext>`, deletes old, then `define_overview(nvram=newpath)`.
- Status strings (`pretty_run_status`): `"Running"`, `"Paused"`, `"Shutting Down"`, `"Shutoff"` (`"Saved"` if managed save), `"Crashed"`, `"Suspended"`, `"Unknown"`.
- Reasons: RUNNING: `"Booted"`, `"Migrated"`, `"Restored"`, `"From snapshot"`, `"Unpaused"`, `"Migration canceled"`, `"Save canceled"`, `"Event wakeup"`, `"Crashed"`; PAUSED: `"User"`, `"Migrating"`, `"Saving"`, `"Dumping"`, `"I/O error"`, `"Watchdog"`, `"From snapshot"`, `"Shutting down"`, `"Creating snapshot"`, `"Crashed"`; SHUTDOWN: `"User"`; SHUTOFF: `"Shut Down"`, `"Destroyed"`, `"Crashed"`, `"Migrated"`, `"Saved"`, `"Failed"`, `"From snapshot"`; CRASHED: `"Panicked"`.
- Status icons: running/blocked/nostate → `state_running`; paused/pmsuspended → `state_paused`; shutoff/shutdown/crashed → `state_shutoff`.

Frame `"Hypervisor Details"`:
| Field | Source / values | Editable? |
|---|---|---|
| `"Hypervisor:"` | `pretty_hv(os_type, domain type)`: `kvm`→`"KVM"`, `qemu`→`"QEMU TCG"`, `hvf`→`"Hypervisor.framework"`, xen+xen→`"xen (paravirt)"`, xen+hvm→`"xen (fullvirt)"`, test+xen→`"test (xen)"`, test+hvm→`"test (hvm)"`, else raw domtype | no |
| `"Architecture:"` | `<os><type arch>`; missing → `"Unknown"` | no |
| `"Emulator:"` | `<devices><emulator>`; missing → `"None"` | no |
| `"Machine _Type: "` | `<os><type machine>`; label, missing → `"Unknown"`. Row shown **only if arch not i686/x86_64**. Combo of `capsinfo.machines` (sorted) | combo only in customize dialog |
| `"Chipse_t:"` | `"i440FX"` (value `pc`) / `"Q35"` (value `q35`, only if `"q35"` in caps machines). Label derived: machine contains `q35` → `Q35` else `i440FX`. Row shown only if conn qemu/test **and** arch i686/x86_64 | combo only in customize dialog |
| `"Firm_ware:"` | see below. Row shown iff `os.is_hvm()` and (domcaps firmware enum has `efi` or arch has UEFI patterns) | combo only in customize dialog |

- Machine/chipset/firmware: outside customize dialog shown as plain labels (effectively install-time only). No hotplug.
- Machine change side effects: `pc`→`q35`: `add_q35_pcie_controllers()`; `q35`→`pc`: removes `pcie-root`/`pcie-root-port` controllers. Clears cached domcaps.
- Firmware combo rows `[label, loader, sensitive, firmware]`, in order:
  1. Default: `label_for_firmware_path(None)` = `"BIOS"` (x86) or `"Default"` (other) → loader None, firmware None → `guest.disable_uefi()` (clears `os/@firmware`, `<loader>`, `<nvram>`, firmware features).
  2. `"UEFI"` (if domcaps `os firmware` enum has `efi`) → `<os firmware="efi">`, loader None (nvram kept).
  3. One per domcaps loader path: `"UEFI %(arch)s: %(path)s"` if path matches arch pattern, else `"Custom: %(path)s"` → `set_uefi_path(path)`: `<loader readonly="yes" type="pflash">path</loader>`; if x86 and path contains `secboot`: `features.smm=on`, `loader secure="yes"`, forces machine q35.
  - Arch patterns: i686 `.*edk2-i386-.*\.fd`, `.*ovmf-ia32.*`; x86_64 `.*edk2-x86_64-.*\.fd`, `.*OVMF_CODE\.fd`, `.*ovmf-x64/OVMF.*\.fd`, `.*ovmf-x86_64-.*`, `.*ovmf.*`, `.*OVMF.*`; aarch64 `.*AAVMF_CODE\.fd`, `.*aarch64/QEMU_EFI.*`, `.*aarch64.*`, `.*edk2-aarch64-code\.fd`; armv7l `.*AAVMF32_CODE\.fd`, `.*arm/QEMU_EFI.*`, `.*edk2-arm-code\.fd`; riscv64 `.*RISCV_VIRT_CODE\..*`, `.*riscv64.*`; loongarch64 `.*loongarch64/QEMU_CODE\..*`, `.*loongarch64.*`.
  - Display on refresh: `os/@firmware == "efi"` → `"UEFI"`; else `label_for_firmware_path(os.loader)`.
  - Warning icon (customize only) tooltip: `"Libvirt or hypervisor does not support UEFI."` or `"Libvirt did not detect any UEFI/OVMF firmware image installed on the host."`

### OS information (`details:_refresh_os_page`, `_apply_os`, `domain:define_os`)
- Frame `"Operating Sys_tem"`: OS search entry (`vmmOSList`), placeholder `"Type to start searching..."`.
  - Popover list: every libosinfo OS, label `"%s (%s)" % (os.label, os.name)` (e.g. `Fedora 40 (fedora40)`), sorted by label, generic entries (`generic`, linux-generic) at end; column `"Name"`.
  - Checkbox `"Include end of life operating systems"` (default off; auto-enabled if VM's OS is EOL).
  - Hint: `"Can't find the operating system you are looking for?\nTry selecting a similar distro or version, or use one of the 'Generic' options."`
  - Current = `guest.osinfo` (from metadata; default `generic`).
  - Apply → `set_os_name(name or "generic")` → `<metadata><libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0"><libosinfo:os id="<full_id>"/></…></metadata>`. No hotplug (running → after-shutdown dialog).
- Inspection (libguestfs) — visible only if `config.inspection_supported()` (libguestfs installed **and** pref inspect-VMs on) and no inspection error:
  - Error row `details-overview-error` (shows `vm.inspection.errorstr`; hides apps/refresh).
  - Expander `"Applications"`: table columns `"Name"`, `"Version"`, (summary, untitled); sortable.
    - Name = `display_name` or `name`; Version = `[epoch:]version[-release]` (epoch only if > 0); Summary = `summary`, else first line of `description` + `" ..."`.
  - Button `"Refresh"` → `vmmInspection.vm_refresh(vm)`.
  - (No hostname/product fields in this version.)

### Performance (`details:_refresh_stats_page`) — hidden in customize dialog; refreshed on each stats tick
| Frame | Text | Graph |
|---|---|---|
| `"CPU usage"` | `"%d %%"` of guest CPU% (cpu time delta / (elapsed × vcpus)), clamp 0–100 | sparkline, filled |
| `"Memory usage"` | `"%(current-memory)s of %(total-memory)s"` — current = `balloon.current − balloon.unused`; total = `<memory>` (pretty_mem) | sparkline, filled, % of balloon |
| `"Disk I/O"` | `"%(received)d %(units)s read"` + `"%(transferred)d %(units)s write"`, units `"KiB/s"`, colored `#82003B` / `#295C45` | 2 series, unfilled, same colors; ceiling = max(maxrate, 10.0) |
| `"Network I/O"` | `"%(received)d %(units)s in"` + `"%(transferred)d %(units)s out"`, `"KiB/s"` | same |
- Any metric with polling pref off → `"Disabled"`. Pref defaults: `enable-cpu-poll=true`, `enable-memory-poll=false`, `enable-disk-poll=false`, `enable-net-poll=false`; `update-interval=3` s; history length fixed 120 samples. Graphs are `reversed` (newest on right).
- Memory stats need memballoon (`balloon.*` / `memoryStats`; sets stats period automatically).

### CPUs (`details:_refresh_config_cpu`, `_apply_vcpus`, `domain:define_cpu`)
Frame `"CPUs"`:
- `"Logical host CPUs:"` label = `host_active_processor_count()`.
- `"vCPU a_llocation:"` spin, range 1–1024, step 1. Warning row (shown if > host CPUs): `"Overcommitting vCPUs can hurt performance"`.
- **Single vCPU value only** (no separate current/max in UI). Apply writes `<vcpu current="N">N</vcpu>` (both `vcpus` and `vcpu_current` = N).
- Insensitive while manual topology enabled (value = sockets×cores×threads).

Frame `"Configu_ration"`:
- Checkbox `"Copy host CP_U configuration"`; label appends `" (host-model)"` / `" (host-passthrough)"` when current `cpu/@mode` is one of those (checkbox then checked). When checked: hides Model + security rows; apply → `host-passthrough` (note: converts host-model to passthrough if CPU edit applied).
- `"M_odel:"` editable combo (free text allowed). Rows (label → value):
  | Label | Value |
  |---|---|
  | `"Application Default"` | `default` → resolved to pref `/new-vm/cpu-default` (default `'default'`) → app default: `maximum` (TCG qemu on x86/arm-virt/riscv-virt/loongarch64 if supported) else `host-passthrough` (if safe) else `host-model` (if safe) else `host-model-only` |
  | `"Hypervisor Default"` | `hv-default` → clears `<cpu>` |
  | `"Clear CPU configuration"` | `clear` → clears `<cpu>` |
  | `host-model` | `<cpu mode="host-model">` (model/vendor/fallback/migratable/check/features removed) |
  | `host-passthrough` | `<cpu mode="host-passthrough">` (same clearing) |
  | `maximum` | `<cpu mode="maximum">` (same clearing) |
  | ── separator ── | |
  | each domcaps `custom` mode model with `usable != "no"` | `<cpu mode="custom" match="exact"><model>NAME</model>`; migratable cleared |
  - Free text not matching a row → used as custom model name.
  - Refresh display: `cpu.model`, else `cpu.mode` if a special mode, else select `"Hypervisor Default"`.
- Checkbox `"Enable available CPU security flaw mitigations"` (`secure`, not in XML): only for custom model. True → add `<feature policy="require" name=…>` for each domcaps security feature; False → remove them. Insensitive unless x86 and domcaps reports security features; tooltip `"No security features to copy, the host is missing security patches or the host CPU is not vulnerable."` State = all security features present as `require` (model suffix `IBRS`→spec-ctrl, `IBPB`→ibpb count).

Expander `"To_pology"` (auto-expanded if `<topology>` exists):
- Checkbox `"Manuall_y set CPU topology"` (checked iff `<cpu><topology>` present).
- `"Socke_ts:"`, `"Cor_es:"`, `"Thread_s:"` spins, 1–256 each (defaults 1). Dies/clusters: **not exposed** (dies preserved on apply).
- Enabled: vcpus forced = product. Disabled: UI shows sockets=vcpus, cores=1, threads=1; apply → `<topology>` removed.
- XML: `<cpu><topology sockets= cores= threads=/>`.
- **No CPU change is hotplugged** (no `hotplug_args`) → running VM always gets `"These changes will take effect after the next guest shutdown."`

### Memory (`details:_refresh_config_memory`, `_apply_memory`, `domain:define_memory`)
Frame `"Memory"`:
| Field | Widget | XML | Notes |
|---|---|---|---|
| `"Total host memory:"` | label `"%d MiB"` | host | read-only |
| `"Current a_llocation:"` | spin MiB, 1–10240000 | `<currentMemory>` KiB = MiB×1024 | raising it bumps max and sets max's lower bound to current |
| `"Ma_ximum allocation:"` | spin MiB, 1–10240000 | `<memory>` KiB | |
| `"Enable shared _memory"` | checkbox | on: `<memoryBacking><source type="memfd"/><access mode="shared"/>`; off: both removed | see below |
- Hotplug (when active): `memory` + `maxmem` → `setMaxMemory` / `setMemory` (order: if new max < actual current, set current first; each call skipped if unchanged). Failure → WARNING after-shutdown dialog.
- Shared memory: checked iff `memoryBacking/source/@type == "memfd"`. Insensitive with tooltip if `<cpu><numa>` cells exist: `"Can not change shared memory setting when <numa> is configured."`; or domcaps lacks virtiofs or memfd: `"Libvirt may not be new enough to support memfd."`. Not hotplugged.
- No `maxMemory`/slots, hugepages, or memballoon UI on this page.

### Boot Options (`details:_refresh_boot_page`, `_apply_boot_options`, `domain:define_boot`)
Frame `"Autostart"`:
- Checkbox `"Start virt_ual machine on host boot up"` → `virDomainSetAutostart` (not XML; immediate, works while running). Insensitive if libvirt returns None. Error: `"Error changing autostart value: %s"`.

Frame `"Container init"` (only containers, `os.is_container()`):
- `"Init _path:"` → `<os><init>`; `"Init ar_gs:"` → one `<initarg>` per `shlex.split` token (display joined with `shlex.quote`). Empty path → `"An init path must be specified"`.

Expander `"Dir_ect kernel boot"` (hidden for containers; auto-expanded if any of kernel/initrd/dtb/args set):
- Checkbox `"Ena_ble direct kernel boot"` (checked iff any set); unchecked → fields insensitive → apply clears all four (text kept in fields for toggling back).
- `"Ke_rnel path:"` → `<os><kernel>`; `"_Initrd path:"` → `<os><initrd>`; `"Kernel ar_gs:"` → `<os><cmdline>`; `"D_TB path:"` → `<os><dtb>` (DTB row visible only if value present, hv `test`, or arch contains `arm`/`microblaze`/`ppc`). Each path has `"Browse"` (storage browser). Empty → element removed; paths made absolute.
- Validation: `"Cannot set initrd without specifying a kernel path"`, `"Cannot set kernel arguments without specifying a kernel path"`.

Frame `"Boot device order"` (hidden for containers and Xen PV):
- Checkbox `"Enable boot me_nu"` → `<os><bootmenu enable="yes|no"/>`.
- List: checkbox + icon + label; up/down buttons (initially insensitive).
  - Per-device mode (`conn_device_boot_order`: always for qemu/test): rows = bootable devices = all `disk` + `interface` + `hostdev` (redirdev excluded), key = `get_xml_id()`, label/icon copied from hw list (e.g. `VirtIO Disk 1`). None → single row `"No bootable devices"` (no checkbox).
  - Legacy mode: fixed rows `"Hard Disk"` (`hd`, `drive-harddisk`), `"CDROM"` (`cdrom`, `media-optical`), `"Network (PXE)"` (`network`, `network-idle`), `"Floppy"` (`fd`, `media-floppy`).
  - Display order: enabled entries first in current boot order, then the rest (unchecked, label greyed).
  - Current order read: devices with `<boot order>` sorted; if none, legacy `<os><boot dev>` converted (first disk / cdrom / floppy / first NIC).
  - Up/Down sensitive only for a checked row that isn't first/last among checked rows; swaps adjacent model rows.
  - Apply (per-device): removes all `<os><boot dev>`, clears every device's `<boot order>`, then sets `<boot order="1..N">` on checked devices in list order. Legacy: writes `<os><boot dev=…/>` list.
- Boot page XML edits are not hotplugged → running VM gets after-shutdown dialog (autostart excepted).
## 2b. Details pages: devices

Source: virt-manager `bac5379` — `virtManager/details/details.py`, `virtManager/object/domain.py`, `virtManager/addhardware.py` (shared combo builders / pretty-name helpers), `virtManager/device/*.py`, `virtinst/devices/*.py`, `ui/details.ui`, `ui/{gfx,fs,tpm,vsock}details.ui`, `ui/netlist.ui`, `ui/addstorage.ui`.

### Common behaviour (all device pages)

- **Hardware list (left sidebar)**: one row per device, ordered by page type: Disk, NIC, Input, Graphics, Sound, Char (serial → parallel → console → channel), Hostdev, Redirdev, Video, Watchdog, Controller, Filesystem, Smartcard, TPM, RNG, Panic, VSOCK. Static rows before them: "Overview", "OS information", "Performance" (hidden in customize-before-install dialog), "CPUs", "Memory", "Boot Options".
- **Devices NOT listed / no page**: `memballoon`, `shmem`, `iommu`, `audio`, `memory` (DIMM/virtio-mem), `pstore`, `hub`, `crypto`, … Edit them only through the domain XML editor (Overview row → XML tab).
- **Hidden controller rows**: models `ich9-uhci1`/`ich9-uhci2`/`ich9-uhci3` (USB2 companion controllers), `pcie-root-port`, `dmi-to-pci-bridge`, `pci-bridge`.
- **Console dup**: if `serial[0]` has a duplicate `<console>` (same `type`, and console `target/@type` is unset or `serial`), the first console gets no row.
- **Every device page has "Details" and "XML" tabs.** On Apply, XML-tab edits win over form edits. The XML tab calls `replace_device_xml`, which only does a persistent define and never attempts hotplug.
- **Buttons**: "_Remove", "_Cancel", "_Apply". Apply/Cancel become sensitive on the first edit. Changing the list selection with unapplied edits shows a confirmation prompt (`confirm_unapplied_changes`), which offers to apply them.
- **Apply flow** (`vmmAddHardware.change_config_helper`):
  1. Runs `define_X(devobj, do_hotplug=False, **edits)`. This looks up the matching device in the **inactive** XML, mutates it, and redefines the domain.
  2. If the VM is running, runs `define_X(devobj, do_hotplug=True, **edits)`. This mutates the **live** device object and calls `virDomainUpdateDeviceFlags(xml, VIR_DOMAIN_DEVICE_MODIFY_LIVE)`.
  3. If the live update fails, a WARNING dialog says "These changes will take effect after the next guest shutdown." and includes the error and traceback as details. The same text appears as INFO when no hotplug was attempted (XML-editor edits).
  - virt-manager always *attempts* a live update for every device page. Whether it succeeds depends on libvirt. libvirt-qemu `updateDevice` accepts roughly: disk/cdrom/floppy media change (plus some disk props), interface `link/@state`/bandwidth/filterref (not model/MAC/source type), graphics `passwd`/`passwdValidTo`/`connected`. Anything else falls back to "next shutdown".
- **Edit tracking**: only fields the user touched are sent (`_active_edits`). Each `define_*` receives only those kwargs.
- **Combos**: most combos are `GtkComboBox` *with entry* (`has-entry=True`): `disk-bus`, `network-model`, `sound-model`, `video-model`, `watchdog-model`, `watchdog-action`, `smartcard-mode`, `controller-model`, `graphics-address`.
  - A value in the XML that isn't in the list is shown as raw text in the entry.
  - Typed free text is returned as the raw XML value.
  - Plain combos (no entry) silently select row 0 when the value is unknown.
  - `build_simple_combo` sorts rows **by label** unless `sort=False`.
- **Remove**:
  - Disk: opens the "Remove Disk Device" dialog ("Remove disk device '<target>'"). It has an optional delete-storage checkbox, default off.
  - Other devices: confirmation "Are you sure you want to remove this device?" with a "don't ask again" checkbox (gsettings `confirm_removedev`).
  - Removal = `remove_device` (persistent) then `detachDevice` (live). If hot-unplug fails, an INFO dialog says "Device could not be removed from the running machine" / "This change will take effect after the next guest shutdown." (plus " Storage will not be deleted." when deleting storage).
- **Remove disabled**, with tooltip:
  - "Hypervisor does not support removing this device":
    - input mouse/keyboard on bus `ps2` or `xen`
    - USB controller on x86
    - any `pci` controller
  - "Cannot remove last video device while Graphics/Display is attached.": the last video device while any graphics device exists.
  - "Cannot remove controller while devices are attached.":
    - `nvme`/`scsi`/`sata`/`ide`/`fdc` controller with attached disks
    - `virtio-serial` controller with attached channels/consoles

#### Hardware-list labels and icons (`_label_for_device`, `_icon_for_device`)

| devtype | label | icon |
|---|---|---|
| disk (floppy) | "Floppy N" | `media-floppy` |
| disk (cdrom) | "<Bus> CDROM N" | `media-optical` |
| disk (disk) | "<Bus> Disk N" | `drive-harddisk` |
| disk (other, e.g. lun) | "<Bus> <Device.capitalize()> N" | `drive-harddisk` |
| interface | "NIC <last 9 chars of MAC>" (e.g. "NIC :a1:b2:c3") | `network-idle` |
| input | "Tablet" / "Mouse" / "Keyboard" / "Input" | `input-tablet` / `input-mouse` / `input-keyboard` |
| graphics | "Display VNC" / "Display Spice" / "Display SDL" / "Display RDP" / "Display <Type>" | `video-display` |
| sound | "Sound <model>" (raw model) | `audio-card` |
| serial / parallel / console | "Serial N" / "Parallel N" / "Console N" (N = target port + 1) | `device_serial` |
| channel | "Channel (<name>)", where name ∈ "spice", "qemu-ga", "libguestfs", "spice-webdav". Otherwise, or for `qemu-vdagent`: "Channel <pretty type>" | `device_serial` |
| hostdev | `hostdev_pretty_name` (see Hostdev) | `device_usb` (usb), else `device_pci` |
| redirdev | "<Bus> Redirector N" (N = XML index + 1) | `device_usb` |
| video | "Video <pretty model>" | `video-display` |
| watchdog | "Watchdog" | `device_pci` |
| controller | "Controller <pretty desc> <index>" (or without index) | `device_pci` |
| filesystem | "Filesystem <target[:8]>" | `folder` |
| smartcard | "Smartcard" | `device_serial` |
| tpm | "TPM <device_path>", else "TPM v<version>", else "TPM" | `device_cpu` |
| rng | "RNG <device>" or "RNG" | `system-run` |
| panic | "Panic Notifier" | `system-run` |
| vsock | "VirtIO VSOCK" | `network-idle` |

- Disk N is counted per (`device` + `bus`) key, in XML order, starting at 1.
- Disk bus pretty names (`disk_pretty_bus`): `ide` "IDE", `nvme` "NVMe", `sata` "SATA", `scsi` "SCSI", `sd` "SD", `usb` "USB", `virtio` "VirtIO", `xen` "Xen". Any other value is shown raw.

---

### Disk

Page frame "<b>Virtual Disk</b>". Covers device types `disk` and `lun`. CDROM/floppy use the same page; see next section.

| UI label | Widget | Editable | XML | Notes |
|---|---|---|---|---|
| "Source path:" | label | no (for `disk`/`lun`) | `source/@file\|@dev\|@dir\|pool+volume\|network` (via `get_source_path`) | Shows "-" if empty. **The path of a hard disk can't be changed in the details page** (XML editor only). |
| "Device type:" | label | no | — | Shows the hw-list label, e.g. "VirtIO Disk 1". |
| "Storage size:" | label | no | — | Storage-volume pretty capacity if the path maps to a known pool volume, "Unknown" if not, "-" if there's no path. |
| "Disk b_us:" | combo (customize dialog) / label (normal) | **only in customize-before-install dialog** | `target/@bus` | In a normal details window the bus is shown read-only (label "Disk bus:"). |
| Advanced options expander ("Advanced _options", collapsed) | | | | from `addstorage.ui` |
| "Cac_he mode:" | combo (unsorted) | yes | `driver/@cache` | Rows: "Hypervisor default" (None), "none", "writethrough", "writeback", "directsync", "unsafe". |
| "Discard mod_e:" | combo (unsorted) | yes | `driver/@discard` | Rows: "Hypervisor default" (None), "ignore", "unmap". |
| "R_eadonly:" | checkbox | yes (insensitive for cdrom) | `<readonly/>` | |
| "Sharea_ble:" | checkbox | yes | `<shareable/>` | |
| "Removab_le:" | checkbox | yes | `target/@removable` on/off | Row visible only when `bus == "usb"`. |
| "Seria_l:" | entry | yes | `<serial>` | Empty → element removed. |

- **Not exposed in the UI** (XML editor only): `driver/@io` (`IO_MODE_NATIVE="native"` etc.), `driver/@detect_zeroes`, `driver/@error_policy`, `driver/@iothread`, `driver/@queues`, `driver/@discard_no_unref`, `driver/@copy_on_read`, `driver/@type`, `driver/@name`, `target/@dev`, boot order (Boot Options page), blkiotune, encryption.
- **Bus list** (`populate_disk_bus_combo` → `disk_recommended_buses`):
  - Source:
    - If domcaps has `<disk><enum name='bus'>`, use those values.
    - Else the fallback `disk_old_recommended_buses`:
      - HVM or test: `ide` (not on q35), `sata`, `fdc`, `nvme`, `scsi`, `usb`, plus `sd`, `virtio` for qemu/kvm/test.
      - Xen or test: also `xen`.
  - Filtered by device type:
    - `disk`: ide, nvme, sata, scsi, sd, usb, virtio, xen
    - `cdrom`: ide, sata, scsi, usb
    - `floppy`: fdc
    - `lun`: scsi
  - Display labels: `disk_pretty_bus`. Sorted by label.
- **Bus change** (`DeviceDisk.change_bus`):
  - Clears `<address>`.
  - If the target prefix changes, regenerates `target/@dev` avoiding used targets. Prefixes: virtio→`vd`, xen→`xvd`, fdc/floppy→`fd`, ide→`hd`, nvme→`nvme<N>n<i>`, sata/scsi/usb/sd→`sd`.
- **Default bus** for new disks (`_default_bus`, for reference):
  1. floppy → `fdc`
  2. xenpv → `xen`
  3. non-HVM → `ide`
  4. disk and guest supports virtio-disk → `virtio`
  5. q35 → `sata`
  6. bhyve → `sata`
  7. x86 → `ide`
  8. cdrom and virtio-scsi supported → `scsi`
  9. vexpress → `sd`
  10. otherwise `usb`
- **Defaults on create** (reference):
  - cdrom → `readonly=True`.
  - qemu block-device disk → `cache=none`, `io=native`, `discard=unmap`.
  - qemu sparse new volume → `discard=unmap`.
- **Apply**: `vmmDomain.define_disk(path, readonly, shareable, removable, cache, discard, bus, serial)`.
  - Persistent path change: `sync_path_props()` + `validate()`.
  - Live: same fields set on the live device, then `updateDeviceFlags(LIVE)`. Only media change and similar succeed live. Bus/cache/etc. → "next guest shutdown".

### CDROM / Floppy (removable media)

Same page as Disk, but "Source path" is replaced by an editable media combo + "_Browse" button (`disk-source-box` visible, `disk-source-label` hidden).

- **Media combo** (`vmmMediaCombo`, `GtkComboBox` with entry):
  - Placeholder "No media selected".
  - Secondary clear icon `edit-clear-symbolic` empties the entry. Applying empty = **eject** (`path=None` → `<source>` removed).
  - Rows, in order:
    1. ISO history paths (gsettings `iso-paths`, label = path).
    2. Separator, if both groups are present.
    3. Host optical/floppy nodedevs matching the media type, labelled "<media label> (<block dev>)". Media label is `media_label`, "Media Unknown", or "No media detected" when `media_available` is false.
  - Typing an arbitrary path is allowed.
  - On Apply, any path not starting with `/dev` is added to the ISO history.
- **"_Browse"**: storage browser. Reason `REASON_ISO_MEDIA` gives title "Locate ISO media" / "Locate ISO media volume". For floppy, `REASON_FLOPPY_MEDIA` gives "Locate floppy media" / "Locate floppy media volume".
- **No separate "Connect"/"Disconnect" buttons** in this version. Insert = choose path + Apply. Eject = clear entry + Apply.
- **Apply checks** (path edits):
  - If another guest uses the path: yes/no prompt "Disk '%(path)s' is already in use by other guests %(names)s" / "Do you really want to use the disk?".
  - Emulator search-permission check: "The emulator may not have search permissions for the path '%s'." / "Do you want to correct this now?", with a "Don't ask about these directories again." checkbox. The fix is setfacl/chmod on parent dirs.
- **Live**: `define_disk(do_hotplug=True)` sets the source on the live device, then `updateDeviceFlags(VIR_DOMAIN_DEVICE_MODIFY_LIVE)`. This is the hot media change.
- Readonly checkbox is insensitive for cdrom (always read-only). It stays sensitive for floppy.
- Bus list for cdrom: `ide`/`sata`/`scsi`/`usb` (∩ domcaps). Floppy: `fdc`.

### NIC

Page frame "<b>Virtual Network Interface</b>".

| UI label | Widget | Editable | XML | Notes |
|---|---|---|---|---|
| "_Network source:" | `vmmNetworkList` combo (no entry) | yes | `@type` + `source/@network\|@bridge\|@dev` + `source/@mode` + `source/@portgroup` | see below |
| "De_vice name:" | entry | yes (manual rows only) | `source/@bridge` (bridge) or `source/@dev` (direct, vdpa) | Visible for "Bridge device...", "Macvtap device...", "vDPA device..." rows. |
| "_Portgroup:" | combo with entry | yes | `source/@portgroup` | Visible only if the selected virtual network defines portgroups. Defaults to the network's default portgroup. |
| macvtap warning | label | — | — | Small text "In most configurations, macvtap does not work for host to guest network communication…", shown for `direct`. |
| "Failed to find a suitable default network." | warn | — | — | Only when the default selection falls back to a manual row. |
| "Device mode_l:" | combo with entry | yes | `model/@type` | Rows: "Hypervisor default" (None) + recommended models, sorted by label. |
| "_MAC address:" | label (normal) / entry (customize dialog) | **only in customize dialog** | `mac/@address` | On change: `check_mac_in_use` → error "The MAC address '%s' is in use by another virtual machine." |
| "Link _state:" | checkbox, label "active" | yes | `link/@state` = `up` / `down` | Checked when `link_state == "up"` or unset. **Live-applicable** (libvirt supports link-state updateDevice). |
| "I_P address:" | label + refresh button | no | — | IPv4 and IPv6 (with `/prefix`), newline-separated. "Unknown" if none. |

- **Network source rows** (`_populate_network_model`):
  1. "Usermode networking" (`type=user`), only for unprivileged qemu (qemu:///session).
  2. One row per libvirt virtual network, sorted by label: "Virtual network '<name>' : <forward desc>".
     - Forward desc ∈ "Isolated network", "NAT", "NAT to <dev>", "Routed network", "Route to <dev>", "<Mode> network" (e.g. "Bridge network", "Open network").
     - Suffixes: " (Inactive)" if inactive, " (OpenVSwitch)" if `virtualport_type == openvswitch`.
  3. "Bridge device..." (`type=bridge`, manual).
  4. "Macvtap device..." (`type=direct`, manual).
  5. "vDPA device..." (`type=vdpa`, manual).
  - Unknown existing types (e.g. `ethernet`, `vhostuser`, `user` on a system connection) are inserted at the top as "<Type.capitalize()> '<source>'".
  - Runtime `type=bridge` with `source/@network` is treated as `type=network`.
- **Source change semantics** (`define_network`):
  - Clears all of `source/@bridge|@network|@dev`, then sets `@type` and the source field for that type.
  - `source/@mode` is set to `"bridge"` for `direct` (macvtap), and cleared otherwise.
  - `portgroup` is set or cleared.
- **NIC types** (`DeviceInterface.TYPE_*`): `bridge`, `network`, `user`, `vhostuser`, `ethernet`, `direct`, `vdpa`.
- **Recommended models** (`interface_recommended_models`):
  - Non-HVM: none.
  - `virtio` for bhyve/kvm/qemu/vz/test.
  - x86 q35: `e1000e`.
  - x86 non-q35: `rtl8139` (not bhyve) and `e1000`.
  - xen/test: `netfront`.
  - Display label = raw value.
- **Default model** (`DeviceInterface.default_model`):
  - Non-HVM: None.
  - virtio-net supported: `virtio`.
  - q35: `e1000e`.
  - Non-x86: None.
  - Otherwise the first osinfo-supported of `e1000`, `rtl8139`, `ne2k_pci`, `pcnet`, falling back to `e1000`.
- **Model change** clears `<address>`.
- **Refresh IP button**:
  - type=network: refreshes the network's DHCP leases.
  - If running: queries `interfaceAddresses` from the guest agent (when the agent is ready) and from ARP.
  - Lookup priority: agent → DHCP leases → ARP. IPv6 `fe80*` is ignored for agent/ARP.
- If the selected virtual network is inactive, Add Hardware prompts "Virtual Network is not active." to start it. Details Apply does not run that check.
- **Live**: libvirt accepts link state live. Model/MAC/source-type changes fall back to "next guest shutdown".

### Input

Page frame "<b>Virtual Input Device</b>". **Read-only**: no Apply-able fields.

| UI label | Value |
|---|---|
| "Type:" | `input_pretty_name(type, bus)` |
| "Mode:" | "Absolute Movement" (tablet) / "Relative Movement" (mouse). Row hidden otherwise. |

- **`input_pretty_name`**:
  - tablet+usb → "EvTouch USB Graphics Tablet".
  - Otherwise "<bus label> <type label>":
    - Bus labels: `ps2` "PS/2", `usb` "USB", `virtio` "VirtIO", `xen` "Xen". Others are raw.
    - Type labels: `keyboard` "Keyboard", `mouse` "Mouse", `tablet` "Tablet". Others are raw.
- **XML**: `@type` ∈ `mouse`, `tablet`, `keyboard`, `evdev`; `@bus` ∈ `ps2`, `usb`, `virtio`, `xen`. Default type `mouse`.
- **Add-HW choices** (reference): (tablet,usb), (mouse,usb), (keyboard,usb), (keyboard,virtio), (tablet,virtio).
- Remove is disabled for mouse/keyboard on `ps2`/`xen`.

### Graphics

Page frame title "<b><TYPE> Server</b>", e.g. "VNC Server", "Spice Server". `graphics_pretty_type_simple`: vnc/sdl/rdp upper-case, others capitalized. Widget: `vmmGraphicsDetails` (`gfxdetails.ui`).

| UI label | Widget | XML | Values / default |
|---|---|---|---|
| "_Type:" | combo (unsorted) | `@type` | "Spice server" (`spice`), "VNC server" (`vnc`). Only these two. sdl/rdp/egl-headless/dbus aren't selectable, and those types hide every row. |
| "L_isten type:" | combo | `<listen type=…>` | "Address" (`address`), "None" (`none`). With no `<listen>` child, row 0 = "Address" is shown. |
| "Addr_ess:" | combo **with entry** | `@listen` / `listen/@address` | "Hypervisor default" (None), "Localhost only" (`127.0.0.1`), "All interfaces" (`0.0.0.0`), or any typed IP. Visible when listen = address. |
| "_Port:" | "A_uto" checkbox + spin (5900–50000) | `@port`, `@autoport` | Auto → `port=-1` (autoport). When running, the checkbox reads "A_uto (Port N)". Tri-state "inconsistent" when the XML has no port. Spin hidden when auto. Visible when listen = address. |
| "Pa_ssword:" | checkbox + entry + "Show passwor_d" checkbox | `@passwd` | Unchecked → `passwd` removed. Entry insensitive and cleared when unchecked. Entry hidden-text unless "Show password" is checked. |
| "Open_GL:" | checkbox | `gl/@enable` yes/no | **Spice only.** |
| (GL sub-options) rendernode combo | combo | `gl/@rendernode` | "Auto" (None) + each host DRM render node (`/dev/dri/renderD*`, label = nodedev pretty name). Visible when Spice and GL is on. |
| warnings | labels | — | "OpenGL only works with 'virtio' graphics with '3D acceleration' enabled" (shown unless a virtio video device with accel3d exists). "OpenGL only works with 'Listen type' value 'none'" (shown unless listen ∈ none/socket). |

- **Row visibility** (`_sync_ui`):
  - vnc/spice: password + listen type.
  - listen = address: also port + address.
  - spice: also OpenGL; plus sub-options when GL is checked.
- **Apply values** (`get_values`):
  - listen = none → `listen="none"`. This removes all listens and port/tlsPort/autoport/socket, and adds `<listen type='none'/>`.
  - listen = address → `listen=<addr or None>`.
  - Port auto → `-1`.
  - Switching none → address while the port checkbox is inconsistent forces autoport.
- **define_graphics** sets: `listen`, `port`, `passwd`, `type` (`gtype`), `gl`, `rendernode`.
  - Spice: `port=-1` with `tlsPort=-1` → `autoport=yes`.
  - Changing type to vnc clears `@connected` unless `keep`.
- **Live**: updateDevice attempted. libvirt accepts password changes live; type/listen/port/gl changes need a restart.
- **Not exposed** (XML only): keymap, tlsPort, websocket, image/streaming/zlib compression, clipboard, mouse mode, filetransfer, defaultMode, passwdValidTo, socket listen.

### Sound

Page frame "<b>Sound Device</b>".

| UI label | Widget | XML | Values |
|---|---|---|---|
| "M_odel:" | combo with entry (sorted by label) | `@model` | `ac97` "AC97", `ich6` "HDA (ICH6)", `ich9` "HDA (ICH9)", `usb` "USB". |

- `sound_pretty_model`: upper-case; ich6/ich9 become "HDA (ICH6)" / "HDA (ICH9)".
- Other libvirt models (`es1370`, `sb16`, `pcspk`, `ich7`, `ics6`…) show as raw text in the entry.
- **Default** (`DeviceSound.default_model`): `ich9` if `defaults_to_pcie()` (q35, arm machvirt, riscv virt, loongarch64), else `ich6`.
- **Model change** clears `<address>`. Live update is attempted but generally fails, so it takes effect at next shutdown.
- Not exposed: `codec`, `audio/@id`, multichannel, streams.

### Serial / Parallel / Console / Channel (char devices)

Single "char" page. **Read-only.** There is no "Open console" button on this page: text consoles open from the VM window's View → Consoles menu, which only supports `pty` and `nmdm` (other types give "Console for device type '%s' is not supported").

- **Header**: "<b>Serial Device</b>" / "Parallel Device" / "Console Device" / "Channel Device".
  - Serial/parallel: " <port+1>" is appended.
  - Console: " <port+1>" is appended.
  - " (Primary Console)" is appended when the serial has a console duplicate.

| UI label | Value (row hidden if empty) | XML |
|---|---|---|
| "Device type:" | raw type, default `pty` | `@type` |
| "Source host:" | "host:port" | `source[@mode='connect']/@host`, `@service` |
| "Bind host:" | "host:port" | `source[@mode='bind']/@host`, `@service` |
| "Source path:" | path | `source/@path` |
| "Target type:" | console/channel only | `target/@type` |
| "Target name:" | | `target/@name` |
| "State:" | only for the qemu-ga channel (`org.qemu.guest_agent.0`) | `target/@state` (connected/disconnected) |
| "Clipboard:" | "On"/"Off", only for `qemu-vdagent` | `source/clipboard/@copypaste` |

- **Char types** (`_DeviceChar.TYPE_*`): `pty`, `dev`, `stdio`, `pipe`, `file`, `vc`, `null`, `tcp`, `udp`, `unix`, `spicevmc`, `spiceport`, `nmdm`, `qemu-vdagent`.
- **Pretty types** (`char_pretty_type`, used in channel labels):

  | Type | Label |
  |---|---|
  | `pty` | "Pseudo TTY" |
  | `file` | "Output to a file" |
  | `tcp` | "TCP net console" |
  | `udp` | "UDP net console" |
  | `unix` | "UNIX socket" |
  | `spicevmc` | "Spice agent" |
  | `spiceport` | "Spice port" |
  | `qemu-vdagent` | "QEMU vdagent" |

- **Channel names**: `com.redhat.spice.0`, `org.qemu.guest_agent.0`, `org.libguestfs.channel.0`, `org.spice-space.webdav.0`.
- **Add-HW recommended types** (reference):
  - console: `pty`.
  - serial/parallel: `pty`, `file`, `unix`.
  - channel: `spicevmc`, `spiceport`, `qemu-vdagent`, `pty`, `file`, `unix`.
- **Defaults**:
  - unix/tcp → `source/@mode=bind`.
  - channel target type `virtio`.
  - spicevmc/qemu-vdagent target name `com.redhat.spice.0`.

### Video

Page frame "<b>Video</b>".

| UI label | Widget | XML | Notes |
|---|---|---|---|
| "M_odel:" | combo with entry (sorted by label) | `model/@type` | see list |
| "_3D acceleration:" | checkbox (tri-state: inconsistent when unset) | `model/acceleration/@accel3d` yes/no | Row visible only when model = `virtio`. |

- **Model list** (`video_recommended_models`):
  - Xen: `xen`, `vga`.
  - qemu/test: `vga`, `bochs`, `qxl`, `virtio`, `ramfb`, `none`.
  - Other hypervisors: a single row "Hypervisor default" (None).
- **Labels** (`video_pretty_model`): qxl/vmvga/vga upper-case, others capitalized → "Bochs", "None", "QXL", "Ramfb", "VGA", "Virtio", "Xen".
- **Default model** (`DeviceVideo.default_model`):
  1. Non-HVM: None.
  2. pseries: `vga`.
  3. loongarch64, riscv virt, s390x+qemu: `virtio`.
  4. Spice+GL: `virtio`.
  5. domcaps virtio + osinfo virtio-gpu: `virtio`.
  6. x86 + spice + domcaps qxl: `qxl`.
  7. UEFI: arm → `ramfb`; with bochs support → `bochs`.
  8. Otherwise `vga`.
  - `virtio` with GL also gets `accel3d=yes`.
- **Model change** (`define_video`):
  - Clears `<address>`, `vram`, `heads`, `ram`, `vgamem`, `accel3d`.
  - A non-qxl model also clears `ram`, `vgamem`, `vram64`.
  - Restart needed.
- Remove disabled for the last video device while graphics exist.

### Watchdog

Page frame "<b>Watchdog</b>".

| UI label | Widget | XML | Values (label) | Default |
|---|---|---|---|---|
| "M_odel:" | combo with entry (sorted) | `@model` | `i6300esb` "I6300ESB", `ib700` "IB700", `diag288` "DIAG288" | `i6300esb` |
| "Ac_tion:" | combo with entry (sorted) | `@action` | `reset` "Forcefully reset the guest", `shutdown` "Gracefully shutdown the guest", `poweroff` "Forcefully power off the guest", `pause` "Pause the guest", `dump` "Dump guest memory core", `none` "No action" | `reset` |

- Model list is not filtered per arch. `diag288` is s390x only; libvirt also has `itco` and `pcie-vpd`, which aren't listed.
- Model change clears `<address>`. Action may apply live via updateDevice, depending on the libvirt version. Model needs a restart.

### Controller

Page frame "<b>Controller</b>".

| UI label | Widget | Editable | XML |
|---|---|---|---|
| "Type:" | label | no | `@type` (+`@model`) via `controller_pretty_desc` |
| "M_odel:" | combo with entry (unsorted) | yes | `@model` |
| "Serial:" | label | no | `<serial>`; nvme only, when set |
| "Devices:" | list | no | Attached devices, each row "<hw label> on <address pretty>". Shown for `nvme`/`scsi`/`sata`/`ide`/`fdc`. |

- **Types** (`DeviceController.TYPE_*`) and labels:

  | Type | Label |
  |---|---|
  | `ide` | "IDE" |
  | `fdc` | "Floppy" |
  | `scsi` | "SCSI" ("VirtIO SCSI" if model `virtio-scsi`) |
  | `nvme` | "NVMe" |
  | `sata` | "SATA" |
  | `virtio-serial` | "VirtIO Serial" |
  | `usb` | "USB" |
  | `pci` | "PCI" ("PCIe" if model `pcie-root`) |
  | `ccid` | "CCID" |
  | `xenbus` | "xenbus" |

- **Model combo rows** (`populate_controller_model_combo`):
  - `usb`: "USB 3" (`usb3`, pseudo-value), "USB 2" (`ich9-ehci1`), "Hypervisor default" (None).
  - `scsi`: "VirtIO SCSI" (`virtio-scsi`), "Hypervisor default".
  - All other types: "Hypervisor default" only.
- **Model row visibility**: shown if the XML has a model or the list has more than 1 row. Always hidden for `pci`.
- **USB display**: any model containing "xhci" (`qemu-xhci`, `nec-xhci`) is displayed as "USB 3".
- **USB model change** (`define_controller`) **removes all USB controllers** and replaces them:
  - `usb3`: one `qemu-xhci` controller (or `nec-xhci` if libvirt lacks qemu-xhci), with `ports=15` when supported.
  - `ich9-ehci1`: `ich9-ehci1` plus `ich9-uhci1`/`uhci2`/`uhci3` companions, with `master/@startport` 0/2/4.
  - Other values: a single `<controller type='usb' model=…>`.
  - Restart needed.
- **Non-USB model change**: sets `@model`, clears `<address>`, and also calls `hotplug(device=…)` (updateDevice) even in the persistent pass.
- **Remove restrictions**: see Common.
- **Add-HW types** (reference): `scsi` (default), `nvme`, `usb`, `virtio-serial`, `ccid`.

### Filesystem

Page frame "<b>Filesystem</b>". Widget: `vmmFSDetails` (`fsdetails.ui`).

| UI label | Widget | XML | Values / notes |
|---|---|---|---|
| "_Type:" | combo | `@type` | **Hidden for qemu/test.** LXC (container-only) offers `mount`, `file`, `block`, `ram` (label = value). Non-container connections offer only `mount`. |
| "_Driver:" | combo | `driver/@type` | qemu: "virtiofs" (`virtiofs`, only if domcaps supports virtiofs), "virtio-9p" (None = default 9p); not sorted. LXC: `loop`, `nbd`, "Hypervisor default" (None). Visible on qemu, or when type = `file`. |
| "_Format:" | combo | `driver/@format` | `raw`, `qcow2`. Visible only when driver = `nbd`. |
| "_Source path:" (or "Te_mplate:" for type `template`) | entry + "_Browse..." (directory browser, title "Locate directory volume") | `source/@dir` (mount), `@file` (file), `@dev` (block), `@name` (template) | |
| "_Usage:" + "MiB" | spin | `source/@usage` + `@units="MiB"` | Type `ram` only, shown instead of source path. |
| "Ta_rget path:" | entry | `target/@dir` | Must be absolute unless qemu/test with type mount (it's a mount tag there). Error: "Filesystem target '%s' must be an absolute path". |
| "E_xport filesystem as readonly mount" | checkbox | `<readonly/>` | Visible for qemu/test/lxc. |
| warning | label | — | "You may need to 'Enable shared memory' on the 'Memory' screen." Shown when driver = virtiofs and the VM lacks shared memory backing. |

- **Driver change** to or from `virtiofs` resets `@accessmode`:
  - virtiofs → None (libvirt default passthrough).
  - Otherwise `mapped`.
  - Access-mode constants: `MODE_MAPPED="mapped"`, `MODE_SQUASH="squash"`. Access mode isn't a UI field.
- **define_filesystem** copies: `type`, `accessmode`, `driver_type`, `driver_format`, `readonly`, `source_units`, `source`, `target`.
- Live update is attempted but generally fails, so changes take effect at next shutdown.
- **Defaults** (new device): `type=mount`, `accessmode=mapped` (non-virtiofs).
- **Not exposed**: `binary/*` (virtiofsd options), `driver/@queue`, `fmode`/`dmode`, `multidevs`, `model`, `source/@socket`.

### Smartcard

Page frame "<b>Smartcard Device</b>".

| UI label | Widget | XML | Values |
|---|---|---|---|
| "M_ode:" | combo with entry (sorted) | `@mode` | `host` "Host", `passthrough` "Passthrough" |

- **Mode change** also resets `@type` to `default_type()`: `spicevmc` for passthrough, else `tcp` (even for `host` mode).
- Default mode on create: `passthrough`.
- Restart needed.
- Not exposed: `source`, `database`, `certificate` (host-certificates mode).

### RNG

Page frame "<b>Random Number Generator</b>". **Read-only.**

| UI label | Value | XML |
|---|---|---|
| "Type:" | `rng_pretty_type(backend_model)`: `random` "Random", `egd` "Entropy Gathering Daemon", `builtin` "Builtin RNG", otherwise raw | `backend/@model` |
| "Host Device:" | backend text, e.g. `/dev/urandom`; row only for `random` | `backend[@model='random']` text |

- Model `@model` defaults to `virtio`.
- Not displayed: `rate/@bytes`, `rate/@period`, egd `backend/@type` / source.

### TPM

Page frame "<b>TPM Device</b>". Widget: `vmmTPMDetails` (`tpmdetails.ui`).

| UI label | Widget | XML | Values / default |
|---|---|---|---|
| "_Type:" | combo (unsorted) | `backend/@type` | "Emulated" (`emulator`), "Passthrough" (`passthrough`). Default emulator. |
| "Device _Path:" | entry | `backend/device/@path` | Passthrough only. Reset default `/dev/tpm0`. |
| "Adva_nced options" expander: "_Model:" | combo (unsorted) | `@model` | "Hypervisor default" (None), then domcaps `<tpm><enum name='model'>` values, or `[tpm-crb, tpm-tis]` if domcaps lacks tpm. Labels: `tpm-tis` "TIS", `tpm-crb` "CRB", `tpm-spapr` "SPAPR". |
| "_Version:" | combo (unsorted) | `backend/@version` | "Hypervisor default" (None), "2.0", "1.2". Emulator only. |

- **Constants**: `MODELS=[tpm-tis, tpm-crb, tpm-spapr]`, `TYPES=[passthrough, emulator]`, `VERSIONS=[1.2, 2.0]`.
- **default_model**:
  - No domcaps tpm and not pseries → `tpm-crb`.
  - domcaps lists crb → `tpm-crb`.
  - Otherwise None.
  - Applied on create only when emulator and neither model nor version is set.
- **define_tpm** copies `model`, `type`, `version`, `device_path`. Restart needed.
- Not exposed: `encryption/@secret`, `persistent_state`, `active_pcr_banks`, `profile`, `source`, `debug`.

### Panic

Page frame "<b>Panic Notifier</b>". **Read-only.**

| UI label | Value | XML |
|---|---|---|
| "Model:" | raw `@model` (empty if unset) | `@model` |

- Add-HW model list (reference): "Hypervisor default" (None) + `domcaps.supported_panic_models()` (domcaps `<panic><enum name='model'>`, e.g. `isa`, `pseries`, `hyperv`, `s390`, `pvpanic`). Label = value.
- With no model, `<panic/>` is a stub.
- An iobase without an address type gets `address/@type=isa`.

### VSOCK

Page frame "<b>Virtio VSOCK</b>". Widget: `vmmVsockDetails`.

| UI label | Widget | XML | Notes |
|---|---|---|---|
| "Guest C_ID:" | "A_uto" checkbox + spin (3 … 4294967295) | `cid/@auto` yes/no, `cid/@address` | Spin hidden when Auto. Label becomes "Auto (CID N)" when running and auto. `MIN_GUEST_CID = 3`. |

- `@model` defaults to `virtio`. With neither auto nor cid set → `auto=yes`.
- `define_vsock(auto_cid, cid)`; Auto and CID are tracked as separate edits. Restart needed.

### USB / PCI / MDEV / SCSI hostdev

Page frame title "<b>Physical <TYPE> Device</b>" (TYPE = `@type` upper-case, e.g. "Physical USB Device", "Physical PCI Device", "Physical MDEV Device").

| UI label | Widget | Editable | XML | Notes |
|---|---|---|---|---|
| "Device:" | label | no | `source/…` | Host nodedev pretty name if a matching nodedev is found (`compare_to_hostdev`). Otherwise `hostdev_pretty_name`. |
| "ROM _BAR:" | checkbox | yes | `rom/@bar` on/off | **PCI only.** Shown checked when unset (default on). |
| "_Startup Policy:" | combo (no entry, sorted) | yes | `source/@startupPolicy` | **USB only.** Rows: "Hypervisor default" (None), `mandatory`, `optional`, `requisite`. |

- **`hostdev_pretty_name`** = "<TYPE>" followed by the first match of:
  1. " vvvv:pppp" (vendor:product, hex without 0x)
  2. " BBB:DDD" (usb bus:device, zero-padded)
  3. " dddd:bb:ss.f" (pci)
  4. " <uuid>" (mdev)
- **define_hostdev(rom_bar, startup_policy)**: restart needed. updateDevice is attempted and generally fails.
- **Defaults on create**: `managed = yes` (`no` on Xen); `mode = subsystem`.
- Not exposed: `managed`, `driver/@name`, `rom/@file`, `display`, `ramfb`, `acpi`, boot order (Boot page).

### Redirdev

Page title = hw-list label in bold (e.g. "USB Redirector 1"). **Read-only.**

| UI label | Value | XML |
|---|---|---|
| "Type:" | `redirdev_pretty_type`: `tcp` "TCP", `spicevmc` "SpiceVMC", others capitalized | `@type` |
| "Address:" | "host:service", tcp only | `source/@host`, `source/@service` |

- Defaults: `bus=usb`, `type=spicevmc`.
- Add-HW offers only "Spice channel" (`spicevmc`).
- Removable.
- Redirdev is excluded from the boot list.

### Memballoon

- **Not shown** in the hardware list; no page. It's only visible and editable through the domain XML editor.
- XML (reference): `@model` (default `virtio`), `@autodeflate` on/off, `@freePageReporting` on/off, `stats/@period`.
- Note: memory stats polling elsewhere relies on it.

### Other devices (shmem, iommu, audio, memory, pstore, …)

- **Not shown** in the hardware list; no details page. Domain XML editor only.
- `virtinst/devices` defines `shmem.py`, `iommu.py`, `audio.py`, `memory.py`, `pstore.py`, but `details.py` never enumerates them.

### Edit → libvirt mapping summary

| Page | define_* | Fields | Live attempt | Typically live in libvirt-qemu |
|---|---|---|---|---|
| Disk / CDROM / Floppy | `define_disk` | path, readonly, shareable, removable, cache, discard, bus, serial | yes | media path (cdrom/floppy) only |
| NIC | `define_network` | ntype+source+mode+portgroup, model, macaddr, linkstate | yes | link state (also source within same type on newer libvirt) |
| Graphics | `define_graphics` | listen, port, passwd, gtype, gl, rendernode | yes | passwd |
| Sound | `define_sound` | model | yes | no |
| Video | `define_video` | model, accel3d | yes | no |
| Watchdog | `define_watchdog` | model, action | yes | action (recent libvirt) |
| Smartcard | `define_smartcard` | mode (+type reset) | yes | no |
| Controller | `define_controller` | model (USB: replace all USB ctrls) | yes | no |
| Filesystem | `define_filesystem` | type, accessmode, driver type/format, readonly, source(+units), target | yes | no |
| Hostdev | `define_hostdev` | rom_bar, startup_policy | yes | no |
| TPM | `define_tpm` | model, type, version, device_path | yes | no |
| VSOCK | `define_vsock` | auto_cid, cid | yes | no |
| Input / Char / Redirdev / RNG / Panic | — (read-only) | — | — | — |
| any (XML tab) | `replace_device_xml` | whole device | **no** | — |

- Customize-before-install dialog only:
  - Disk bus becomes a combo.
  - MAC becomes an entry.
  - No Performance page.
## 3. Add Hardware dialog

Sources: `virtManager/addhardware.py`, `virtManager/device/{addstorage,netlist,gfxdetails,fsdetails,tpmdetails,vsockdetails}.py`, `virtManager/object/domain.py`, `virtManager/object/nodedev.py`, `virtManager/object/network.py`, `virtManager/connection.py`, `virtManager/config.py`, `virtManager/lib/uiutil.py`, `virtinst/devices/*.py`, `virtinst/storage.py`, `virtinst/diskbackend.py`, `virtinst/generatename.py`, `ui/addhardware.ui`, `ui/addstorage.ui`, `ui/netlist.ui`, `ui/gfxdetails.ui`, `ui/fsdetails.ui`, `ui/tpmdetails.ui`, `ui/vsockdetails.ui`, `ui/xmleditor.ui`.

### 3.0 Window shell

- Window title: `"Add New Virtual Hardware"`. Buttons: `"_Cancel"`, `"_Finish"` (id `create-finish`). Esc closes.
- Layout: left sidebar list (column header `"Hardware"`, min width 165, icon + text, insensitive rows greyed) | right: page title bar (`page-title-label`) + page notebook (tabs hidden) wrapped by XML editor notebook with tabs `"_Details"` / `"_XML"` (XML tab tooltip `"Edit libvirt XML"`; when XML editing disabled in prefs: `"XML editing is disabled in 'Preferences'. Only enable it if you know what you are doing."`).
- On `show()`: every page reset (`_reset_state`), sidebar selects row 0 (Storage), triggers priority poll of nets/pools/nodedevs.
- Selecting an **insensitive** row → error page (`top-pages` page 1) with label = row's tooltip text or fallback `"Hardware selection error."`; Finish disabled.
- Selecting any sensitive row re-enables Finish (some pages then disable it again: Controller, Host device).
- XML tab: shows `dev.get_xml()` of what the Details page would build. If XML tab is active on Finish, device is re-parsed from edited XML. For disks: if source path unchanged and original had a pending volume creation, the vol-install is carried over; else `set_backend_for_existing_path()` so path is validated.
- Generic errors:
  - build: `"Error building device XML: %s"`
  - validate: `"Error validating device parameters: %s"`
  - add: `"Unable to add device: %s"` (+ traceback details)
- Finish runs async job: title `"Creating device"`, text `"Depending on the device, this may take a few minutes to complete."` → `_setup_device` (disk storage creation only) → `_add_device` (§3.19). Dialog closes after (also when user answers "No" to the hotplug prompt).

### 3.1 Sidebar categories (exact order)

Model columns: label, icon-name, page, sensitive, tooltip/error text, sub-type.

| # | Label | Icon | Page | Sensitive when | Error text when insensitive | Sub-type |
|---|---|---|---|---|---|---|
| 1 | `"Storage"` | `drive-harddisk` | DISK | local conn, or remote conn supports storage API | **None** (bug: `have_storage and storage_tooltip or None` always None → falls back to `"Hardware selection error."`). Intended: `"Connection does not support storage management."` | – |
| 2 | `"Controller"` | `device_pci` | CONTROLLER | always | – | – |
| 3 | `"Network"` | `network-idle` | NETWORK | always | – | – |
| 4 | `"Input"` | `input-mouse` | INPUT | `vm.is_hvm()` | `"Not supported for this guest type."` | – |
| 5 | `"Graphics"` | `video-display` | GRAPHICS | always | – | – |
| 6 | `"Sound"` | `audio-card` | SOUND | `is_hvm()` | `"Not supported for this guest type."` | – |
| 7 | `"Serial"` | `device_serial` | CHAR | `is_hvm()` | `"Not supported for this guest type."` | `serial` |
| 8 | `"Parallel"` | `device_serial` | CHAR | `is_hvm()` | `"Not supported for this guest type."` | `parallel` |
| 9 | `"Console"` | `device_serial` | CHAR | always | – | `console` |
| 10 | `"Channel"` | `device_serial` | CHAR | `is_hvm()` | `"Not supported for this guest type."` | `channel` |
| 11 | `"USB Host Device"` | `device_usb` | HOSTDEV | conn supports nodedev API | `"Connection does not support host device enumeration"` | `usb` |
| 12 | `"PCI Host Device"` | `device_pci` | HOSTDEV | nodedev API **and** not container guest | nodedev: `"Connection does not support host device enumeration"`; container: `"Not supported for containers"` | `pci` |
| 13 | `"MDEV Host Device"` | `device_pci` | HOSTDEV | nodedev API | `"Connection does not support host device enumeration"` | `mdev` |
| 14 | `"Video"` | `video-display` | VIDEO | always (text `"Libvirt version does not support video devices."` is dead) | – | – |
| 15 | `"Watchdog"` | `device_pci` | WATCHDOG | `is_hvm()` | `"Not supported for this guest type."` | – |
| 16 | `"Filesystem"` | `folder` | FILESYSTEM | always | – | – |
| 17 | `"Smartcard"` | `device_serial` | SMARTCARD | always | – | – |
| 18 | `"USB Redirection"` | `device_usb` | USBREDIR | always | – | – |
| 19 | `"TPM"` | `device_cpu` | TPM | always | – | – |
| 20 | `"RNG"` | `system-run` | RNG | always | – | – |
| 21 | `"Panic Notifier"` | `system-run` | PANIC | always | – | – |
| 22 | `"VirtIO VSOCK"` | `network-idle` | VSOCK | `is_hvm()` | `"Not supported for this hypervisor/libvirt/arch combination."` | – |

- No arch/domcaps gating on the sidebar itself; gating is only `is_hvm()`, `is_container()`, conn capabilities.
- No Memory/IOMMU/Shmem/Audio/Pstore/Evdev page in Add Hardware.

Page titles (title bar):

| Page | Title |
|---|---|
| DISK | `"Storage"` |
| CONTROLLER | `"Controller"` |
| NETWORK | `"Network"` |
| INPUT | `"Input"` |
| GRAPHICS | `"Graphics"` |
| SOUND | `"Sound"` |
| VIDEO | `"Video Device"` |
| WATCHDOG | `"Watchdog Device"` |
| FILESYSTEM | `"Filesystem Passthrough"` |
| SMARTCARD | `"Smartcard"` |
| USBREDIR | `"USB Redirection"` |
| TPM | `"TPM"` |
| RNG | `"Random Number Generator"` |
| PANIC | `"Panic Notifier"` |
| VSOCK | `"VM Sockets"` |
| CHAR | `"%s Device" % DEVICE_TYPE.capitalize()` → `"Serial Device"`, `"Parallel Device"`, `"Console Device"`, `"Channel Device"` |
| HOSTDEV | `"USB Device"` / `"PCI Device"` / `"MDEV Device"` |

**Combo sorting rule** (applies everywhere `uiutil.build_simple_combo` is used without `sort=False`): rows are **sorted by label ascending** (GTK collation); when no default value is given, the first *sorted* row is selected. Combos marked "editable" have a text entry: free text is accepted and used as the XML value when no row matches.

After any page builds its device: `dev.set_defaults(vm.get_xmlobj())` is called (fills defaults noted below).

---

### 3.2 Storage

#### Fields (top → bottom)

| Widget | Label | Type | Default |
|---|---|---|---|
| `storage-create` | `"C_reate a disk image for the virtual machine"` | radio | selected |
| `storage-size` | (suffix `"_GiB"`) | spin, 0 – 1000000, step 0.1, 1 decimal | `20` |
| `phys-hd-label` | `"%s available in the default location"` with `"%.1f GiB"` or `"Unknown GiB"` | label | default pool `available` (pool refreshed if last refresh > 10 s) |
| `storage-select` | `"_Select or create custom storage"` | radio | – |
| `storage-browse` | `"_Manage..."` | button → storage browser (reason `image`: `"Locate existing storage"` / `"Locate or create storage volume"`, button `"_Open"`) | sensitive only when `storage-select` active |
| `storage-entry` | (path entry) | text | `""` |
| `storage-devtype` | `"_Device type:"` | combo with icons | row 0 (`Disk device`) |
| `storage-bustype` | `"_Bus type:"` | combo (sorted) | see bus default |
| `storage-advanced` | expander `"Advanced _options"` | – | collapsed |
| `disk-cache` | `"Cac_he mode:"` | editable combo, **unsorted** | `"Hypervisor default"` |
| `disk-discard` | `"Discard mod_e:"` | editable combo, **unsorted** | `"Hypervisor default"` |
| `disk-readonly` | `"R_eadonly:"` | check | off |
| `disk-shareable` | `"Sharea_ble:"` | check | off |
| `disk-removable` | `"Removab_le:"` | check, row visible **only when bus == `usb`** | off |
| `disk-serial` | `"Seria_l:"` | entry | `""` |

- Whole storage box insensitive (tooltip `"Connection does not support storage management."`) if remote and no storage API.
- Advanced options are only written to XML if the user touched that widget (edit tracking); otherwise defaults from `set_defaults` apply.
- Not exposed in Add Hardware: `detect_zeroes`, `io`, iotune, error policy, boot order.

#### Device type list (`storage-devtype`, unsorted, in order)

| Value | Label | Icon | Condition |
|---|---|---|---|
| `disk` | `"Disk device"` | `drive-harddisk` | always |
| `cdrom` | `"CDROM device"` | `media-optical` | always |
| `floppy` | `"Floppy device"` | `media-floppy` | always |
| `lun` | `"LUN Passthrough"` | `drive-harddisk` | `conn.is_qemu()` or test |

- Device type change: refresh bus list; `cdrom`/`floppy` → `storage-create-box` insensitive and `storage-select` forced on. (`lun` still allows create.)

#### Bus list

Supported set = domcaps `devices.disk` enum `bus` if present; else fallback:
- if HVM (or test): `ide` (only if **not** q35), `sata`, `fdc`, `nvme`, `scsi`, `usb`; plus `sd`, `virtio` if domain type in `qemu`/`kvm`/`test`
- plus `xen` if xen (or test) connection

Filtered per device type:

| devtype | allowed buses |
|---|---|
| `disk` | `ide`, `nvme`, `sata`, `scsi`, `sd`, `usb`, `virtio`, `xen` |
| `cdrom` | `ide`, `sata`, `scsi`, `usb` |
| `floppy` | `fdc` |
| `lun` | `scsi` |

Bus labels: `ide`→`"IDE"`, `nvme`→`"NVMe"`, `sata`→`"SATA"`, `scsi`→`"SCSI"`, `sd`→`"SD"`, `usb`→`"USB"`, `virtio`→`"VirtIO"`, `xen`→`"Xen"`, `fdc`→`"fdc"` (raw, no mapping).

Bus default selection:
1. bus of the first existing disk in VM (live XML) with the same `device`;
2. else first row of the **label-sorted** list (e.g. `"IDE"` before `"VirtIO"`).
3. Only if list empty → bus `None` → `DeviceDisk._default_bus()` in `set_defaults`:
   - floppy → `fdc`; xenpv → `xen`; non-HVM → `ide`; disk && guest supports virtio-disk → `virtio`; q35 → `sata`; bhyve → `sata`; x86 → `ide`; cdrom && supports virtio-scsi → `scsi`; machine startswith `vexpress` → `sd`; else `usb`.

#### Cache / discard option lists

| Combo | Rows (value → label), in order |
|---|---|
| Cache | `None`→`"Hypervisor default"`, `none`, `writethrough`, `writeback`, `directsync`, `unsafe` |
| Discard | `None`→`"Hypervisor default"`, `ignore`, `unmap` |

#### Path resolution

- `storage-create` active → `get_default_path(vmname, collideguest=vm.xmlobj)`:
  - pool = `conn.get_default_pool()` = pool named `"default"`, else pool whose target path == `<libvirt data root>/images`; else none (no path → validation error).
  - data root: privileged conn `/var/lib/libvirt` → `/var/lib/libvirt/images`; session `$XDG_DATA_HOME/libvirt` (default `~/.local/share/libvirt/images`).
  - suffix from format: `raw`→`.img`, `qcow2`→`.qcow2`, none→`.img`.
  - name = `generate_name(vmname, collision, suffix)`: tries `vmname.qcow2`, then `vmname-1.qcow2`, `vmname-2.qcow2`, … (sep `-`, start 1, unnumbered first). Collision = existing volume in pool (pool started + refreshed first) **or** basename of any disk of this VM located in the pool dir.
  - full path = `pool.target_path/name`.
- `storage-select` → `storage-entry` text `.strip()`; `""` → None. `file://` prefix stripped.
- Path not under a pool: `manage_path` auto-creates a **dir pool** for the parent dir (name = parent basename, spaces→`_`, `"dirpool"` if empty, de-duplicated with `-N`), `build=False, create=True, autostart=True`. Not done for `/dev`, `/sys`, `/proc` paths or URLs.

#### Default pool auto-creation

- On every connection open (`connection.py` `_populate_initial_state`): `StoragePool.build_default_pool()` — if no default pool, define `dir` pool `name="default"`, `target_path=<data root>/images`, `build=True, create=True, autostart=True`. Failure only logged (`"Couldn't create default storage pool '%(path)s': %(error)s"`).

#### Storage creation (when path doesn't exist: `disk.wants_storage_creation()`)

- size = spin value (GiB, float); `capacity = size * 1024^3` bytes.
- format `fmt = conn.get_default_storage_format()`:
  - prefs `/new-vm/storage-format`: `"default"` | `"raw"` | `"qcow2"` (prefs labels: `"System default (qcow2)"`, `"Raw"`, `"QCOW2"`).
  - `"raw"`/`"qcow2"` explicit → used as-is; `"default"` → `qcow2` if hypervisor supports default qcow2 (qemu ≥ 1.2.0), else `None`.
- sparse = `fmt != "raw"` → allocation `0` (qcow2) or `= capacity` (raw: fully allocated).
- `vol.format = fmt` only if the volume type supports format (file volumes).
- Applies to custom typed non-existent paths too (e.g. typing `/x/new.img` creates a **qcow2** volume if prefs format is qcow2; size from the spinner even though it's under the other radio).
- Volume validate: format defaults to `raw` if unset; qcow2 gets `lazy_refcounts` if supported; logical pools force allocation = capacity.
- Volume install: `pool.createXML(xml, flags)`; qcow2 without backing gets `VIR_STORAGE_VOL_CREATE_PREALLOC_METADATA` if pool supports it. Progress text `"Allocating '%(filename)s'"`. Error `"Couldn't create storage volume '%s': '%s'"`.
- After creation the parent pool is refreshed.
- Size conflict:
  - fatal (raised as validation error) when `allocation > pool available`: `"There is not enough free space on the storage pool to create the volume. (%(mem1)s M requested allocation > %(mem2)s M available)"` → only reachable for raw/non-sparse.
  - non-fatal (`capacity > available`, sparse): `"The requested volume capacity will exceed the available pool space when the volume is fully allocated. (...)"` → **only logged**, never shown.
- No minimum size check (0 GiB accepted).

#### Validation (in order)

1. `disk.is_empty()` and device in `disk`/`lun` → `"A storage path must be specified."`
2. `disk.validate()`:
   - empty + not cdrom/floppy → `"Device type '%s' requires a path"`
   - non-existent and no creation info → `"Must specify storage creation parameters for non-existent path '%s'."`
   - creation: size check above; missing pool → `"Don't know how to create storage for path '%s'. Use libvirt APIs to manage the parent directory as a pool first."`
3. In-use check (respects shareable/readonly): `"Disk '%(path)s' is already in use by other guests %(names)s"` + `"Do you really want to use the disk?"` (Yes/No; No aborts).
4. Search-permission check for emulator user (`check_path_search`): `"The emulator may not have search permissions for the path '%s'."` / `"Do you want to correct this now?"` + checkbox `"Don't ask about these directories again."` (Yes/No). Fix errors: `"Errors were encountered changing permissions for the following directories:"` + details `"<dir> : <err>"` … `"It is very likely the VM will fail to start up."` Ignored dirs stored in config.

#### Target generation

- Used targets = targets of all disks in live XML + inactive XML.
- Prefix by bus: `virtio`→`vd` (max 1024), `xen`→`xvd` (1024), `fdc` or floppy→`fd` (2), `ide`→`hd` (4), `nvme`→`nvme` (1024), else (`sata`/`scsi`/`usb`/`sd`)→`sd` (1024).
- Letters: 1→`a` … 26→`z`, 27→`aa` … First free; error: `"Only %(number)s disk(s) for bus '%(bus)s' are supported"`.
- NVMe target: `nvme{ns}n{i}`, `ns` = index of nvme controller whose `<serial>` == disk serial, else 0.

#### Auto-added controller (attached/added together with disk)

- bus `scsi` and guest has **no** scsi controller and guest supports virtio-scsi → `<controller type="scsi" model="virtio-scsi" index="0"/>`.
- bus `nvme`:
  - existing nvme controller → disk serial (if empty) = first nvme controller's serial; no new controller.
  - none → disk serial (if empty) = `"0"`; add `<controller type="nvme" index="0"><serial>0</serial></controller>`.

#### `set_defaults` additions

- `type`: `file`/`block`/`volume`/`network` from backend; driver name `qemu` (qemu; xen+block → `phy`); driver type from backend (vol format; block or `iso` → `raw`).
- cdrom → `<readonly/>` forced.
- qemu + disk + new sparse volume (allocation 0) → `discard="unmap"` (if user didn't set discard).
- qemu + disk + type block → `discard="unmap"`, `cache="none"`, `io="native"` (if unset).
- usb bus + Removable checked → `<target ... removable="on"/>`.

#### XML examples

```xml
<!-- default "Create a disk image", qcow2 prefs, existing virtio disk -->
<disk type="file" device="disk">
  <driver name="qemu" type="qcow2" discard="unmap"/>
  <source file="/var/lib/libvirt/images/myvm-1.qcow2"/>
  <target dev="vdb" bus="virtio"/>
</disk>

<!-- empty CDROM on SATA -->
<disk type="file" device="cdrom">
  <target dev="sdb" bus="sata"/>
  <readonly/>
</disk>

<!-- NVMe disk, first NVMe controller auto-added -->
<controller type="nvme" index="0"><serial>0</serial></controller>
<disk type="file" device="disk">
  <driver name="qemu" type="qcow2" discard="unmap"/>
  <source file="/var/lib/libvirt/images/myvm-1.qcow2"/>
  <target dev="nvme0n1" bus="nvme"/>
  <serial>0</serial>
</disk>
```

---

### 3.3 Controller

| Widget | Label | Type | Rows | Default |
|---|---|---|---|---|
| `controller-type` | `"_Type:"` | editable combo (sorted) | `ccid`→`"CCID"`, `nvme`→`"NVMe"`, `scsi`→`"SCSI"`, `usb`→`"USB"`, `virtio-serial`→`"VirtIO Serial"` | `scsi` |
| `controller-model` | `"_Model:"` | editable combo (sorted); row hidden if only 1 row | per type, below | first row of the *unsorted* list |
| `controller-tooltip` | info icon | – | visible only on USB block | – |

Model rows per type:

| type | rows | selected |
|---|---|---|
| `usb` | `usb3`→`"USB 3"`, `ich9-ehci1`→`"USB 2"`, `None`→`"Hypervisor default"` | `usb3` |
| `scsi` | `virtio-scsi`→`"VirtIO SCSI"`, `None`→`"Hypervisor default"` | `virtio-scsi` |
| other | `None`→`"Hypervisor default"` (row hidden) | `None` |

Other pretty labels (used elsewhere): `ide`→`"IDE"`, `fdc`→`"Floppy"`, `sata`→`"SATA"`, `pci`→`"PCI"`, `xenbus`→`"xenbus"`; desc overrides `scsi`+`virtio-scsi`→`"VirtIO SCSI"`, `pci`+`pcie-root`→`"PCIe"`.

USB rules (on type change):
- VM has 0 USB controllers → Finish enabled, normal add.
- VM has exactly 1 USB controller with `model="none"` → Finish enabled; Finish **replaces** it instead of adding: `vm.define_controller(existing, model=<selected>)` via `change_config_helper` (§3.19): removes all USB controllers then adds: `ich9-ehci1` → 4 controllers (`ich9-ehci1`, `ich9-uhci1` startport 0, `ich9-uhci2` startport 2, `ich9-uhci3` startport 4); `usb3` → USB3 controller; other → one `usb` controller with that model.
- Otherwise → Finish disabled, info icon shown with tooltip: `"%s already has a USB controller attached.\nAdding more than one USB controller is not supported.\nYou can change the USB controller type in the VM details screen."` (`%s` = VM name).
- (Quirk: the "replace none-controller" flag isn't cleared when switching type away from USB.)

Build:
- index = `max(existing index of same type) + 1`, else `0`.
- `usb3` → `get_usb3_controller`: model `qemu-xhci` if libvirt ≥ 3.3.0 & qemu ≥ 2.9.0 else `nec-xhci`; `ports="15"` if libvirt ≥ 1.3.5.
- `ich9-ehci1` (add path) → single controller with that model (no companions).
- model `None`/`"none"` → no model attr.
- `nvme` → `<serial>` = str(index).

```xml
<controller type="scsi" index="1" model="virtio-scsi"/>
<controller type="usb" index="0" model="qemu-xhci" ports="15"/>
<controller type="nvme" index="1"><serial>1</serial></controller>
<controller type="virtio-serial" index="1"/>
```

---

### 3.4 Network

| Widget | Label | Type | Default |
|---|---|---|---|
| `net-source` | `"_Network source:"` | combo (insensitive rows supported) | see below |
| `net-manual-source` | `"De_vice name:"` | entry, row visible only for manual rows | `""`, or host default bridge |
| `net-macvtap-warn-box` | `"In most configurations, macvtap does not work for host to guest network communication."` | warning, visible for `direct` | – |
| `net-default-warn-box` | `"Failed to find a suitable default network."` | warning | hidden |
| `net-portgroup` | `"_Portgroup:"` | editable combo, row visible only if selected virtual network has portgroups | portgroup with `default='yes'` |
| `mac-address` + `create-mac-address` | `"_MAC address:"` | check + entry (entry sensitive iff checked) | checked, newly generated MAC |
| `net-model` | `"Device mode_l:"` | editable combo (sorted) | `DeviceInterface.default_model(guest)` |

#### Source list (`netlist.py`), order

1. `"Usermode networking"` (`type=user`) — only when `conn.is_qemu_unprivileged()` (qemu:///session); also disables default-bridge logic.
2. Virtual networks, sorted by label: `"Virtual network '<name>' : <mode>"` + `" (Inactive)"` if inactive + `" (OpenVSwitch)"` if virtualport openvswitch. (`type=network`)
   - mode (`pretty_forward_mode`): no forward → `"Isolated network"`; `nat` → `"NAT"` / `"NAT to <dev>"`; `route` → `"Routed network"` / `"Route to <dev>"`; other → `"<Mode> network"` (e.g. `"Bridge network"`, `"Open network"`).
3. `"Bridge device..."` (`type=bridge`, manual)
4. `"Macvtap device..."` (`type=direct`, manual; source mode `bridge`)
5. `"vDPA device..."` (`type=vdpa`, manual)

(Older labels like "Host device X: macvtap" / "Specify shared device name" do not exist in this source.)

Default selection:
1. Host default bridge exists (local conn, Linux `/proc/net/route` default-route iface that is a bridge, or legacy `xenbrN`) → `"Bridge device..."` with name prefilled.
2. else network named `default`.
3. else row 0; if row 0 is `"Bridge device..."` (no networks, not session) → show `"Failed to find a suitable default network."`.

List re-populates on `net-added`/`net-removed`, preserving current label selection.

#### MAC

- Generated on every dialog show: OUI `52:54:00` (qemu) else `00:16:3e` (xen) + 3 random bytes; retried up to 256× to avoid MACs in use on this connection.
- Unchecking the box sends `macaddr=None` → `set_defaults` generates a **new random MAC anyway**.
- Validation: `"The MAC address '%s' is in use by another virtual machine."`

#### Model list

- `"Hypervisor default"` (None) + `interface_recommended_models(guest)` (label = value), non-HVM → only Hypervisor default:
  - `virtio` if domain type in `bhyve`, `kvm`, `qemu`, `vz`, `test`
  - x86: q35 → `e1000e`; else `rtl8139` (not bhyve) + `e1000`
  - xen/test → `netfront`
- Default (`default_model`): non-HVM → None; guest supports virtio-net (qemu + osinfo, or always on riscv-virt/s390x/pseries/loongarch64) → `virtio`; q35 → `e1000e`; non-x86 → None; else first of `e1000`, `rtl8139`, `ne2k_pci`, `pcnet` supported by osinfo, else `e1000`.
- Selecting `"Hypervisor default"` → `set_defaults` still fills `default_model()`.

#### Validation

- Virtual network inactive → Yes/No: `"Virtual Network is not active."` / `"Virtual Network '%s' is not active. Would you like to start the network now?"`; Yes → start (error `"Could not start virtual network '%(device)s': %(error)s"`); No → proceed anyway.
- MAC in-use check; `net.validate()`.
- Bridge row with empty name → `set_defaults` fills host default bridge (may still be None).

```xml
<interface type="network">
  <source network="default"/>
  <mac address="52:54:00:6b:2c:1e"/>
  <model type="virtio"/>
</interface>
<interface type="bridge"><source bridge="br0"/><mac address="..."/><model type="virtio"/></interface>
<interface type="direct"><source dev="eth0" mode="bridge"/><mac address="..."/><model type="virtio"/></interface>
<interface type="vdpa"><source dev="/dev/vhost-vdpa-0"/><mac address="..."/><model type="virtio"/></interface>
<interface type="user"><mac address="..."/><model type="virtio"/></interface>
<!-- with portgroup -->
<interface type="network"><source network="ovsnet" portgroup="vlan-10"/>...</interface>
```

---

### 3.5 Input

- `"_Type:"` combo (sorted; built once, not reset on show). Value = (type, bus).

| Label | type | bus |
|---|---|---|
| `"EvTouch USB Graphics Tablet"` | `tablet` | `usb` |
| `"USB Keyboard"` | `keyboard` | `usb` |
| `"USB Mouse"` | `mouse` | `usb` |
| `"VirtIO Keyboard"` | `keyboard` | `virtio` |
| `"VirtIO Tablet"` | `tablet` | `virtio` |

- Default: first sorted = `"EvTouch USB Graphics Tablet"`.
- Label rule: tablet+usb special; else `"%(input_bus)s %(input_type)s"` with bus labels `ps2`→`"PS/2"`, `usb`→`"USB"`, `virtio`→`"VirtIO"`, `xen`→`"Xen"`; types `"Keyboard"`, `"Mouse"`, `"Tablet"`.

```xml
<input type="tablet" bus="usb"/>
```

---

### 3.6 Graphics (`gfxdetails.py`)

| Widget | Label | Type | Rows / range | Default |
|---|---|---|---|---|
| `graphics-type` | `"_Type:"` | editable combo | `spice`→`"Spice server"`, `vnc`→`"VNC server"` | prefs `/new-vm/graphics-type` (`system`→build default `spice`) |
| `graphics-listen-type` | `"L_isten type:"` | editable combo | `address`→`"Address"`, `none`→`"None"` | `address` |
| `graphics-address` | `"Addr_ess:"` | editable combo (custom IP allowed) | `None`→`"Hypervisor default"`, `127.0.0.1`→`"Localhost only"`, `0.0.0.0`→`"All interfaces"` | Hypervisor default |
| `graphics-port-auto` | `"_Port:"` / check `"A_uto"` | check | – | checked |
| `graphics-port` | spin | 5900–50000 | 5900 (hidden while Auto) |
| `graphics-password-chk` + `graphics-password` | `"Pa_ssword:"` | check + entry (entry sensitive iff checked; cleared when unchecked) | – | off, `""` |
| `graphics-visibility-chk` | `"Show passwor_d"` | check | – | off |
| `graphics-opengl` | `"Open_GL:"` | check | – | off |
| `graphics-rendernode` | (in GL sub-box) | editable combo | `None`→`"Auto"` + each DRM render node: value `/dev/dri/renderD128`, label `"<parent pretty name> (render)"` | **last** row |
| warnings | `"OpenGL only works with 'virtio' graphics with '3D acceleration' enabled"` (shown if VM has no virtio video with accel3d); `"OpenGL only works with 'Listen type' value 'none'"` (shown if listen not `none`) | | | |

Row visibility:
- vnc/spice: password + listen type always; port + address only when listen = `address`; OpenGL only for spice; GL sub-box only spice && GL checked.
- No keymap field (not in UI).

Build mapping:
- port: Auto → `-1`; listen `none` → port None.
- listen: `address` → `listen` = address value (None for Hypervisor default); `none` → `<listen type="none"/>` (libvirt ≥ 2.0.0), clears port/tlsPort/autoport.
- `gl`: None if OpenGL row hidden (vnc); else True/False (spice unchecked → `<gl enable="no"/>`).
- `rendernode`: only if visible (GL on).
- passwd: None unless checked.

`set_defaults`: port None → `-1` for vnc/spice with address/no listen; spice `tlsPort=-1`; spice with port & tlsPort −1 → `autoport="yes"`; spice on local conn → `<image compression="off"/>`; spice+gl without rendernode → first DRM render node.

```xml
<graphics type="spice" port="-1" tlsPort="-1" autoport="yes">
  <gl enable="no"/>
  <image compression="off"/>
</graphics>
<graphics type="vnc" port="-1" listen="127.0.0.1" passwd="secret"/>
<graphics type="spice">
  <listen type="none"/>
  <gl enable="yes" rendernode="/dev/dri/renderD128"/>
  <image compression="off"/>
</graphics>
```

---

### 3.7 Sound

- `"_Model:"` editable combo (sorted). Rows: `ac97`→`"AC97"`, `ich6`→`"HDA (ICH6)"`, `ich9`→`"HDA (ICH9)"`, `usb`→`"USB"` (label = `model.upper()`, HDA wrap for ich6/ich9).
- Default `DeviceSound.default_model`: `ich9` if `defaults_to_pcie()` (q35, ARM `virt`, RISC-V `virt`, loongarch64) else `ich6`.

```xml
<sound model="ich9"/>
```

---

### 3.8 Char devices: Serial / Parallel / Console / Channel (shared page)

Fields (row visibility per device type):

| Widget | Label | Shown when | Default |
|---|---|---|---|
| `char-device-type` | `"Device _Type:"` | always | `pty` |
| `char-path` | `"_Path:"` | type ∈ `file`, `unix`, `dev`, `pipe` (and for channel+unix only if Auto socket unchecked) | `""` |
| `char-channel` | `"_Channel:"` | type `spiceport` | `""` |
| `char-vdagent-clipboard` | `"_Share Clipboard:"` | type `qemu-vdagent` | checked |
| `char-target-name` | `"_Name:"` (editable combo, sorted) | channel | first sorted: `com.redhat.spice.0` |
| `char-target-type` | `"T_ype:"` | console | qemu: `virtio`→`"VirtIO"` only; else `None`→`"Hypervisor default"` |
| `char-auto-socket` | `"_Auto socket:"` | channel && type `unix` | checked |

Device types offered (combo sorted by label; label = `"<pretty> (<value>)"`):

| Kind | Types |
|---|---|
| console | `pty` |
| serial, parallel | `pty`, `file`, `unix` |
| channel | `spicevmc`, `spiceport`, `qemu-vdagent`, `pty`, `file`, `unix` |

Pretty labels: `pty`→`"Pseudo TTY"`, `file`→`"Output to a file"`, `tcp`→`"TCP net console"`, `udp`→`"UDP net console"`, `unix`→`"UNIX socket"`, `spicevmc`→`"Spice agent"`, `spiceport`→`"Spice port"`, `qemu-vdagent`→`"QEMU vdagent"` (tcp/udp/dev/pipe not offered in Add Hardware).
Sorted channel list: `"Output to a file (file)"`, `"Pseudo TTY (pty)"`, `"QEMU vdagent (qemu-vdagent)"`, `"Spice agent (spicevmc)"`, `"Spice port (spiceport)"`, `"UNIX socket (unix)"`.

Channel target names (`CHANNEL_NAMES`): `com.redhat.spice.0`, `org.qemu.guest_agent.0`, `org.libguestfs.channel.0`, `org.spice-space.webdav.0` (pretty short names elsewhere: `"spice"`, `"qemu-ga"`, `"libguestfs"`, `"spice-webdav"`).
Name → auto type: `com.redhat.spice.0`→`spicevmc`; `org.spice-space.webdav.0`→`spiceport` + Channel field = name; `org.qemu.guest_agent.0` / `org.libguestfs.channel.0`→`unix`. Initial channel page therefore = `spicevmc` + `com.redhat.spice.0`.

Build: hidden fields → None. `set_defaults`: `unix`/`tcp` → `<source mode="bind">`; channel → target type `virtio`; `spicevmc`/`qemu-vdagent` without name → `com.redhat.spice.0`.

```xml
<serial type="pty"/>
<serial type="file"><source path="/tmp/serial.log"/></serial>
<console type="pty"><target type="virtio"/></console>
<channel type="spicevmc"><target type="virtio" name="com.redhat.spice.0"/></channel>
<channel type="unix"><source mode="bind"/><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
<channel type="spiceport"><source channel="org.spice-space.webdav.0"/><target type="virtio" name="org.spice-space.webdav.0"/></channel>
<channel type="qemu-vdagent"><source><clipboard copypaste="yes"/></source><target type="virtio" name="com.redhat.spice.0"/></channel>
```

---

### 3.9 Host devices: USB / PCI / MDEV (shared page)

| Widget | Label | Notes |
|---|---|---|
| `host-device` | `"Host _Device:"` | tree list, sorted ascending by label; tooltip column |
| `hostdev-usb-startup-policy` | `"_Startup Policy:"` | USB only; combo (sorted) `None`→`"Hypervisor default"`, `mandatory`, `optional`, `requisite`; default Hypervisor default |

Enumeration (`conn.filter_nodedevs(devtype)`; devtype `usb_device` | `pci` | `mdev`):
- Skip USB Linux root hubs (vendor `0x1d6b`, product `0x0001`/`0x0002`/`0x0003`) and PCI bridges (capability `pci-bridge`).
- Labels:
  - USB: `"%.3d:%.3d %s %s" % (bus, device, vendor_name|vendor_id, product_name|product_id)` → `"001:005 Logitech, Inc. Unifying Receiver"`
  - PCI: `"%.4X:%.2X:%.2X:%X %s %s" % (domain, bus, slot, function, vendor_name, product_name)` → `"0000:00:19:0 Intel Corporation 82579LM ..."` (colon before function); plus `" (Interface eth0)"` for each `net` nodedev whose parent is this device.
  - MDEV: nodedev name; if label ≤ 41 chars, prefixed with parent device pretty name.
- Inactive nodedev → row insensitive, tooltip `"%s is not active in the host system.\nPlease start the mdev in the host system before adding it to the guest."`
- Empty → single insensitive row `"No Devices Available"`.
- Row 0 selected; Finish sensitive only if selected row sensitive.

Build (`set_from_nodedev`):
- PCI: `type=pci`, `<address domain bus slot function>`.
- USB: `type=usb`, vendor/product ids; if >1 host device with same vendor:product, also `<address bus device>`; `startupPolicy` from combo.
- MDEV by `type_id`: `vfio_ccw-io`→model `vfio-ccw`, managed `no`; `vfio_ap-passthrough`→`vfio-ap`, managed `no`; `nvidia-NN*` or `i915-GVTg_V#_#`→`vfio-pci`, managed `yes`, `display="off"`, `ramfb="off"`; other → error `"Don't know how to generate nodedev for mdev type id '%s'"`; `<address uuid>`.
- `set_defaults`: `managed` = `no` on Xen else `yes`; `mode="subsystem"`.

Validation: in-use by any VM on conn → Yes/No `"The device is already in use by other guests %s"` / `"Do you really want to use the device?"`.

```xml
<hostdev mode="subsystem" type="usb" managed="yes">
  <source startupPolicy="optional"><vendor id="0x046d"/><product id="0xc52b"/></source>
</hostdev>
<hostdev mode="subsystem" type="pci" managed="yes">
  <source><address domain="0x0000" bus="0x00" slot="0x19" function="0x0"/></source>
</hostdev>
<hostdev mode="subsystem" type="mdev" managed="yes" model="vfio-pci" display="off" ramfb="off">
  <source><address uuid="4b20d080-1b54-4048-85b3-a6a62d165c01"/></source>
</hostdev>
```

---

### 3.10 Video

- `"_Model:"` editable combo (sorted). Label: `qxl`/`vmvga`/`vga` → upper; else `capitalize()`.
  - qemu/test: `bochs`→`"Bochs"`, `none`→`"None"`, `qxl`→`"QXL"`, `ramfb`→`"Ramfb"`, `vga`→`"VGA"`, `virtio`→`"Virtio"`
  - xen: `vga`→`"VGA"`, `xen`→`"Xen"`
  - other: `None`→`"Hypervisor default"`
- Default `DeviceVideo.default_model`: non-HVM None; pseries `vga`; loongarch64/riscv-virt `virtio`; s390x+qemu `virtio`; spice+gl `virtio`; domcaps virtio video && osinfo virtio-gpu → `virtio`; x86+spice+domcaps qxl → `qxl`; UEFI: ARM → `ramfb`, domcaps bochs → `bochs`; else `vga`.
- `set_defaults`: virtio + guest has GL graphics → `accel3d="yes"`.

```xml
<video><model type="virtio"/></video>
<video><model type="virtio"><acceleration accel3d="yes"/></model></video>
```

---

### 3.11 Watchdog

| Field | Label | Rows (sorted) | Default |
|---|---|---|---|
| model | `"_Model:"` | `diag288`→`"DIAG288"`, `i6300esb`→`"I6300ESB"`, `ib700`→`"IB700"` | `i6300esb` |
| action | `"Ac_tion:"` | `dump`→`"Dump guest memory core"`, `poweroff`→`"Forcefully power off the guest"`, `reset`→`"Forcefully reset the guest"`, `shutdown`→`"Gracefully shutdown the guest"`, `none`→`"No action"`, `pause`→`"Pause the guest"` | `reset` |

No arch filtering of models.

```xml
<watchdog model="i6300esb" action="reset"/>
```

---

### 3.12 Filesystem (`fsdetails.py`)

| Widget | Label | Shown | Rows | Default |
|---|---|---|---|---|
| `fs-type-combo` | `"_Type:"` | not qemu/test (i.e. LXC etc.) | container-only conn: `mount`, `file`, `block`, `ram`; else `mount` | row 0 |
| `fs-driver-combo` | `"_Driver:"` | qemu/test, or type `file` | qemu: `virtiofs`→`"virtiofs"` (only if domcaps supports virtiofs), `None`→`"virtio-9p"` (unsorted); container-only: `loop`, `nbd`, `None`→`"Hypervisor default"` | row 0 (virtiofs if supported) |
| `fs-format-combo` | `"_Format:"` | driver `nbd` | `raw`, `qcow2` | `raw` |
| `fs-source` + `"_Browse..."` | `"_Source path:"` (`"Te_mplate:"` for template) | type ≠ ram | – | `""` |
| `fs-ram-source-spin` | `"_Usage:"` + `"MiB"` | type `ram` | 0–18446744073709 | – |
| `fs-target` | `"Ta_rget path:"` | always | – | `""` |
| `fs-readonly` | `"E_xport filesystem as readonly mount"` | qemu/test/lxc | – | off |
| warning | `"You may need to 'Enable shared memory' on the 'Memory' screen."` | driver virtiofs and VM lacks memfd shared memory | | |

- Browse uses storage browser reason `fs` (`"Locate directory volume"`).
- Driver switch to/from virtiofs resets accessmode.
- `set_defaults` (qemu/lxc/test): type `mount`; accessmode: virtiofs → none (libvirt default passthrough); else `mapped`.
- Validation: qemu/test + mount → target is a free-form tag; otherwise must be absolute: `"Filesystem target '%s' must be an absolute path"`.

```xml
<filesystem type="mount">
  <driver type="virtiofs"/>
  <source dir="/srv/share"/>
  <target dir="share"/>
</filesystem>
<filesystem type="mount" accessmode="mapped">
  <source dir="/srv/share"/>
  <target dir="share"/>
  <readonly/>
</filesystem>
```

---

### 3.13 Smartcard

- `"_Mode:"` combo (sorted, no explicit default): `host`→`"Host"`, `passthrough`→`"Passthrough"` → default = first sorted = **`host`**.
- `set_defaults`: type = `spicevmc` if passthrough else `tcp`.

```xml
<smartcard mode="passthrough" type="spicevmc"/>
<smartcard mode="host" type="tcp"/>
```

---

### 3.14 USB Redirection

- `"_Type:"` combo: only `spicevmc`→`"Spice channel"`.
- `set_defaults`: bus `usb`.

```xml
<redirdev bus="usb" type="spicevmc"/>
```

---

### 3.15 TPM (`tpmdetails.py`)

| Widget | Label | Shown | Rows (unsorted) | Default |
|---|---|---|---|---|
| `tpm-type` | `"_Type:"` | always | `emulator`→`"Emulated"`, `passthrough`→`"Passthrough"` (not domcaps-filtered) | `emulator` |
| `tpm-device-path` | `"Device _Path:"` | passthrough | – | `/dev/tpm0` |
| expander | `"Adva_nced options"` | | | |
| `tpm-model` | `"_Model:"` | always | `None`→`"Hypervisor default"` + domcaps tpm model enum (or `tpm-crb`, `tpm-tis` if no domcaps tpm); labels `tpm-tis`→`"TIS"`, `tpm-crb`→`"CRB"`, `tpm-spapr`→`"SPAPR"` | `default_model` |
| `tpm-version` | `"_Version:"` | emulator | `None`→`"Hypervisor default"`, `2.0`, `1.2` | Hypervisor default |

- `default_model`: no domcaps tpm and not pseries → `tpm-crb`; domcaps lists `tpm-crb` → `tpm-crb`; else None.
- `set_defaults`: device_path w/o type → passthrough; no type → emulator; emulator && no model && no version → `default_model`.

```xml
<tpm model="tpm-crb"><backend type="emulator"/></tpm>
<tpm model="tpm-tis"><backend type="passthrough"><device path="/dev/tpm0"/></backend></tpm>
```

---

### 3.16 RNG

- Single field `"Host _Device:"` entry. Default `/dev/urandom` if libvirt ≥ 1.3.4 else `/dev/random`.
- Backend model always `random` (no EGD/builtin in Add Hardware; labels `"Random"`, `"Entropy Gathering Daemon"`, `"Builtin RNG"` exist only for details).
- `set_defaults`: model `virtio`.

```xml
<rng model="virtio"><backend model="random">/dev/urandom</backend></rng>
```

---

### 3.17 Panic Notifier

- `"_Model:"` editable combo (sorted): `None`→`"Hypervisor default"` + domcaps `devices.panic` model enum values (label = value, e.g. `isa`, `pvpanic`, `hyperv`, `s390`, `pseries`). Default Hypervisor default.
- `set_defaults`: no model → empty `<panic/>` (libvirt picks).

```xml
<panic/>
<panic model="hyperv"/>
```

---

### 3.18 VirtIO VSOCK (`vsockdetails.py`)

- `"Guest C_ID:"`: check `"A_uto"` (default on) + spin (3 – 4294967295, default 3, hidden while Auto).
- Build always sets both `auto_cid` and `cid` (spin value even when Auto).
- `set_defaults`: model `virtio`.

```xml
<vsock model="virtio"><cid auto="yes" address="3"/></vsock>
<vsock model="virtio"><cid auto="no" address="7"/></vsock>
```

---

### 3.19 Hot-plug vs persistent config

`_add_device(dev)`:
1. If replacing a USB `model="none"` controller → `change_config_helper(vm.define_controller, …)` path (below) and return.
2. Hotplug: if VM active (`not shutoff`, so **paused counts**): `virDomainAttachDevice(xml)` (no flags) for the auto-added controller (if any) then the device. VM not active → skipped.
3. On attach exception → modal WARNING Yes/No:
   - primary: `"Are you sure you want to add this device?"`
   - secondary: `"This device could not be attached to the running machine. Would you like to make the device available after the next guest shutdown?"`
   - details: error + traceback.
   - **No** → nothing added to config; dialog closes (no error). Any disk volume already created in `_setup_device` is **not** deleted.
   - **Yes** → continue.
4. Persistent: `vm.add_device(controller)` then `vm.add_device(dev)` → inactive XML + device → `defineXML`.
- Successful hotplug + define → no message. No per-device "hotplug unsupported" table: any device type is attempted live; libvirt error drives the prompt.
- Storage is created **before** hotplug/define (async job), pool refreshed afterwards.

`change_config_helper` (USB none-controller replace; shared with Details):
- define error → `"Error changing VM configuration: %s"`.
- VM active → try hotplug; failure, or no hotplug possible → dialog `"These changes will take effect after the next guest shutdown."` (WARNING with error details if hotplug failed, INFO otherwise, OK button).

### 3.20 Customize-before-install differences

- VM object is `vmmDomainVirtinst` (in-memory `Guest`): status always SHUTOFF → no hotplug, no prompt; `add_device` appends to the in-memory Guest and emits `state-changed` (no libvirt define).
- Same dialog, same pages, same sidebar gating.
- Disk volumes for new images are still created **immediately** on Finish (`build_storage` in `_setup_device`), not deferred to install.
- Hostdev/disk/MAC in-use checks only see libvirt-defined VMs (the VM being customized isn't defined yet); disk filename collision still checks the in-memory guest's disks (`collideguest`).
- XML-editor edits of disks preserve pending vol-install (`_sync_disk_storage_params`).
# D. Host storage, virtual networks, host overview, connections

Source: virt-manager `virtManager/{hoststorage,storagebrowse,createpool,createvol,hostnets,createnet,host,createconn,manager}.py`, `virtManager/object/{storagepool,network,libvirtobject}.py`, `virtinst/{storage,network}.py`, `ui/*.ui`, `data/org.virt-manager.virt-manager.gschema.xml`.
Mnemonic underscores (`_`) kept as in source; strip for macOS display.

---

## 4. Storage: host storage tab + volume chooser

### 4.1 Host storage tab (`vmmHostStorage`, `ui/hoststorage.ui`)

Layout: left pane = pool list; right = notebook (tabs hidden) page 0 details / page 1 error label. Toolbar under pool list; button row bottom-right.

#### Pool list
- Single column header: `"Storage Pools"`
- Model: `[pool obj, label markup, is_active bool, percent markup]`
- Cell order: percent (left, fixed) then label (expands, ellipsize END)
- Label markup: `"%s\n<span size='small'>%s</span>" % (name, pretty_type)`
- Percent markup: `"<span size='small'>%s%%</span>"`; value = `int(allocation / capacity * 100)`; `0` if capacity 0/None
- Inactive pools: label rendered insensitive (greyed) via `is_active`
- Sort: label ascending
- No state icon in list (icon only in details)
- On conn active: auto-select row 0. Selection change triggers unapplied-changes confirm (see 4.1.5)
- Rows refresh on pool `state-changed` / `refreshed` signals; list rebuilt on conn `pool-added` / `pool-removed`

#### Pool pretty type (`POOL_TYPE_DESCS`; fallback `"%s pool" % type`)
| type | label |
|---|---|
| `dir` | `"Filesystem Directory"` |
| `fs` | `"Pre-Formatted Block Device"` |
| `netfs` | `"Network Exported Directory"` |
| `logical` | `"LVM Volume Group"` |
| `disk` | `"Physical Disk Device"` |
| `iscsi` | `"iSCSI Target"` |
| `scsi` | `"SCSI Host Adapter"` |
| `mpath` | `"Multipath Device Enumerator"` |
| `gluster` | `"Gluster Filesystem"` |
| `rbd` | `"RADOS Block Device/Ceph"` |
| `zfs` | `"ZFS Pool"` |

(No `sheepdog`, `iscsi-direct`, `vstorage` in this version.)

#### Pool details (page 0, grid rows)
| Row label | Widget | Content |
|---|---|---|
| `"Name:"` | Entry `pool-name-entry` | pool name; editable only when pool **inactive** |
| `"Size:"` | Label `pool-sizes` (markup) | `"%(bytesfree)s Free / <i>%(bytesinuse)s In Use</i>"` (available / allocation) |
| `"Location:"` | Label `pool-location` | `<target><path>` or `""` |
| `"State:"` | Icon + Label | icon `state_running` if active else `state_shutoff`; text `"Active"` / `"Inactive"` |
| `"A_utostart:"` | CheckButton `pool-autostart` | label `"On Boot"`; checked = libvirt autostart |
- Pool type not shown as a detail row (only in list sublabel).
- Byte formatting `_pretty_bytes`: `> 1024^3` → `"%2.2f GiB"`, else `"%2.2f MiB"` (always 2 decimals).

#### Volumes section
- Header label: `"<b>Volumes</b>"`
- Buttons (icon-only, right of header):
  | id | icon | tooltip | enabled when |
  |---|---|---|---|
  | `vol-add` | `list-add` | `"Create new volume"`; if unsupported: `"Pool does not support volume creation"` | pool active AND type in `dir, fs, netfs, disk, logical, rbd, zfs` |
  | `pool-refresh` | `view-refresh` | `"Refresh volume list"` | pool active |
  | `vol-delete` | `edit-delete` | `"Delete volume"` | a volume selected |
- Volume list (insensitive when pool inactive). Columns:
  | Header | Data | Sort key |
  |---|---|---|
  | `"Volumes"` | name; for `iscsi` pools `"name (key)"` | name |
  | `"Size"` | `_pretty_bytes(capacity)` | numeric capacity |
  | `"Format"` | `<target><format type>` or `""` | format |
  | `"Used By"` | `", ".join(vm names)` using path (incl. backing-chain users); empty if none | string |
- Default sort: name ascending. Vertical scroll position preserved across repopulate.
- Each cell has `sensitive` attr from `vol_sensitive_cb(fmt)` (used by chooser).
- Right-click (button 3) popup menu: single item `"Copy Volume Path"` → copies target path to clipboard.
- Volumes failing to read info are silently hidden.

#### Pool toolbar (under pool list, icon-only)
| id | icon | tooltip | enabled when |
|---|---|---|---|
| `pool-add` | `list-add` | `"Add Pool"` | conn active AND supports storage |
| `pool-start` | `media-playback-start` | `"Start Pool"` | pool inactive |
| `pool-stop` | `process-stop` | `"Stop Pool"` | pool active |
| `pool-delete` | `edit-delete` | `"Delete Pool"` | pool inactive |

#### Bottom button row
| id | label | tooltip | visible |
|---|---|---|---|
| `browse-local` | `"_Browse Local"` | `"Browse local filesystem"` | chooser only |
| `browse-cancel` | `"_Cancel"` | `"Cancel and close dialog"` | chooser only |
| `choose-volume` | `"Ch_oose Volume"` | `"Choose the selected volume"` | chooser only |
| `pool-apply` | `"_Apply"` | `"Apply pool changes"` | host tab only; sensitive only with pending edits |

#### Actions / behavior
- Start: `pool.create(0)`; err `"Error starting pool '%s'"`
- Stop: `pool.destroy()`; err `"Error stopping pool '%s'"`
- Delete pool: confirm yes/no `"Are you sure you want to permanently delete the pool %s?"` → `undefine()` (no delete of data); err `"Error deleting pool '%s'"`
- Refresh: confirm pending changes first, then `pool.refresh(0)`; err `"Error refreshing pool '%s'"`
- Add volume: opens Create Volume (4.4) for current pool; passes name hint; inherits modality. Err `"Error launching volume wizard: %s"`
- Delete volume: confirm `"Are you sure you want to permanently delete the volume %s?"` → `vol.delete(0)` then pool refresh; err `"Error deleting volume '%s'"`
- After volume created → list refreshed and new vol auto-selected
- Add pool: opens Create Pool (4.3); err `"Error launching pool wizard: %s"`
- All actions async, no progress dialog (`simple_async_noshow`)
- Apply (edit set `{NAME, AUTOSTART, XML}`), applied in order:
  1. autostart → `setAutostart(bool)`
  2. name → rename (redefine with new name; preserves autostart) then repopulate list
  3. XML → `define_xml(editor xml)`
  - err `"Error changing pool settings: %s"`
- Unapplied changes: on pool-selection change (and refresh), if edits pending and window visible → dialog `"There are unapplied changes. Would you like to apply them now?"` with checkbox `"Don't warn me again."` (default No; gsettings confirm/unapplied-dev). Edits discarded otherwise.
- Error page messages: `"Connection not active."`, `"Libvirt connection does not support storage management."`, `"No storage pool selected."`, `"Error selecting pool: %s"`. Error page disables delete/stop/start/apply.
- Tab activation (`refresh_page`): repopulate volumes + priority poll pools.

#### Pool XML editor
- `vmmXMLEditor` wraps details: two tabs `"_Details"` / `"_XML"`.
- XML tab shows current pool XML (`set_xml_from_libvirtobject`). Editing → enables Apply (EDIT_POOL_XML).
- If XML editing disabled in prefs: shows `"<small>XML editing is disabled in 'Preferences'. Only enable it if you know what you are doing.</small>"` (read-only).
- Leaving tab with unapplied changes: `"There are unapplied changes."` + `"Your changes will be lost if you leave this tab. Really leave this tab?"` (details→XML) / `"Your XML changes will be lost if you leave this tab. Really leave this tab?"` (XML→details).

### 4.2 Storage browser / volume chooser (`vmmStorageBrowser`, `ui/storagebrowse.ui`)

- Separate window embedding the same `vmmHostStorage` widget.
- Modifications vs host tab:
  - Hidden rows: `Name`, `State`, `Autostart`
  - Shown: `"_Browse Local"`, `"_Cancel"`, `"Ch_oose Volume"` (initially insensitive)
  - Hidden: `"_Apply"`
  - `"_Browse Local"` insensitive on remote conn, tooltip `"Cannot use local storage on remote connection."`
- First show: selects default pool (pool named `default`, else pool whose target = `<libvirt data root>/images`).
- Escape closes. Errors modal.
- Choose: `"Ch_oose Volume"` or double-click row → returns `vol.target_path` → finish callback, close.
- `choose-volume` sensitive only if selected row is `sensitive`.
- Name hint (`set_vm_name`) forwarded to Create Volume default name.

#### Browse reasons
| Reason const | value | window title | local file dialog title | dialog type | accept label | start-dir gsettings key | vol-add enabled |
|---|---|---|---|---|---|---|---|
| `REASON_IMAGE` | `"image"` | `"Locate or create storage volume"` | `"Locate existing storage"` | SAVE (can type new name) | `"_Open"` | `/paths/image-default` | yes |
| `REASON_ISO_MEDIA` | `"isomedia"` | `"Locate ISO media volume"` | `"Locate ISO media"` | OPEN | default | `/paths/media-default` | no |
| `REASON_FLOPPY_MEDIA` | `"floppymedia"` | `"Locate floppy media volume"` | `"Locate floppy media"` | OPEN | default | `/paths/media-default` | no |
| `REASON_FS` | `"fs"` | `"Locate directory volume"` | `"Locate directory volume"` | SELECT_FOLDER | default | none | no |
| `None` | — | `"Choose Storage Volume"` | (None) | OPEN | default | none | yes |
- Filter: only `REASON_FS` filters — volumes with format != `"dir"` are insensitive/unchoosable. No file-extension filters.
- Browse Local: native file chooser; after pick, saves `dirname(path)` back to the gsettings key (skipped if path under `/dev`). Returns path to callback.
- vol-add sensitivity by reason is set in `set_browse_reason`, but gets reset on pool selection (`_populate_pool_state` sets it from pool active state) — effectively always enabled for active pools.

#### Call sites
| Caller | Trigger | Reason |
|---|---|---|
| New VM wizard | ISO browse | `isomedia` |
| New VM wizard | import disk / app (container) / storage page browse | `image` |
| New VM wizard | OS container root FS browse | `fs` |
| Add Hardware (disk storage browse, fs source) | Browse | `image` or `fs` if dir |
| Filesystem device details | source browse | `image` or `fs` if dir |
| VM Details disk/cdrom media | Browse | `floppymedia` if floppy else `isomedia` |
| VM Details boot: kernel / initrd / DTB path | Browse | `image` |
| VM Details other image browse | Browse | `image` (default) |
| Clone wizard change-storage | Browse | not set (`None`) |
| Create Volume backing store | `"_Browse..."` | `image` |

### 4.3 Add pool wizard (`vmmCreatePool`, `ui/createpool.ui`)

- Window title `"Add a New Storage Pool"`; header `"<span size='large'>Create storage pool</span>"`
- Single page + XML editor tabs (`"_Details"`/`"_XML"`). Buttons `"_Cancel"`, `"_Finish"`. Escape closes.

#### Fields (grid rows; visibility per type)
| Label | id | Widget | Notes |
|---|---|---|---|
| `"_Name:"` | `pool-name` | Entry | default `find_free_name("pool")` → `pool`, `pool-1`, `pool-2`… |
| `"_Type:"` | `pool-type` | Combo | rows `"%s: %s" % (type, pretty)`, sorted by type key; default row 0 = `dir` |
| `"Tar_get Path:"` | `pool-target-path` + `"B_rowse"` | Entry + button | Browse → folder chooser `"Choose target directory"`, start = dirname(current) |
| `"_Source Path:"` / `"_Source IQN:"` (iscsi) / `"_Source Adapter:"` (scsi) | `pool-source-path` + `"Bro_wse"` | Combo with entry | Browse → file chooser `"Choose source path"`, start `/dev` |
| `"Host Na_me:"` | `pool-hostname` | Entry | → `<source><host name=…/>` |
| `"F_ormat:"` | `pool-format` | Combo with entry | list = `["auto"]` only; free text allowed; default row 0 `auto` |
| `"Initiator _IQN:"` | `pool-iqn-chk` + `pool-iqn` | Checkbox + Entry | entry sensitive only when checked; default unchecked/empty |
| `"Volg_roup Name:"` (logical) / `"Sou_rce Name:"` | `pool-source-name` | ComboBoxText with entry | |

Type list order (as displayed): `dir`, `disk`, `fs`, `gluster`, `iscsi`, `logical`, `mpath`, `netfs`, `rbd`, `scsi`, `zfs`.

#### Field visibility matrix
| type | target | source path | host | format | iqn | source name | build on create |
|---|---|---|---|---|---|---|---|
| `dir` | Y | – | – | – | – | – | Y |
| `fs` | Y | Y (device) | – | Y | – | – | Y |
| `netfs` | Y | Y (dir) | Y | Y | – | – | Y |
| `logical` | – | – | – | – | – | Y (`Volg_roup Name:`) | – |
| `disk` | – | Y (device) | – | Y | – | – | – |
| `iscsi` | Y | Y (`_Source IQN:`, device) | Y | – | Y | – | – |
| `scsi` | Y | Y (`_Source Adapter:`) | – | – | – | – | – |
| `mpath` | Y | – | – | – | – | – | – |
| `gluster` | – | Y (dir) | Y | – | – | Y | – |
| `rbd` | – | – | Y | – | – | Y | – |
| `zfs` | – | – | – | – | – | Y | – |

- Browse buttons disabled on remote conn. Source browse also disabled for `netfs`, `iscsi`, `scsi`, `gluster`.
- On type change: target path entry reset to `default_target_path()`; source name entry reset to `default_source_name()`.
- Pre-populated combos:
  - `scsi` → source path list = `"host<N>"` for each nodedev `scsi_host` (first selected)
  - `logical` → source name list from `findStoragePoolSources("logical")` (`./source/name`), first selected
- Hidden/insensitive fields are ignored when building XML.

#### Defaults
| type | `default_target_path()` | `default_source_name()` |
|---|---|---|
| `dir`, `fs`, `netfs` | `<data_root>/images/<name>`; data_root = `/var/lib/libvirt` (privileged) or `$XDG_DATA_HOME/libvirt` (`~/.local/share/libvirt`) | – |
| `iscsi`, `scsi` | `/dev/disk/by-path` | – |
| `mpath` | `/dev/mapper` | – |
| `rbd` | – | `rbd` |
| `gluster` | – | `gv0` |
- Note: target default computed with the name at time of type change (not live-updated on name edit).

#### Validation / XML finalization (`StoragePool.validate`)
- Name: required (`"A name must be specified for the Storage object"`), no `/` (`"Storage object name '%(name)s' can not contain '/' character."`), unique (`"Name '%s' already in use by another pool."`)
- Empty target: `disk` → `/dev`; else `default_target_path()`
- Empty source name → `default_source_name()`
- Empty format & type supports format → `auto`; `disk` with `auto` → format omitted
- Source path XML element by type: `netfs`/`gluster` → `<source><dir path=…/>`; `scsi` → `<source><adapter name=…/>`; others → `<source><device path=…/>`
- Auth (`<source><auth type username><secret uuid>`) supported in XML model, **not in UI**.

#### XML element order
`name, type(@), uuid, capacity, allocation, available, source/format, source/host, source/dir, source/adapter, source/device, source/name, target/path, target/permissions, source/auth`
```xml
<pool type="dir">
  <name>pool</name>
  <target><path>/var/lib/libvirt/images/pool</path></target>
</pool>
<pool type="netfs">
  <name>nfs</name>
  <source>
    <format type="auto"/>
    <host name="nas.example"/>
    <dir path="/export/vms"/>
  </source>
  <target><path>/var/lib/libvirt/images/nfs</path></target>
</pool>
<pool type="iscsi">
  <name>iscsi</name>
  <source>
    <host name="10.0.0.5"/>
    <device path="iqn.2024-01.example:target"/>
    <initiator><iqn name="iqn.1994-05.com.redhat:client"/></initiator>
  </source>
  <target><path>/dev/disk/by-path</path></target>
</pool>
```

#### Finish
- Async progress dialog: `"Creating storage pool..."` / `"Creating the storage pool may take a while..."`
- Steps: `storagePoolDefineXML` → if build (dir/fs/netfs) `build(VIR_STORAGE_POOL_BUILD_NEW)` → `create(0)` → `setAutostart(True)` (always autostart)
- On build/start failure: undefine pool, error `"Could not build storage pool: %s"` / `"Could not start storage pool: %s"` / `"Could not define storage pool: %s"`
- UI error wrap: `"Error creating pool: %s"`; `"Error building XML: %s"`; `"Error validating pool: %s"`
- Success → priority pool poll, close.

### 4.4 Create volume (`vmmCreateVolume`, `ui/createvol.ui`)

- Title `"Add a Storage Volume"`; header `"<span size='large'>Create storage volume</span>"`; description `"Create a storage unit to be used directly by a virtual machine."`
- Details/XML tabs. Buttons `"_Cancel"`, `"_Finish"`.

#### Fields
| Label | id | Widget | Default / behavior |
|---|---|---|---|
| `"_Name:"` | `vol-name` + `vol-name-suffix` label | Entry + suffix label | default = free name from hint (VM name) or `"vol"`, with suffix stripped (e.g. `vol`, `vol-1`) |
| `"F_ormat:"` | `vol-format` | Combo with entry (free text) | list `["raw", "qcow2"]`; row visible only if pool's volume type is FILE; default = connection default storage format |
| (section) `"<b>Storage Volume Quota</b>"` | | | |
| (info) | `vol-parent-info` | markup | `"<b>%(volume)s's</b> available space: %(size)s"` (pool name, pretty available) |
| `"Ca_pacity:"` | `vol-capacity` | SpinButton, 1 digit, unit label `"GiB"` | range 0.1–1000000; default `min(20, int(pool_available_GiB))` |
| — | `vol-nonsparse` | Checkbox `"_Allocate entire volume now"` | default checked unless format = `qcow2`; re-defaults on format change; row visible only when pool disk type FILE or pool type `zfs` |
| Expander `"_Backing store"` | `backing-expander` | collapsed by default | visible if pool type `logical` OR format `qcow2` |
| `"Pa_th:"` | `backing-store` + `"_Browse..."` | Entry + button | Browse → storage chooser, reason `image` |

- Suffix: `get_file_extension_for_format(fmt)`: `raw` → `.img`; other → `.<fmt>`; none → `""`; only for FILE-type pools; suffix cleared if name contains `"."`; updated on name/format change.
- Final name = `name + suffix`.
- Default storage format: gsettings `default-storage-format`; `"default"` → config default `qcow2` (if conn supports qcow2 default, else none). Prefs label `"System default (%s)"`.

#### Build
- `capacity = GiB * 1024^3`; `allocation = capacity` if non-sparse else `0`
- `backing_store` → `<backingStore><path>`; backing format auto-detected at install from the backing volume if it supports format
- `format` → `<target><format type>`

#### Validation (`StorageVolume.validate`)
- Name required / no `/` (`"Storage object"` label) / unique `"Name '%s' already in use by another volume."`
- No format on FILE vol → `raw`
- `qcow2` → `<target><features><lazy_refcounts/>` if conn supports
- `logical` pool: allocation forced = capacity (warning `"Sparse logical volumes are not supported, setting allocation equal to capacity"`)
- Size check vs pool available:
  - allocation > avail → **fatal** `"There is not enough free space on the storage pool to create the volume. (%(mem1)s M requested allocation > %(mem2)s M available)"`
  - capacity > avail → warning only (logged) `"The requested volume capacity will exceed the available pool space when the volume is fully allocated. (%(mem1)s M requested capacity > %(mem2)s M available)"`
- Errors: `"Error validating volume: %s"`, `"Error building XML: %s"`, `"Error creating vol: %s"`

#### Install
- Progress: `"Creating storage volume..."` / `"Creating the storage volume may take a while..."`; meter text `"Allocating '%(filename)s'"`, polls `vol.info()` allocation every 1s
- Flags: qcow2 without backing store & pool supports → `VIR_STORAGE_VOL_CREATE_PREALLOC_METADATA`
- `pool.createXML(xml, flags)`; then pool refresh → emits `vol-created(pool, vol)` → host tab selects it
- XML order: `name, key, capacity, allocation, target/format, target/path, target/permissions` (+ backingStore, features)
```xml
<volume>
  <name>vol.qcow2</name>
  <capacity>21474836480</capacity>
  <allocation>0</allocation>
  <target>
    <format type="qcow2"/>
    <features><lazy_refcounts/></features>
  </target>
</volume>
```

---

## 5. Virtual networks tab + create network wizard

### 5.1 Host networks tab (`vmmHostNets`, `ui/hostnets.ui`)

#### Network list
- Column header `"Networks"`; cells: icon `network-idle` (LARGE_TOOLBAR) + name (ellipsize END)
- Inactive → name insensitive (greyed). Sort name ascending. Auto-select row 0 on conn active.
- Selection change → unapplied-changes confirm (same dialog as 4.1).

#### Details (page 0)
| Row label | id | Content |
|---|---|---|
| `"Name:"` | Entry `net-name` | editable only when inactive |
| `"Device:"` | Label `net-device` | `<bridge name>` or `""` |
| `"State:"` | icon + label | `state_running`/`state_shutoff`; `"Active"`/`"Inactive"` |
| `"A_utostart:"` | Checkbox `net-autostart` | label `"On Boot"` |
| `"Domain:"` | Label `net-name-domain` | `<domain name>`; row hidden if empty |

Expander `"<b>IPv_4 configuration</b>"` (hidden if no IPv4 address):
| Row | Content |
|---|---|
| `"Network:"` | CIDR, e.g. `192.168.122.0/24` (from address+prefix or netmask) |
| `"DHCP range:"` | `"start - end"` (first `<range>`) or `"Disabled"` |
| `"Forwarding:"` | `pretty_forward_mode()` |

`pretty_forward_mode()`:
| forward mode | dev | text |
|---|---|---|
| none | – | `"Isolated network"` |
| `nat` | set / unset | `"NAT to %s"` / `"NAT"` |
| `route` | set / unset | `"Route to %s"` / `"Routed network"` |
| other (`open`, `bridge`, `hostdev`, …) | – | `"%s network" % mode.capitalize()` |

Expander `"<b>IPv_6 configuration</b>"` (hidden if no IPv6 address):
| Row | Content |
|---|---|
| `"Network:"` | IPv6 CIDR |
| `"DHCP range:"` | `"start - end"` or `"Disabled"` |
| `"Forwarding:"` | has IPv6 net → `"Routed network"`; else `<network ipv6='yes'>` → `"Isolated network, internal routing only"`; else `"Isolated network, routing disabled"` |

- No DNS details, QoS, port groups, DHCP host list, or leases in this tab.

#### Toolbar (icon-only, under list)
| id | icon | tooltip | enabled when |
|---|---|---|---|
| `net-add` | `list-add` | `"Add Network"` | conn active AND supports networks |
| `net-start` | `media-playback-start` | `"Start Network"` | inactive |
| `net-stop` | `process-stop` | `"Stop Network"` | active |
| `net-delete` | `edit-delete` | `"Delete Network"` | inactive |
- `"_Apply"` (bottom-right) — enabled on pending edits.

#### Actions
- Start `create()` err `"Error starting network '%s'"`; Stop `destroy()` err `"Error stopping network '%s'"`
- Delete: confirm `"Are you sure you want to permanently delete the network %s?"` → `undefine()`; err `"Error deleting network '%s'"`
- Add → Create Network wizard; err `"Error launching network wizard: %s"`
- Apply order: autostart → rename (repopulate) → XML define; err `"Error changing network settings: %s"`; edits cleared even on error (`finally`)
- Error page: `"Connection not active."`, `"Libvirt connection does not support virtual network management."`, `"No virtual network selected."`, `"Error selecting network: %s"`
- XML tab: same `vmmXMLEditor` behavior as pools.
- Tab activation → priority poll networks.

### 5.2 Create network wizard (`vmmCreateNetwork`, `ui/createnet.ui`)

- Title `"Create a new virtual network"`; header `"<span size='large'>Create virtual network</span>"`; Details/XML tabs; `"_Cancel"`/`"_Finish"`; Escape closes.

#### Top fields
| Label | id | Widget | Default |
|---|---|---|---|
| `"_Name:"` | `net-name` | Entry | `network`, `network-1`, … (first free) |
| `"_Mode:"` | `net-forward-mode` | Combo | row 0 `nat` |
| `"Fo_rward to:"` | `net-forward-device` | Combo | row 0 `"Any physical device"` |
| `"De_vice:"` | `net-forward-manual` | Entry | `""`; visible only when `"Physical device..."` chosen |
| `"Device _List:"` | `net-hostdevs` | Combo (ellipsize MIDDLE) | SR-IOV PFs; visible only for `hostdev` |

Mode list:
| value | label |
|---|---|
| `nat` | `"NAT"` |
| `route` | `"Routed"` |
| `open` | `"Open"` |
| `isolated` | `"Isolated"` (→ no `<forward>`) |
| `hostdev` | `"SR-IOV pool"` |

Forward-to list: `[False, "Any physical device"]`, `[True, "Physical device..."]`
- Forward-to row visible only for `nat`, `route`.
- `hostdev`: hides IPv4/IPv6/DNS expanders; Device List = `"%s (%s)" % (ifname, pci pretty name)` for each SR-IOV-capable PCI device's child net interface; empty → `"No available device"` (value None).

#### IPv4 expander `"<b>IPv_4 configuration</b>"` (collapsed by default)
| Widget | Label | Default |
|---|---|---|
| `net-ipv4-enable` | `"_Enable IPv4"` | checked |
| `net-ipv4-network` | `"_Network:"` (max 20 chars) | `192.168.100.0/24` |
| `net-dhcpv4-enable` | `"Enable DHCPv4"` | checked |
| `net-dhcpv4-start` | `"Start:"` | `192.168.100.128` |
| `net-dhcpv4-end` | `"End:"` | `192.168.100.254` |
- Disabling IPv4 hides its box; disabling DHCP hides start/end rows.
- On network edit (valid IPv4): start = `network + num_addresses//2`, end = `network + num_addresses - 2`.

#### IPv6 expander `"<b>IPv_6 configuration</b>"` (collapsed)
| Widget | Label | Default |
|---|---|---|
| `net-ipv6-enable` | `"_Enable IPv6"` | **unchecked** |
| `net-ipv6-network` | `"_Network:"` (max 40 chars) | `""` |
| `net-dhcpv6-enable` | `"Enable DHCPv6"` | unchecked |
| `net-dhcpv6-start` | `"Start:"` | `""` |
| `net-dhcpv6-end` | `"End:"` | `""` |
- On network edit (valid IPv6): start = `network + 256`, end = `network + 511`.

#### DNS expander `"<b>DNS domain name</b>"` (collapsed)
- Radio `"Use net_work name"` (default) → domain = network name
- Radio `"Cust_om"` → enables `net-domain-name` entry (default empty)

#### Build (`_build_xmlobj_from_ui`)
- `name`; `<domain name=…>` (always set when DNS section visible; = net name by default)
- `forward.mode` = mode (None for isolated); `forward.dev` = manual dev if `"Physical device..."`
- `hostdev`: `<forward mode="hostdev" managed="yes"><pf dev="ifname"/></forward>`; no IP/DNS
- IPv4: `<ip address="<net+1>" netmask="<mask>">` + `<dhcp><range start end/></dhcp>` if DHCP
- IPv6: `<ip family="ipv6" address="<net+1>" prefix="<len>">` + dhcp range if enabled
- Invalid IP strings → parsed as None, attributes omitted (no explicit field validation)
- No bridge name, MAC, STP, delay, routes set (libvirt auto-assigns `virbrN`)

#### Validation
- `"A name must be specified for the Network"`; no `/`; unique `"Name '%s' already in use by another network."`
- `"Error validating network: %s"`, `"Error building XML: %s"`

#### Create
- Progress `"Creating virtual network..."` / `"Creating the virtual network may take a while..."`
- `networkDefineXML` → `create()` → `setAutostart(True)`; on failure undefine
- Error `"Error creating virtual network: %s"`; success → priority net poll, close.

#### Default XML produced
```xml
<network>
  <name>network</name>
  <forward mode="nat"/>
  <domain name="network"/>
  <ip address="192.168.100.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.100.128" end="192.168.100.254"/>
    </dhcp>
  </ip>
</network>
```
- XML prop order: `@ipv6, name, uuid, forward, virtualport, bridge(name,stp,delay), domain, mac, ip*, route*`

---

## 6. Host overview tab + connection

### 6.1 Connection details window (`vmmHost`, `ui/host.ui`)

- One instance per URI. Title `"%(connection)s - Connection Details"` (pretty desc).
- Default size from per-conn gsettings `window-size` `(ii)`; fallback 800×600; saved on cleanup.
- Menu `"_File"`: `"_View Manager"`, separator, `"_Close"` (Ctrl+W), `"_Quit"` (Ctrl+Q).
- Tabs (notebook `details-tabs`): `"_Overview"` (0), `"_Virtual Networks"` (1), `"_Storage"` (2). Switching to 1/2 triggers refresh of that page.
- No separate interfaces / nodedev tabs in this version.

#### Overview tab
Frame `"<b>Basic details</b>"`:
| Label | Widget | Behavior |
|---|---|---|
| `"_Name:"` | Entry `overview-name` | shows pretty desc; edits saved live to per-conn gsettings `pretty-name` (not stored until user changes it from default) |
| `"Libvirt URI:"` | Label | conn URI |
| `"A_utoconnect:"` | Checkbox (no label) | toggles autoconnect |

Frame `"<b>CPU usage</b>"`: Sparkline graph (filled) + label `"%d %%"` (host CPU % used by all running VMs).
Frame `"<b>Memory usage</b>"`: Sparkline + label `"%(currentmem)s of %(maxmem)s"`.
- Memory = sum of running VMs' memory; max = host memory.
- `pretty_mem(KiB)`: `> 10 GiB (in KiB)` → `"%2.2f GiB"`, else `"%2.0f MiB"`.
- CPU% = Σ VM cpuTime delta ×100 / (Δt ns × host active CPUs), clamped 0–100. Mem% = mem×100/host mem, clamped.
- Updated on conn `resources-sampled`.
- **No** hostname, hypervisor, logical CPUs, architecture, or host memory rows in this version.

#### Autoconnect storage
- gsettings `org.virt-manager.virt-manager.connections` key `autoconnect` (`as`, default `[]`) — list of URIs; path `/connections/autoconnect`
- Known URIs: same schema key `uris` (`as`) — `/connections/uris`; new URI inserted before the last element
- Per-conn settings: `/conns/<uri with '/' stripped>/{pretty-name, window-size}` (schema `org.virt-manager.virt-manager.connection`)
- Removing a conn removes it from both `uris` and `autoconnect`.

### 6.2 Add Connection dialog (`vmmCreateConn`, `ui/createconn.ui`)

- Title `"Add Connection"`; buttons `"_Cancel"`, `"Co_nnect"` (default). Singleton.

#### Fields
| Label | id | Widget | Default |
|---|---|---|---|
| `"_Hypervisor:"` | `hypervisor` | Combo w/ separator row | detected default |
| (warning, session only) | `session-warning-box` | icon + small text | `"QEMU usermode session is not the virt-manager default. It is likely that any pre-existing QEMU/KVM guests will not be available. Networking options are very limited."` |
| — | `connect-remote` | Checkbox `"Connect to _remote host over SSH"` | unchecked |
| `"_Username:"` | `username-entry` | Entry | `""`; becomes `root` when remote toggled on and empty |
| `"H_ostname:"` | `hostname` | Entry | `""` |
| `"_Autoconnect:"` | `autoconnect` | Checkbox | checked; toggling remote sets it to `not remote` |
| `"Generated URI:"` | `uri-label` | Label | live-generated |
| `"Cu_stom URI:"` | `uri-entry` | Entry | shown only for Custom; prefilled with last generated URI |

Hypervisor list (filtered by build config `default_hvs` if set; rows with no config name always shown):
| id | config name | label |
|---|---|---|
| `HV_QEMU` (0) | `qemu` | `"QEMU/KVM"` |
| `HV_QEMU_SESSION` (3) | `qemu` | `"QEMU/KVM user session"` |
| `HV_XEN` (1) | `xen` | `"Xen"` |
| `HV_LXC` (2) | `lxc` | `"Libvirt-LXC"` |
| `HV_BHYVE` (4) | `bhyve` | `"Bhyve"` |
| `HV_VZ` (5) | `vz` | `"Virtuozzo"` |
| -1 | – | separator |
| `HV_CUSTOM` (6) | – | `"Custom URI..."` |

- Default selection: from `_default_uri()` probe (`xen:///` if Xen present; `qemu:///system` if qemu binaries; `lxc:///`; `bhyve:///system`); none/qemu → QEMU/KVM.
- Session / Custom: hide remote checkbox, username, hostname (force remote off). Custom: hide generated URI, show custom entry.
- Transport: **SSH only** (no TCP/TLS options).
- Hostname/username entries sensitive only when remote checked.

#### URI generation
- `hv` prefix: `xen` | `qemu` (both qemu rows) | `bhyve` | `vz` | else `lxc`
- remote: `hv + "+ssh://" + [urlquote(user) + "@"] + host + "/"`; host with >1 `:` wrapped in `[ ]` (IPv6)
- local: `hv + ":///"`
- suffix: `system` for QEMU/Bhyve/VZ; `session` for QEMU session; none for Xen/LXC
- Examples: `qemu:///system`, `qemu:///session`, `qemu+ssh://root@host/system`, `xen:///`, `lxc:///`

#### Connect
- Validate: remote with empty hostname → `"A hostname is required for remote connections."`
- Add conn to manager (persist URI) → set autoconnect → `open()` async (busy cursor).
- On error: shows error + `"Would you still like to remember this connection?"` (Yes/No question). No → remove conn.
- Err launching: `"Error launching connect dialog: %s"`

### 6.3 Connection object states (`vmmConnection`)
| const | value | `get_state_text()` | manager row text |
|---|---|---|---|
| `_STATE_DISCONNECTED` | 1 | `"Disconnected"` | `"%(connection)s - Not Connected"` (insensitive color); tooltip `"%(uri)s (Double click to connect)"` |
| `_STATE_CONNECTING` | 2 | `"Connecting"` | `"%(connection)s - Connecting..."` |
| `_STATE_ACTIVE` | 3 | `"Active"` | `"%(connection)s"` |
- Pretty desc: config `pretty-name` if set, else hv map (`esx`→`ESX`, `lxc`→`LXC`, `openvz`→`OpenVZ`, `qemu`→`QEMU/KVM`, `vbox`→`Virtualbox`, `vmware`→`VMWare`, `xen`→`Xen`, else driver name) + `" User session"` if path `/session` (+ basename for other non-`/system` paths) + `": hostname"` if remote.

### 6.4 Manager connection context menu (`manager.py`)
| Item | Label | Action | Sensitive when |
|---|---|---|---|
| create | `"_New"` | New VM wizard | not disconnected |
| connect | `"_Connect"` | open conn | disconnected |
| disconnect | `"Dis_connect"` | close conn | not disconnected and not connecting |
| — | separator | | |
| delete | `"De_lete"` | remove conn | disconnected |
| — | separator | | |
| details | `"_Details"` | open Connection Details window | always |
- Delete confirm: `"This will remove the connection:\n\n%s\n\nAre you sure?"` (URI).
- Row double-click: VM → VM window; disconnected conn → connect; else → Connection Details.
- Manager menus: File `"_Add Connection..."`; Edit `"_Connection Details"`.
# E. Snapshots & Consoles (virt-manager parity spec)

Sources: `virtManager/details/snapshots.py`, `ui/snapshots.ui`, `ui/snapshotsnew.ui`, `virtManager/object/domain.py` (`vmmDomainSnapshot`, snapshot methods), `virtinst/snapshot.py`, `virtManager/vmwindow.py`, `ui/vmwindow.ui`, `virtManager/vmmenu.py`, `virtManager/details/console.py`, `ui/console.ui`, `virtManager/details/serialcon.py`, `virtManager/details/viewers.py`, `virtManager/details/sshtunnels.py`, `virtManager/config.py`, `virtManager/preferences.py`, gschema.

---

## 7. Snapshots

### 7.1 Availability / entry point
- Page is the 3rd page of the VM window notebook (`DETAILS_PAGE_SNAPSHOTS`=2); reached via toolbar radio "Snapshots" (icon `vm_clone_wizard`) or View menu "Sna_pshots".
- Gate: `vm.snapshots_supported()` → `conn.support.domain_list_snapshots` (probes `virDomain.listAllSnapshots`).
  - Unsupported → toolbar button + menu item insensitive; tooltip `"Manage VM snapshots"` + `"\n"` + `"Libvirt connection does not support snapshots."`
  - Supported → tooltip `"Manage VM snapshots"`.
  - Customize-before-install pseudo-VM: `snapshots_supported()` returns `False` (always enabled-looking; toolbar hidden anyway).
- List populated lazily on first page visit (`vmwindow_refresh_vm_state` → only if not `_initial_populate`). Later refreshes only on explicit actions.
- No checks in source for: qcow2-only, raw disks, UEFI/NVRAM internal-snapshot limitations, pflash. (None present — libvirt errors surface via generic error dialog.)

### 7.2 Layout (snapshots.ui)
- Horizontal `GtkPaned`: left = list (scrolled, no h-scrollbar), right = notebook (tabs hidden): page 0 = details grid, page 1 = error/placeholder label.
- Bottom bar left: icon buttons (no labels) in order:

| id | icon | tooltip | default sensitivity |
|---|---|---|---|
| `snapshot-add` | `list-add` | "Create new snapshot" | always True |
| `snapshot-start` | `media-playback-start` | "Run selected snapshot" | only when exactly 1 selected |
| `snapshot-refresh` | `view-refresh` | "Refresh snapshot list" | always |
| `snapshot-delete` | `edit-delete` | "Delete selected snapshot" | ≥1 selected |

- Bottom bar right: button "_Apply" (tooltip "Save updated snapshot metadata"); insensitive until description edited.

### 7.3 Snapshot list
- Flat list (`Gtk.ListStore`), NOT a parent/child tree. Headers hidden. Single column, min width 150, spacing 6.
- Selection mode: **MULTIPLE**.
- Model columns: `[name, row label markup, tooltip, icon name, sortname, is_current]`.
- Cell renderers (left→right):
  1. State icon (LARGE_TOOLBAR size) = `run_status_icon_name()` of snapshot's captured state.
  2. Markup label (ellipsize END):
     - Internal: `"%(vm)s\n<span size='small'>VM State: %(state)s</span>"`
     - External: `"%(vm)s\n<span size='small'>VM State: %(state)s (External)</span>"`
     - `%(vm)` = snapshot name (xml-escaped), `%(state)` = pretty state.
  3. Current marker: icon `emblem-default` (MENU size), visible only if `snap.is_current()` (`virDomainSnapshotIsCurrent`).
- Row tooltip = snapshot `<description>`.
- Sort ascending by sortname: internal = `"1"+name`, external = `"3"+name`; if both kinds exist, separator row with sortname `"2"` inserted (row separator func = empty name). → internal block, separator, external block; alphabetical within each. No date sort.
- No creation time shown in list.
- Reselects previously selected names after repopulate; or selects `select_name` (newly created snapshot).
- Error during list: error page `"Error refreshing snapshot list: %s"`.
- Right-click (button 3) popup menu:
  - "_Start snapshot" → same as Run button
  - "_Delete snapshot" → same as Delete button
- Row activate (double-click/Enter) → Run snapshot.

#### State mapping (snapshot XML `<state>` → libvirt enum → label/icon)
| `<state>` | label (`pretty_run_status`, managed_save=False) | icon |
|---|---|---|
| nostate | "Unknown" | `state_running` |
| running | "Running" | `state_running` |
| blocked | "Unknown" | `state_running` |
| paused | "Paused" | `state_paused` |
| shutdown | "Shutting Down" | `state_shutoff` |
| shutoff | "Shutoff" | `state_shutoff` |
| crashed | "Crashed" | `state_shutoff` |
| pmsuspended | "Suspended" | `state_paused` |
| (other/missing; incl. `disk-snapshot`) | "Shutoff" (default → SHUTOFF) | `state_shutoff` |

- `is_external()` = `<memory snapshot='external'>` OR any `<disks><disk snapshot='external'>`.
- `has_run_state()` = state in {running, paused}.
- `is_running()` = state == running.

### 7.4 Details pane (grid rows)
| row | label | widget / content |
|---|---|---|
| 0 (span 2) | — | title markup `"<b>Snapshot '%(name)s':</b>"` |
| 1 (span 2) | — | `snapshot-is-current` box: `dialog-information` icon + `"<small><i>This was the most recently applied snapshot.</i></small>"`; row visible only if current |
| 2 | "Timestamp:" | `str(datetime.datetime.fromtimestamp(creationTime))` → local time `YYYY-MM-DD HH:MM:SS` (no tz; microseconds absent since int) |
| 3 | "VM State:" | state icon (BUTTON size) + state text |
| 4 | "Snapshot Mode:" | row visible only if external; text: `"External disk and memory"` / `"External memory only"` / `"External disk only"` (see note) |
| 5 | "Description:" | editable multi-line TextView (height 80, margins 2) |
| 6 | "Screenshot:" | image (if cached file exists) else label "No screenshot available" |

- Note (bug-compatible logic): `is_disk` is a *list* `[d.snapshot == "external" for d in disks]` → truthy whenever any disks listed, so "External disk and memory" whenever memory external + disks element non-empty; "External memory only" only when no `<disk>` children; else "External disk only".
- Selection states:
  - 0 selected → error page "No snapshot selected."; Delete/Run insensitive.
  - >1 selected → error page "Multiple snapshots selected."; Run & Apply insensitive; Delete sensitive.
  - 1 selected → details page; Add, Delete, Run sensitive; Apply insensitive.
  - Exception → "Error selecting snapshot: %s".

### 7.5 Edit description / Apply
- Any buffer change → Apply sensitive; if text differs from stored description and exactly 1 selected → `_unapplied_changes=True`.
- Apply: set `xmlobj.description = text`, if XML changed → `snapshotCreateXML(newxml, VIR_DOMAIN_SNAPSHOT_CREATE_REDEFINE)`; then refresh list.
- Changing selection with unapplied changes → `confirm_unapplied_changes()` dialog: "There are unapplied changes. Would you like to apply them now?" + checkbox "Don't warn me again." (default answer No; gated by pref `confirm unapplied`). Yes → apply. Selection change always proceeds.
- Only description editable (name/state not editable).

### 7.6 Create snapshot dialog (`snapshotsnew.ui`)
- Window title "Create snapshot"; header `<span size='large'>Create snapshot</span>` with `document-new` icon. Transient for VM window; Esc closes; resized to minimal on show.
- Pre-check on "+" click: if `vm.has_managed_save()` → OK/Cancel dialog:
  - text1: "Saved memory state will not be part of the snapshot"
  - text2: "The domain is currently saved. Due to technical limitations that saved memory state will not become part of the snapshot. Running it later will be the same as having forced the system off mid-flight. It is recommended to snapshot either the running or shut down system instead."
  - Cancel → abort.

| row | label | widget | default |
|---|---|---|---|
| 0 | "_Name:" | entry | generated name (below); focused |
| 1 | "Status:" | VM run-status icon + text (current VM status) | — |
| 2 | "Snapshot _Mode:" | radios "_external" / "_internal" | see below |
| 3 | "Memory _State:" | checkbox "_auto" + combo-with-entry (memory file path) | auto=checked; row visible only if external selected AND VM active |
| 4 | "_Description:" | multi-line TextView | empty |

- Buttons: "_Cancel", "_Finish" (Finish insensitive when name empty; Enter in name entry = Finish).
- Name default: `generate_name("snapshot", collision via snapshotLookupByName, sep="", start_num=1, force_num=True)` → `snapshot1`, `snapshot2`, … first non-existing.
- Name validation: non-empty ("A name must be specified for the Snapshot"); must not contain `/` ("Snapshot name '%(name)s' can not contain '/' character."). Error wrapper: "Error validating snapshot: %s".
- Mode radio:
  - External disabled if `capabilities.guest.features.externalSnapshot` not reported; tooltip "external snapshots not supported with this libvirt connection".
  - Default: external if supported, UNLESS current snapshot exists and is internal → internal. If external unsupported → internal.
- Memory path (external + running only):
  - `_auto` checked → combo insensitive; populated with `<dir of each disk source path>/<vmname>-mem.<snapname>` (dedup, disks w/o source skipped), first row selected; repopulated on name change.
  - `_auto` unchecked → combo sensitive, free text entry (list not refreshed).
  - Value = selected row or entry text.
- Confirmation on Finish if a current snapshot exists and its mode (internal/external) differs from chosen mode → Yes/No: "Mixing external and internal snapshots for the same VM is not recommended. Are you sure you want to continue?"
- Generated XML (`<domainsnapshot>`): `<name>`, `<description>` (omitted if empty); if external AND VM active: `<memory snapshot='external' file='<path>'/>`. No `<disks>` element emitted (libvirt default per disk).
- Flags: `VIR_DOMAIN_SNAPSHOT_CREATE_DISK_ONLY` iff VM NOT active AND mode external; otherwise 0. (Internal → libvirt default internal/full system checkpoint when running.)
- Runs in async progress dialog: title "Creating snapshot", text "Creating virtual machine snapshot". Error: "Error creating snapshot: %s". On success emits created → list refresh selecting new name; dialog closes.

### 7.7 Snapshot screenshot capture/storage
- Taken *before* create (in UI thread, prior to async job), only if VM active AND domain has ≥1 `<graphics>` device; else skipped.
- Method: `virDomainScreenshot(stream, screen=0, flags=0)` via libvirt stream (`newStream(0)`, `recvAll`), done **twice** (2nd result used; workaround qemu+qxl stale-frame bug).
- Accepted MIME: `image/x-portable-pixmap`→`ppm`, `image/png`→`png`; other → not saved.
- Stored only locally (NOT in libvirt XML/metadata): `$XDG_CACHE_HOME|~/.cache` + `/virt-manager/<conn URI with "/"→"_">/<VM UUID>/snap-screenshot-<snapname>.<ext>`; pre-existing `.ppm`/`.png` for that name deleted first. Failure only logged.
- Display: glob `snap-screenshot-<name>.*`, first match, scale so longest side ≤ 450 px (bilinear).
- Not deleted when snapshot is deleted; not shown for snapshots created by other clients.

### 7.8 Run / revert ("Start snapshot")
- Requires exactly 1 selected.
- Confirm Yes/No:
  - VM active: "Are you sure you want to run the snapshot '%(name)s'? All the disk changes since the last snapshot was created will be discarded."
  - VM inactive: "Are you sure you want to run the snapshot '%(name)s'? All the disk and configuration changes since the last snapshot was created will be discarded."
- If VM has managed save AND snapshot has no run state (not running/paused) → OK/Cancel:
  - text1: "Saved state will be removed to avoid filesystem corruption"
  - text2: "Snapshot '%s' contains only disk and no memory state. Restoring the snapshot would leave the existing saved state in place, effectively switching a disk underneath a running system. Running the domain afterwards would likely result in extensive filesystem corruption. Therefore the saved state will be removed before restoring the snapshot."
  - OK → `managedSaveRemove` first.
- Action: `virDomainRevertToSnapshot(snap, flags=0)` (async: title "Running snapshot", text "Running snapshot '%s'", error "Error running snapshot '%s'"); refresh list after.
- If snapshot state == running → after revert, async guest time sync via agent (`_async_set_time`).

### 7.9 Delete
- ≥1 selected. Confirm Yes/No: "Are you sure you want to permanently delete the selected snapshots?"
- Per snapshot: `virDomainSnapshotDelete(flags=0)` (no children/metadata-only flags); async title "Deleting snapshot", text "Deleting snapshot '%s'", error "Error deleting snapshot '%s'"; refresh after each.
- Connection ignores agent-lifecycle events for shutoff VMs (external-snapshot-delete side effect workaround).

### 7.10 Refresh
- Button: clears cached list (`listAllSnapshots`) and repopulates, preserving selection.
- VM undefine (elsewhere) uses `VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA`.

---

## 8. Consoles

### 8.1 VM window structure (vmwindow.ui)
- Window title default "Virtual Machine"; runtime title `"%(vm-name)s on %(connection-name)s"`; when pointer grabbed prefixed with `"Press %s to release pointer."` (`%s` = viewer grab-key string).
- Default size: first open forces viewer area 1280×800 then releases; afterwards per-VM saved size (`vm-window-size`).
- One window per (conn URI + VM UUID).
- Default page on open: Console; then default console activated.

#### Menubar
- "_File": "_View Manager"; separator; "_Close" (Ctrl+Shift+W); "_Quit" (Ctrl+Shift+Q).
- "Virtual _Machine" (`VMActionMenu`, show_open=False), in order:
  - "_Run" (label becomes "_Restore" if managed save exists & supported) — sensitive if shutoff
  - "_Pause" (visible if not paused; sensitive if stoppable) / "R_esume" (visible+sensitive if paused)
  - "_Shut Down" ▸ submenu: "_Reboot", "_Shut Down", "F_orce Reset", "_Force Off", separator, "Sa_ve"
  - separator
  - "Clone..." (sensitive only shutoff), "Migrate..." (sensitive if stoppable), "_Delete"
  - separator
  - "_Take Screenshot" (sensitive iff graphical viewer visible+connected)
  - "_Redirect USB device" (tooltip "Redirect host USB device to virtual machine with SPICE graphics."; sensitive iff viewer visible AND SPICE w/ USB manager; re-checked when menu opened)
- "_View":
  - radio "_Console" (default), "_Details", "Sna_pshots" (gated, see 7.1)
  - separator
  - check "_Fullscreen"
  - "_Resize to VM"
  - "_Scale Display" ▸ radio "_Always" / "_Only when Fullscreen" / "_Never"; separator; check "Auto _resize VM with window"
  - "Co_nsoles" ▸ (dynamic, 8.2)
  - check "_Autoconnect"
  - separator
  - check "T_oolbar" (default on; global pref `details/show-toolbar`)
- "Send _Key" ▸ (8.4)

#### Toolbar (`details-toolbar`)
| item | type | label | icon | tooltip |
|---|---|---|---|---|
| control-vm-console | radio (default active) | "Console" | `icon_console` | "Show the graphical console" |
| control-vm-details | radio | "Details" | `dialog-information` | "Show virtual hardware details" |
| — | separator | | | |
| control-run | button | "Run" / "Restore" | `media-playback-start` | "Power on the virtual machine" |
| control-pause | toggle | "Pause" | `media-playback-pause` | "Pause the virtual machine" / "Resume the virtual machine" when paused |
| control-shutdown | menu button (shutdown submenu) | "_Shut Down" | `system-shutdown` | "Shut down the virtual machine" |
| — | separator | | | |
| control-snapshots | radio | "Snapshots" | `vm_clone_wizard` | "Manage VM snapshots" (+ error) |
| control-fullscreen | toggle | — | `view-fullscreen` | "Switch to fullscreen view" |

- Sensitivity: Run ← `is_runable` (shutoff); Shut Down & Pause ← stoppable (running/paused/crashed/pmsuspended); Fullscreen / View>Fullscreen / Resize to VM ← viewer visible.
- Confirmations (chkbox w/ "don't ask" prefs): pause "Are you sure you want to pause '%s'?"; shutdown "Are you sure you want to poweroff '%s'?"; reboot "Are you sure you want to reboot '%s'?"; force reset "Are you sure you want to force reset '%s'?" + "This will immediately reset the VM without shutting down the OS and may cause data loss."; force off "Are you sure you want to force poweroff '%s'?" + "This will immediately poweroff the VM without shutting down the OS and may cause data loss."; save "Are you sure you want to save '%s'?".
- Switching away from Details with unapplied changes is blocked (stays on Details).
- Customize-before-install mode: hides menubar + details toolbar; shows "_Begin Installation" / "_Cancel Installation" toolbar.

### 8.2 View ▸ Consoles menu (dynamic, rebuilt on each show)
- Radio items: graphics entries, separator, text entries.
- Graphics entries (one per `<graphics>`):
  - Label: `"Graphical Console" + " " + pretty_type` (+ `" %d"` (idx+1) if idx>0). pretty_type: vnc/sdl/rdp → upper ("VNC","SDL","RDP"); else capitalize ("Spice", "Egl-headless", "Dbus"). E.g. "Graphical Console VNC", "Graphical Console Spice", "Graphical Console VNC 2".
  - Disabled + tooltip if type ∉ {vnc, spice}: "Cannot display graphical console type '%s'".
  - Second+ embeddable graphics disabled: "virt-manager does not support more than one graphical console".
  - None configured: single insensitive item "Graphical console not configured for guest".
- Text entries: devices = all `<serial>` + all `<console>` (first `<console>` dropped if it duplicates serial[0]: same type and target_type None/"serial").
  - `<console>` → "Text Console %d"; `<serial>` → "Serial %d"; number = xml index within its own device type + 1 (so after dup removal list may begin at "Text Console 2").
  - Supported char types: **pty, nmdm** only. Others disabled with tooltip "Console for device type '%s' is not supported".
  - None: insensitive "No text console available".
- Insensitive items with no reason get tooltip = their label.
- Selection: keeps previously selected label; else first sensitive item active.
- Selecting: if VM shutoff → status page; graphics/invalid → graphics page + init viewer; text → serial page (one tab per device, created lazily, cached by label).

### 8.3 Console pages (console.ui)
Top notebook `console-pages` (tabs hidden):
| idx | page | content |
|---|---|---|
| 0 | Unavailable | bold markup label (default "The console is currently unavailable") |
| 1 | Serial | notebook of serial terminals |
| 2 | Graphics | inner notebook `console-gfx-pages` |
| 3 | Connect | button "_Connect to console" |

Inner graphics notebook:
| idx | page | content |
|---|---|---|
| 0 | Viewer | overlay → scrolled window → viewport (black bg) → VNC/SPICE widget; fullscreen toolbar overlay |
| 1 | Auth | grid: "_Username:" entry, "_Password:" entry (hidden chars), button "_Login", check "_Save this password in your keyring" (tooltip "Check to save password, uncheck to forget password.") |
| 2 | Unavailable | bold markup message |

Messages (exact):
- VM shutoff: "Guest is not running." ; crashed: "Guest has crashed."
- Connecting: "Connecting to graphical console for guest"
- Viewer closed (window hidden): "Viewer window closed."
- Disconnecting: "Viewer is disconnecting."
- Disconnected: "Viewer was disconnected." + optional "\n<details>" + "\n\nSSH tunnel error output: %s". With details → gfx unavailable page (no auto-reconnect); without → top unavailable page (reconnect on next state refresh).
- Connect failure: "Error connecting to graphical console:\n%s"
- SPICE lib missing: "Error opening SPICE console: %s"
- Auth error dialog: "Viewer authentication error: %s"
- USB redir error: "USB redirection error" + detail.
- SPICE channel errors: "Encountered SPICE %(error-name)s" (+ ": msg").
- VNC unsupported cred: "Unable to provide requested credentials to the VNC server.\nThe credential type %s is not supported"
- Bad config (ConnectionInfo.bad_config):
  - "Guest is on a remote host, but is only configured to allow local file descriptor connections."
  - "Guest is configured for TLS only which does not work over SSH."
  - "Guest is on a remote host with transport '%s' but is only configured to listen locally. To connect remotely you will need to change the guest's listen address."

Autoconnect:
- Per-VM setting (`/vms/<uuid>/autoconnect`, -1 = global) → global `console/autoconnect` (default **true**).
- Off and Connect not clicked → Connect page; clicking button connects selected console.
- Bug: per-VM autoconnect change listener watches `/resize-guest` key instead of `/autoconnect`.

Default console activation: when VM not shutoff, viewer not open, and top page is Unavailable → rebuild menu, toggle first sensitive item; if none, init viewer with error.

### 8.4 Send Key menu
Built by `build_keycombo_menu`; labels via `Gtk.accelerator_get_label` (GTK3 English rendering). Keys sent as X keysym names → `Gdk.keyval_from_name`; VNC `send_keys`, SPICE `send_keys(..., CLICK)` (press all, release reverse).

| # | accel string | label (GTK3) | keysyms sent | keyvals |
|---|---|---|---|---|
| 1 | `<Control><Alt>BackSpace` | Ctrl+Alt+BackSpace | Control_L, Alt_L, BackSpace | 0xffe3, 0xffe9, 0xff08 |
| 2 | `<Control><Alt>Delete` | Ctrl+Alt+Delete | Control_L, Alt_L, Delete | 0xffe3, 0xffe9, 0xffff |
| 3 | `<Control><Alt><Shift>Escape` | Shift+Ctrl+Alt+Escape | Control_L, Alt_L, Shift_L, Escape | 0xffe3, 0xffe9, 0xffe1, 0xff1b |
| — | separator | | | |
| 4–15 | `<Control><Alt>F1`…`F12` | Ctrl+Alt+F1 … Ctrl+Alt+F12 | Control_L, Alt_L, F1…F12 | 0xffe3, 0xffe9, 0xffbe…0xffc9 |
| — | separator | | | |
| 16 | `Print` | Print | Print | 0xff61 |

- All items insensitive unless viewer visible AND VM not paused.
- Same menu also popped from fullscreen toolbar key button.
- Serial console ignores Send Key (graphics only).

### 8.5 Scaling / resize
- Scale Display (per-VM `/scaling`, -1 → global `console/scaling`, global default **2 = Always**). Values: 0 Never, 1 Only when Fullscreen, 2 Always. Prefs labels: "Never", "Fullscreen only", "Always" ("Graphical console _scaling:").
  - Never → scaling off; Always → on; Fullscreen → on only while fullscreen.
- VNC: `set_keep_aspect_ratio(True)` if supported; `force_size = !scaling && !resizeguest`.
- "Auto _resize VM with window" (per-VM `/resize-guest`, -1 → global `console/resize-guest`, -1 → built-in default **0/off**). Prefs "_Resize guest with window:" options "System default (Off)", "Off", "On".
  - VNC: `set_allow_resize` (gtk-vnc ≥ support); tooltip if unsupported "GTK-VNC viewer is too old".
  - SPICE: `resize-guest` property; tooltip "Guest agent is not available." when no vdagent.
  - Menu item tooltip = warning string (empty if fine); item stays enabled.
- "_Resize to VM": guest resolution (VNC desktop-resize / SPICE primary-create; SPICE w/o scaling+resize uses widget preferred size) + window chrome delta → unmaximize + resize window. No-op if size unknown.

### 8.6 Fullscreen
- Toggle via toolbar button, View ▸ "_Fullscreen" (kept in sync).
- Enter: `window.fullscreen()`, hide menubar + toolbar, force-reveal overlay toolbar then auto-hide after 2000 ms; re-sync scaling.
- Overlay toolbar (top center, revealer; 1px hot zone at top): pointer enter reveals, leave hides after 1000 ms.
  - "Leave Fullscreen" button (icon `view-restore`, tooltip "Leave fullscreen").
  - Send-key button (icon `preferences-desktop-keyboard-shortcuts`, tooltip "Send key combination") → Send Key menu.
- Leaving: unfullscreen, restore menubar, toolbar only if "T_oolbar" checked.
- Viewer close/disconnect forces leave fullscreen; closing window also unsets fullscreen.

### 8.7 Keyboard/pointer grab
- Grab key combo: global `console/grab-keys` (comma-separated keyvals), default `"65507,65513"` = Control_L+Alt_L. Applied via `GrabSequence.new(keys)` on VNC/SPICE display; live-updated on pref change.
- Prefs: "Gr_ab keys:" + "Change..." → dialog "Configure grab key combination", text "You can now define grab keys by pressing them.\nTo confirm your selection please click OK button\nwhile you have desired keys pressed.", live label "Please press desired grab key combination"; Cancel/OK.
- VNC: `set_pointer_grab(True)`.
- Pointer grabbed → window title prefix "Press %s to release pointer.".
- While keyboard grabbed (viewer) OR a serial terminal has focus: window accel groups removed, `gtk-menu-bar-accel` (F10) disabled, mnemonics disabled; restored afterward.

### 8.8 Auth
- Triggered by VNC credential request (PASSWORD/USERNAME; CLIENTNAME auto-answered "libvirt-vnc") or SPICE `ERROR_AUTH` with no password set (password only).
- Prefill from keyring (secret name `vm-console-<uuid>`, attrs uuid + hvuri); username stored in per-VM gsettings `console-username`.
- Remember checkbox: sensitive only if keyring available; pre-checked if keyring available and stored value present.
- Login/Enter → set creds; remember → store; unchecked → delete from keyring.
- VNC auth failure → error dialog then reconnect attempt; SPICE wrong password → error, no forced disconnect.

### 8.9 Connection transport (ConnectionInfo / SSH tunnels)
- Graphics info: type, idx, port, socket (listen socket or `<graphics socket>`), listen addr (default "127.0.0.1"), tlsPort, listen type; conn URI transport/user/host (localhost→127.0.0.1)/port.
- FD selection order:
  1. Needs tunnel (listen is loopback AND transport == "ssh") → SSH tunnel FD.
  2. Remote conn (no tunnel) → direct host connect.
  3. TLS-port-only → direct (openGraphicsFD disabled).
  4. Local + `virDomainOpenGraphicsFD` supported → `openGraphicsFD(idx, 0)`.
  5. Else direct `open_host(host, port[, tlsport])`; listen 0.0.0.0/:: → use conn hostname.
- SSH tunnel: `ssh [-p port] [-l user] host sh -c '<nc script>'`; nc target `-U <socket>` or `<addr> <port>`; uses `nc -q 0` if supported. Socketpair fd handed to viewer; tunnel opens serialized app-wide (lock until channel event; avoids concurrent ssh-askpass). stderr collected for disconnect message. Killed (SIGKILL) on close.
- SPICE: session `auto-clipboard`=True; `auto-usbredir` from pref (default **true**, "Auto redirect on USB attach" vs "Manual redirect only"); multi-head unsupported (channel 0 only); audio playback/record channels attached.

### 8.10 USB redirection (SPICE only)
- Menu "_Redirect USB device" → info dialog "Select USB devices for redirection" containing `SpiceClientGtk.UsbDeviceWidget`; button Close.
- Unavailable for VNC; error "Error initializing spice USB device widget" if widget fails.

### 8.11 Screenshot (VM menu "_Take Screenshot")
- Source: viewer widget framebuffer pixbuf (client-side, not libvirt).
- PNG with tEXt chunks: "Hypervisor URI", "Domain Name", "Domain UUID", "Generator App", "Generator Version".
- Save dialog: title "Save Virtual Machine Screenshot", filter "PNG files" (*.png), button "_Save", confirm overwrite; start folder = last screenshot dir (`default-directory` "screenshot").
- Default filename: `Screenshot_<vmname>_<YYYY-MM-DD_HH:MM:SS>.png` (local time, space → `_`, microseconds stripped).
- Appends ".png" if missing. Error: "Error taking screenshot: %s".

### 8.12 Serial / text console
- VTE terminal: scrollback 1000 lines, audible bell off, black background border 2px, vertical scrollbar shown only when content exceeds page.
- Right-click popup: "_Copy" (sensitive only with selection), "_Paste".
- Stream: `newStream(VIR_STREAM_NONBLOCK)` + `virDomainOpenConsole(alias name or None, stream, flags=0)` (no FORCE flag). Read chunks ≤100 KiB; input queued and written on WRITABLE.
- Closes on stream ERROR/HANGUP/EOF or recv/send exception (no message beyond close).
- Reconnect: on VM state change → RUNNING reopen; any other state → close. Switching menu entry re-opens. No periodic retry.
- Open failure → in-tab error page: "Error connecting to text console: %s".
- Device lookup by xml index within combined serial+console list; logs path changes.
- Autoconnect off → serial tab is created but the Connect page is shown until "_Connect to console" is clicked.

### 8.13 Global console preferences (Preferences ▸ "Graphical Consoles")
| label | key | default | values |
|---|---|---|---|
| "Graphical console _scaling:" | console/scaling | 2 | Never/Fullscreen only/Always |
| "Gr_ab keys:" | console/grab-keys | "" → 65507,65513 | Change... dialog |
| "_Resize guest with window:" | console/resize-guest | -1 (→0) | System default (Off)/Off/On; tooltip "Change guest resolution when the guest window size is changed. Only works with properly configured guest using spice and the desktop agent." |
| "SPICE _USB Redirection:" | console/auto-redirect | true | Manual redirect only/Auto redirect on USB attach |
| "Console autoconnec_t:" | console/autoconnect | true | checkbox |
- Per-VM overrides (`/vms/<uuid>/`): scaling (-1), resize-guest (-1), autoconnect (-1), console-username (""), vm-window-size.
# F. Manager window, wizards, preferences — feature-parity spec

Source: virt-manager (`virtManager/*.py`, `ui/*.ui`, `data/org.virt-manager.virt-manager.gschema.xml`). Labels quoted verbatim; `_` = GTK mnemonic marker (drop on macOS, or map to keyboard shortcut).

## 9. Manager window

### 9.1 Window
- Title widget `vmm-manager`; default size from gsettings `manager-window-width/height` (default `0` → falls back to **550×550**); size saved on close/cleanup.
- Closing (`File > Close`, Ctrl+W, window X) only hides; app exits when window counter hits 0 (other VM windows keep app alive).
- Two-page notebook (tabs hidden): page 0 = VM list, page 1 = startup error label (e.g. `"Checking for virtualization packages..."` shown when no saved URIs; engine adds default conn after 1 s).

### 9.2 Menus (`ui/manager.ui`)
| Menu | Items (exact labels) | Notes |
|---|---|---|
| `"_File"` | `"_Add Connection..."` · `"_New Virtual Machine"` · — · `"_Close"` (Ctrl+W) · `"_Quit"` (Ctrl+Q) | New VM uses selected row's conn URI as hint |
| `"_Edit"` | `"_Connection Details"` · `"_Virtual Machine Details"` · `"_Delete"` · — · `"_Preferences"` | Conn Details sensitive if VM or conn selected; VM Details only if VM; Delete if VM or conn |
| `"_View"` | `"_Graph"` ▸ check items: `"_Guest CPU Usage"`, `"_Host CPU Usage"`, `"_Memory Usage"`, `"_Disk I/O"`, `"_Network I/O"` | Bound to `vmlist-fields/*` keys (see 9.5). If the corresponding polling pref is off: item unchecked + insensitive, tooltip `"Disabled in preferences dialog."` (CPU poll gates both Guest and Host CPU items) |
| `"_Help"` | `"_About"` | |

### 9.3 Toolbar (`vm-toolbar`, large icons)
| Button | Label | Tooltip | Icon | Enabled when |
|---|---|---|---|---|
| `vm-new` | `"New"` | `"Create a new virtual machine"` | vm_new_large | always |
| sep | | | | |
| `vm-open` | `"_Open"` (is-important → shows text) | `"Show the virtual machine console and details"` | icon_console | VM selected |
| `vm-run` | `"_Run"` / `"Restore"` | `"Power on the virtual machine"` | media-playback-start | `vm.is_runable()` (= shutoff) |
| `vm-pause` (toggle) | `"_Pause"` | `"Pause the virtual machine"` / `"Resume the virtual machine"` when paused | media-playback-pause | paused → `is_unpauseable` (PAUSED); else `is_pauseable` (RUNNING). Toggle state mirrors paused |
| `vm-shutdown` (menu tool button) | `"_Shut Down"` | `"Shut down the virtual machine"` | system-shutdown | `is_stoppable()`; click = Shut Down; arrow = VMShutdownMenu |
- Run label becomes `"Restore"` (menu: `"_Restore"`) if `vm.managedsave_supported` and `has_managed_save()`.

### 9.4 Tree (connections → VMs)
- `Gtk.TreeStore`, headers visible, tooltip column = row hint. Level indentation negative (VMs visually flush).
- Row model: handle, sort key, markup, status icon, hint, is_conn, is_conn_connected, is_vm, is_vm_running, color, inspection OS icon (16×16, libguestfs only).
- **Connection row**
  - Name = `conn.get_pretty_desc()`: custom per-conn gsettings `pretty-name` else `<HV>[ "User session"| <xmlbasename>][": <hostname>"]`; HV map: esx→`ESX`, lxc→`LXC`, openvz→`OpenVZ`, qemu→`QEMU/KVM`, vbox→`Virtualbox`, vmware→`VMWare`, xen→`Xen`.
  - Markup (small): `name`, `"%(connection)s - Not Connected"` (disconnected), `"%(connection)s - Connecting..."` (connecting).
  - Disconnected → text color = theme insensitive fg.
  - Hint: URI, or `"%(uri)s (Double click to connect)"` when disconnected.
  - State text API: `"Disconnected"` / `"Connecting"` / `"Active"`.
  - No status icon, no sparklines (stats cells hidden for conn rows).
  - Conn becomes inactive → child VM rows removed. Conn added → VMs appended, conn row auto-expanded on each VM add.
- **VM row**
  - Status icon (DND size) by state: running/blocked/nostate→`state_running`; paused/pmsuspended→`state_paused`; shutoff/shutdown/crashed→`state_shutoff`.
  - Markup: line 1 bold small = `get_name_or_title()` (title if set, else name); line 2 small = run status text.
  - Status text: `"Running"`, `"Paused"`, `"Shutting Down"`, `"Shutoff"` (or `"Saved"` if managed save), `"Crashed"`, `"Suspended"` (pmsuspended), `"Unknown"`.
  - Tooltip = VM `<description>` (XML-escaped).
- **Columns**
| Col | Title | Content | Default visible (gsettings) |
|---|---|---|---|
| 0 | `"Name"` | status icon + OS icon + markup; expands | always |
| 1 | `"CPU usage"` | sparkline guest CPU % | `vmlist-fields/cpu-usage` **true** |
| 2 | `"Host CPU usage"` | sparkline host CPU % | `host-cpu-usage` false |
| 3 | `"Memory usage"` | sparkline mem % | `memory-usage` false |
| 4 | `"Disk I/O"` | sparkline avg(read,write)/max_disk_rate | `disk-usage` false |
| 5 | `"Network I/O"` | sparkline avg(rx,tx)/max_net_rate | `network-traffic` false |
  - Stats cols: min width 140, sparkline reversed, xpad 6 / ypad 12. Spacer cell shown in Name col when no stats col visible.
  - Sparkline points: `GRAPH_LEN = 40`. Disk/net normalization: running max starts 10.0, grows to max of conn-reported max rates.
- **Sorting**: every column sortable; default Name ascending. Name = case-insensitive sort key; others by `guest_cpu_time_percentage`, `host_cpu_time_percentage`, `stats_memory`, `disk_io_rate`, `network_traffic_rate`.

### 9.5 Interaction
- Double-click/Enter (`row-activated`): VM → open VM window; disconnected conn → connect (errors shown via dialog); connected conn → Connection Details (host window).
- Right-click (button 3) or `Menu` key → context menu (VM row → VMActionMenu; top-level → conn menu).
- `--connect URI` CLI selects that conn row initially.
- Delete on conn: `"This will remove the connection:\n\n%s\n\nAre you sure?"` (yes/no) → removes URI from `connections/uris` (and `autoconnect`).

### 9.6 Connection context menu
| Item | Sensitive when |
|---|---|
| `"_New"` | not disconnected |
| `"_Connect"` | disconnected |
| `"Dis_connect"` | not disconnected and not connecting |
| — | |
| `"De_lete"` | disconnected only |
| — | |
| `"_Details"` | always |

### 9.7 VM context menu (`vmmenu.VMActionMenu`, show_open=True)
| Item | Sensitive | Visible |
|---|---|---|
| `"_Run"` (or `"_Restore"`) | `is_runable` (shutoff) | always |
| `"_Pause"` | `is_stoppable` | not paused |
| `"R_esume"` | `is_paused` | paused |
| `"_Shut Down"` ▸ submenu | `is_stoppable` | |
| ─ `"_Reboot"` | `is_stoppable` | |
| ─ `"_Shut Down"` | `is_stoppable` | |
| ─ `"F_orce Reset"` | `is_stoppable` | |
| ─ `"_Force Off"` | `is_destroyable` | |
| ─ — / `"Sa_ve"` | `is_destroyable` | |
| — | | |
| `"Clone..."` | `is_cloneable` (shutoff) | |
| `"Migrate..."` | `is_stoppable` | |
| `"_Delete"` | always | |
| — / `"_Open"` | always | |
- State predicates: `is_stoppable` = RUNNING/PAUSED/CRASHED/PMSUSPENDED; `is_destroyable` = stoppable or CRASHED; `is_runable` = SHUTOFF; `is_pauseable` = RUNNING; `is_paused`/`is_unpauseable` = PAUSED; `is_cloneable` = SHUTOFF; `is_active` = not SHUTOFF.
- Same shutdown submenu attached to toolbar `vm-shutdown`.

### 9.8 Action confirmations (`err.chkbox_helper`: Yes/No + checkbox `"Don't ask me again"`; checking it sets pref false)
| Action | Pref key (default) | text1 | text2 |
|---|---|---|---|
| Shut Down | `confirm/poweroff` (false) | `"Are you sure you want to poweroff '%s'?"` | — |
| Reboot | `confirm/poweroff` | `"Are you sure you want to reboot '%s'?"` | — |
| Save | `confirm/poweroff` | `"Are you sure you want to save '%s'?"` | — |
| Force Off | `confirm/forcepoweroff` (true) | `"Are you sure you want to force poweroff '%s'?"` | `"This will immediately poweroff the VM without shutting down the OS and may cause data loss."` |
| Force Reset | `confirm/forcepoweroff` | `"Are you sure you want to force reset '%s'?"` | `"This will immediately reset the VM without shutting down the OS and may cause data loss."` |
| Pause | `confirm/pause` (false) | `"Are you sure you want to pause '%s'?"` | — |
| Resume / Run | none | | |
| Remove device (details) | `confirm/removedev` (true) | `"Are you sure you want to remove this device?"` | |
| Unapplied changes (details) | `confirm/unapplied-dev` (true) | `"There are unapplied changes. Would you like to apply them now?"` | chk: `"Don't warn me again."` |
| Delete storage (delete dlg) | `confirm/delete-storage` (true) | `"Are you sure you want to delete the storage?"` | `"The following paths will be deleted:\n\n%s"` |
- Run with managed save: progress `"Restoring Virtual Machine"` / `"Restoring virtual machine memory from disk"`; on error: `"Error restoring domain: %s"` + `"The domain could not be restored. Would you like\nto remove the saved state and perform a regular\nstart up?"` (Yes/No) → remove saved image and retry run.
- Save: progress `"Saving Virtual Machine"` / `"Saving virtual machine memory to disk "`, cancellable if `supports_domain_job_info` (abort_job).
- Error intros: `"Error starting domain"`, `"Error shutting down domain"`, `"Error rebooting domain"`, `"Error resetting domain"`, `"Error pausing domain"`, `"Error unpausing domain"`, `"Error saving domain: %s"`.

### 9.9 Polling / stats
- Engine timer: every `stats/update-interval` seconds (default **3**, min clamp 1) enqueue a tick per conn (`stats_update=True, pollvm=True`) on a background tick thread (priority queue, size 100).
- History length: fixed **120** samples (`get_stats_history_length`); manager sparklines show last 40.
- Bulk via `getAllDomainStats` with flags: CPU poll → STATE|CPU_TOTAL|VCPU; memory → BALLOON; disk → BLOCK; net → INTERFACE.
- Guest CPU% = Δcpu.time/(Δt·1e9)·100 / vcpus; Host CPU% = same / host active CPUs; clamp 0–100; 0 when inactive/poll off.
- Memory% = (balloon.current − balloon.unused)/balloon.current; sets `setMemoryStatsPeriod(5s)` once per VM (virtio balloon only).
- Disk/net rates: per-sample Δbytes / Δt; max rates start 10.0 per direction.
- Poll defaults: CPU **true**, disk false, net false, memory false.

## 10. Wizards and preferences

### 10.1 Create VM wizard (`createvm.py`, `ui/createvm.ui`, window title `"New VM"`)
- Header: `"Create a new virtual machine"` + `"Step %(current_page)d of %(max_page)d"` (5 steps; 4 when storage page skipped: Import / containers).
- Buttons: `"_Cancel"`, `"_Back"` (disabled on step 1), `"_Forward"` (hidden on last), `"_Finish"` (last only). Esc closes. Single instance.
- Pages: 0 Name/intro, 1 Install, 2 Memory, 3 Storage, 4 Finish.
- Cancel after a failed install: async `"Removing disk images"` / `"Removing disk images we created for this virtual machine."` cleans created disks.

#### Step 1 (intro)
- `"C_onnection:"` combo of **active** conns (label = pretty desc, ellipsize middle); default = URI hint, else first local conn; replaced by plain label if ≤1 conn. None → error `"No active connection to install on."`. Conn disconnect closes wizard.
- Errors/warnings (box with icon): `"Error: %s"`; `"No hypervisor options were found for this connection."` (+ QEMU hint `"This usually means that QEMU or KVM is not installed on your machine, or the KVM kernel modules are not loaded."`); warning `"KVM is not available. This may mean the KVM package is not installed, or the KVM kernel modules are not loaded. Your virtual machines may perform poorly."`; `"No install methods available for this connection."`.
- VZ only: `"Choose virtualization type"` → `"_Virtual machine"` (default) / `"_Container"`.
- `"Choose how you would like to install the operating system"` (radio):
| Radio | Label | Default | Sensitive rule / tooltip when disabled |
|---|---|---|---|
| method-local | `"_Local install media (ISO image or CDROM)"` | ✔ | not Xen PV and storage-capable and installable arch; tt `"CDROM/ISO installs not available for paravirt guests."` / `"Architecture '%s' is not installable"` / `"Connection does not support storage management."` |
| method-tree | `"Network _Install (HTTP, HTTPS, or FTP)"` | | (local or remote-URL supported) and installable arch; tt `"Libvirt version does not support remote URL installs."` |
| method-import | `"Import _existing disk image"` | | storage-capable |
| method-manual | `"Ma_nual install"` | | not container-only conn |
- Installable arch = x86 / ppc64 / s390x, or UEFI-capable; otherwise `kernel-info-box`: `"Kernel/initrd settings can be configured with 'Customize before install' on the final page."`. If preferred method insensitive, first sensitive one auto-selected.
- Container-only conns (LXC): `"Choose the container type"` → `"_Application container"` (default) / `"O_perating system container"`.
- Expander `"Architecture options"` (collapsed; row hidden if all sub-rows hidden):
  - `"_Xen Type:"` — Xen/test only; labels via `pretty_hv` (`"xen (paravirt)"`, `"xen (fullvirt)"`).
  - `"_Architecture:"` — caps archs for os_type; i686 merged into x86_64 on x86_64 hosts; prio order `x86_64, i686, aarch64, armv7l(shown "arm"), ppc64, ppc64le, riscv64, s390x`, separator, rest sorted; hidden if <2. Default = caps default (host arch).
  - `"_Virt Type:"` — QEMU only and arch not in {i686,x86_64,ppc64,ppc64le}; labels `"KVM"`, `"QEMU TCG"`, `"Hypervisor.framework"` (hvf); kvm first; hidden if ≤1.
  - `"_Machine Type:"` — hidden for x86; recommended machine first + separator (ppc64→`pseries`, arm/aarch64→`virt` (fallback `vexpress-a15`), s390x→`s390-ccw-virtio`, riscv→`virt`); hidden if ≤1.
  - UEFI: if OS/arch prefers UEFI or pref `new-vm/firmware=uefi` (x86 HVM) → enable UEFI; failure warning `"Failed to setup UEFI: %s\nInstall options are limited."`.

#### Step 2 (install source + OS)
| Method | Fields | Defaults / validation |
|---|---|---|
| ISO | `"Choose _ISO or CDROM install media:"` editable combo (history `urls/isos`, max 10, + host CDROM nodedevs `"<media label> (/dev/x)"`, `"No media detected"`, `"Media Unknown"`; placeholder `"No media selected"`, clear icon) + `"Bro_wse..."` (storage browser, reason ISO) | `"An install media selection is required."` |
| URL | `"Provide the operating system install U_RL:"` editable combo (history `urls/urls`, max 10); expander `"URL _Options"` → `"Kerne_l options:"` entry | `"An install tree is required."` |
| Import | `"Provide the existing stora_ge path:"` + `"B_rowse..."` | `"A storage path to import is required."`, `"The import path must point to an existing storage."` |
| Manual | none (focus OS search) | |
| App container | `"Provide the _application path:"` default `/bin/sh` + browse | `"An application path is required."` |
| OS container | `"Provide the existing OS root _directory:"` + browse; `"Create OS directory tree from container image"` (default off); `"Source URI:"` combo (history `urls/containers`; tooltip lists `file:///path/to/rootfs.tar`, `docker://registry:port/image:tag`, `virt-builder://template`); `"Do not verify TLS certificates of registry"`; expander `"Credentials for accessing the source registry"` → `"Username:"`/`"Password:"`; `"Root password:"` | needs virt-bootstrap + local conn (else notices); default dir `/var/lib/libvirt/filesystems/<name>` or `~/.local/share/libvirt/filesystems/<name>`; errors `"An OS directory path is required."`, `"Source URL is required"`, `"Please specify password for accessing source registry"`, `"Destination path is not directory: %s"`, `"No write permissions for directory path: %s"`, non-empty → yes/no `"OS root directory is not empty"` |
| VZ template | `"Select _container template:"` default `centos-7-x86_64` | `"A template name is required."` |
- OS selection (hidden for containers): `"C_hoose the operating system you are installing:"` + search entry (placeholder `"Type to start searching..."`).
  - `"A_utomatically detect from the installation media / source"` (default **on**); shown only for URL, or ISO on local conn. While on: search disabled showing `"Waiting for install media / source"`.
  - Detection: background thread, spinner, text `"Detecting..."`, timeout **20 s** (polled every 500 ms); result selects OS or `"None detected"`. Triggered on media change (not while entry focused), on activate, or on Forward (then auto-advances).
  - Popover list: all libosinfo OSes, label `"<label> (<short-id>)"`, natural sort (numbers reversed); generic entries (`generic` = `"Generic or unknown OS. Usage is not recommended."`, `linuxYYYY`) at end and always shown; filter substring on label or short-id; Down key opens popover.
  - `"Include end of life operating systems"` (default **off**; auto-checked if detected OS is EOL). Hint: `"Can't find the operating system you are looking for?\nTry selecting a similar distro or version, or use one of the 'Generic' options."`.
  - Missing OS → `"You must select an OS."` + hint.
- On valid Forward: default VM name generated; recommended resources applied; media paths saved to history; emulator search-permission check (`"The emulator may not have search permissions for the path '%s'."` / `"Do you want to correct this now?"` / chk `"Don't ask about these directories again."` → `paths/perms-fix-ignore`).

#### Step 3 (memory/CPU)
- `"Choose Memory and CPU settings:"`.
- `"_Memory:"` spin (MiB) range **50 … host RAM MiB**; label `"Up to %(maxmem)s available on the host"`. Default = OS recommended RAM (or minimum×2) else **1024**.
- `"C_PUs:"` spin range **1 … host active CPUs**; label `"Up to %(numcpus)d available"`. Default = OS recommended ncpus else **1**.
- Sets memory = currentMemory = value×1024 KiB.

#### Step 4 (storage; skipped for Import/containers)
- `"_Enable storage for this virtual machine"` (default **on**; off + ISO → livecd).
- Radio `"C_reate a disk image for the virtual machine"` (default) + size spin `"_GiB"` (1 decimal, 0–1,000,000, step 0.1; default **20**, overridden by OS recommended storage in GiB) + `"%s available in the default location"` (default pool free, `"Unknown GiB"`).
- Radio `"_Select or create custom storage"` + `"_Manage..."` (storage browser) + path entry.
- Default path: default pool target dir + `find_free_name(<vmname>, suffix by format: .qcow2 / .img)`; format = pref storage format (default qcow2); sparse unless raw.
- Errors: `"A storage path must be specified."`, `"Storage parameter error."`, disk conflict yes/no `"Disk '%(path)s' is already in use by other guests %(names)s"` / `"Do you really want to use the disk?"`.
- Advanced disk options (cache/discard/readonly/etc.) **not** shown in this wizard.

#### Step 5 (finish/summary)
- `"Ready to begin the installation"`; `"_Name:"` entry; summary rows `"OS:"`, `"Install:"`, `"Memory:"` (`"%d MiB"`), `"CPUs:"`, `"Storage:"` (`"%.1f GiB"` + small path, or `"None"`).
- Install text: `"Local CDROM/ISO"`, `"URL Install Tree"`, `"Import existing OS image"`, `"Manual install"`, `"Application container"`, `"Operating system container"`, `"Virtuozzo container"`.
- Default name: `Guest.generate_name` — base = osinfo short-id (strip `-unknown`); `generic` → `vm`/`container` with forced number (`vm1`, `vm2`, no sep); non-host arch appends `-<arch>`; collisions → `<base>-2`, `-3`… Name edits live-update default storage path.
- `"C_ustomize configuration before install"` (default **off**).
- Expander `"N_etwork selection"` (collapsed; auto-expands if no net source) → `"_Network source:"` combo:
  - Unprivileged qemu: `"Usermode networking"` first (and no default bridge).
  - Virtual networks sorted: `"Virtual network '<name>' : <forward mode>"` + `" (Inactive)"` / `" (OpenVSwitch)"`.
  - Manual rows: `"Bridge device..."`, `"Macvtap device..."`, `"vDPA device..."` → `"De_vice name:"` entry; macvtap warning `"In most configurations, macvtap does not work for host to guest network communication."`; mode `bridge` for macvtap.
  - `"_Portgroup:"` shown if net has portgroups (default = portgroup flagged default).
  - Default: host default bridge (manual bridge row prefilled) → `default` network → first row (+ warning `"Failed to find a suitable default network."`).
  - Inactive net on finish: yes/no `"Virtual Network is not active."` / `"Virtual Network '%s' is not active. Would you like to start the network now?"`.
  - MAC randomly generated; in-use check.
- Name errors: `"Invalid guest name"`.
- No unattended-install options in this version.

#### Finish
- `installer.set_install_defaults(guest)` (graphics type pref, CPU default pref, etc.).
- Customize off → async `"Creating Virtual Machine"` / `"The virtual machine is now being created. Allocation of disk storage and retrieval of the installation images may take a few minutes to complete."`.
- Customize on → opens VM details window for the unsaved guest with `"_Begin Installation"` / `"_Cancel Installation"`; closing it closes wizard (cleanup).
- After install: wait ≤20 s (200×0.1 s) for VM to appear (`"VM '%s' didn't show up after expected time."`); if shutoff → start; if post-boot XML changes needed → restart VM when install-phase shutdown observed (unless user aborted); refresh affected pools; close wizard; **open VM window** (console) for new VM.
- Error: `"Unable to complete install: '%s'"` (disks kept for retry; reused path).

### 10.2 Clone dialog (`clone.py`, `ui/clone.ui`, title `"Clone Virtual Machine"`)
- One instance per connection. Header `"Clone virtual machine"`. VM must be shutoff (`"Domain to clone must be shutoff."`).
- Fields: `"Original VM:"` (name), `"Connection:"` (pretty desc; row only if remote), `"_Name:"` entry, `"Storage:"` list + `"_Details..."` (enabled when row selected), note `"Cloning does not alter the guest OS contents. If you need to do things like change passwords or static IPs, please see the virt-sysprep(1) tool."`. Buttons `"_Cancel"`, `"C_lone"`.
- Default name: `<orig>-clone`; if orig matches `-clone[N]` → `<base>-clone<N+1>`; collisions → `-clone1`, `-clone2`… (no separator).
- Storage list cols: `"Clone"` (checkbox; replaced by info/warning icon if not cloneable) | `"Storage"` (device icon floppy/optical/harddisk + small markup: orig path or `"No storage."`; 2nd line `"Share disk with %s"` or `"Clone this disk (%.1f GiB)"`). Rows separated by separators. Tooltip: `"Disk target: %s"`, `"Original path: %s"`, `"New path: %s"`, `"Storage is safe to share: %(reason)s"` / `"Sharing this storage is potentially dangerous."`, `"Storage is not cloneable: %(reason)s"`.
- Default per disk: **Clone**, unless share-safe reason (→ Share): `"No storage to clone."` (empty), `"Read Only"`, `"Marked as shareable"`; or not cloneable: `"Disk path '%s' does not exist."`, rbd unsupported, `"Disk network type '%s' is not cloneable."`.
- New disk path: orig path with ext split (≤7 chars): `<base>-clone.<ext>`; if basename == orig VM name → `<newname>.<ext>`; collision numbering. Recomputed on name change unless manually set.
- `"Change storage path"` sub-dialog: `"Existing disk"` (`"Path:"`, `"Target:"`, `"Size:"`), `"Create a new disk (c_lone) for the virtual machine"`, `"New _Path:"` + `"_Browse..."`; existing target → yes/no `"Cloning will overwrite the existing file"`.
- Shared-but-unsafe disks → ok/cancel `"Sharing storage may cause data to be overwritten."` + list.
- Always: new UUID (and sysinfo UUID), title cleared, graphics fixed ports → autoport, **all NIC MACs regenerated**, target dev cleared, agent unix channel paths cleared, NVRAM copied to `<dir>/<newname>_VARS<.fd>`; sparse clones.
- Progress: `"Creating virtual machine clone '%s'"` (+ `" and selected storage (this may take a while)"`); errors `"Error with clone settings: %s"`, `"Error creating virtual machine clone '%(vm)s': %(error)s"`. On success: poll VMs, close.

### 10.3 Migrate dialog (`migrate.py`, `ui/migrate.ui`, title `"Migrate the virtual machine"`)
- Header `"Migrate '%(vm)s'"`; `"Migrating VM:"` (name/title), `"Original host:"` (`"<hostname> (<pretty desc>)"`, tooltip URI).
- `"New _host:"` combo of all known conns sorted; row labels: `"%(uri)s (Hypervisors do not match)"`, `"%(uri)s (Disconnected)"`, `"%(uri)s (Same connection)"` → insensitive; none usable → `"No usable connections available."`. Invalid → Migrate disabled, tooltip `"A valid destination connection must be selected."`.
- Frame `"Connectivity"`:
  - `"M_ode:"` combo `"Direct"` (default) / `"Tunnelled"` (tooltip explains p2p tunnel).
  - Direct: `"_Address:"` checkbox (default **on**) + entry (default dest `libvirt_gethostname()`), else `"Let libvirt decide"`; `"_Port:"` checkbox (default on; forced off if address off) + spin 0–70000 (default **49152**, Xen **8002**). URI `tcp:<addr>[:<port>]` (Xen: `<addr>[:port]`).
  - Tunnelled: `"_URI:"` entry = dest conn URI; warning if dest is local URI (`"A remotely accessible libvirt URI is required for tunneled migration, ..."`).
- Expander `"Advanced options"` (collapsed): `"A_llow unsafe:"` (off) → VIR_MIGRATE_UNSAFE; `"_Temporary move:"` (off) → if off: PERSIST_DEST|UNDEFINE_SOURCE.
- Always LIVE; tunnel → PEER2PEER|TUNNELLED + `migrateToURI3`; else `migrate3`. Optional XML tab (xmleditor) → DEST_XML. No bandwidth/downtime/offline options.
- Buttons `"_Cancel"`, `"_Migrate"`. Progress `"Migrating VM '%s'"` / `"Migrating VM '%(name)s' to %(host)s. This may take a while."`, cancellable via abort_job. Error `"Unable to migrate guest: %s"`.

### 10.4 Delete dialog (`delete.py`, `ui/delete.ui`, title `"Delete Virtual Machine"`)
- Header `"Delete '%(vmname)s'"`. Running VM → warning `"This VM is currently running and will be forced off before being deleted"`.
- `"Delete _associated storage files"` default **on** (VM delete; off for "Remove Disk Device" variant); toggles list visibility.
- List cols: checkbox | `"Storage Path"` (ellipsize middle) | `"Target"` | warning icon (tooltip = reason). Rows: all disks with a path + `kernel`, `initrd`, `dtb` (treated read-only media).
- Cannot delete (checkbox inconsistent/insensitive): `"Cannot delete iSCSI share."`, `"Cannot delete SCSI device."`, `"Cannot delete unmanaged remote storage."`, `"Path does not exist."`, `"No write access to parent directory."`, `"Cannot delete unmanaged block device."`.
- Deletable but default **unchecked** if: `"Storage is read-only."`, `"No write access to path."`, `"Storage is marked as shareable."`, `"Storage is a media device."` (cdrom/floppy), `"Storage is in use by the following virtual machines\n- …"`, `"Failed to check disk usage conflict."`. Otherwise checked.
- Finish: storage confirm (pref) → async: force off if active → delete each path (managed vol `delete(0)` else `unlink`) → undefine with SNAPSHOTS_METADATA | MANAGED_SAVE | NVRAM (if nvram) (fallback plain undefine; transient VMs skipped).
- Progress `"Deleting virtual machine '%s'"` (+ `" and selected storage (this may take a while)"`); errors `"Errors encountered while removing certain storage devices."`.

### 10.5 Preferences (`preferences.py`, `ui/preferences.ui`; Close button `"_Close"`, Esc closes; changes apply immediately)
| Tab | Label | Widget | gsettings key | Default | Values |
|---|---|---|---|---|---|
| `"_General"` | `"Enable _system tray icon"` | check | `system-tray` | false | disabled + warning on Wayland without AppIndicator |
| | `"Enable _XML editing"` | check | `xmleditor-enabled` | false | |
| | `"Enable libgues_tfs VM introspection"` | check | `enable-libguestfs-vm-inspection` | false | warns `"You must restart the application for this change to take effect"` |
| `"P_olling"` (frame `"Stats Options"`) | `"_Update status every"` … `"seconds"` | spin | `stats/update-interval` | 3 | 1–60 step 1 |
| | `"Poll C_PU usage"` | check | `stats/enable-cpu-poll` | true | |
| | `"Poll _Disk I/O"` | check | `stats/enable-disk-poll` | false | |
| | `"Poll _Network I/O"` | check | `stats/enable-net-poll` | false | |
| | `"Poll _Memory stats"` | check | `stats/enable-memory-poll` | false | |
| `"N_ew VM"` (frame `"New VM Defaults"`) | `"Gra_phics type:"` | combo | `new-vm/graphics-type` | `system` | `"System default (spice)"`=system, `"VNC"`=vnc, `"Spice"`=spice |
| | `"_Storage format:"` | combo | `new-vm/storage-format` | `default` | `"System default (qcow2)"`, `"Raw"`, `"QCOW2"` |
| | `"CPU _default:"` | combo | `new-vm/cpu-default` | `default` | `"Application default"`=default, `"Hypervisor default"`=hv-default, `"Nearest host CPU model"`=host-model-only, `host-model`, `host-passthrough`, `maximum` |
| | `"x86 _Firmware:"` | combo | `new-vm/firmware` | `default` | `"System default"`, `"UEFI"` |
| `"Conso_le"` (frame `"Graphical Consoles"`) | `"Graphical console _scaling:"` | combo | `console/scaling` | 2 | 0 `"Never"`, 1 `"Fullscreen only"`, 2 `"Always"` |
| | `"_Resize guest with window:"` | combo | `console/resize-guest` | -1 | -1 `"System default (Off)"`, 0 `"Off"`, 1 `"On"` |
| | `"SPICE _USB Redirection:"` | combo | `console/auto-redirect` | true | false `"Manual redirect only"`, true `"Auto redirect on USB attach"` |
| | `"Console autoconnec_t:"` | check | `console/autoconnect` | true | |
| | `"Gr_ab keys:"` + value label + `"Change..."` | dialog | `console/grab-keys` | `''` → `65507,65513` (Control_L+Alt_L) | comma keysyms; shown as `Control_L+Alt_L` |
| `"Feed_back"` (frame `"Confirmations"`) | `"_Force Poweroff:"` | check | `confirm/forcepoweroff` | true | |
| | `"Poweroff/_Reboot/Save:"` | check | `confirm/poweroff` | false | |
| | `"_Pause:"` | check | `confirm/pause` | false | |
| | `"Device re_moval:"` | check | `confirm/removedev` | true | |
| | `"_Unapplied changes:"` | check | `confirm/unapplied-dev` | true | |
| | `"_Deleting storage:"` | check | `confirm/delete-storage` | true | |
- Grab-keys dialog: title `"Configure grab key combination"`, Cancel/OK, text `"You can now define grab keys by pressing them.\nTo confirm your selection please click OK button\nwhile you have desired keys pressed."` + live `"Please press desired grab key combination"`; saves keys held at OK.
- Tooltips: storage format `"Default storage format for new disk images."`; CPU default (perf vs. migration tradeoff); firmware `"Default Firmware for new VMs. Boot using either BIOS or UEFI."`; resize guest (spice + agent only); autoconnect `"If disabled, the VM window will not automatically connect to the running VM graphical console."`.
- Other gsettings (no prefs UI): per-VM `vm-window-size`, `scaling` (-1 global), `console-username`, `resize-guest` (-1), `autoconnect` (-1); per-conn `pretty-name`, `window-size`; `connections/uris`, `connections/autoconnect`; `urls/{urls,isos,containers,kickstarts}` (history max 10, newest first); `paths/{image,media,screenshot}-default`, `paths/perms-fix-ignore`; `details/show-toolbar` (true); `manager-window-width/height` (0).
- Not present in this source: console keyboard-accels pref, add-sound pref, stats-history-length pref (hardcoded 120), unattended-install UI.
