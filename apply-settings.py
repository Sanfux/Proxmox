curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh -o upstream-latest.sh
python3 apply-settings.py upstream-latest.sh post-pve-install.sh
bash -n post-pve-install.sh && echo "Syntax OK"