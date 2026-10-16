# Roadmap

## Done in 0.2
- Feature parity with virt-manager: hardware editor and Add Hardware, snapshots,
  serial console, performance graphs, storage pools and volumes, virtual networks,
  clone, migrate, extended create-VM wizard, preferences.

## Next
- Polish from real-world use (clone/migrate between real hosts, more guest-agent info).

## Later (after virt-manager parity, if wanted)
- **Apple Virtualization.framework backend**: a separate, non-libvirt connection
  type ("This Mac (Apple Virtualization)") next to the bundled QEMU/HVF backend.
  Enables macOS guests, Rosetta for Linux guests, and native graphics/virtio-fs.
  Snapshots, XML editing and other libvirt-specific features would not apply there.
- SPICE console (would require a SPICE client implementation).
