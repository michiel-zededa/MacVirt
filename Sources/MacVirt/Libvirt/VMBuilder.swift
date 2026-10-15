// SPDX-License-Identifier: GPL-2.0-or-later
// Generates domain XML for new virtual machines.

import Foundation

struct VMSpec: Sendable {
    var name: String
    var arch: String              // aarch64 / x86_64
    var domainType: String        // hvf / kvm / qemu
    var emulator: String
    var memoryMiB: Int
    var vcpus: Int
    var diskPath: String
    var isoPath: String?          // nil = no installation media
    var networkXML: String        // <interface> element
    /// Explicit UEFI firmware (bundled QEMU) or nil to let libvirt pick.
    var firmware: (code: String, varsTemplate: String)?
}

enum VMBuilder {
    static func xml(for spec: VMSpec) -> String {
        let isARM = spec.arch == "aarch64"
        let cdromBus = isARM ? "scsi" : "sata"

        var os: String
        if let fw = spec.firmware {
            os = """
              <os>
                <type arch='\(spec.arch)' machine='\(isARM ? "virt" : "q35")'>hvm</type>
                <loader readonly='yes' type='pflash'>\(fw.code.xmlEscaped)</loader>
                <nvram template='\(fw.varsTemplate.xmlEscaped)'/>
              </os>
            """
        } else {
            os = """
              <os\(isARM ? " firmware='efi'" : "")>
                <type arch='\(spec.arch)' machine='\(isARM ? "virt" : "q35")'>hvm</type>
              </os>
            """
        }

        let cpu = spec.domainType == "qemu" ? "" : "<cpu mode='host-passthrough'/>"
        let features = isARM
            ? "<features><acpi/><gic version='\(spec.domainType == "hvf" ? "3" : "host")'/></features>"
            : "<features><acpi/><apic/></features>"

        var cdrom = ""
        if let iso = spec.isoPath {
            cdrom = """
                <disk type='file' device='cdrom'>
                  <driver name='qemu' type='raw'/>
                  <source file='\(iso.xmlEscaped)'/>
                  <target dev='sda' bus='\(cdromBus)'/>
                  <readonly/>
                  <boot order='2'/>
                </disk>
            """
        }

        return """
        <domain type='\(spec.domainType)'>
          <name>\(spec.name.xmlEscaped)</name>
          <memory unit='MiB'>\(spec.memoryMiB)</memory>
          <vcpu>\(spec.vcpus)</vcpu>
        \(os)
          \(features)
          \(cpu)
          <clock offset='utc'/>
          <on_poweroff>destroy</on_poweroff>
          <on_reboot>restart</on_reboot>
          <on_crash>destroy</on_crash>
          <devices>
            <emulator>\(spec.emulator.xmlEscaped)</emulator>
            <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2' discard='unmap'/>
              <source file='\(spec.diskPath.xmlEscaped)'/>
              <target dev='vda' bus='virtio'/>
              <boot order='1'/>
            </disk>
        \(cdrom)
            \(isARM ? "<controller type='scsi' model='virtio-scsi'/>" : "")
            <controller type='usb' model='qemu-xhci'/>
            \(spec.networkXML)
            <input type='tablet' bus='usb'/>
            <input type='keyboard' bus='usb'/>
            <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
            <video><model type='\(isARM ? "virtio" : "vga")'/></video>
            <console type='pty'/>
            <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
          </devices>
        </domain>
        """
    }

    static let userNetwork = "<interface type='user'><model type='virtio'/></interface>"

    static func libvirtNetwork(_ name: String) -> String {
        "<interface type='network'><source network='\(name.xmlEscaped)'/><model type='virtio'/></interface>"
    }
}
