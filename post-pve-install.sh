#!/usr/bin/env bash

# ============================================================
#  CUSTOM FORK of community-scripts/ProxmoxVE post-pve-install
#  Upstream: https://github.com/community-scripts/ProxmoxVE
#
#  Pre-configured settings (auto-applied, no prompt):
#    ✓ Disable pve-enterprise repo
#    ✓ Enable pve-no-subscription repo
#    ✓ Correct Ceph package sources
#    ✓ Disable subscription nag
#    ✓ Disable High Availability
#    ✓ Run apt update/dist-upgrade
#
#  Settings still prompted (not forced):
#    - Correct PVE Sources (your choice at runtime)
#    - Reboot at the end
#
#  Maintained via GitHub Actions — auto-syncs with upstream.
# ============================================================

# Copyright (c) 2021-2026 tteck
# Author: tteckster | MickLesk (CanbiZ)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

header_info() {
  clear
  cat <<"EOF"
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/

                    [ CUSTOM FORK - Auto-configured ]
EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# Telemetry (upstream compat)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "post-pve-install" "pve"

get_pve_version() {
  local pve_ver
  pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  echo "$pve_ver"
}

get_pve_major_minor() {
  local ver="$1"
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  echo "$major $minor"
}

component_exists_in_sources() {
  local component="$1"
  grep -h -E "^[^#]*Components:[^#]*\b${component}\b" /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -q .
}

# ── AUTO FUNCTIONS (no prompts) ──────────────────────────────

auto_disable_enterprise_repo_8() {
  msg_info "Disabling 'pve-enterprise' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
  msg_ok "Disabled 'pve-enterprise' repository"
}

auto_enable_no_subscription_repo_8() {
  msg_info "Enabling 'pve-no-subscription' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-install-repo.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
  msg_ok "Enabled 'pve-no-subscription' repository"
}

auto_correct_ceph_8() {
  msg_info "Correcting 'ceph package repositories'"
  cat <<EOF >/etc/apt/sources.list.d/ceph.list
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
  msg_ok "Corrected 'ceph package repositories'"
}

auto_disable_enterprise_repo_9() {
  msg_info "Disabling 'pve-enterprise' repository (deb822)"
  for file in /etc/apt/sources.list.d/*.sources; do
    if grep -q "Components:.*pve-enterprise" "$file" 2>/dev/null; then
      if grep -q "^Enabled:" "$file"; then
        sed -i 's/^Enabled:.*/Enabled: false/' "$file"
      else
        echo "Enabled: false" >>"$file"
      fi
    fi
  done
  msg_ok "Disabled 'pve-enterprise' repository"
}

auto_enable_no_subscription_repo_9() {
  msg_info "Adding 'pve-no-subscription' repository (deb822)"
  cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  msg_ok "Added 'pve-no-subscription' repository"
}

auto_correct_ceph_9() {
  msg_info "Adding 'ceph package repositories' (deb822)"
  cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  msg_ok "Added 'ceph package repositories'"
}

auto_disable_subscription_nag() {
  msg_info "Disabling subscription nag"
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) { dialog.remove(); }" \
      "    });" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) { card.remove(); }" \
      "    });" \
      "  }" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF
  chmod 755 /usr/local/bin/pve-remove-nag.sh
  cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
  chmod 644 /etc/apt/apt.conf.d/no-nag-script
  msg_ok "Disabled subscription nag (clear browser cache after reboot)"
}

auto_disable_high_availability() {
  if systemctl is-active --quiet pve-ha-lrm; then
    msg_info "Disabling high availability"
    systemctl disable -q --now pve-ha-lrm
    systemctl disable -q --now pve-ha-crm
    systemctl disable -q --now corosync 2>/dev/null || true
    msg_ok "Disabled high availability + Corosync"
  else
    msg_ok "High availability already inactive — skipped"
  fi
}

auto_update() {
  msg_info "Updating Proxmox VE (this may take a while)"
  apt update &>/dev/null || msg_error "apt update failed"
  apt -y dist-upgrade &>/dev/null || msg_error "apt dist-upgrade failed"
  msg_ok "Updated Proxmox VE"
}

# ── MAIN ─────────────────────────────────────────────────────

