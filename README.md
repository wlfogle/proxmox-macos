# proxmox-macos

**One-script macOS Tahoe (26) VM on Proxmox — AMD + RX 580 GPU passthrough, headless/NomMachine**

Automated, non-interactive setup script for running macOS Tahoe on Proxmox VE 9 with an AMD CPU and Radeon GPU. No manual `qm` commands, no OpenCore editing, no config.plist fiddling.

## Hardware (tested on)

| Component | Spec |
|-----------|------|
| CPU | AMD Ryzen 5 3600 |
| GPU | AMD Radeon RX 580 (Ellesmere) |
| RAM | 32 GB |
| Hypervisor | Proxmox VE 9.2.3 |
| macOS | Tahoe 26.5.1 |

## Prerequisites

On your Proxmox host, ensure the following are already set in `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt vfio-pci.ids=1002:67df,1002:aaf0"
```

And in `/etc/modprobe.d/kvm.conf`:

```
options kvm ignore_msrs=Y report_ignored_msrs=0
```

Run `update-grub && update-initramfs -u -k all` and reboot the host once.

## Usage

### Phase 1 — Install macOS

Copy the script to your Proxmox host and run it as root:

```bash
scp install-macos-tahoe-tiamat.sh root@proxmox:/root/
ssh root@proxmox "bash /root/install-macos-tahoe-tiamat.sh"
```

The script will:
1. Check for existing ISOs — downloads only what's missing
2. Create VM 103 (`macos-tahoe`) via [osx-proxmox-next](https://github.com/lucid-fabrics/osx-proxmox-next)
3. Apply AMD-optimised QEMU args (Cascadelake-Server emulation)
4. Set `vga: vmware` so Proxmox noVNC works during installation
5. Start the VM

Then open **Proxmox web UI → VM 103 → Console** and complete the macOS installer:

1. OpenCore picker → **macOS Base System**
2. Disk Utility → Erase VirtIO disk → **APFS / GUID**
3. Install macOS Tahoe (~15 GB download from Apple)
4. VM reboots 2–3× automatically
5. `Less than a minute` hang = APFS sealing — **wait 90+ minutes**

### Phase 2 — Post-install

Inside macOS (via noVNC):

```bash
# Mount and copy OpenCore EFI to disk
# Open LongQT-OpenCore on Desktop → Mount_EFI.command
cp -R /Volumes/LongQT-OpenCore/EFI_RELEASE/EFI /Volumes/EFI/
```

Install [NomMachine](https://www.nomachine.com/download) for persistent remote access.

### Phase 3 — Enable GPU passthrough

Once NomMachine is running inside macOS, run on the Proxmox host:

```bash
bash /root/install-macos-tahoe-tiamat.sh --enable-gpu
```

This stops the VM, adds RX 580 passthrough (`vga: none`), and restarts. NomMachine/Moonlight will use the GPU.

## Idempotent

Re-running the script is safe at any point. If the VM already exists, it skips creation and re-applies the full config. Useful for fixing a broken config without starting over.

## QEMU Args

```
-device isa-applesmc,osk=...
-smbios type=2
-device qemu-xhci
-device usb-kbd -device usb-tablet
-global nec-usb-xhci.msi=off
-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
-cpu Cascadelake-Server,vendor=GenuineIntel,+invtsc,-pcid,-hle,-rtm,
     -avx512f,-avx512dq,-avx512cd,-avx512bw,-avx512vl,-avx512vnni,
     kvm=on,vmware-cpuid-freq=on
```

- `Cascadelake-Server` — named Intel CPU model; [30–44% faster than `-cpu host`](https://github.com/LongQT-sea/qemu-cpu-guide#macos-guests) for macOS
- `vendor=GenuineIntel` — required by macOS CPUID check
- `+invtsc` — fixes AMD TSC synchronisation (kernel panic without this)
- AVX-512/TSX/PCID disabled — not present on Ryzen 3600

## Sources

- [osx-proxmox-next](https://github.com/lucid-fabrics/osx-proxmox-next) — VM creation tool
- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) — OpenCore for Proxmox
- [OSX-KVM](https://github.com/kholia/OSX-KVM) — QEMU/KVM macOS reference
- [Dortania OpenCore Guide](https://dortania.github.io/OpenCore-Install-Guide/)
- [tonymacx86 Tahoe guide](https://www.tonymacx86.com/threads/howto-macos-26-tahoe-with-opencore-1-0-5-z390-i9-9900-rx-6600-xt.332345/)

## License

MIT
