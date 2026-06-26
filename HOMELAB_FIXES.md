# Homelab Fixes Log

## 2026-06-26 — mediastack (CT 300) & tiamat

### 1. APT repo certificate failures (mediastack)

**Symptom:** Cockpit "Software updates" failed with TLS certificate errors for:
- `packagecloud.io/crowdsec/crowdsec`
- `deb.nodesource.com/node_24.x`
- `dl.cloudsmith.io/public/caddy/stable`

**Root cause:** `/etc/hosts` had stale Fastly IPs pinned by the `install-homarr-ct300.sh`
helper script (`bms-apt-pin` block). Those Fastly IPs began serving wrong TLS
certificates (`*.imgur.com`, `j.sni-644-default.ssl.fastly.net`, etc.) after a CDN
reconfiguration. DNS now resolves these hosts to AWS/Cloudflare IPs that serve
correct certificates.

**Fix:** Updated `/etc/hosts` bms-apt-pin entries with verified working IPs:

| Host | Old (Fastly — broken) | New (working) |
|------|-----------------------|---------------|
| `dl.cloudsmith.io` | 151.101.66.132 | 3.165.181.3 (AWS) |
| `deb.nodesource.com` | 151.101.0.193 | 172.66.150.169 (Cloudflare) |
| `packagecloud.io` | 151.101.0.165 | 52.8.205.153 (AWS) |

Each new IP was verified with `curl --resolve` before applying.

---

### 2. filebrowser.service failing (mediastack)

**Symptom:** `filebrowser.service` failed at startup — error:
> `/usr/local/community-scripts/filebrowser.db does not exist. Please run 'filebrowser config init' first.`

**Root cause:** The `ExecStartPre` in the service unit runs `touch` (creates empty file)
then `filebrowser config set`, but `config set` requires the database to be properly
initialised (valid SQLite schema) — an empty file is not sufficient.

**Fix:**
```bash
rm -f /usr/local/community-scripts/filebrowser.db
/usr/local/bin/filebrowser config init -d /usr/local/community-scripts/filebrowser.db
systemctl start filebrowser
```

Service is active and listening on port 32348.

---

### 3. lightdm / display-manager on headless server (mediastack)

**Symptom:** `display-manager` and `lightdm` showing "Failed to start" in Cockpit
Services — neither should exist on a headless media stack with no desktop environment.

**Fix:**
```bash
apt-get purge -y lightdm lxlock xscreensaver xscreensaver-data
apt-get autoremove -y
systemctl reset-failed lightdm.service
```

0 failed units remaining after cleanup.

---

### 4. tigervncserver@:1.service failing (tiamat)

**Symptom:** `tigervncserver@:1.service` stuck in "failed" state, no log entries
(journal rotated).

**Root cause (2 issues):**

1. `/etc/systemd/system/tigervncserver@:1.service.d/override.conf` had:
   ```ini
   ExecStart=/usr/libexec/tigervncsession-start :1 --I-KNOW-THIS-IS-INSECURE
   ```
   `tigervncsession-start` strictly requires exactly 1 argument and exits with
   `status=1/FAILURE` when given 2. The extra flag was never valid for this wrapper.

2. No VNC password file existed at `/root/.vnc/passwd`.

**Fix:**

Corrected override to pass only the display argument:
```ini
[Service]
ExecStart=
ExecStart=/usr/libexec/tigervncsession-start :1
```

Created password file (password: `tigervnc`):
```bash
printf 'tigervnc\ntigervnc\nn\n' | vncpasswd /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
systemctl daemon-reload && systemctl start tigervncserver@:1.service
```

Service is active — `tigervncsession root :1` running on tiamat.
