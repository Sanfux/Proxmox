# Proxmox VE Post-Install (Custom Fork)

A personal fork of the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) post-install script with my preferred settings pre-applied — no interactive prompts for those choices.

## What's pre-configured (runs automatically)

| Setting | Value |
|---|---|
| Disable `pve-enterprise` repo | ✅ Yes |
| Enable `pve-no-subscription` repo | ✅ Yes |
| Correct Ceph package sources | ✅ Yes |
| Disable subscription nag | ✅ Yes |
| Disable High Availability + Corosync | ✅ Yes |
| Run `apt update` / `dist-upgrade` | ✅ Yes |

## What's still prompted at runtime

- **Correct PVE sources** (`sources.list` / deb822 migration) — answered manually
- **Reboot** at the end — answered manually

## How to use

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/post-pve-install/post-pve-install.sh)"
```

> Replace `YOUR_USERNAME/YOUR_REPO` with your actual GitHub username and repository name.

Works on **PVE 8.x**, **PVE 9.x**, and will fall back gracefully on newer major versions.

---

## How auto-sync works

A [GitHub Actions workflow](.github/workflows/sync-upstream.yml) runs **daily at 06:00 UTC**:

1. Downloads the latest upstream script
2. Compares its SHA-256 hash to the previously stored one
3. If it changed → runs `apply-settings.py` to re-apply your custom settings on top
4. Validates the output with `bash -n` (syntax check)
5. Commits and pushes the updated script automatically

You can also trigger it manually from the **Actions** tab in GitHub.

---

## Repo structure

```
.
├── post-pve-install.sh       ← Your ready-to-use custom script
├── apply-settings.py         ← Patch engine (re-applies settings after upstream changes)
├── upstream-reference.sh     ← Latest upstream snapshot (for diffing)
├── .upstream-hash            ← SHA-256 of last-seen upstream (change detector)
└── .github/
    └── workflows/
        └── sync-upstream.yml ← Daily sync automation
```

---

## Customising further

Edit `apply-settings.py` — each entry in the `PATCHES` list controls one behaviour.  
To change a setting from "auto-yes" back to "prompted", remove or comment out its entry.

After editing, test locally:
```bash
curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh -o upstream-latest.sh
python3 apply-settings.py upstream-latest.sh post-pve-install.sh
bash -n post-pve-install.sh && echo "Syntax OK"
```

---

## Credits

Original script by [tteck / MickLesk (CanbiZ)](https://github.com/community-scripts/ProxmoxVE) — MIT License.
