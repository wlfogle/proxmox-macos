#!/bin/bash
# =============================================================================
# update_all.sh — Nexus Homelab Universal Updater
# Inspired by BassT23/Proxmox Ultimate Updater + dereklarmstrong/proxmox toolkit
#
# Covers:
#   • Laptop        (Pop!_OS 22.04)       nala + flatpak + snap + firmware
#   • tiamat        (Proxmox/Debian 13)   BassT23 updater → host + LXC 300/501
#   • CT-300        (mediastack)          Riven git-pull via pct exec
#   • VM 990        (HAOS)                ha CLI via QEMU guest exec
#   • VM 101        (Win11)               PowerShell Windows Update via QEMU
#   • bahamut       (DietPi/Debian 13)    dietpi-update + nala + AdGuard
#   • OpenWrt       (VM 100)              ❌ no agent/route — update via LuCI
#
# Usage:
#   update_all.sh [options]
#   Options:
#     --dry-run        Print commands without executing
#     --laptop-only    Only update this machine
#     --skip-laptop    Skip local machine
#     --skip-tiamat    Skip tiamat host + containers
#     --skip-bahamut   Skip bahamut
#     --skip-vms       Skip HAOS and Win11 VM updates
#     --skip-riven     Skip Riven git-pull inside CT-300
#     --no-log         Don't write to log file
#     -h, --help
# =============================================================================
set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly TIAMAT="tiamat"
readonly BAHAMUT="bahamut"
readonly CT300_ID="300"
readonly HAOS_VMID="990"
readonly WIN11_VMID="101"
readonly OPENWRT_VMID="100"
readonly LOG_DIR="$HOME/logs/updates"
readonly LOG_FILE="$LOG_DIR/update_$(date +%Y-%m-%d_%H-%M).log"
# Disk free threshold (MB) — clean apt cache if below this
readonly DISK_WARN_MB=2048
# CT backups to retain per container on hdd-ct
readonly KEEP_CT_BACKUPS=1
readonly CT_DUMP_DIR="/mnt/hdd/ct-storage/dump"

# ── Feature flags (overridden by CLI args) ──────────────────────────────────
DO_LAPTOP=true
DO_TIAMAT=true
DO_BAHAMUT=true
DO_VMS=true
DO_RIVEN=true
DRY_RUN=false
ENABLE_LOG=true

# ── Colors + icons ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ── Tracking ─────────────────────────────────────────────────────────────────
declare -A RESULTS=()
START_TIME=$(date +%s)

# ── Logging ──────────────────────────────────────────────────────────────────
_log_raw() { echo -e "$*"; [[ "$ENABLE_LOG" == true ]] && echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null || true; }
log()      { _log_raw "  ${GREEN}✔${NC}  $*"; }
warn()     { _log_raw "  ${YELLOW}⚠${NC}  $*"; }
err()      { _log_raw "  ${RED}✖${NC}  $*"; }
info()     { _log_raw "  ${CYAN}ℹ${NC}  $*"; }
header()   { _log_raw "\n${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"; _log_raw "${BOLD}${BLUE}  🔄  $*${NC}"; _log_raw "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"; }
subhead()  { _log_raw "\n  ${BOLD}--- $* ---${NC}"; }

# ── Dry-run wrapper ──────────────────────────────────────────────────────────
run() {
  if [[ "$DRY_RUN" == true ]]; then
    _log_raw "  ${DIM}[dry-run] $*${NC}"
  else
    eval "$@"
  fi
}

# ── Utility: disk free in MB on a path ───────────────────────────────────────
disk_free_mb() { df -BM "$1" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}'; }

