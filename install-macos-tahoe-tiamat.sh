#!/usr/bin/env bash
# install-macos-tahoe-tiamat.sh
# Sources: OSX-KVM, LongQT-sea/OpenCore-ISO, osx-proxmox-next, tonymacx86, dortania
# Tiamat: AMD Ryzen 3600 · RX 580 passthrough · macOS Tahoe 26 · non-interactive
set -euo pipefail

REPO_URL="https://github.com/lucid-fabrics/osx-proxmox-next.git"
REPO_DIR="/root/osx-proxmox-next"
REPO_BRANCH="main"
VENV_DIR="$REPO_DIR/.venv"
LOG_FILE="/root/osx-proxmox-next-install.log"

# ── Tiamat VM config ──────────────────────────────────────────────────────────
VMID="103"
VM_NAME="macos-tahoe"
MACOS_VERSION="tahoe"
CORES="4"       # power-of-2 required — 6 cores causes Apple logo hang on AMD
MEMORY="16384"  # 16 GB
DISK="160"      # Tahoe minimum (tool default for tahoe is 160 GB)
STORAGE="local-lvm"
ISO_DIR="/var/lib/vz/template/iso"
BRIDGE="vmbr0"

# ── RX 580 PCI addresses (confirmed via lspci on tiamat) ─────────────────────
GPU_PCI="0000:09:00.0"   # 1002:67df  Ellesmere RX 580
GPU_AUDIO="0000:09:00.1" # 1002:aaf0  Ellesmere HDMI Audio
# ─────────────────────────────────────────────────────────────────────────────

# QEMU args — Cascadelake-Server for AMD (30-44% faster than -cpu host per
# LongQT-sea benchmarks); vendor=GenuineIntel satisfies macOS CPUID check;
# +invtsc fixes AMD TSC sync; AVX-512/TSX/PCID disabled (not on Ryzen 3600);
# ICH9 hotplug off required for PCIe GPU passthrough on q35.
QEMU_ARGS="-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
QEMU_ARGS+=" -smbios type=2"
QEMU_ARGS+=" -device qemu-xhci"
QEMU_ARGS+=" -device usb-kbd"
QEMU_ARGS+=" -device usb-tablet"
QEMU_ARGS+=" -global nec-usb-xhci.msi=off"
QEMU_ARGS+=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
QEMU_ARGS+=" -cpu Cascadelake-Server,vendor=GenuineIntel,+invtsc,-pcid,-hle,-rtm,-avx512f,-avx512dq,-avx512cd,-avx512bw,-avx512vl,-avx512vnni,kvm=on,vmware-cpuid-freq=on"

log() { echo "$1" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $1"; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
}

install_dependencies() {
    log "Installing dependencies..."
    apt-get update >>/dev/null 2>&1 || die "apt-get update failed"
    apt-get install -y git python3 python3-venv python3-pip >>/dev/null 2>&1 \
        || die "Failed to install packages"
}

sync_repo() {
    if [[ -d "$REPO_DIR/.git" ]]; then
        git -C "$REPO_DIR" fetch origin                        >>"$LOG_FILE" 2>&1
        git -C "$REPO_DIR" checkout "$REPO_BRANCH"             >>"$LOG_FILE" 2>&1
        git -C "$REPO_DIR" reset --hard "origin/$REPO_BRANCH"  >>"$LOG_FILE" 2>&1
    else
        git clone "$REPO_URL" "$REPO_DIR"          >>"$LOG_FILE" 2>&1 || die "git clone failed"
        git -C "$REPO_DIR" checkout "$REPO_BRANCH" >>"$LOG_FILE" 2>&1
    fi
    find "$REPO_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
}

setup_runtime() {
    python3 -m venv "$VENV_DIR" >>"$LOG_FILE" 2>&1 || die "venv creation failed"
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip                              >>"$LOG_FILE" 2>&1
    pip install --force-reinstall --no-deps -e "$REPO_DIR" >>"$LOG_FILE" 2>&1 || die "editable install failed"
    pip install -e "$REPO_DIR"                             >>"$LOG_FILE" 2>&1 || die "dependency install failed"
}

launch() {
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"

    log "[1/5] Preflight..."
    osx-next-cli preflight

    log "[2/5] Downloading OpenCore + macOS $MACOS_VERSION recovery..."
    osx-next-cli download --macos "$MACOS_VERSION" --iso-dir "$ISO_DIR"

    log "[3/5] Creating VM $VMID..."
    osx-next-cli apply --execute    \
        --vmid         "$VMID"      \
        --name         "$VM_NAME"   \
        --macos        "$MACOS_VERSION" \
        --cores        "$CORES"     \
        --memory       "$MEMORY"    \
        --disk         "$DISK"      \
        --storage      "$STORAGE"   \
        --iso-dir      "$ISO_DIR"   \
        --bridge       "$BRIDGE"    \
        --smbios-model "MacPro7,1" \
        --apple-services            \
        --verbose-boot

    log "[4/5] Applying correct AMD args + RX 580 GPU passthrough..."
    # Override CPU args (Cascadelake-Server + feature masking for Ryzen 3600)
    qm set "$VMID" --args "$QEMU_ARGS"
    # Ensure cpu: kvm64 so Proxmox doesn't inject conflicting AMD KVM flags
    qm set "$VMID" --cpu kvm64
    # Disable ballooning (required for macOS)
    qm set "$VMID" --balloon 0
    # RX 580 GPU — pcie=1, rombar=1, primary GPU
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1,rombar=1,x-vga=1"
    # RX 580 HDMI audio companion
    qm set "$VMID" --hostpci1 "${GPU_AUDIO},pcie=1"
    # No virtual display once GPU is passed through
    qm set "$VMID" --vga none
    # QEMU guest agent via ISA serial (correct transport for macOS)
    qm set "$VMID" --agent enabled=1,type=isa

    log "[5/5] Starting VM $VMID..."
    qm start "$VMID"

    log ""
    log "══════════════════════════════════════════════════════"
    log " VM $VMID started. Connect monitor to RX 580 physically."
    log ""
    log " INSTALL STEPS:"
    log "  1. OpenCore picker → select macOS Base System"
    log "  2. Disk Utility → Erase VirtIO disk → APFS / GUID"
    log "  3. Install macOS Tahoe (downloads ~15 GB from Apple)"
    log "  4. VM reboots 2-3x automatically — normal"
    log "  5. 'Less than 1 minute' hang = APFS sealing, wait 90+ min"
    log ""
    log " POST-INSTALL (on macOS, via Terminal):"
    log "  Mount EFI: open LongQT-OpenCore on Desktop → Mount_EFI.command"
    log "  Copy EFI:  cp -R /Volumes/LongQT-OpenCore/EFI_RELEASE/EFI /Volumes/EFI/"
    log "══════════════════════════════════════════════════════"
}

nuke_stale() {
    [[ -d "$REPO_DIR" ]] && { log "Removing stale install..."; rm -rf "$REPO_DIR"; }
}

main() {
    require_root
    nuke_stale
    install_dependencies
    sync_repo
    setup_runtime
    launch
}

main "$@"
