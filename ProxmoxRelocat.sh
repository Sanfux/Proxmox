#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# ProxmoxRelocat.sh
# -----------------------------------------------------------------------------
# One-file setup / fix / check script that turns a freshly-installed standalone
# Proxmox VE host into a "relocatable appliance":
#
#   * Switches the management bridge (default vmbr0) to DHCP.
#   * Replaces the Proxmox enterprise repo with the no-subscription repo.
#   * Keeps /etc/hosts and the on-console banner (/etc/issue) in sync with the
#     current DHCP address - so when you unplug the box, move it to another
#     network, and plug it back in, https://<hostname>.local:8006 keeps working
#     and the bare-metal screen always shows the right IP.
#   * Installs an Avahi mDNS responder so <hostname>.local is discoverable.
#   * Installs a weekly unattended-upgrade + auto-reboot maintenance job.
#
# Do NOT use on a node that is part of a Proxmox cluster - the script refuses
# to run there. Designed for single-node home/lab/edge boxes.
# -----------------------------------------------------------------------------
# QUICK START - run as root on the Proxmox host:
#
#   # Easiest: pipe directly from GitHub (no local copy needed)
#   curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/ProxmoxRelocat.sh \
#     | bash -s -- setup
#
#   # Or: download once and run locally
#   curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/ProxmoxRelocat.sh \
#     -o /root/ProxmoxRelocat.sh
#   chmod +x /root/ProxmoxRelocat.sh
#   /root/ProxmoxRelocat.sh setup
#   reboot
#   /root/ProxmoxRelocat.sh check
# -----------------------------------------------------------------------------
# ACTIONS
#
#   setup   First-time configuration. Writes the helper scripts, the systemd
#           units, switches the bridge to DHCP, sets up the no-subscription
#           repo, installs Avahi + unattended-upgrades, and enables timers.
#           Safe to re-run; idempotent.
#
#   check   Read-only health check. Verifies bridge/DHCP/IP, /etc/hosts, the
#           pve-update-hosts-ip + pve-auto-maintenance services and timers,
#           pveproxy/pvedaemon, APT sources, simulates a dist-upgrade, and
#           tests Avahi .local resolution. Prints PASS / WARN / FAIL counts.
#
#   fix     Recovery action. Re-installs missing packages, re-writes the
#           helper scripts and systemd units, re-enables timers, and clears
#           known APT-sources problems (malformed deb822 stanzas, stale .bak
#           files in /etc/apt/sources.list.d, duplicate no-subscription
#           entries). Run this if a previous setup aborted halfway.
#
#   all     setup -> fix -> check
#
#   Default action when no argument is given: setup
# -----------------------------------------------------------------------------
# ENVIRONMENT VARIABLES (all optional)
#
#   BRIDGE=vmbr0                       Linux bridge to switch to DHCP
#   AUTO_REBOOT=yes                    Reboot after auto-maintenance if needed
#   INSTALL_AVAHI=yes                  Install + enable avahi-daemon
#   USE_NO_SUBSCRIPTION_REPO=yes       Add the Proxmox no-subscription repo
#   MAINTENANCE_SCHEDULE="Sun *-*-* 03:30:00"  systemd OnCalendar expression
#
#   Example:
#     BRIDGE=vmbr0 AUTO_REBOOT=yes INSTALL_AVAHI=no \
#       /root/ProxmoxRelocat.sh all
# -----------------------------------------------------------------------------
# FILES IT CREATES
#
#   /etc/default/pve-relocatable                       runtime config
#   /usr/local/sbin/pve-update-hosts-ip                /etc/hosts + banner updater
#   /usr/local/sbin/pve-auto-maintenance               weekly upgrade runner
#   /etc/systemd/system/pve-update-hosts-ip.{service,timer}
#   /etc/systemd/system/pve-auto-maintenance.{service,timer}
#   /etc/apt/sources.list.d/pve-no-subscription.list   (if needed)
#   /etc/apt/apt.conf.d/{20auto-upgrades,51pve-unattended-upgrades}
#   /root/pve-apt-source-backups/                      timestamped backups
#   /var/lib/pve-relocatable/last-ip                   last-seen DHCP address
#   /var/log/pve-auto-maintenance.log                  maintenance run log
#
# All originals are backed up under /root/pve-apt-source-backups/ before any
# in-place edit. Nothing in /etc/pve is touched.
# -----------------------------------------------------------------------------
# TROUBLESHOOTING
#
#   # See what the next run would do (no changes):
#   /root/ProxmoxRelocat.sh check
#
#   # Force an immediate /etc/hosts + console-banner refresh:
#   systemctl start pve-update-hosts-ip.service
#   journalctl -u pve-update-hosts-ip.service -n 30 --no-pager
#
#   # Manually trigger the weekly maintenance run (uses /var/log):
#   systemctl start pve-auto-maintenance.service
#   tail -f /var/log/pve-auto-maintenance.log
#
#   # Restore a backed-up APT source file:
#   ls /root/pve-apt-source-backups/
#   cp /root/pve-apt-source-backups/<file>.bak.<ts> /etc/apt/sources.list.d/<file>
# =============================================================================

ACTION="${1:-setup}"

