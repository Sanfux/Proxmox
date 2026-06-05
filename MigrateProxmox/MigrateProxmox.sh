#!/usr/bin/env bash
# MigrateProxmox.sh
# -----------------------------------------------------------------------------
# Migrate all LXC containers and QEMU VMs from THIS Proxmox node to another
# Proxmox node, with automatic VMID-collision handling and bridge remapping.
#
# Run this script ON THE SOURCE node as root.
# -----------------------------------------------------------------------------
# RUN DIRECTLY FROM GITHUB (no local copy needed)
#
# The canonical copy lives at:
#   https://github.com/Sanfux/Proxmox/blob/main/MigrateProxmox.sh
# Raw URL used below:
#   https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox.sh
#
# Option A - pipe straight into bash (CLI flags after `--`):
#
#   curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox.sh \
#     | bash -s -- --target 10.94.32.127 --target-pass 'YOURPASS' \
#                  --regenerate-mac --test-boot
#
# Option B - process substitution, drive it with env vars instead of flags:
#
#   TARGET_HOST=10.94.32.127 \
#   TARGET_PASS='YOURPASS' \
#   REGEN_MAC=1 TEST_BOOT=1 \
#     bash <(curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox.sh)
#
# Option C - download once, inspect, then run (recommended for production):
#
#   curl -fsSL https://raw.githubusercontent.com/Sanfux/Proxmox/main/MigrateProxmox.sh \
#     -o /root/MigrateProxmox.sh
#   chmod +x /root/MigrateProxmox.sh
#   less /root/MigrateProxmox.sh           # review before running
#   /root/MigrateProxmox.sh --target 10.94.32.127 --target-pass 'YOURPASS'
#
# If you use --target-pass, install sshpass first:
#   apt-get update && apt-get install -y sshpass
# -----------------------------------------------------------------------------
# WORKFLOW PER GUEST
#   1. Shut it down on the source if it was running.
#   2. vzdump (zstd) into $DUMP_DIR.
#   3. scp to the target.
#   4. Restore on the target on the chosen storage.
#        - If the original VMID exists on the target, the script asks the
#          target for `pvesh get /cluster/nextid` and uses that, appending
#          a name suffix (default: -fromold). Existing target guests are
#          NEVER touched.
#   5. Remap every NIC `bridge=` on the restored config to $TARGET_BRIDGE.
#   6. Optionally regenerate each NIC MAC ( --regenerate-mac ) so the copy
#      can coexist on the LAN with the original.
#   7. Optionally boot-test the restored guest ( --test-boot ) and stop it.
#   8. Delete the backup file from both sides.
#   9. Restart the guest on the source if it was previously running.
#
# Idempotent: safe to re-run. Existing target guests are never modified.
# -----------------------------------------------------------------------------
# USAGE
#   ./MigrateProxmox.sh --target <ip|host> [options]
#
# Required:
#   --target HOST            Target Proxmox node (IP or DNS)
#
# Common options:
#   --storage NAME           Target storage (default: local-lvm)
#   --bridge NAME            Target bridge to remap all NICs to (default: vmbr0)
#   --suffix STR             Name suffix on VMID collision (default: -fromold)
#   --only-ids "100 200"     Space-separated VMIDs to limit migration
#   --skip-ct                Skip LXC containers
#   --skip-vm                Skip QEMU VMs
#   --regenerate-mac         Random LAA MAC on every NIC of the copy
#   --test-boot              Briefly start each restored guest, then stop it
#   --dump-dir DIR           Backup staging dir (default: /var/lib/vz/dump)
#   --target-user USER       SSH user on target (default: root)
#   --target-pass PASSWORD   Use sshpass with this password to do first SSH
#                            (script will then push a key for passwordless use)
#   --log FILE               Log file (default: ./migrate-proxmox-<ts>.log)
#   -h, --help               Show this help
#
# Examples:
#   ./MigrateProxmox.sh --target 10.0.0.20
#   ./MigrateProxmox.sh --target tgt.lan --regenerate-mac --test-boot
#   ./MigrateProxmox.sh --target 10.0.0.20 --only-ids "100 200" \
#                       --storage local-zfs --bridge vmbr1 --suffix ''
#
# Security:
#   - Prefer setting up SSH key auth to the target beforehand and omitting
#     --target-pass. If you pass a password, install `sshpass` first.
#   - After a successful migration consider rotating root passwords and
#     disabling password SSH (PermitRootLogin prohibit-password).
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------- defaults (also overridable via environment variables) -----------
TARGET_HOST="${TARGET_HOST:-}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PASS="${TARGET_PASS:-}"
TARGET_STORAGE="${TARGET_STORAGE:-local-lvm}"
TARGET_BRIDGE="${TARGET_BRIDGE:-vmbr0}"
NAME_SUFFIX="${NAME_SUFFIX:--fromold}"
DUMP_DIR="${DUMP_DIR:-/var/lib/vz/dump}"
ONLY_IDS="${ONLY_IDS:-}"
SKIP_CT="${SKIP_CT:-0}"
SKIP_VM="${SKIP_VM:-0}"
REGEN_MAC="${REGEN_MAC:-0}"
TEST_BOOT="${TEST_BOOT:-0}"
LOG_FILE="${LOG_FILE:-}"

