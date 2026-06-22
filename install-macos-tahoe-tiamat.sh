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

# ── ISO filenames ────────────────────────────────────────────────────────────
# Prefer the full installer ISO over recovery-only if present
FULL_ISO="macOS_Tahoe_26.5.1.iso"
RECOVERY_ISO="tahoe-recovery.iso"

# ── macOS recovery installer staging (self-heal a dead OpenCore picker) ───────
# board Mac-27AD2F918AE68F61 == MacPro7,1; with os=latest Apple serves Tahoe (26)
RECOVERY_BOARD_ID="Mac-27AD2F918AE68F61"
MACREC_PY="/root/OSX-PROXMOX/tools/macrecovery/macrecovery.py"
MACREC_URL="https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py"
RECOVERY_DIR="$ISO_DIR/tahoe-recovery"
RECOVERY_IMG="$ISO_DIR/tahoe-BaseSystem.img"

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

# Resolve which installer ISO to use; sets INSTALLER_ISO global
resolve_installer_iso() {
    if [[ -f "$ISO_DIR/$FULL_ISO" ]]; then
        INSTALLER_ISO="$FULL_ISO"
        log "  [found] $FULL_ISO (full installer)"
    elif [[ -f "$ISO_DIR/$RECOVERY_ISO" ]] || \
         [[ -f "$ISO_DIR/${MACOS_VERSION}-recovery.img" ]] || \
         [[ -f "$ISO_DIR/macOS_Tahoe_Recovery.iso" ]]; then
        # Normalise recovery to expected name
        if [[ ! -f "$ISO_DIR/$RECOVERY_ISO" ]]; then
            local src
            src=$(ls "$ISO_DIR/${MACOS_VERSION}-recovery.img" \
                     "$ISO_DIR/macOS_Tahoe_Recovery.iso" 2>/dev/null | head -1)
            ln -sf "$src" "$ISO_DIR/$RECOVERY_ISO"
            log "  [symlink] $(basename "$src") → $RECOVERY_ISO"
        fi
        INSTALLER_ISO="$RECOVERY_ISO"
        log "  [found] $RECOVERY_ISO (recovery only)"
    else
        INSTALLER_ISO=""
    fi
}

check_isos() {
    local need_download=0

    if [[ -f "$ISO_DIR/opencore-osx-proxmox-vm.iso" ]]; then
        log "  [found] opencore-osx-proxmox-vm.iso"
    else
        log "  [missing] opencore-osx-proxmox-vm.iso — will download"
        need_download=1
    fi

    resolve_installer_iso
    if [[ -z "$INSTALLER_ISO" ]]; then
        log "  [missing] macOS installer ISO — will download"
        need_download=1
    fi

    return $need_download
}

launch() {
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"

    log "[1/5] Preflight..."
    osx-next-cli preflight

    log "[2/5] Checking ISOs in $ISO_DIR..."
    if ! check_isos; then
        log "  Downloading missing assets..."
        osx-next-cli download --macos "$MACOS_VERSION"
    else
        log "  All ISOs present — skipping download."
    fi

    log "[3/5] Creating VM $VMID..."
    if qm status "$VMID" &>/dev/null; then
        log "  VM $VMID already exists — skipping creation, will re-apply config."
        # Stop it so config changes can be applied cleanly
        if qm status "$VMID" | grep -q running; then
            log "  Stopping VM $VMID..."
            qm stop "$VMID"
            sleep 3
        fi
    else
        # The tool's recovery ISO stamping step may fail on ISO 9660 images
        # (it expects HFS+). VM is still fully created — continue if it exists.
        set +e
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
        APPLY_EXIT=$?
        set -e
        if [[ $APPLY_EXIT -ne 0 ]]; then
            qm status "$VMID" &>/dev/null \
                || die "VM $VMID was not created (apply exited $APPLY_EXIT). Check: $LOG_FILE"
            log "  WARNING: apply exited $APPLY_EXIT (recovery ISO stamp — non-fatal)."
            log "  VM $VMID exists — continuing."
        fi
    fi

    log "[4/5] Applying AMD args + install-phase display config..."
    # Override QEMU CPU args (Cascadelake-Server + feature masking for Ryzen 3600)
    qm set "$VMID" --args "$QEMU_ARGS"
    # kvm64 prevents Proxmox injecting conflicting AMD KVM flags alongside our args
    qm set "$VMID" --cpu kvm64
    # Attach installer ISO as cdrom (full installer preferred over recovery)
    resolve_installer_iso
    qm set "$VMID" --ide2 "local:iso/${INSTALLER_ISO},media=cdrom"
    # Boot: OpenCore (ide0) → recovery cdrom (ide2) → main disk (virtio0)
    qm set "$VMID" --boot order='ide0;ide2;virtio0'
    # Disable ballooning (required for macOS)
    qm set "$VMID" --balloon 0
    # INSTALL PHASE: virtual display so noVNC works (headless / no physical monitor)
    # GPU passthrough is added via enable-gpu-passthrough() AFTER macOS is installed
    # and NomMachine is running inside the VM.
    qm set "$VMID" --vga vmware,memory=256
    # ISA serial is the correct QEMU guest agent transport for macOS
    qm set "$VMID" --agent enabled=1,type=isa

    log "[5/5] Starting VM $VMID..."
    qm start "$VMID"

    log ""
    log "══════════════════════════════════════════════════════"
    log " VM $VMID started — use Proxmox noVNC console to interact."
    log ""
    log " PHASE 1 — INSTALL (noVNC in Proxmox web UI):"
    log "  1. OpenCore picker → select macOS Base System"
    log "  2. Disk Utility → Erase VirtIO disk → APFS / GUID"
    log "  3. Install macOS Tahoe (~15 GB download from Apple)"
    log "  4. VM reboots 2-3x automatically — normal"
    log "  5. 'Less than 1 minute' hang = APFS sealing, wait 90+ min"
    log ""
    log " PHASE 2 — POST-INSTALL (inside macOS):"
    log "  a. Mount EFI: open LongQT-OpenCore on Desktop → Mount_EFI.command"
    log "  b. Copy EFI: cp -R /Volumes/LongQT-OpenCore/EFI_RELEASE/EFI /Volumes/EFI/"
    log "  c. Install NomMachine: https://www.nomachine.com/download/download&id=1"
    log "  d. Once NomMachine is running, switch to GPU passthrough:"
    log "     bash $0 --enable-gpu"
    log "══════════════════════════════════════════════════════"
}

