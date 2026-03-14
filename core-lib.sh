#!/usr/bin/env bash
# core-lib.sh — shared functions for backup-to-usb.sh and restore-from-usb.sh
# This file is sourced, not executed directly.

LUKS_LABEL="PEACEFUL_BACKUP"
MOUNT_POINT="/mnt/peaceful_backup"
MAPPER_NAME="peaceful_backup"
CONF_FILE="$SCRIPT_DIR/backup.conf"
IGNORE_FILE="$SCRIPT_DIR/.backupignore"

# ─── Config parser ──────────────────────────────────────────────
# Reads backup.conf and populates three parallel arrays:
#   CONF_SOURCES[]   — source paths (relative to $HOME)
#   CONF_CATEGORIES[] — category names (subfolder on drive)
#   CONF_RESTORES[]  — restore paths (relative to $HOME)

load_config() {
    CONF_SOURCES=()
    CONF_CATEGORIES=()
    CONF_RESTORES=()

    if [[ ! -f "$CONF_FILE" ]]; then
        echo "Error: config file not found: $CONF_FILE"
        exit 1
    fi

    while IFS= read -r line; do
        # Strip comments and blank lines
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue

        # Parse "source : category : restore"
        IFS=':' read -r src cat rst <<< "$line"
        src=$(echo "$src" | xargs)    # trim whitespace
        cat=$(echo "$cat" | xargs)
        rst=$(echo "$rst" | xargs)

        if [[ -z "$src" || -z "$cat" || -z "$rst" ]]; then
            echo "Warning: skipping malformed line in backup.conf: $line"
            continue
        fi

        CONF_SOURCES+=("$src")
        CONF_CATEGORIES+=("$cat")
        CONF_RESTORES+=("$rst")
    done < "$CONF_FILE"

    if [[ ${#CONF_SOURCES[@]} -eq 0 ]]; then
        echo "Error: no backup items found in $CONF_FILE"
        exit 1
    fi
}

# ─── Machine ID ─────────────────────────────────────────────────
# Produces a stable, human-readable identifier like "thinkpad-0036232"
# by combining the hostname with a MAC-derived suffix to avoid collisions.

machine_id() {
    local hostname mac_hex mac_dec suffix

    hostname="$(hostname)"

    # Grab the MAC of the first non-loopback interface
    mac_hex=""
    for iface in /sys/class/net/*; do
        [[ "$(basename "$iface")" == "lo" ]] && continue
        if [[ -f "$iface/address" ]]; then
            mac_hex=$(cat "$iface/address" | tr -d ':')
            break
        fi
    done

    if [[ -n "$mac_hex" ]]; then
        # Convert hex MAC to decimal, mod 1048576 (2^20), zero-pad to 7 digits
        mac_dec=$(( 16#${mac_hex} % 1048576 ))
        suffix=$(printf '%07d' "$mac_dec")
        echo "${hostname}-${suffix}"
    else
        # No MAC found; fall back to hostname alone
        echo "$hostname"
    fi
}

# ─── LUKS helpers ────────────────────────────────────────────────

find_luks_partition() {
    # First check: is the mapper already open? If so, find its backing device.
    if [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
        local backing
        backing=$(cryptsetup status "$MAPPER_NAME" 2>/dev/null | awk '/device:/{print $2}')
        if [[ -n "$backing" ]]; then
            echo "$backing"
            return 0
        fi
    fi

    # Scan partitions for LUKS — more reliable than label lookup,
    # since the label may resolve to the wrong partition when LUKS is already open.
    while IFS= read -r dev; do
        if cryptsetup isLuks "$dev" 2>/dev/null; then
            echo "$dev"
            return 0
        fi
    done < <(lsblk -lnp -o NAME,TYPE | awk '$2=="part"{print $1}')

    return 1
}

open_and_mount() {
    local part="$1"

    # Track whether we opened/mounted, so cleanup only undoes what we did
    _WE_OPENED=false
    _WE_MOUNTED=false

    # Check if this partition is already mapped (possibly under a different name)
    local existing_mapper=""
    existing_mapper=$(lsblk -lnp -o NAME,TYPE "$part" 2>/dev/null | awk '$2=="crypt"{print $1}' | head -1)

    if [[ -n "$existing_mapper" ]]; then
        echo "LUKS device already open as $(basename "$existing_mapper")."
        ACTIVE_MAPPER="$existing_mapper"
    elif [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
        echo "LUKS device already open."
        ACTIVE_MAPPER="/dev/mapper/$MAPPER_NAME"
    else
        echo "Opening encrypted drive (enter passphrase)..."
        cryptsetup luksOpen "$part" "$MAPPER_NAME"
        ACTIVE_MAPPER="/dev/mapper/$MAPPER_NAME"
        _WE_OPENED=true
    fi

    # Check if it's already mounted somewhere
    local existing_mount=""
    existing_mount=$(lsblk -ln -o MOUNTPOINT "$ACTIVE_MAPPER" 2>/dev/null | head -1)

    if [[ -n "$existing_mount" ]]; then
        MOUNT_POINT="$existing_mount"
        echo "Already mounted at $MOUNT_POINT"
    elif mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo "Already mounted at $MOUNT_POINT"
    else
        mkdir -p "$MOUNT_POINT"
        mount "$ACTIVE_MAPPER" "$MOUNT_POINT"
        echo "Mounted at $MOUNT_POINT"
        _WE_MOUNTED=true
    fi
    echo ""
}

cleanup_mount() {
    echo ""
    echo "Cleaning up..."
    # Only undo what we did
    if $_WE_MOUNTED && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if $_WE_OPENED && [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
        cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null || true
    fi
    echo "Drive safely closed."
}

_WE_OPENED=false
_WE_MOUNTED=false
ACTIVE_MAPPER=""

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Needs root for mount/cryptsetup. Re-running with sudo..."
        exec sudo --preserve-env=BACKUP_HOST bash "$0" "$@"
    fi
}