usage() {
    cat <<'USAGE'
migrate-proxmox.sh - Copy all LXC/VM guests from THIS Proxmox node to another.

Usage:
  migrate-proxmox.sh --target <ip|host> [options]

Required:
  --target HOST            Target Proxmox node (IP or DNS)

Common options:
  --target-user USER       SSH user on target (default: root)
  --target-pass PASSWORD   sshpass password for first SSH (key is then pushed)
  --storage NAME           Target storage           (default: local-lvm)
  --bridge  NAME           Target bridge for NICs   (default: vmbr0)
  --suffix  STR            Name suffix on VMID collision (default: -fromold)
  --only-ids "100 200"     Limit migration to these VMIDs
  --skip-ct                Skip LXC containers
  --skip-vm                Skip QEMU VMs
  --regenerate-mac         Random locally-admin MAC on every NIC of the copy
  --test-boot              Briefly start each restored guest, then stop it
  --dump-dir DIR           Backup staging dir (default: /var/lib/vz/dump)
  --log FILE               Log file (default: ./migrate-proxmox-<ts>.log)
  -h, --help               Show this help

All options can also be set via environment variables of the same name
(uppercase, with underscores): TARGET_HOST, TARGET_PASS, TARGET_STORAGE,
TARGET_BRIDGE, NAME_SUFFIX, ONLY_IDS, SKIP_CT=1, SKIP_VM=1, REGEN_MAC=1,
TEST_BOOT=1, DUMP_DIR, LOG_FILE. This makes `curl ... | bash` usage easy:

  TARGET_HOST=10.0.0.20 TARGET_PASS='pw' REGEN_MAC=1 \
      bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/migrate-proxmox.sh)
USAGE
    exit "${1:-0}"
}

# ---------- arg parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)         TARGET_HOST="$2"; shift 2 ;;
        --target-user)    TARGET_USER="$2"; shift 2 ;;
        --target-pass)    TARGET_PASS="$2"; shift 2 ;;
        --storage)        TARGET_STORAGE="$2"; shift 2 ;;
        --bridge)         TARGET_BRIDGE="$2"; shift 2 ;;
        --suffix)         NAME_SUFFIX="$2"; shift 2 ;;
        --only-ids)       ONLY_IDS="$2"; shift 2 ;;
        --skip-ct)        SKIP_CT=1; shift ;;
        --skip-vm)        SKIP_VM=1; shift ;;
        --regenerate-mac) REGEN_MAC=1; shift ;;
        --test-boot)      TEST_BOOT=1; shift ;;
        --dump-dir)       DUMP_DIR="$2"; shift 2 ;;
        --log)            LOG_FILE="$2"; shift 2 ;;
        -h|--help)        usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$TARGET_HOST" ]] && { echo "ERROR: --target is required" >&2; usage 1; }