enable_gpu_passthrough() {
    require_root
    log "Switching VM $VMID to RX 580 GPU passthrough..."
    qm stop "$VMID" || true
    sleep 3
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1,rombar=1,x-vga=1"
    qm set "$VMID" --hostpci1 "${GPU_AUDIO},pcie=1"
    qm set "$VMID" --vga none
    qm start "$VMID"
    log "GPU passthrough enabled. NomMachine/Moonlight will use the RX 580."
}

# Download a genuine macOS Tahoe recovery installer and attach it to the VM so
# the OpenCore picker has a "macOS Base System" entry to boot. Idempotent and
# safe to re-run. Use this if the picker only shows OPENCORE/UEFI Shell/Reset
# NVRAM (i.e. the installer media was deleted) — selecting OpenCore then "does
# nothing" because there is no OS and no installer to boot.
stage_recovery_installer() {
    require_root
    log "Staging macOS Tahoe recovery installer for VM $VMID..."

    # Ensure macrecovery.py is available (fetch from OpenCorePkg if missing).
    if [[ ! -f "$MACREC_PY" ]]; then
        MACREC_PY="/root/macrecovery.py"
        if [[ ! -f "$MACREC_PY" ]]; then
            log "  Fetching macrecovery.py..."
            curl -fsSL "$MACREC_URL" -o "$MACREC_PY" || die "Failed to fetch macrecovery.py"
        fi
    fi

    # Download + convert the BaseSystem only if we don't already have it.
    if [[ -f "$RECOVERY_IMG" ]] && [[ "$(stat -c%s "$RECOVERY_IMG")" -gt 500000000 ]]; then
        log "  Recovery image already present: $RECOVERY_IMG"
    else
        mkdir -p "$RECOVERY_DIR"
        log "  Downloading Tahoe recovery (board=$RECOVERY_BOARD_ID os=latest)..."
        python3 "$MACREC_PY" -b "$RECOVERY_BOARD_ID" -m 00000000000000000 -os latest \
            -o "$RECOVERY_DIR" download || die "macrecovery download failed"
        local dmg
        dmg="$(find "$RECOVERY_DIR" -iname 'BaseSystem.dmg' | head -1)"
        [[ -n "$dmg" ]] || die "BaseSystem.dmg not found after download"
        log "  Converting $dmg -> $RECOVERY_IMG"
        dmg2img -i "$dmg" -o "$RECOVERY_IMG" || die "dmg2img conversion failed"
    fi

    qm status "$VMID" &>/dev/null || die "VM $VMID does not exist — run the installer first."

    if qm status "$VMID" | grep -q running; then
        log "  Stopping VM $VMID to attach installer..."
        qm stop "$VMID"; sleep 3
    fi

    # Drop any dangling unused disk references (e.g. a previously deleted installer).
    local u
    for u in $(qm config "$VMID" | grep -oE '^unused[0-9]+' || true); do
        log "  Removing stale $u..."
        qm set "$VMID" --delete "$u" || true
    done

    if qm config "$VMID" | grep -qE '^ide2:'; then
        log "  Installer already attached on ide2."
    else
        log "  Importing installer image into $STORAGE..."
        qm importdisk "$VMID" "$RECOVERY_IMG" "$STORAGE"
        local volid
        volid="$(qm config "$VMID" | grep -E '^unused[0-9]+:' | head -1 | awk '{print $2}')"
        [[ -n "$volid" ]] || die "Could not find imported installer disk"
        log "  Attaching $volid as ide2..."
        qm set "$VMID" --ide2 "${volid},media=disk"
    fi

    # Boot order: OpenCore (ide0) -> installer (ide2) -> macOS target (virtio0)
    qm set "$VMID" --boot order='ide0;ide2;virtio0'
    qm start "$VMID"

    log ""
    log "Installer staged. In noVNC: pick 'macOS Base System' ->"
    log "  Disk Utility -> Show All Devices -> erase the 160G VirtIO disk (APFS/GUID)"
    log "  -> Reinstall macOS Tahoe."
}

nuke_stale() {
    [[ -d "$REPO_DIR" ]] && { log "Removing stale install..."; rm -rf "$REPO_DIR"; }
}

main() {
    case "${1:-}" in
        --enable-gpu)
            enable_gpu_passthrough
            ;;
        --stage-installer)
            stage_recovery_installer
            ;;
        *)
            require_root
            nuke_stale
            install_dependencies
            sync_repo
            setup_runtime
            launch
            ;;
    esac
}

main "$@"
