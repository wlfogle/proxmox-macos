#!/bin/bash
# cockpit-install-debian.sh — install cockpit extensions on Debian (bookworm or trixie)
# Run as root. Tested on Debian 12 (bookworm) and 13 (trixie).
set -euo pipefail

. /etc/os-release

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

COCKPIT_FILES_URL="https://github.com/cockpit-project/cockpit-files/releases/download/42/cockpit-files-42.tar.xz"
COCKPIT_SENSORS_URL="https://github.com/ocristopfer/cockpit-sensors/releases/download/1.1/cockpit-sensors.deb"
COCKPIT_COMPOSE_URL="https://github.com/RXTX4816/cockpit-compose/releases/download/v0.10.3/cockpit-compose_0.10.3-1_all.deb"
COCKPIT_PKGMGR_URL="https://github.com/hatlabs/cockpit-package-manager-debian/releases/download/v0.1.1-1/cockpit-package-manager_0.1.1-1_all.deb"

log() { echo "[cockpit-install] $*"; }

# ── 1. 45Drives repo ────────────────────────────────────────────────────────
log "Setting up 45Drives repo..."
mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/45drives-archive-keyring.gpg ]]; then
    wget -qO - https://repo.45drives.com/key/gpg.asc \
        | gpg --pinentry-mode loopback --batch --yes --dearmor \
              -o /etc/apt/keyrings/45drives-archive-keyring.gpg
fi

if [[ ! -f /etc/apt/sources.list.d/45drives-enterprise-bookworm.list ]]; then
    curl -sSL https://repo.45drives.com/repofiles/debian/45drives-enterprise-bookworm.list \
         -o /etc/apt/sources.list.d/45drives-enterprise-bookworm.list
fi

# Trixie needs apt pinning: 45Drives publishes against bookworm; on trixie
# its older podman pin (100:3.4.2) would shadow the distro's podman without this.
if [[ "${VERSION_ID}" == "13" ]]; then
    log "Applying 45Drives apt pinning for trixie..."
    cat > /etc/apt/preferences.d/99-45drives-pin <<'EOF'
Package: *
Pin: origin repo.45drives.com
Pin-Priority: 1

Package: cockpit-file-sharing
Pin: origin repo.45drives.com
Pin-Priority: 500
EOF
fi

# ── 2. dockermanager repo ───────────────────────────────────────────────────
log "Adding cockpit-dockermanager repo..."
echo "deb [trusted=yes arch=all] https://chrisjbawden.github.io/cockpit-dockermanager stable main" \
    > /etc/apt/sources.list.d/cockpit-dockermanager.list

# ── 3. apt update ───────────────────────────────────────────────────────────
log "Running apt update..."
apt-get update -qq

# ── 4. Install from apt repos ───────────────────────────────────────────────
log "Installing packages from repos..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cockpit-file-sharing \
    cockpit-storaged \
    cockpit-389-ds \
    packagekit \
    lm-sensors \
    dockermanager

# ── 5. cockpit-sensors (.deb) ───────────────────────────────────────────────
log "Installing cockpit-sensors..."
curl -sSL -o "$TMPDIR_WORK/sensors.deb" "$COCKPIT_SENSORS_URL"
dpkg -i "$TMPDIR_WORK/sensors.deb" || DEBIAN_FRONTEND=noninteractive apt-get install -f -y

# ── 6. cockpit-compose (.deb) ───────────────────────────────────────────────
log "Installing cockpit-compose..."
curl -sSL -o "$TMPDIR_WORK/compose.deb" "$COCKPIT_COMPOSE_URL"
dpkg -i "$TMPDIR_WORK/compose.deb" || DEBIAN_FRONTEND=noninteractive apt-get install -f -y

# ── 7. cockpit-package-manager (.deb) ───────────────────────────────────────
log "Installing cockpit-package-manager..."
curl -sSL -o "$TMPDIR_WORK/pkgmgr.deb" "$COCKPIT_PKGMGR_URL"
dpkg -i "$TMPDIR_WORK/pkgmgr.deb" || DEBIAN_FRONTEND=noninteractive apt-get install -f -y

# ── 8. cockpit-files (tarball → /usr/share/cockpit/files/) ─────────────────
# NOTE: the v42 tarball is a SOURCE tarball. Built assets live in dist/
# (contains manifest.json, index.html, etc.), not in an inner 'files/' dir.
log "Installing cockpit-files..."
curl -sSL -o "$TMPDIR_WORK/files.tar.xz" "$COCKPIT_FILES_URL"
mkdir -p "$TMPDIR_WORK/files-src"
tar -xJf "$TMPDIR_WORK/files.tar.xz" -C "$TMPDIR_WORK/files-src"
# Locate the built dist/ directory (contains manifest.json)
DIST_DIR="$(find "$TMPDIR_WORK/files-src" -maxdepth 3 -name 'manifest.json' -printf '%h\n' | head -1)"
if [[ -z "$DIST_DIR" ]]; then
    echo "[cockpit-install] ERROR: cannot locate manifest.json in tarball — aborting cockpit-files install" >&2
else
    rm -rf /usr/share/cockpit/files
    mkdir -p /usr/share/cockpit/
    cp -r "$DIST_DIR" /usr/share/cockpit/files
    ls /usr/share/cockpit/files/manifest.json && log "cockpit-files installed OK"
fi

# ── 9. Optimize cockpit settings ────────────────────────────────────────────
log "Configuring cockpit..."
mkdir -p /etc/cockpit
cat > /etc/cockpit/cockpit.conf <<'EOF'
[WebService]
AllowUnencrypted = true

[Session]
IdleTimeout = 15
Banner = /etc/issue
EOF

# Allow root login via cockpit
if [[ -f /etc/cockpit/disallowed-users ]]; then
    sed -i '/^root$/d' /etc/cockpit/disallowed-users
fi

# Ensure cockpit socket enabled
systemctl enable --now cockpit.socket
systemctl restart cockpit.socket 2>/dev/null || true

log "=== cockpit extensions installed successfully ==="
dpkg -l | grep -E "^ii.*(cockpit|dockermanager)" | awk '{print $2, $3}'
log "Manual install (tarball): cockpit-files → /usr/share/cockpit/files"