[[ $EUID -ne 0 ]]      && { echo "ERROR: run as root on the source Proxmox node" >&2; exit 1; }

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$(pwd)/migrate-proxmox-$(date +%Y%m%d-%H%M%S).log"
fi

# ---------- logging ----------------------------------------------------------
log() {
    local color="${2:-}"
    local msg
    msg="[$(date +%H:%M:%S)] $1"
    case "$color" in
        red)    printf '\e[31m%s\e[0m\n' "$msg" ;;
        green)  printf '\e[32m%s\e[0m\n' "$msg" ;;
        yellow) printf '\e[33m%s\e[0m\n' "$msg" ;;
        cyan)   printf '\e[36m%s\e[0m\n' "$msg" ;;
        *)      printf '%s\n' "$msg" ;;
    esac
    printf '%s\n' "$msg" >> "$LOG_FILE"
}
err() { log "$1" red; }

: > "$LOG_FILE"
log "=== Proxmox migration $(date -Iseconds) ===" cyan
log "source=$(hostname)  target=${TARGET_USER}@${TARGET_HOST}  storage=${TARGET_STORAGE}  bridge=${TARGET_BRIDGE}"

# ---------- SSH helpers ------------------------------------------------------
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
ssh_t() { ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_HOST}" "$@"; }
scp_t() { scp "${SSH_OPTS[@]}" "$1" "${TARGET_USER}@${TARGET_HOST}:$2"; }

# ---------- set up key-based SSH source->target ------------------------------
setup_ssh() {
    log "Setting up key-based SSH source -> target ..." cyan
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
    local pub; pub="$(cat /root/.ssh/id_ed25519.pub)"

    ssh-keyscan -H -t ed25519,rsa,ecdsa "$TARGET_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true
    sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts

    # Quick probe; if it already works, we're done.
    if ssh_t 'true' 2>/dev/null; then
        log "  Passwordless SSH already works."
        return 0
    fi

    if [[ -n "$TARGET_PASS" ]]; then
        command -v sshpass >/dev/null || { err "sshpass not installed; install it or set up key auth manually"; exit 1; }
        log "  Pushing public key via sshpass..."
        sshpass -p "$TARGET_PASS" ssh -o StrictHostKeyChecking=accept-new "${TARGET_USER}@${TARGET_HOST}" \
            "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
             grep -qxF '$pub' /root/.ssh/authorized_keys || echo '$pub' >> /root/.ssh/authorized_keys"
    else
        err "Cannot SSH to target without password. Either set up key auth manually, or rerun with --target-pass."
        exit 1
    fi

    ssh_t 'hostname && pveversion' >/dev/null || { err "Key auth still failing after push."; exit 1; }
    log "  OK."
}

setup_ssh

# ---------- inventory --------------------------------------------------------
filter_ids() {
    # Reads "vmid name status" lines on stdin, optionally filters to ONLY_IDS.
    if [[ -z "$ONLY_IDS" ]]; then cat; return; fi
    awk -v keep="$ONLY_IDS" 'BEGIN{n=split(keep,a," "); for(i=1;i<=n;i++) k[a[i]]=1} {if ($1 in k) print}'
}

list_cts() { pct list | awk 'NR>1 {print $1, $NF, $2}' | filter_ids; }
list_vms() { qm  list | awk 'NR>1 {print $1, $2,  $3}' | filter_ids; }

declare -A EXISTING
while read -r id _; do [[ -n "$id" ]] && EXISTING[$id]=1; done < <(ssh_t 'pct list' | awk 'NR>1 {print $1}')
while read -r id _; do [[ -n "$id" ]] && EXISTING[$id]=1; done < <(ssh_t 'qm  list' | awk 'NR>1 {print $1}')
log "Target existing IDs: ${!EXISTING[*]:-(none)}"