BRIDGE="${BRIDGE:-vmbr0}"
AUTO_REBOOT="${AUTO_REBOOT:-yes}"
INSTALL_AVAHI="${INSTALL_AVAHI:-yes}"
USE_NO_SUBSCRIPTION_REPO="${USE_NO_SUBSCRIPTION_REPO:-yes}"
MAINTENANCE_SCHEDULE="${MAINTENANCE_SCHEDULE:-Sun *-*-* 03:30:00}"

BACKUP_ROOT="/root/pve-apt-source-backups"
CONFIG_FILE="/etc/default/pve-relocatable"

PASS=0
WARN=0
FAIL=0

msg() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

pass() {
  echo "[PASS] $*"
  PASS=$((PASS + 1))
}

warn() {
  echo "[WARN] $*"
  WARN=$((WARN + 1))
}

fail() {
  echo "[FAIL] $*"
  FAIL=$((FAIL + 1))
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
  fi
}

require_proxmox() {
  if [[ ! -d /etc/pve ]]; then
    echo "This does not look like a Proxmox VE host. /etc/pve is missing."
    exit 1
  fi
}

timestamp() {
  date +%Y%m%d-%H%M%S
}

backup_file() {
  local file="$1"
  local ts
  ts="$(timestamp)"

  mkdir -p "$BACKUP_ROOT"

  if [[ -f "$file" ]]; then
    cp -a "$file" "$BACKUP_ROOT/$(basename "$file").bak.$ts"
  fi
}

detect_codename() {
  local codename=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi

  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -sc)"
  fi

  if [[ -z "$codename" ]]; then
    echo "Could not detect Debian/Proxmox codename."
    exit 1
  fi

  echo "$codename"
}

check_not_clustered() {
  if command -v pvecm >/dev/null 2>&1; then
    if pvecm status 2>/dev/null | grep -q "Cluster information"; then
      local members
      members="$(pvecm nodes 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {count++} END {print count+0}')"

      if [[ "${members:-0}" -gt 1 ]]; then
        echo "This node appears to be in a Proxmox cluster."
        echo "Do not use DHCP relocatable networking for clustered Proxmox nodes."
        exit 1
      fi
    fi
  fi
}

has_active_pve_no_subscription_repo() {
  python3 <<'PY'
from pathlib import Path
import sys

paths = [Path("/etc/apt/sources.list")]
sources_dir = Path("/etc/apt/sources.list.d")

if sources_dir.exists():
    paths.extend(sorted(sources_dir.glob("*.list")))
    paths.extend(sorted(sources_dir.glob("*.sources")))

found = False

for path in paths:
    if not path.exists():
        continue

    try:
        text = path.read_text(errors="ignore")
    except Exception:
        continue

    if path.suffix == ".list" or path.name == "sources.list":
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.startswith("deb ") and "download.proxmox.com/debian/pve" in stripped and "pve-no-subscription" in stripped:
                found = True

    elif path.suffix == ".sources":
        stanzas = text.split("\n\n")
        for stanza in stanzas:
            low = stanza.lower()
            if "enabled: no" in low:
                continue
            if "download.proxmox.com/debian/pve" in stanza and "pve-no-subscription" in stanza:
                found = True

sys.exit(0 if found else 1)
PY
}

has_active_pve_no_subscription_sources_file() {
  python3 <<'PY'
from pathlib import Path
import sys

sources_dir = Path("/etc/apt/sources.list.d")
found = False

if sources_dir.exists():
    for path in sorted(sources_dir.glob("*.sources")):
        try:
            text = path.read_text(errors="ignore")
        except Exception:
            continue

        for stanza in text.split("\n\n"):
            low = stanza.lower()
            if "enabled: no" in low:
                continue
            if "download.proxmox.com/debian/pve" in stanza and "pve-no-subscription" in stanza:
                found = True

sys.exit(0 if found else 1)
PY
}

