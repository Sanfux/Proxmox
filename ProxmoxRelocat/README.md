# ProxmoxRelocat.sh

A one-file setup/fix/check script that turns a freshly-installed standalone Proxmox VE host into a **relocatable appliance** — plug it into any network and it just works.

> ⚠️ **Do not use on a Proxmox cluster node.** Designed for single-node home/lab/edge boxes only.

---

## What It Does

- Switches the management bridge (default `vmbr0`) to DHCP
- Replaces the Proxmox enterprise repo with the free no-subscription repo
- Keeps `/etc/hosts` and the on-console banner (`/etc/issue`) in sync with the current DHCP address
- Installs Avahi mDNS so `<hostname>.local` is always discoverable on the LAN
- Installs a weekly unattended-upgrade + auto-reboot maintenance job

After setup, when you move the box to a new network it gets a new IP automatically, the web UI at `https://<hostname>.local:8006` keeps working, and the physical console always shows the right address.

---

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/ProxmoxRelocat/ProxmoxRelocat.sh)" -- setup
```

Then reboot and verify:

```bash
reboot
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/ProxmoxRelocat/ProxmoxRelocat.sh)" -- check
```

To inspect before running (recommended for production):

```bash
curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/ProxmoxRelocat/ProxmoxRelocat.sh \
  -o /root/ProxmoxRelocat.sh
less /root/ProxmoxRelocat.sh
bash /root/ProxmoxRelocat.sh setup
reboot
bash /root/ProxmoxRelocat.sh check
```

---

## Actions

| Action | Description |
|--------|-------------|
| `setup` | First-time configuration. Writes helper scripts, systemd units, switches bridge to DHCP, sets up repos, installs packages. Safe to re-run. |
| `check` | Read-only health check. Verifies DHCP/IP, `/etc/hosts`, services, APT sources, upgrade simulation, and Avahi. Prints PASS/WARN/FAIL counts. |
| `fix` | Recovery action. Re-installs missing packages, re-writes helper scripts and systemd units, clears broken APT source files and duplicates. Run this if setup aborted halfway. |
| `all` | Runs `setup` → `fix` → `check` in sequence. |

Default action when no argument is given: `setup`

---

## Environment Variables

All settings are optional and have sensible defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `BRIDGE` | `vmbr0` | Linux bridge to switch to DHCP |
| `AUTO_REBOOT` | `yes` | Reboot after auto-maintenance if a new kernel is installed |
| `INSTALL_AVAHI` | `yes` | Install and enable avahi-daemon for `.local` discovery |
| `USE_NO_SUBSCRIPTION_REPO` | `yes` | Add the Proxmox no-subscription repo |
| `MAINTENANCE_SCHEDULE` | `Sun *-*-* 03:30:00` | systemd `OnCalendar` expression for weekly maintenance |

Example with custom options:

```bash
BRIDGE=vmbr0 AUTO_REBOOT=yes INSTALL_AVAHI=no \
  bash /root/ProxmoxRelocat.sh all
```

---

## Files Created

| Path | Purpose |
|------|---------|
| `/etc/default/pve-relocatable` | Runtime config (bridge name, hostname, options) |
| `/usr/local/sbin/pve-update-hosts-ip` | Updates `/etc/hosts` and console banner with current DHCP IP |
| `/usr/local/sbin/pve-auto-maintenance` | Weekly upgrade runner |
| `/etc/systemd/system/pve-update-hosts-ip.{service,timer}` | Runs IP updater on boot and every 5 minutes |
| `/etc/systemd/system/pve-auto-maintenance.{service,timer}` | Runs weekly maintenance job |
| `/etc/apt/sources.list.d/pve-no-subscription.list` | Proxmox no-subscription repo (if added) |
| `/etc/apt/apt.conf.d/20auto-upgrades` | APT periodic update config |
| `/etc/apt/apt.conf.d/51pve-unattended-upgrades` | Unattended-upgrades config for Proxmox |
| `/root/pve-apt-source-backups/` | Timestamped backups of any modified APT source files |
| `/var/lib/pve-relocatable/last-ip` | Last-seen DHCP address |
| `/var/log/pve-auto-maintenance.log` | Maintenance run log |

---

## Troubleshooting

Force an immediate `/etc/hosts` and console banner refresh:
```bash
systemctl start pve-update-hosts-ip.service
journalctl -u pve-update-hosts-ip.service -n 30 --no-pager
```

Manually trigger the weekly maintenance run:
```bash
systemctl start pve-auto-maintenance.service
tail -f /var/log/pve-auto-maintenance.log
```

Something went wrong during setup? Run fix:
```bash
bash /root/ProxmoxRelocat.sh fix
```

Restore a backed-up APT source file:
```bash
ls /root/pve-apt-source-backups/
cp /root/pve-apt-source-backups/<file>.bak.<timestamp> /etc/apt/sources.list.d/<file>
```

---

## License

MIT
