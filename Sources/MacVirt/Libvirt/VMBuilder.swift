// SPDX-License-Identifier: GPL-2.0-or-later
// Generates domain XML for new virtual machines.

import Foundation

/// A guest OS profile: sensible device defaults, like virt-install's osinfo.
struct OSProfile: Hashable, Identifiable {
    var id: String { libosinfo }
    var name: String
    var libosinfo: String
    var isWindows = false
    var minMemoryMiB = 1024
    var defaultDiskGiB = 20

    static let all: [OSProfile] = [
        OSProfile(name: "Generic Linux", libosinfo: "http://libosinfo.org/linux/2024", minMemoryMiB: 2048, defaultDiskGiB: 20),
        OSProfile(name: "Ubuntu 24.04", libosinfo: "http://ubuntu.com/ubuntu/24.04", minMemoryMiB: 4096, defaultDiskGiB: 25),
        OSProfile(name: "Debian 13", libosinfo: "http://debian.org/debian/13", minMemoryMiB: 2048, defaultDiskGiB: 20),
        OSProfile(name: "Fedora", libosinfo: "http://fedoraproject.org/fedora/unknown", minMemoryMiB: 4096, defaultDiskGiB: 25),
        OSProfile(name: "RHEL / Rocky / Alma 10", libosinfo: "http://redhat.com/rhel/10.0", minMemoryMiB: 4096, defaultDiskGiB: 30),
        OSProfile(name: "Alpine Linux", libosinfo: "http://alpinelinux.org/alpinelinux/3.22", minMemoryMiB: 512, defaultDiskGiB: 8),
        OSProfile(name: "Windows 11", libosinfo: "http://microsoft.com/win/11", isWindows: true, minMemoryMiB: 4096, defaultDiskGiB: 64),
        OSProfile(name: "Windows 10", libosinfo: "http://microsoft.com/win/10", isWindows: true, minMemoryMiB: 4096, defaultDiskGiB: 64),
        OSProfile(name: "Windows Server 2025", libosinfo: "http://microsoft.com/win/2k25", isWindows: true, minMemoryMiB: 4096, defaultDiskGiB: 64),
        OSProfile(name: "FreeBSD", libosinfo: "http://freebsd.org/freebsd/14.3", minMemoryMiB: 2048, defaultDiskGiB: 20),
        OSProfile(name: "Generic / unknown OS", libosinfo: "http://libosinfo.org/unknown", minMemoryMiB: 1024, defaultDiskGiB: 20),
    ]
}

enum InstallMethod: String, CaseIterable, Identifiable {
    case iso = "Local install media (ISO image or CDROM)"
    case pxe = "Network Boot (PXE)"
    case importDisk = "Import existing disk image"
    case manual = "Manual install"
    var id: String { rawValue }
}

enum Firmware: String, CaseIterable, Identifiable {
    case bios = "BIOS", uefi = "UEFI", uefiSecure = "UEFI with Secure Boot"
    var id: String { rawValue }
}

struct VMSpec: Sendable {
    var name: String
    var arch: String              // aarch64 / x86_64
    var domainType: String        // hvf / kvm / qemu
    var emulator: String
    var machine: String? = nil
    var memoryMiB: Int
    var vcpus: Int
    var diskPath: String?         // nil = no disk
    var diskFormat = "qcow2"
    var isoPath: String?          // nil = no installation media
    var pxe = false
    var networkXML: String        // <interface> element(s)
    var firmware: Firmware = .bios
    /// Explicit UEFI images (bundled QEMU) or nil to let libvirt pick.
    var firmwareFiles: (code: String, varsTemplate: String)?
    var osID: String?
    var windows = false
}