next_free_id() {
    local pref="$1"
    if [[ -z "${EXISTING[$pref]:-}" ]]; then EXISTING[$pref]=1; echo "$pref"; return; fi
    local n; n="$(ssh_t 'pvesh get /cluster/nextid' | tr -d '[:space:]')"
    while [[ -n "${EXISTING[$n]:-}" ]]; do n=$((n+1)); done
    EXISTING[$n]=1; echo "$n"
}

# ---------- helpers: bridge remap & MAC regen on target ----------------------
random_laa_mac() {
    # locally-administered, unicast
    printf '%02X:%02X:%02X:%02X:%02X:%02X\n' \
        $(( (RANDOM & 0xFC) | 0x02 )) \
        $((RANDOM & 0xFF)) $((RANDOM & 0xFF)) \
        $((RANDOM & 0xFF)) $((RANDOM & 0xFF)) $((RANDOM & 0xFF))
}

remap_net() {
    local conf="$1"
    ssh_t "sed -i -E 's/bridge=[^ ,]+/bridge=${TARGET_BRIDGE}/g' '$conf'"
    if (( REGEN_MAC )); then
        # For every netN line, either replace existing hwaddr= or insert one.
        local idxs
        idxs="$(ssh_t "grep -oE '^net[0-9]+' '$conf' | sed 's/net//'")"
        for i in $idxs; do
            local mac; mac="$(random_laa_mac)"
            ssh_t "awk -v mac='$mac' -v i='$i' '
                BEGIN{FS=OFS=\"\"}
                \$0 ~ \"^net\" i \":\" {
                    if (index(\$0,\"hwaddr=\")) { sub(/hwaddr=[^,]+/, \"hwaddr=\" mac) }
                    else { sub(\"^net\" i \":[[:space:]]*\", \"net\" i \": hwaddr=\" mac \",\") }
                }
                {print}
            ' '$conf' > '${conf}.new' && mv '${conf}.new' '$conf'"
        done
    fi
}

# ---------- per-guest migration ---------------------------------------------
declare -a SUMMARY
migrate_guest() {
    local kind="$1" vmid="$2" name="$3"   # kind = ct | vm
    log "" 
    log "=== Migrating ${kind^^} $vmid [$name] ===" green

    local status_cmd shutdown_cmd start_cmd dump_prefix dump_ext conf_path restore_cmd
    if [[ "$kind" == "ct" ]]; then
        status_cmd="pct status $vmid"; shutdown_cmd="pct shutdown $vmid --forceStop 1 --timeout 120"
        start_cmd="pct start $vmid";   dump_prefix="vzdump-lxc"; dump_ext="tar.zst"
    else
        status_cmd="qm status $vmid";  shutdown_cmd="qm shutdown $vmid --forceStop 1 --timeout 180"
        start_cmd="qm start $vmid";    dump_prefix="vzdump-qemu"; dump_ext="vma.zst"
    fi

    local was_running=0
    if $status_cmd 2>/dev/null | grep -q running; then
        was_running=1
        log "  shutting down on source"
        $shutdown_cmd >/dev/null 2>&1 || true
    fi

    local target_id renamed=0 target_name="$name"
    target_id="$(next_free_id "$vmid")"
    if [[ "$target_id" != "$vmid" && -n "$NAME_SUFFIX" ]]; then
        renamed=1
        target_name="${name}${NAME_SUFFIX}"
        log "  collision -> new VMID $target_id (name $target_name)" yellow
    else
        log "  no collision -> keeping VMID $target_id"
    fi

    mkdir -p "$DUMP_DIR"
    rm -f "$DUMP_DIR/${dump_prefix}-${vmid}-"*.${dump_ext} 2>/dev/null || true
    log "  dumping on source ..."
    if ! vzdump "$vmid" --mode stop --compress zstd --dumpdir "$DUMP_DIR" >>"$LOG_FILE" 2>&1; then
        err "  vzdump failed"; return 1
    fi
    local produced; produced="$(ls -1t "$DUMP_DIR"/${dump_prefix}-${vmid}-*.${dump_ext} 2>/dev/null | head -1)"
    [[ -z "$produced" ]] && { err "  no backup file produced"; return 1; }
    log "  produced: $produced"

    local remote="$DUMP_DIR/$(basename "$produced")"
    log "  scp -> target"
    ssh_t "mkdir -p '$DUMP_DIR'"
    if ! scp_t "$produced" "$remote" >>"$LOG_FILE" 2>&1; then
        err "  scp failed"; return 1
    fi

    log "  restoring on target as ID $target_id (storage=$TARGET_STORAGE)"
    if [[ "$kind" == "ct" ]]; then
        if ! ssh_t "pct restore $target_id '$remote' --storage '$TARGET_STORAGE' --hostname '$target_name'" >>"$LOG_FILE" 2>&1; then
            err "  pct restore failed"; ssh_t "rm -f '$remote'"; rm -f "$produced"; return 1
        fi
        conf_path="/etc/pve/lxc/$target_id.conf"
    else
        if ! ssh_t "qmrestore '$remote' $target_id --storage '$TARGET_STORAGE'" >>"$LOG_FILE" 2>&1; then
            err "  qmrestore failed"; ssh_t "rm -f '$remote'"; rm -f "$produced"; return 1
        fi
        (( renamed )) && ssh_t "qm set $target_id --name '$target_name'" >>"$LOG_FILE" 2>&1 || true
        conf_path="/etc/pve/qemu-server/$target_id.conf"
    fi

    remap_net "$conf_path"

    if (( TEST_BOOT )); then
        log "  test-boot ..."
        if [[ "$kind" == "ct" ]]; then
            ssh_t "pct start $target_id" >>"$LOG_FILE" 2>&1 && sleep 8 && \
                ssh_t "pct status $target_id" | tee -a "$LOG_FILE" >/dev/null
            ssh_t "pct shutdown $target_id --forceStop 1 --timeout 60" >>"$LOG_FILE" 2>&1 || true
        else
            ssh_t "qm start $target_id"  >>"$LOG_FILE" 2>&1 && sleep 15 && \
                ssh_t "qm status $target_id"  | tee -a "$LOG_FILE" >/dev/null
            ssh_t "qm shutdown $target_id --forceStop 1 --timeout 180" >>"$LOG_FILE" 2>&1 || true
        fi
    fi

    rm -f "$produced"
    ssh_t "rm -f '$remote'"

    if (( was_running )); then
        log "  restarting on source (was running before)"
        $start_cmd >/dev/null 2>&1 || true
    fi

    SUMMARY+=("${kind^^} $vmid -> $target_id  $target_name")
    log "  DONE: $vmid -> $target_id" green
}

# ---------- main loop --------------------------------------------------------
if (( ! SKIP_CT )); then
    while read -r id name _; do
        [[ -z "$id" ]] && continue
        migrate_guest ct "$id" "$name" || err "CT $id failed; continuing"
    done < <(list_cts)
fi

if (( ! SKIP_VM )); then
    while read -r id name _; do
        [[ -z "$id" ]] && continue
        migrate_guest vm "$id" "$name" || err "VM $id failed; continuing"
    done < <(list_vms)
fi

# ---------- summary ----------------------------------------------------------
log "" cyan
log "=== SUMMARY ===" cyan
for line in "${SUMMARY[@]:-}"; do log "  $line"; done

log "Target final pct list:" cyan
ssh_t 'pct list' | tee -a "$LOG_FILE"
log "Target final qm list:" cyan
ssh_t 'qm list'  | tee -a "$LOG_FILE"

log "Log saved to $LOG_FILE" cyan