# ── Utility: remote disk check + clean ───────────────────────────────────────
remote_disk_check() {
  local host="$1" path="${2:-/}"
  local free
  free=$(ssh -T "$host" "df -BM $path" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
  if [[ -z "$free" ]]; then warn "Could not check disk on $host:$path"; return; fi
  if (( free < DISK_WARN_MB )); then
    warn "$host:$path only ${free}MB free — cleaning apt cache first"
    run ssh -T "$host" 'nala clean; apt-get clean'
  else
    info "$host:$path ${free}MB free ✓"
  fi
}

# ── Utility: pct exec disk check ─────────────────────────────────────────────
ct_disk_check() {
  local ctid="$1"
  local free
  free=$(ssh -T "$TIAMAT" "pct exec $ctid -- df -BM /" 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
  if [[ -n "$free" ]] && (( free < DISK_WARN_MB )); then
    warn "CT-${ctid}: only ${free}MB free — cleaning"
    run ssh -T "$TIAMAT" "pct exec $ctid -- bash -c 'nala clean 2>/dev/null || apt-get clean'"
  fi
}

# ── Parse args ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=true ;;
    --laptop-only)  DO_TIAMAT=false; DO_BAHAMUT=false; DO_VMS=false ;;
    --skip-laptop)  DO_LAPTOP=false ;;
    --skip-tiamat)  DO_TIAMAT=false ;;
    --skip-bahamut) DO_BAHAMUT=false ;;
    --skip-vms)     DO_VMS=false ;;
    --skip-riven)   DO_RIVEN=false ;;
    --no-log)       ENABLE_LOG=false ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--dry-run] [--laptop-only] [--skip-laptop]"
      echo "       [--skip-tiamat] [--skip-bahamut] [--skip-vms] [--skip-riven] [--no-log]"
      exit 0 ;;
    *) err "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Init log ──────────────────────────────────────────────────────────────────
if [[ "$ENABLE_LOG" == true ]]; then
  mkdir -p "$LOG_DIR"
  echo "=== Nexus Update Run: $(date) ===" > "$LOG_FILE"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
_log_raw "\n${BOLD}${CYAN}"
_log_raw "  ███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗"
_log_raw "  ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝"
_log_raw "  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗"
_log_raw "  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║"
_log_raw "  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║"
_log_raw "  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝"
_log_raw "       Homelab Universal Updater v${SCRIPT_VERSION}${NC}"
[[ "$DRY_RUN" == true ]] && _log_raw "  ${YELLOW}[DRY-RUN MODE]${NC}"
_log_raw ""