enum VMBuilder {
    static func xml(for spec: VMSpec) -> String {
        let isARM = spec.arch == "aarch64"
        let machine = spec.machine ?? (isARM ? "virt" : "q35")
        let diskBus = spec.windows && !isARM ? "sata" : "virtio"
        let cdromBus = isARM ? "scsi" : "sata"
        let uefi = isARM || spec.firmware != .bios

        var os: String
        if uefi, let fw = spec.firmwareFiles {
            os = """
              <os>
                <type arch='\(spec.arch)' machine='\(machine)'>hvm</type>
                <loader readonly='yes' type='pflash' format='\(fw.code.hasSuffix(".qcow2") ? "qcow2" : "raw")'>\(fw.code.xmlEscaped)</loader>
                <nvram template='\(fw.varsTemplate.xmlEscaped)' \(fw.varsTemplate.hasSuffix(".qcow2") ? "templateFormat='qcow2' format='qcow2'" : "")/>
              </os>
            """
        } else if uefi {
            let secure = spec.firmware == .uefiSecure
                ? "<firmware><feature enabled='yes' name='secure-boot'/><feature enabled='yes' name='enrolled-keys'/></firmware>" : ""
            os = """
              <os firmware='efi'>
                <type arch='\(spec.arch)' machine='\(machine)'>hvm</type>
                \(secure)
              </os>
            """
        } else {
            os = """
              <os>
                <type arch='\(spec.arch)' machine='\(machine)'>hvm</type>
              </os>
            """
        }

        let cpu = spec.domainType == "qemu" ? "" : "<cpu mode='host-passthrough'/>"
        var features: String
        if isARM {
            features = "<features><acpi/><gic version='\(spec.domainType == "hvf" ? "3" : "host")'/></features>"
        } else {
            let hyperv = spec.windows && spec.domainType == "kvm"
                ? "<hyperv mode='custom'><relaxed state='on'/><vapic state='on'/><spinlocks state='on' retries='8191'/><vpindex state='on'/><runtime state='on'/><synic state='on'/><stimer state='on'/><frequencies state='on'/></hyperv>" : ""
            let smm = spec.firmware == .uefiSecure ? "<smm state='on'/>" : ""
            features = "<features><acpi/><apic/>\(hyperv)\(smm)</features>"
        }
        let clock = spec.windows
            ? "<clock offset='localtime'><timer name='rtc' tickpolicy='catchup'/><timer name='pit' tickpolicy='delay'/><timer name='hpet' present='no'/>\(spec.domainType == "kvm" ? "<timer name='hypervclock' present='yes'/>" : "")</clock>"
            : "<clock offset='utc'/>"

        var bootOrder = 1
        var disk = ""
        var cdrom = ""
        var net = spec.networkXML
        if spec.pxe {
            net = net.replacingOccurrences(of: "</interface>", with: "<boot order='1'/></interface>")
            bootOrder = 2
        }
        if let iso = spec.isoPath {
            cdrom = """
                <disk type='file' device='cdrom'>
                  <driver name='qemu' type='raw'/>
                  <source file='\(iso.xmlEscaped)'/>
                  <target dev='sda' bus='\(cdromBus)'/>
                  <readonly/>
                  <boot order='\(bootOrder + 1)'/>
                </disk>
            """
        }
        if let path = spec.diskPath {
            disk = """
                <disk type='\(path.hasPrefix("/dev/") ? "block" : "file")' device='disk'>
                  <driver name='qemu' type='\(spec.diskFormat)' discard='unmap'/>
                  <source \(path.hasPrefix("/dev/") ? "dev" : "file")='\(path.xmlEscaped)'/>
                  <target dev='\(diskBus == "virtio" ? "vda" : "sdb")' bus='\(diskBus)'/>
                  <boot order='\(bootOrder)'/>
                </disk>
            """
        }
        let tpm = spec.windows
            ? "<tpm model='\(isARM ? "tpm-tis" : "tpm-crb")'><backend type='emulator' version='2.0'/></tpm>" : ""
        let metadata = spec.osID.map {
            "<metadata><libosinfo:libosinfo xmlns:libosinfo='http://libosinfo.org/xmlns/libvirt/domain/1.0'><libosinfo:os id='\($0.xmlEscaped)'/></libosinfo:libosinfo></metadata>"
        } ?? ""

        return """
        <domain type='\(spec.domainType)'>
          <name>\(spec.name.xmlEscaped)</name>
          \(metadata)
          <memory unit='MiB'>\(spec.memoryMiB)</memory>
          <currentMemory unit='MiB'>\(spec.memoryMiB)</currentMemory>
          <vcpu>\(spec.vcpus)</vcpu>
        \(os)
          \(features)
          \(cpu)
          \(clock)
          <on_poweroff>destroy</on_poweroff>
          <on_reboot>restart</on_reboot>
          <on_crash>destroy</on_crash>
          \(isARM ? "" : "<pm><suspend-to-mem enabled='no'/><suspend-to-disk enabled='no'/></pm>")
          <devices>
            <emulator>\(spec.emulator.xmlEscaped)</emulator>
        \(disk)
        \(cdrom)
            \(cdromBus == "scsi" || isARM ? "<controller type='scsi' model='virtio-scsi'/>" : "")
            <controller type='usb' model='qemu-xhci' ports='15'/>
            \(net)
            <console type='pty'/>
            <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
            <input type='tablet' bus='usb'/>
            <input type='keyboard' bus='usb'/>
            <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>
            <video><model type='\(isARM ? "virtio" : (spec.windows ? "vga" : "virtio"))'/></video>
            \(tpm)
            <memballoon model='virtio'/>
            <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
          </devices>
        </domain>
        """
    }

    static let userNetwork = "<interface type='user'><model type='virtio'/></interface>"

    static func libvirtNetwork(_ name: String, model: String = "virtio") -> String {
        "<interface type='network'><source network='\(name.xmlEscaped)'/><model type='\(model)'/></interface>"
    }

    static func bridgeNetwork(_ bridge: String, model: String = "virtio") -> String {
        "<interface type='bridge'><source bridge='\(bridge.xmlEscaped)'/><model type='\(model)'/></interface>"
    }
}
