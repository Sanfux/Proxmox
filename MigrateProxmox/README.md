# MigrateProxmox.sh

A Bash script to migrate all LXC containers and QEMU VMs from one Proxmox node to another, with automatic VMID collision handling and bridge remapping.

Run this script **on the source node** as `root`.

---

## Features

- Migrates all LXC containers and/or QEMU VMs in one shot
- Handles VMID collisions automatically — existing guests on the target are **never modified**
- Remaps NIC bridges to the target bridge
- Optionally regenerates MAC addresses to avoid LAN conflicts
- Optional boot-test of each restored guest
- Idempotent — safe to re-run
- Full log output to file

---

## Requirements

- Proxmox VE on both source and target nodes
- `root` access on the source node
- SSH access to the target node (key-based preferred)
- `sshpass` — only if using `--target-pass` for first-time authentication:
  ```bash
  apt-get update && apt-get install -y sshpass
  ```

---

## Quick Start

With flags:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh)" \
  -- --target 10.0.0.20 --target-pass 'YOURPASS'
```

Or use environment variables:
```bash
TARGET_HOST=10.0.0.20 TARGET_PASS='YOURPASS' \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh)"
```

To inspect before running (recommended for production):
```bash
curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh \
  -o /root/MigrateProxmox.sh
less /root/MigrateProxmox.sh
bash /root/MigrateProxmox.sh --target 10.0.0.20 --target-pass 'YOURPASS'
```

---

## Usage

```
./MigrateProxmox.sh --target <ip|host> [options]
```

### Required

| Flag | Description |
|------|-------------|
| `--target HOST` | Target Proxmox node (IP or DNS) |

### Options

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--target-user USER` | `TARGET_USER` | `root` | SSH user on target |
| `--target-pass PASS` | `TARGET_PASS` | — | Password for first SSH (key is then pushed) |
| `--storage NAME` | `TARGET_STORAGE` | `local-lvm` | Storage on target |
| `--bridge NAME` | `TARGET_BRIDGE` | `vmbr0` | Bridge to remap all NICs to |
| `--suffix STR` | `NAME_SUFFIX` | `-fromold` | Name suffix on VMID collision |
| `--only-ids "100 200"` | `ONLY_IDS` | — | Limit migration to specific VMIDs |
| `--skip-ct` | `SKIP_CT=1` | — | Skip LXC containers |
| `--skip-vm` | `SKIP_VM=1` | — | Skip QEMU VMs |
| `--regenerate-mac` | `REGEN_MAC=1` | — | Assign new random MAC to each NIC |
| `--test-boot` | `TEST_BOOT=1` | — | Start each restored guest briefly, then stop it |
| `--dump-dir DIR` | `DUMP_DIR` | `/var/lib/vz/dump` | Staging directory for backups |
| `--log FILE` | `LOG_FILE` | `./migrate-proxmox-<timestamp>.log` | Log file path |

---

## Examples

Migrate everything to a target node:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh)" \
  -- --target 10.0.0.20
```

Migrate with MAC regeneration and boot test:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh)" \
  -- --target 10.0.0.20 --regenerate-mac --test-boot
```

Migrate only specific VMIDs to a ZFS storage pool on a different bridge:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox/MigrateProxmox.sh)" \
  -- --target 10.0.0.20 --only-ids "100 200" --storage local-zfs --bridge vmbr1 --suffix ''
```

---

## How It Works

For each guest, the script:

1. Shuts it down on the source (if running)
2. Creates a `vzdump` (zstd compressed) backup into `$DUMP_DIR`
3. Transfers the backup to the target via `scp`
4. Restores it on the target storage
   - If the VMID already exists on the target, the next available ID is used and a name suffix is appended
5. Remaps all NIC `bridge=` entries to `$TARGET_BRIDGE`
6. Optionally regenerates MAC addresses (`--regenerate-mac`)
7. Optionally boot-tests the restored guest (`--test-boot`)
8. Cleans up backup files from both sides
9. Restarts the guest on the source if it was running before

---

## Security Notes

- **Prefer SSH key auth** — set up key-based SSH to the target before running and omit `--target-pass`. The script will push an SSH key on first run if a password is provided.
- If using `--target-pass`, the password is only used once to push the public key; subsequent operations use key auth.
- After migration, consider rotating root passwords and disabling password-based SSH (`PermitRootLogin prohibit-password`).

---

## License

MIT