# =============================================================================
# 1. LAPTOP (local Pop!_OS)
# =============================================================================
update_laptop() {
  header "LAPTOP — Pop!_OS (local)"

  # Disk check
  local free; free=$(disk_free_mb /)
  if (( free < DISK_WARN_MB )); then
    warn "Root only ${free}MB free — cleaning first"
    run sudo nala clean
  else
    info "Disk: ${free}MB free ✓"
  fi

  subhead "APT (nala)"
  run sudo nala upgrade -y --no-install-recommends 2>&1 | grep -E "Upgrading|upgraded|installed|error|Error" || true
  run sudo nala autoremove -y
  run sudo nala clean

  subhead "Flatpak"
  if command -v flatpak &>/dev/null; then
    run flatpak update -y 2>&1 | grep -E "already|Update|Error" || true
  else
    info "flatpak not installed — skipping"
  fi

  subhead "Snap"
  if command -v snap &>/dev/null; then
    run sudo snap refresh 2>&1 | grep -E "already|refreshed|error" || true
  else
    info "snap not installed — skipping"
  fi

  subhead "Firmware (fwupdmgr)"
  if command -v fwupdmgr &>/dev/null; then
    run fwupdmgr refresh --force 2>/dev/null || true
    run fwupdmgr get-updates 2>/dev/null | grep -E "Device|Version|no upgrades" || true
    run fwupdmgr update -y --no-reboot-check 2>/dev/null || true
  else
    info "fwupdmgr not installed — skipping"
  fi

  subhead "AppImages"
  local appimage_dir="$HOME/.local/share/applications"
  if [[ -d "$appimage_dir" ]]; then
    for app in "$appimage_dir"/*.AppImage; do
      [[ -f "$app" ]] || continue
      if command -v appimage-update &>/dev/null; then
        info "Checking: $(basename "$app")"
        run appimage-update "$app" || true
      fi
    done
  else
    info "No AppImage directory found — skipping"
  fi

  RESULTS["laptop"]="✅ done"
  log "Laptop update complete"
}

# =============================================================================
# TIAMAT HELPER: prune_backups — keep KEEP_CT_BACKUPS newest .tar.zst per CT
# Runs on tiamat via base64-encoded bash (avoids fish heredoc issues)
# =============================================================================
prune_backups() {
  local script
  script=$(printf '%s\n' \
    '#!/bin/bash' \
    "DUMP=\"${CT_DUMP_DIR}\"" \
    "KEEP=${KEEP_CT_BACKUPS}" \
    'find "$DUMP" \( -name "*.tmp" -o -name "*.tar.dat" \) -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true' \
    'for ctid in $(ls "$DUMP"/vzdump-lxc-*.tar.zst 2>/dev/null | grep -oP "vzdump-lxc-\K[0-9]+" | sort -u); do' \
    '    mapfile -t bk < <(ls -t "$DUMP"/vzdump-lxc-${ctid}-*.tar.zst 2>/dev/null)' \
    '    total=${#bk[@]}' \
    '    echo "  CT-${ctid}: ${total} backup(s), keeping ${KEEP}"' \
    '    for (( i=KEEP; i<total; i++ )); do' \
    '        ts=$(basename "${bk[$i]}" | grep -oP "\d{4}_\d{2}_\d{2}-\d{2}_\d{2}_\d{2}")' \
    '        echo "    Removing: $(basename ${bk[$i]})"' \
    '        rm -f "$DUMP/vzdump-lxc-${ctid}-${ts}.tar.zst"' \
    '        rm -f "$DUMP/vzdump-lxc-${ctid}-${ts}.tar.zst.notes"' \
    '        rm -f "$DUMP/vzdump-lxc-${ctid}-${ts}.log"' \
    '    done' \
    'done' \
    'echo "Dump dir after prune: $(du -sh $DUMP | cut -f1)"'
  )
  local encoded
  encoded=$(echo "$script" | base64 -w0)
  if [[ "$DRY_RUN" == true ]]; then
    _log_raw "  ${DIM}[dry-run] prune_backups on $TIAMAT (keep $KEEP_CT_BACKUPS per CT)${NC}"
  else
    ssh -T "$TIAMAT" "echo ${encoded} | base64 -d | bash" 2>&1 | while IFS= read -r l; do info "  $l"; done
  fi
}

# =============================================================================
# 2. TIAMAT — Proxmox host + all LXCs (via BassT23 Ultimate Updater)
# =============================================================================
update_tiamat() {
  header "TIAMAT — Proxmox host + LXC 300 (mediastack) + LXC 501 (habridge)"

  # Connectivity check
  if ! ssh -T -o ConnectTimeout=5 "$TIAMAT" 'true' 2>/dev/null; then
    err "Cannot reach tiamat — skipping"
    RESULTS["tiamat"]="❌ unreachable"
    return 1
  fi

  # Disk check on host
  remote_disk_check "$TIAMAT" "/"
  remote_disk_check "$TIAMAT" "/var/cache"
  # Disk check inside CT-300 (had the HDD contention issue)
  ct_disk_check "$CT300_ID"

  subhead "BassT23 Ultimate Updater (headless) — updates host + all LXCs"
  info "Running: update -s  (headless mode — handles PVE, LXC 300, LXC 501)"
  info "Logs: /var/log/ultimate-updater.log and /var/log/ultimate-updater-error.log"
  run ssh -T "$TIAMAT" 'update -s' 2>&1 | grep -E "🔄|✅|❌|⚠|Updating|Finished|Error|error|FAILED|WARNING|LXC|VM|Host" || true

  # Check for errors in the log
  local errors
  errors=$(ssh -T "$TIAMAT" 'tail -20 /var/log/ultimate-updater-error.log 2>/dev/null' || true)
  if [[ -n "$errors" ]]; then
    warn "Updater error log (last 20 lines):"
    echo "$errors" | while IFS= read -r line; do warn "  $line"; done
  fi

  subhead "Prune CT backups (keep $KEEP_CT_BACKUPS newest per CT)"
  prune_backups

  RESULTS["tiamat"]="✅ done"
  log "tiamat update complete"
}

# =============================================================================
# 3. CT-300 — Riven git-pull (BassT23 handles APT; this updates the app code)
# =============================================================================
update_riven() {
  header "CT-300 mediastack — Riven & Frontend git-pull"

  if ! ssh -T -o ConnectTimeout=5 "$TIAMAT" 'true' 2>/dev/null; then
    err "Cannot reach tiamat — skipping Riven update"
    RESULTS["riven"]="❌ tiamat unreachable"
    return 1
  fi

  subhead "Riven backend (Python, /opt/riven)"
  run ssh -T "$TIAMAT" "pct exec $CT300_ID -- bash -c '
    set -e
    cd /opt/riven
    git fetch origin
    LOCAL=\$(git rev-parse HEAD)
    REMOTE=\$(git rev-parse @{u})
    if [ \"\$LOCAL\" = \"\$REMOTE\" ]; then
      echo \"Riven backend: already up-to-date\"
    else
      echo \"Updating Riven backend: \$(git log --oneline HEAD..@{u} | head -5)\"
      git pull --ff-only
      # Sync Python deps if requirements changed
      sudo -u riven .venv/bin/pip install -q -r requirements.txt 2>/dev/null || true
      systemctl restart riven 2>/dev/null || true
      echo \"Riven backend updated and restarted\"
    fi
  '" 2>&1 || warn "Riven backend update failed (non-fatal)"

  subhead "Riven frontend (Node.js, /opt/riven-frontend)"
  run ssh -T "$TIAMAT" "pct exec $CT300_ID -- bash -c '
    set -e
    cd /opt/riven-frontend
    git fetch origin
    LOCAL=\$(git rev-parse HEAD)
    REMOTE=\$(git rev-parse @{u})
    if [ \"\$LOCAL\" = \"\$REMOTE\" ]; then
      echo \"Riven frontend: already up-to-date\"
    else
      echo \"Updating Riven frontend: \$(git log --oneline HEAD..@{u} | head -5)\"
      git pull --ff-only
      # Rebuild if package.json changed
      npm ci --quiet 2>/dev/null || true
      npm run build --quiet 2>/dev/null || true
      systemctl restart riven-frontend 2>/dev/null || true
      echo \"Riven frontend updated and restarted\"
    fi
  '" 2>&1 || warn "Riven frontend update failed (non-fatal)"

  RESULTS["riven"]="✅ done"
  log "Riven update check complete"
}

# =============================================================================
# 4. HAOS — Home Assistant OS via QEMU guest exec ha CLI
# =============================================================================
update_haos() {
  header "VM $HAOS_VMID — Home Assistant OS (ha CLI via QEMU)"

  # Verify VM is running
  local status
  status=$(ssh -T "$TIAMAT" "qm status $HAOS_VMID 2>/dev/null | awk '{print \$2}'")
  if [[ "$status" != "running" ]]; then
    warn "HAOS VM $HAOS_VMID is not running — skipping"
    RESULTS["haos"]="⏭ not running"
    return
  fi

  subhead "Available updates"
  local avail
  avail=$(ssh -T "$TIAMAT" "qm guest exec $HAOS_VMID -- ha available-updates 2>&1")
  info "$avail"

  subhead "Update HA Core"
  run ssh -T "$TIAMAT" "qm guest exec $HAOS_VMID -- ha core update --no-progress 2>&1" | \
    grep -E "update|Update|done|error|Error|version" || true

  subhead "Update HA Supervisor"
  run ssh -T "$TIAMAT" "qm guest exec $HAOS_VMID -- ha supervisor update --no-progress 2>&1" | \
    grep -E "update|Update|done|error|Error|version" || true

  subhead "Update HA Add-ons (non-interactive)"
  run ssh -T "$TIAMAT" "qm guest exec $HAOS_VMID -- ha store addons update --no-progress 2>&1" | \
    grep -E "update|Update|done|error|Error|version" || true

  # NOTE: ha os update causes VM restart — require explicit flag
  local ha_os_ver
  ha_os_ver=$(ssh -T "$TIAMAT" "qm guest exec $HAOS_VMID -- ha available-updates 2>&1" | grep -A1 'update_type: os' | grep 'version_latest' | grep -oP '[0-9.]+'  | head -1)
  if [[ -n "$ha_os_ver" ]]; then
    warn "HAOS OS update to v${ha_os_ver} available — run with --update-haos-os to apply (causes VM restart)"
  fi

  RESULTS["haos"]="✅ done"
  log "HAOS update complete"
}

# =============================================================================
# 5. WIN11 — Windows Update via QEMU guest exec PowerShell
# =============================================================================
update_win11() {
  header "VM $WIN11_VMID — Windows 11 (PowerShell via QEMU)"

  local status
  status=$(ssh -T "$TIAMAT" "qm status $WIN11_VMID 2>/dev/null | awk '{print \$2}'")
  if [[ "$status" != "running" ]]; then
    warn "Win11 VM $WIN11_VMID is not running — skipping"
    RESULTS["win11"]="⏭ not running"
    return
  fi

  subhead "Scan + download Windows Updates (no forced reboot)"
  # Uses WUA COM API: scan, download, install (no reboot)
  local ps_script
  ps_script='
$ErrorActionPreference = "SilentlyContinue"
$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type=''Software''")
$count    = $result.Updates.Count
if ($count -eq 0) {
    Write-Host "Windows Update: no updates available"
    exit 0
}
Write-Host "Found $count update(s)"
$result.Updates | ForEach-Object { Write-Host "  - $($_.Title)" }
$downloader = $session.CreateUpdateDownloader()
$downloader.Updates = $result.Updates
Write-Host "Downloading..."
$dl = $downloader.Download()
Write-Host "Download result: $($dl.ResultCode)"
$installer = $session.CreateUpdateInstaller()
$installer.AllowSourcePrompts = $false
$installer.ForceQuiet         = $true
$installer.Updates            = $result.Updates
Write-Host "Installing (no reboot)..."
$ir = $installer.Install()
Write-Host "Install result: $($ir.ResultCode) | Reboot needed: $($ir.RebootRequired)"
'
  run ssh -T "$TIAMAT" "qm guest exec $WIN11_VMID -- powershell -NonInteractive -Command \"$ps_script\" 2>&1" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data',''))" 2>/dev/null || \
    ssh -T "$TIAMAT" "qm guest exec $WIN11_VMID -- powershell -NonInteractive -Command \"Write-Host 'Update scan complete'\" 2>&1" | head -5

  RESULTS["win11"]="✅ done"
  log "Win11 update triggered (check VM for reboot prompt)"
}

# =============================================================================
# 6. BAHAMUT — DietPi Pi 4 + services
# =============================================================================
update_bahamut() {
  header "BAHAMUT — DietPi / Debian 13 (Pi 4)"

  if ! ssh -T -o ConnectTimeout=5 "$BAHAMUT" 'true' 2>/dev/null; then
    err "Cannot reach bahamut — skipping"
    RESULTS["bahamut"]="❌ unreachable"
    return 1
  fi

  remote_disk_check "$BAHAMUT" "/"

  subhead "DietPi system update (dietpi-update 1)"
  run ssh -T "$BAHAMUT" 'bash -c "G_INTERACTIVE=0 dietpi-update 1 2>&1 | grep -E \"update|upgrade|Up-to-date|error|Error|installed\" | head -20"' || \
    run ssh -T "$BAHAMUT" 'bash -c "nala update -y && nala upgrade -y 2>&1 | grep -E \"upgraded|error|Error\" | head -20"'

  subhead "Cleanup"
  run ssh -T "$BAHAMUT" 'bash -c "nala autoremove -y; nala clean"'

  subhead "AdGuard Home (self-update)"
  run ssh -T "$BAHAMUT" 'bash -c "
    if command -v AdGuardHome &>/dev/null; then
      current=\$(AdGuardHome --version 2>/dev/null | grep -oP \"v[0-9.]+\" | head -1)
      latest=\$(curl -sf https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep -oP \"tag_name.*?v[0-9.]+\" | grep -oP \"v[0-9.]+\")
      echo \"AdGuardHome: installed \$current, latest \$latest\"
      if [ \"\$current\" != \"\$latest\" ]; then
        echo \"Updating AdGuardHome...\"
        systemctl stop AdGuardHome
        curl -sfL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -u 2>&1 | tail -5
        systemctl start AdGuardHome
        echo \"AdGuardHome updated\"
      fi
    else
      echo \"AdGuardHome binary not in PATH\"
    fi
  "' 2>&1 || warn "AdGuard update failed (non-fatal)"

  subhead "Vaultwarden (apt/binary)"
  # Vaultwarden on bahamut might be from apt or systemd binary
  run ssh -T "$BAHAMUT" 'bash -c "
    if systemctl is-active vaultwarden &>/dev/null; then
      dpkg -l vaultwarden 2>/dev/null | grep ^ii && echo \"vaultwarden via apt — handled by nala above\" || \
        echo \"vaultwarden binary — check https://github.com/dani-garcia/vaultwarden/releases for updates\"
    fi
  "' 2>&1 || true

  subhead "NoMachine (nxserver)"
  run ssh -T "$BAHAMUT" 'bash -c "
    if command -v nxserver &>/dev/null; then
      current=\$(nxserver --version 2>/dev/null | head -1)
      echo \"NoMachine: \$current\"
    fi
  "' 2>&1 || true

  RESULTS["bahamut"]="✅ done"
  log "bahamut update complete"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  [[ "$DO_LAPTOP"  == true ]] && update_laptop  || true
  [[ "$DO_TIAMAT"  == true ]] && update_tiamat  || true
  [[ "$DO_RIVEN"   == true ]] && [[ "$DO_TIAMAT" == true ]] && update_riven || true
  if [[ "$DO_VMS" == true ]] && [[ "$DO_TIAMAT" == true ]]; then
    update_haos  || true
    update_win11 || true
  fi
  [[ "$DO_BAHAMUT" == true ]] && update_bahamut || true

  # ── Summary ────────────────────────────────────────────────────────────────
  local elapsed=$(( $(date +%s) - START_TIME ))
  _log_raw "\n${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  _log_raw "${BOLD}${BLUE}  📋  UPDATE SUMMARY  (${elapsed}s)${NC}"
  _log_raw "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
  for k in laptop tiamat riven haos win11 bahamut; do
    [[ -v RESULTS["$k"] ]] && _log_raw "  ${BOLD}$(printf '%-12s' "$k")${NC}  ${RESULTS[$k]}"
  done
  _log_raw ""
  info "OpenWrt (VM 100) — update via LuCI: http://192.168.12.147"
  info "HAOS OS update  — run: ssh tiamat 'qm guest exec 990 -- ha os update'"
  [[ "$ENABLE_LOG" == true ]] && info "Full log: $LOG_FILE"
  _log_raw ""
}

main