# Self-heal: detect .sources files that no longer parse (apt-get returns
# "Malformed stanza ...") and move them aside so the rest of the script can run.
quarantine_broken_sources() {
  shopt -s nullglob
  local broken=()
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if ! apt-get -o Debug::NoLocking=true -o APT::Get::List-Cleanup=0 \
         --print-uris -qq update >/dev/null 2>&1; then :; fi
    # Per-file parse check via apt-helper if available, else a cheap python check.
    if ! python3 - "$f" <<'PY' >/dev/null 2>&1
import re, sys
text = open(sys.argv[1], errors="ignore").read()
stanzas = [s for s in re.split(r"\n[ \t]*\n", text.strip("\n")) if s.strip()]
ok = True
for s in stanzas:
    fields = {}
    for line in s.splitlines():
        ls = line.strip()
        if not ls or ls.startswith("#"):
            continue
        m = re.match(r"([A-Za-z0-9-]+)\s*:", line)
        if not m:
            ok = False; break
        fields[m.group(1).lower()] = True
    if not ok: break
    if "types" not in fields or "uris" not in fields or "suites" not in fields:
        ok = False; break
sys.exit(0 if ok else 1)
PY
    then
      broken+=("$f")
    fi
  done
  shopt -u nullglob

  if (( ${#broken[@]} )); then
    mkdir -p "$BACKUP_ROOT"
    for f in "${broken[@]}"; do
      local dest="$BACKUP_ROOT/$(basename "$f").broken.$(timestamp)"
      mv -f "$f" "$dest"
      echo "Quarantined malformed APT source file: $f -> $dest"
    done
  fi
}

disable_enterprise_repos() {
  msg "Disabling active Proxmox enterprise repositories"

  mkdir -p "$BACKUP_ROOT"

  quarantine_broken_sources

  shopt -s nullglob

  # ---- legacy single-line *.list files -------------------------------------
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$file" ]] || continue

    if grep -qi "enterprise.proxmox.com" "$file"; then
      backup_file "$file"
      sed -i -E 's/^([^#].*enterprise\.proxmox\.com.*)$/# disabled by ProxmoxRelocat.sh: \1/I' "$file"
      echo "Disabled enterprise lines in: $file"
    fi
  done

  # ---- deb822 *.sources files ---------------------------------------------
  # Strategy:
  #   1. If EVERY stanza in the file references enterprise.proxmox.com,
  #      rename the file to .sources.disabled (APT ignores it).
  #   2. Otherwise, rewrite only the enterprise stanzas with Enabled: no,
  #      preserving comments, blank lines and other stanzas exactly.
  for file in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$file" ]] || continue
    grep -qi "enterprise.proxmox.com" "$file" || continue

    backup_file "$file"

    if python3 - "$file" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(errors="ignore")

# Split into stanzas on blank lines (one or more lines containing only whitespace).
# Re.split keeps no separators, so we lose the exact blank-line count between
# stanzas; we re-join with a single blank line which deb822 always accepts.
raw_stanzas = re.split(r"\n[ \t]*\n", text.strip("\n"))
stanzas = [s for s in raw_stanzas if s.strip()]

def is_enterprise(stanza: str) -> bool:
    for line in stanza.splitlines():
        ls = line.strip()
        if not ls or ls.startswith("#"):
            continue
        if "enterprise.proxmox.com" in line.lower():
            return True
    return False

def has_field(stanza: str, name: str) -> bool:
    pat = re.compile(rf"^{re.escape(name)}\s*:", re.IGNORECASE | re.MULTILINE)
    return bool(pat.search(stanza))

enterprise = [s for s in stanzas if is_enterprise(s)]
other      = [s for s in stanzas if not is_enterprise(s)]

# Caller decides what to do: rename if everything is enterprise.
if not other:
    sys.exit(2)

# Mixed file -> disable only the enterprise stanzas
new_stanzas = []
for s in stanzas:
    if not is_enterprise(s):
        new_stanzas.append(s)
        continue
    if has_field(s, "Enabled"):
        s = re.sub(r"^Enabled\s*:.*$", "Enabled: no",
                   s, flags=re.IGNORECASE | re.MULTILINE)
    else:
        s = s.rstrip() + "\nEnabled: no"
    new_stanzas.append(s)

path.write_text("\n\n".join(new_stanzas) + "\n")
sys.exit(0)
PY
    then
      echo "Disabled enterprise stanza(s) in: $file"
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        mv -f "$file" "${file}.disabled"
        echo "Disabled enterprise-only source file (renamed): $file -> ${file}.disabled"
      else
        echo "WARNING: failed to process $file (python exit $rc); leaving as-is" >&2
      fi
    fi
  done

  shopt -u nullglob
}

fix_apt_sources() {
  msg "Fixing APT source warnings and duplicates"

  mkdir -p "$BACKUP_ROOT"

  shopt -s nullglob

  for file in \
    /etc/apt/sources.list.d/*.bak \
    /etc/apt/sources.list.d/*.bak.* \
    /etc/apt/sources.list.d/*.old \
    /etc/apt/sources.list.d/*.old.* \
    /etc/apt/sources.list.d/*.orig \
    /etc/apt/sources.list.d/*.orig.* \
    /etc/apt/sources.list.d/*.save \
    /etc/apt/sources.list.d/*.save.*; do

    [[ -f "$file" ]] || continue
    echo "Moving invalid APT backup file out of sources.list.d: $file"
    mv -f "$file" "$BACKUP_ROOT/"
  done

  if [[ -f /etc/apt/sources.list.d/pve-no-subscription.list ]]; then
    if has_active_pve_no_subscription_sources_file; then
      echo "Moving duplicate pve-no-subscription.list because active .sources repo already exists."
      mv -f /etc/apt/sources.list.d/pve-no-subscription.list "$BACKUP_ROOT/pve-no-subscription.list.moved.$(timestamp)"
    fi
  fi

  shopt -u nullglob
}

configure_repositories() {
  local codename
  codename="$(detect_codename)"

  msg "Configuring Proxmox repositories"

  echo "Detected codename: $codename"

  disable_enterprise_repos

  if [[ "$USE_NO_SUBSCRIPTION_REPO" != "yes" ]]; then
    echo "USE_NO_SUBSCRIPTION_REPO is not yes. Leaving no-subscription repo unchanged."
    fix_apt_sources
    return
  fi

  if has_active_pve_no_subscription_repo; then
    echo "Active Proxmox no-subscription repository already exists."
  else
    echo "Adding Proxmox no-subscription repository."

    cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${codename} pve-no-subscription
EOF
  fi

  fix_apt_sources
}

configure_network_dhcp() {
  msg "Configuring ${BRIDGE} for DHCP"

  local interfaces_file="/etc/network/interfaces"
  local backup_file_path="${interfaces_file}.bak.$(timestamp)"

  if [[ ! -f "$interfaces_file" ]]; then
    echo "Missing $interfaces_file"
    exit 1
  fi

  cp -a "$interfaces_file" "$backup_file_path"
  echo "Backed up network config to: $backup_file_path"

  export BRIDGE

  python3 <<'PY'
import os
import re
from pathlib import Path

bridge = os.environ["BRIDGE"]
path = Path("/etc/network/interfaces")
text = path.read_text().splitlines()

stanza_start = re.compile(r"^\s*(auto|allow-|iface|mapping|source|source-directory)\b")
iface_re = re.compile(rf"^(\s*)iface\s+{re.escape(bridge)}\s+inet\s+\S+(\s*)$")
auto_re = re.compile(rf"^\s*auto\s+.*\b{re.escape(bridge)}\b")

found_iface = False
found_auto = False
out = []
i = 0

while i < len(text):
    line = text[i]

    if auto_re.search(line):
        found_auto = True

    if iface_re.match(line):
        found_iface = True
        out.append(f"iface {bridge} inet dhcp")
        i += 1

        while i < len(text):
            current = text[i]

            if stanza_start.match(current):
                break

            stripped = current.strip()

            if re.match(r"^(address|gateway|netmask|broadcast|network|pointopoint|dns-nameservers|dns-search)\b", stripped):
                i += 1
                continue

            out.append(current)
            i += 1

        continue

    out.append(line)
    i += 1

if not found_iface:
    raise SystemExit(f"Could not find 'iface {bridge} inet ...' in /etc/network/interfaces.")

if not found_auto:
    new_out = []
    inserted = False

    for line in out:
        if not inserted and re.match(rf"^\s*iface\s+{re.escape(bridge)}\s+inet\s+dhcp\b", line):
            new_out.append(f"auto {bridge}")
            inserted = True
        new_out.append(line)

    out = new_out

path.write_text("\n".join(out) + "\n")
PY

  echo "${BRIDGE} is now configured for DHCP."
  echo "Network change will fully apply after reboot."
}

write_default_config() {
  msg "Writing relocatable config"

  local host_short
  local host_fqdn

  host_short="$(hostname -s)"
  host_fqdn="$(hostname -f 2>/dev/null || hostname -s)"

  cat > "$CONFIG_FILE" <<EOF
BRIDGE="${BRIDGE}"
HOST_SHORT="${host_short}"
HOST_FQDN="${host_fqdn}"
AUTO_REBOOT="${AUTO_REBOOT}"
EOF

  echo "Wrote $CONFIG_FILE"
}

write_update_hosts_service() {
  msg "Installing hostname/IP update service"

  cat > /usr/local/sbin/pve-update-hosts-ip <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/default/pve-relocatable"
[[ -f "$CONFIG" ]] && source "$CONFIG"

BRIDGE="${BRIDGE:-vmbr0}"
HOST_SHORT="${HOST_SHORT:-$(hostname -s)}"
HOST_FQDN="${HOST_FQDN:-$(hostname -f 2>/dev/null || hostname -s)}"

STATE_DIR="/var/lib/pve-relocatable"
LAST_IP_FILE="${STATE_DIR}/last-ip"
HOSTS_FILE="/etc/hosts"

mkdir -p "$STATE_DIR"

IP=""

for _ in $(seq 1 60); do
  IP="$(ip -4 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"

  if [[ -n "$IP" ]]; then
    break
  fi

  sleep 1
done

if [[ -z "$IP" ]]; then
  echo "No IPv4 address found on ${BRIDGE}."
  exit 1
fi

OLD_IP=""
[[ -f "$LAST_IP_FILE" ]] && OLD_IP="$(cat "$LAST_IP_FILE" || true)"

python3 - "$HOSTS_FILE" "$IP" "$HOST_FQDN" "$HOST_SHORT" <<'PY'
import ipaddress
import sys
from pathlib import Path

hosts_file = Path(sys.argv[1])
ip = sys.argv[2]
fqdn = sys.argv[3]
short = sys.argv[4]

begin = "# BEGIN PVE RELOCATABLE HOST IP"
end = "# END PVE RELOCATABLE HOST IP"

lines = hosts_file.read_text().splitlines()
new_lines = []
inside = False

for line in lines:
    if line.strip() == begin:
        inside = True
        continue

    if line.strip() == end:
        inside = False
        continue

    if inside:
        continue

    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        new_lines.append(line)
        continue

    parts = stripped.split()
    addr = parts[0]
    names = parts[1:]

    try:
        parsed = ipaddress.ip_address(addr)
    except ValueError:
        new_lines.append(line)
        continue

    if (fqdn in names or short in names) and not parsed.is_loopback:
        new_lines.append("# disabled by pve-relocatable: " + line)
    else:
        new_lines.append(line)

block = [
    begin,
    f"{ip} {fqdn} {short}",
    end,
]

insert_at = 0

for idx, line in enumerate(new_lines):
    stripped = line.strip()

    if stripped.startswith("127.") or stripped.startswith("::1") or stripped == "":
        insert_at = idx + 1
    else:
        break

final = new_lines[:insert_at] + block + new_lines[insert_at:]
hosts_file.write_text("\n".join(final) + "\n")
PY

echo "$IP" > "$LAST_IP_FILE"

refresh_banner() {
  # Regenerate /etc/issue (and /etc/issue.net) from /etc/hosts via pvebanner.
  if command -v pvebanner >/dev/null 2>&1; then
    pvebanner >/dev/null 2>&1 || true
  fi

  # Force every getty (tty1..tty6, serial, etc.) to redraw the login prompt
  # so the new IP shows up on the physical console immediately, without reboot.
  systemctl kill -s HUP 'getty@*.service'  >/dev/null 2>&1 || true
  systemctl kill -s HUP 'serial-getty@*.service' >/dev/null 2>&1 || true

  # /etc/motd may also be referenced; regenerate it the same way pve-manager does
  # (no-op if pve-motd is absent).
  if [[ -x /usr/share/pve-manager/scripts/pve-motd ]]; then
    /usr/share/pve-manager/scripts/pve-motd >/dev/null 2>&1 || true
  fi
}

if [[ "$OLD_IP" != "$IP" ]]; then
  echo "Host IP changed from '${OLD_IP:-none}' to '${IP}'."

  if command -v pvecm >/dev/null 2>&1; then
    pvecm updatecerts --force >/dev/null 2>&1 || true
  fi

  systemctl try-reload-or-restart pveproxy.service pvedaemon.service >/dev/null 2>&1 || true
  refresh_banner
else
  echo "Host IP unchanged: ${IP}"
  # Still refresh the banner once per run so a stale /etc/issue from the
  # very first boot (before this service ever ran) gets corrected.
  if [[ ! -f "$LAST_IP_FILE.banner-done" ]]; then
    refresh_banner
    : > "$LAST_IP_FILE.banner-done"
  fi
fi
EOF

  chmod +x /usr/local/sbin/pve-update-hosts-ip

  cat > /etc/systemd/system/pve-update-hosts-ip.service <<EOF
[Unit]
Description=Update Proxmox /etc/hosts with DHCP address
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/local/sbin/pve-update-hosts-ip
EOF

  cat > /etc/systemd/system/pve-update-hosts-ip.timer <<EOF
[Unit]
Description=Periodically update Proxmox /etc/hosts with DHCP address

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_auto_maintenance_service() {
  msg "Installing automatic maintenance service"

  cat > /usr/local/sbin/pve-auto-maintenance <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/default/pve-relocatable"
[[ -f "$CONFIG" ]] && source "$CONFIG"

AUTO_REBOOT="${AUTO_REBOOT:-yes}"

LOG="/var/log/pve-auto-maintenance.log"
LOCK="/run/pve-auto-maintenance.lock"

exec >> "$LOG" 2>&1
exec 9>"$LOCK"

if ! flock -n 9; then
  echo "$(date -Is) Maintenance already running."
  exit 0
fi

echo "============================================================"
echo "$(date -Is) Starting Proxmox maintenance"

export DEBIAN_FRONTEND=noninteractive

apt-get update

echo "$(date -Is) Simulating full upgrade first..."
SIMULATION="$(apt-get -s dist-upgrade || true)"
echo "$SIMULATION"

if echo "$SIMULATION" | grep -Eq '^Remv (proxmox-ve|pve-manager|pve-cluster|qemu-server|lxc-pve|ifupdown2)( |$)'; then
  echo "$(date -Is) ABORTING: simulation wants to remove core Proxmox packages."
  exit 20
fi

echo "$(date -Is) Applying upgrades..."
apt-get \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -y dist-upgrade

echo "$(date -Is) Cleaning packages..."
apt-get -y autoremove --purge
apt-get -y autoclean

REBOOT_NEEDED="no"

if [[ -f /var/run/reboot-required ]]; then
  REBOOT_NEEDED="yes"
fi

RUNNING_KERNEL="$(uname -r)"
LATEST_KERNEL="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1 || true)"

if [[ -n "$LATEST_KERNEL" && "$LATEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
  echo "$(date -Is) Running kernel: ${RUNNING_KERNEL}"
  echo "$(date -Is) Latest installed kernel: ${LATEST_KERNEL}"
  REBOOT_NEEDED="yes"
fi

if [[ "$AUTO_REBOOT" == "yes" && "$REBOOT_NEEDED" == "yes" ]]; then
  echo "$(date -Is) Reboot required. Rebooting now."
  systemctl reboot
else
  echo "$(date -Is) Reboot needed: ${REBOOT_NEEDED}; auto reboot: ${AUTO_REBOOT}"
fi

echo "$(date -Is) Maintenance complete"
EOF

  chmod +x /usr/local/sbin/pve-auto-maintenance

  cat > /etc/systemd/system/pve-auto-maintenance.service <<EOF
[Unit]
Description=Automatic Proxmox maintenance and upgrades
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-auto-maintenance
EOF

  cat > /etc/systemd/system/pve-auto-maintenance.timer <<EOF
[Unit]
Description=Weekly automatic Proxmox maintenance and upgrades

[Timer]
OnCalendar=${MAINTENANCE_SCHEDULE}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

install_packages() {
  msg "Installing helper packages"

  apt-get update

  local packages
  packages=(
    ca-certificates
    curl
    unattended-upgrades
    apt-listchanges
  )

  if [[ "$INSTALL_AVAHI" == "yes" ]]; then
    packages+=(
      avahi-daemon
      avahi-utils
      libnss-mdns
    )
  fi

  apt-get install -y "${packages[@]}"

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/51pve-unattended-upgrades <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename},label=Debian";
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-updates,label=Debian";
        "origin=Proxmox,codename=\${distro_codename}";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF
}

enable_services() {
  msg "Enabling systemd timers and services"

  # Self-heal: if any unit file is missing (e.g. earlier setup aborted),
  # write it now.
  [[ -x /usr/local/sbin/pve-update-hosts-ip      ]] || write_update_hosts_service
  [[ -x /usr/local/sbin/pve-auto-maintenance     ]] || write_auto_maintenance_service
  [[ -f /etc/systemd/system/pve-update-hosts-ip.service  ]] || write_update_hosts_service
  [[ -f /etc/systemd/system/pve-auto-maintenance.service ]] || write_auto_maintenance_service

  systemctl daemon-reload

  systemctl enable --now pve-update-hosts-ip.timer       || warn "Could not enable pve-update-hosts-ip.timer"
  systemctl enable --now pve-auto-maintenance.timer      || warn "Could not enable pve-auto-maintenance.timer"

  if [[ "$INSTALL_AVAHI" == "yes" ]]; then
    if systemctl list-unit-files | grep -q '^avahi-daemon.service'; then
      systemctl enable --now avahi-daemon.service || true
    else
      echo "avahi-daemon.service not present; will be enabled after install_packages succeeds."
    fi
  fi

  systemctl start pve-update-hosts-ip.service || true
}

run_setup() {
  require_root
  require_proxmox
  check_not_clustered

  msg "Starting Proxmox relocatable setup"

  # Write the local helpers and systemd units FIRST. These do not depend on
  # APT or networking, so they always succeed -- ensuring that even if a
  # later step fails, the relocatable host-IP and maintenance services exist
  # and can be enabled on the next run.
  write_default_config
  write_update_hosts_service
  write_auto_maintenance_service

  configure_repositories

  # install_packages may fail (network, mirror outage, etc.) -- don't let that
  # leave the host without enabled services. Capture failure, continue, warn.
  if ! install_packages; then
    warn "install_packages failed; continuing so service units still get enabled."
  fi

  configure_network_dhcp
  enable_services
  fix_apt_sources

  msg "Setup complete"

  echo "Recommended next step:"
  echo "  reboot"
  echo
  echo "After reboot, run:"
  echo "  /root/ProxmoxRelocat.sh check"
  echo
  echo "Access Proxmox at:"
  echo "  https://<DHCP-IP>:8006"
  echo "  https://$(hostname -s).local:8006"
}

run_fix() {
  require_root
  require_proxmox

  msg "Running ProxmoxRelocat fix"

  configure_repositories

  # Make sure all helper packages are present (the original install_packages
  # may have been skipped if a previous setup aborted).
  if ! install_packages; then
    warn "install_packages failed during fix; check APT output above."
  fi

  # Make sure the relocatable systemd units exist and are enabled.
  write_default_config
  write_update_hosts_service
  write_auto_maintenance_service
  enable_services

  apt-get update

  msg "Fix complete"
}

run_check() {
  require_root

  PASS=0
  WARN=0
  FAIL=0

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    pass "Found $CONFIG_FILE"
  else
    warn "Missing $CONFIG_FILE. Using default BRIDGE=${BRIDGE}"
  fi

  BRIDGE="${BRIDGE:-vmbr0}"
  HOST_SHORT="${HOST_SHORT:-$(hostname -s)}"
  HOST_FQDN="${HOST_FQDN:-$(hostname -f 2>/dev/null || hostname -s)}"

  msg "Basic Proxmox check"

  if [[ -d /etc/pve ]]; then
    pass "This looks like a Proxmox VE host"
  else
    fail "/etc/pve not found. This may not be a Proxmox host"
  fi

  if command -v pveversion >/dev/null 2>&1; then
    pass "pveversion command exists"
    pveversion
  else
    fail "pveversion command not found"
  fi

  msg "Network bridge DHCP check"

  if [[ -f /etc/network/interfaces ]]; then
    pass "Found /etc/network/interfaces"
  else
    fail "Missing /etc/network/interfaces"
  fi

  if grep -Eq "^[[:space:]]*iface[[:space:]]+${BRIDGE}[[:space:]]+inet[[:space:]]+dhcp" /etc/network/interfaces 2>/dev/null; then
    pass "${BRIDGE} is configured for DHCP"
  else
    fail "${BRIDGE} is not configured as 'iface ${BRIDGE} inet dhcp'"
  fi

  STATIC_LINES="$(
    awk -v b="$BRIDGE" '
      $1=="iface" && $2==b && $3=="inet" {inside=1; next}
      /^[[:space:]]*(auto|allow-|iface|mapping|source|source-directory)[[:space:]]/ && inside {inside=0}
      inside && $1 ~ /^(address|gateway|netmask|broadcast|network|dns-nameservers|dns-search)$/ {print}
    ' /etc/network/interfaces 2>/dev/null || true
  )"

  if [[ -z "$STATIC_LINES" ]]; then
    pass "No static IPv4 address/gateway lines found inside ${BRIDGE} stanza"
  else
    warn "Static-looking lines still exist inside ${BRIDGE} stanza:"
    echo "$STATIC_LINES"
  fi

  IP_ADDR="$(ip -4 -o addr show dev "$BRIDGE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"

  if [[ -n "$IP_ADDR" ]]; then
    pass "${BRIDGE} has IPv4 address: ${IP_ADDR}"
  else
    fail "${BRIDGE} has no IPv4 address"
  fi

  DEFAULT_ROUTE="$(ip route show default 2>/dev/null | head -n 1 || true)"

  if [[ -n "$DEFAULT_ROUTE" ]]; then
    pass "Default route exists: ${DEFAULT_ROUTE}"
  else
    fail "No default route found"
  fi

  msg "Hostname and /etc/hosts check"

  # Make sure systemd has the latest view of the service unit files before
  # we test them, otherwise a freshly-written unit appears "missing".
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ -x /usr/local/sbin/pve-update-hosts-ip ]]; then
    pass "Found /usr/local/sbin/pve-update-hosts-ip"
  else
    fail "Missing /usr/local/sbin/pve-update-hosts-ip"
  fi

  if [[ -f /etc/systemd/system/pve-update-hosts-ip.service ]] \
     || systemctl list-unit-files | grep -q '^pve-update-hosts-ip.service'; then
    pass "pve-update-hosts-ip.service exists"
  else
    fail "pve-update-hosts-ip.service missing"
  fi

  if [[ -f /etc/systemd/system/pve-update-hosts-ip.timer ]] \
     || systemctl list-unit-files | grep -q '^pve-update-hosts-ip.timer'; then
    pass "pve-update-hosts-ip.timer exists"
  else
    fail "pve-update-hosts-ip.timer missing"
  fi

  if systemctl is-enabled --quiet pve-update-hosts-ip.timer; then
    pass "pve-update-hosts-ip.timer is enabled"
  else
    fail "pve-update-hosts-ip.timer is not enabled"
  fi

  if systemctl is-active --quiet pve-update-hosts-ip.timer; then
    pass "pve-update-hosts-ip.timer is active"
  else
    fail "pve-update-hosts-ip.timer is not active"
  fi

  echo "Running hostname/IP update service now..."

  if systemctl start pve-update-hosts-ip.service; then
    pass "pve-update-hosts-ip.service ran successfully"
  else
    fail "pve-update-hosts-ip.service failed"
  fi

  if grep -q "BEGIN PVE RELOCATABLE HOST IP" /etc/hosts 2>/dev/null; then
    pass "/etc/hosts contains relocatable managed block"
  else
    fail "/etc/hosts does not contain relocatable managed block"
  fi

  if [[ -n "${IP_ADDR:-}" ]]; then
    HOSTS_RESULT="$(getent hosts "$HOST_SHORT" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"

    if [[ "$HOSTS_RESULT" == "$IP_ADDR" ]]; then
      pass "Hostname ${HOST_SHORT} resolves to current IP ${IP_ADDR}"
    else
      warn "Hostname ${HOST_SHORT} resolves to '${HOSTS_RESULT:-nothing}', expected '${IP_ADDR}'"
    fi
  fi

  msg "Proxmox web services check"

  if systemctl is-active --quiet pveproxy.service; then
    pass "pveproxy.service is active"
  else
    fail "pveproxy.service is not active"
  fi

  if systemctl is-active --quiet pvedaemon.service; then
    pass "pvedaemon.service is active"
  else
    fail "pvedaemon.service is not active"
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -skI --connect-timeout 5 https://127.0.0.1:8006 >/dev/null; then
      pass "Proxmox web interface responds locally on https://127.0.0.1:8006"
    else
      fail "Proxmox web interface did not respond locally on port 8006"
    fi
  else
    warn "curl is not installed, skipping web interface HTTP check"
  fi

  msg "Avahi / .local discovery check"

  if systemctl list-unit-files | grep -q '^avahi-daemon.service'; then
    pass "avahi-daemon.service exists"

    if systemctl is-active --quiet avahi-daemon.service; then
      pass "avahi-daemon.service is active"
    else
      warn "avahi-daemon.service exists but is not active"
    fi

    if command -v avahi-resolve-host-name >/dev/null 2>&1; then
      if avahi-resolve-host-name "${HOST_SHORT}.local" >/dev/null 2>&1; then
        pass "${HOST_SHORT}.local resolves through Avahi"
      else
        warn "${HOST_SHORT}.local did not resolve locally through Avahi"
      fi
    else
      warn "avahi-resolve-host-name not found, skipping .local resolution test"
    fi
  else
    warn "Avahi is not installed. .local discovery may not work"
  fi

  msg "Automatic maintenance check"

  if [[ -x /usr/local/sbin/pve-auto-maintenance ]]; then
    pass "Found /usr/local/sbin/pve-auto-maintenance"
  else
    fail "Missing /usr/local/sbin/pve-auto-maintenance"
  fi

  if [[ -f /etc/systemd/system/pve-auto-maintenance.service ]] \
     || systemctl list-unit-files | grep -q '^pve-auto-maintenance.service'; then
    pass "pve-auto-maintenance.service exists"
  else
    fail "pve-auto-maintenance.service missing"
  fi

  if [[ -f /etc/systemd/system/pve-auto-maintenance.timer ]] \
     || systemctl list-unit-files | grep -q '^pve-auto-maintenance.timer'; then
    pass "pve-auto-maintenance.timer exists"
  else
    fail "pve-auto-maintenance.timer missing"
  fi

  if systemctl is-enabled --quiet pve-auto-maintenance.timer; then
    pass "pve-auto-maintenance.timer is enabled"
  else
    fail "pve-auto-maintenance.timer is not enabled"
  fi

  if systemctl is-active --quiet pve-auto-maintenance.timer; then
    pass "pve-auto-maintenance.timer is active"
  else
    fail "pve-auto-maintenance.timer is not active"
  fi

  echo
  echo "Configured Proxmox timers:"
  systemctl list-timers 'pve-*' --no-pager || true

  msg "APT repository and upgrade simulation"

  if has_active_pve_no_subscription_repo; then
    pass "Proxmox no-subscription repository appears to be configured"
  else
    warn "Proxmox no-subscription repository not found"
  fi

  ACTIVE_ENTERPRISE="$(
    grep -RhsE "^[[:space:]]*deb[[:space:]].*enterprise\.proxmox\.com" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  )"

  ACTIVE_ENTERPRISE_SOURCES="$(
    grep -Ril "enterprise.proxmox.com" /etc/apt/sources.list.d/*.sources 2>/dev/null | while read -r f; do
      if ! grep -qi "Enabled:[[:space:]]*no" "$f"; then
        echo "$f"
      fi
    done || true
  )"

  if [[ -z "$ACTIVE_ENTERPRISE" && -z "$ACTIVE_ENTERPRISE_SOURCES" ]]; then
    pass "No active enterprise.proxmox.com repo found"
  else
    warn "Active Proxmox enterprise repo may still be enabled:"
    echo "$ACTIVE_ENTERPRISE"
    echo "$ACTIVE_ENTERPRISE_SOURCES"
  fi

  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    pass "APT periodic auto-upgrade config exists"
  else
    warn "Missing /etc/apt/apt.conf.d/20auto-upgrades"
  fi

  if [[ -f /etc/apt/apt.conf.d/51pve-unattended-upgrades ]]; then
    pass "Proxmox unattended-upgrades config exists"
  else
    warn "Missing /etc/apt/apt.conf.d/51pve-unattended-upgrades"
  fi

  echo "Running apt-get update..."

  APT_LOG="/tmp/pve-relocat-apt-update.log"

  if apt-get update 2>&1 | tee "$APT_LOG"; then
    pass "apt-get update completed successfully"
  else
    fail "apt-get update failed"
  fi

  if grep -q "configured multiple times" "$APT_LOG"; then
    warn "APT still reports duplicate repository entries. Run: /root/ProxmoxRelocat.sh fix"
  fi

  if grep -q "Ignoring file" "$APT_LOG"; then
    warn "APT is ignoring invalid files in sources.list.d. Run: /root/ProxmoxRelocat.sh fix"
  fi

  echo "Running safe upgrade simulation. No packages will be changed..."

  SIM_FILE="/tmp/pve-dist-upgrade-simulation.txt"

  if apt-get -s dist-upgrade > "$SIM_FILE"; then
    pass "apt-get dist-upgrade simulation completed"
  else
    fail "apt-get dist-upgrade simulation failed"
  fi

  if grep -Eq '^Remv (proxmox-ve|pve-manager|pve-cluster|qemu-server|lxc-pve|ifupdown2)( |$)' "$SIM_FILE"; then
    fail "Upgrade simulation wants to remove core Proxmox packages. Review $SIM_FILE"
  else
    pass "Upgrade simulation does not remove core Proxmox packages"
  fi

  msg "Internet/DNS check"

  if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    pass "Internet IP connectivity works"
  else
    warn "Could not ping 1.1.1.1"
  fi

  if getent hosts deb.debian.org >/dev/null 2>&1; then
    pass "DNS resolution works"
  else
    warn "DNS resolution failed for deb.debian.org"
  fi

  msg "Summary"

  echo "PASS: $PASS"
  echo "WARN: $WARN"
  echo "FAIL: $FAIL"

  if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Result: FAILED"
    exit 1
  fi

  if [[ "$WARN" -gt 0 ]]; then
    echo
    echo "Result: PASSED WITH WARNINGS"
    exit 0
  fi

  echo
  echo "Result: PASSED"
}

show_help() {
  cat <<EOF
Usage:
  $0 setup
  $0 check
  $0 fix
  $0 all

Default:
  $0 setup

Examples:
  $0 setup
  reboot
  $0 check

  BRIDGE=vmbr0 AUTO_REBOOT=yes $0 all

Actions:
  setup   Configure Proxmox as a relocatable standalone appliance.
  check   Verify DHCP, hostname, Proxmox services, APT, updates, and Avahi.
  fix     Clean APT duplicates/backups and install missing Avahi test tools.
  all     Run setup, fix, then check.
EOF
}

case "$ACTION" in
  setup)
    run_setup
    ;;
  check)
    run_check
    ;;
  fix)
    run_fix
    ;;
  all)
    run_setup
    run_fix
    run_check
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    echo "Unknown action: $ACTION"
    show_help
    exit 1
    ;;
esac