main() {
  header_info
  echo -e "\nThis script will perform Post Install Routines with your pre-configured settings.\n"
  echo -e "${YW}Auto-applying:${CL} enterprise repo disable, no-subscription repo, ceph sources,"
  echo -e "               subscription nag removal, HA disable, system update.\n"

  while true; do
    read -p "Start the Proxmox VE Post Install Script (y/n)? " yn
    case $yn in
    [Yy]*) break ;;
    [Nn]*) clear; exit ;;
    *) echo "Please answer yes or no." ;;
    esac
  done

  local PVE_VERSION PVE_MAJOR PVE_MINOR
  PVE_VERSION="$(get_pve_version)"
  read -r PVE_MAJOR PVE_MINOR <<<"$(get_pve_major_minor "$PVE_VERSION")"

  echo -e "\n${GN}Detected Proxmox VE ${PVE_VERSION} (major: ${PVE_MAJOR})${CL}\n"

  case "$PVE_MAJOR" in
  8) start_routines_8 ;;
  9) start_routines_9 ;;
  *)
    # Future-proof: fall through to common routines and warn
    echo -e "${YW}Warning: Proxmox VE major version ${PVE_MAJOR} is newer than this script was"
    echo -e "last tested against. Applying common routines only. Check for script updates.${CL}\n"
    post_routines_common
    ;;
  esac
}

# ── PVE 8 ────────────────────────────────────────────────────

start_routines_8() {
  header_info

  # Sources — still prompted (user chose not to pre-set this one)
  CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "SOURCES" --menu \
    "Correct Proxmox VE Sources?" 14 58 2 \
    "yes" " " "no" " " 3>&2 2>&1 1>&3)
  case $CHOICE in
  yes)
    msg_info "Correcting Proxmox VE Sources"
    cat <<EOF >/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
    msg_ok "Corrected Proxmox VE Sources"
    ;;
  no) msg_error "Selected no to Correcting Proxmox VE Sources" ;;
  esac

  # Auto-configured
  auto_disable_enterprise_repo_8
  auto_enable_no_subscription_repo_8
  auto_correct_ceph_8

  # pvetest — skip (not in user's pre-set list, not critical)
  msg_ok "Skipping 'pvetest' repository (not configured)"

  post_routines_common
}

# ── PVE 9 ────────────────────────────────────────────────────

start_routines_9() {
  header_info

  # Sources — still prompted
  if find /etc/apt/sources.list.d/ -maxdepth 1 -name '*.sources' | grep -q .; then
    echo -e "${GN}Modern deb822 sources already exist — skipping source migration.${CL}\n"
  else
    CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "SOURCES" --menu \
      "Migrate to deb822 sources format?" 14 58 2 \
      "yes" " " "no" " " 3>&2 2>&1 1>&3)
    case $CHOICE in
    yes)
      msg_info "Correcting Proxmox VE Sources (deb822)"
      rm -f /etc/apt/sources.list.d/*.list
      sed -i '/proxmox/d;/bookworm/d' /etc/apt/sources.list || true
      cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      msg_ok "Corrected Proxmox VE 9 (Trixie) Sources"
      ;;
    no) msg_error "Selected no to Correcting Proxmox VE Sources" ;;
    esac
  fi

  # Auto-configured
  auto_disable_enterprise_repo_9

  if ! component_exists_in_sources "pve-no-subscription"; then
    auto_enable_no_subscription_repo_9
  else
    msg_ok "'pve-no-subscription' repository already exists — skipped"
  fi

  if ! component_exists_in_sources "no-subscription"; then
    auto_correct_ceph_9
  else
    msg_ok "'ceph' repository already exists — skipped"
  fi

  post_routines_common
}

# ── COMMON ───────────────────────────────────────────────────

post_routines_common() {
  # All of these are pre-configured to YES
  auto_disable_subscription_nag

  apt --reinstall install proxmox-widget-toolkit &>/dev/null || msg_error "Widget toolkit reinstall failed"

  auto_disable_high_availability

  auto_update

  # Reinstall nag patch after update (update may overwrite it)
  /usr/local/bin/pve-remove-nag.sh 2>/dev/null || true

  echo -e "\n${YW}IMPORTANT:${CL} If you have multiple PVE hosts in a cluster, run this on every node."
  echo -e "${YW}IMPORTANT:${CL} Clear your browser cache (Ctrl+Shift+R) before using the Web UI.\n"

  CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "REBOOT" --menu \
    "\nReboot Proxmox VE now? (recommended)" 11 58 2 \
    "yes" " " "no" " " 3>&2 2>&1 1>&3)
  case $CHOICE in
  yes)
    msg_info "Rebooting Proxmox VE"
    sleep 2
    msg_ok "Completed Post Install Routines"
    reboot
    ;;
  no)
    msg_error "Selected no to Rebooting Proxmox VE (Reboot recommended)"
    msg_ok "Completed Post Install Routines"
    ;;
  esac
}

main
