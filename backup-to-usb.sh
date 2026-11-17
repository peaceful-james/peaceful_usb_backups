#!/usr/bin/env bash
set -euo pipefail

# backup-to-usb.sh
# Syncs your important files to a LUKS-encrypted USB drive,
# stored under a per-machine directory.
#
# Usage: ./backup-to-usb.sh [--dry-run]
#
# Override the machine name:  BACKUP_HOST=mybox ./backup-to-usb.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/core-lib.sh"

# ─── Load configuration ─────────────────────────────────────────

load_config

# ─── Options ────────────────────────────────────────────────────

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo "*** DRY RUN — no files will be changed ***"
    echo ""
fi

ensure_root "$@"

# When running under sudo, HOME may be /root — always resolve from SUDO_USER
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(eval echo "~$SUDO_USER")
else
    REAL_HOME="$HOME"
fi
HOST_ID="${BACKUP_HOST:-$(machine_id)}"

trap cleanup_mount EXIT

# ─── Find and mount ─────────────────────────────────────────────

echo "Looking for LUKS device labeled '$LUKS_LABEL'..."

LUKS_PART=$(find_luks_partition) || {
    echo "Error: No LUKS device found. Is the USB drive plugged in?"
    echo ""
    echo "Available devices:"
    list_devices
    exit 1
}

echo "Using: $LUKS_PART"
open_and_mount "$LUKS_PART"

# ─── Sync files ─────────────────────────────────────────────────
# Anything that touches the drive goes through on_drive / drive_path
# (see core-lib.sh), so the same code works when the drive is in a VM.

MACHINE_DIR="$MOUNT_POINT/$HOST_ID"
on_drive mkdir -p "$MACHINE_DIR"

echo "Machine:  $HOST_ID"
echo "Backing up to: $HOST_ID/"
echo ""

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SYNCED=0
SKIPPED=0

# Build rsync exclude argument if ignore file exists
EXCLUDE_ARG=""
if [[ -f "$IGNORE_FILE" ]]; then
    EXCLUDE_ARG="--exclude-from=$IGNORE_FILE"
fi

for i in "${!CONF_SOURCES[@]}"; do
    SRC_REL="${CONF_SOURCES[$i]}"
    DEST_SUB="${CONF_CATEGORIES[$i]}"
    SRC_PATH="$REAL_HOME/$SRC_REL"

    if [[ ! -e "$SRC_PATH" ]]; then
        ((SKIPPED++)) || true
        continue
    fi

    DEST_PATH="$MACHINE_DIR/$DEST_SUB/"
    on_drive mkdir -p "$DEST_PATH"

    echo "  $SRC_REL → $HOST_ID/$DEST_SUB/"

    if [[ -d "$SRC_PATH" ]]; then
        "${RSYNC[@]}" --delete ${EXCLUDE_ARG:+"$EXCLUDE_ARG"} $DRY_RUN \
            "$SRC_PATH/" "$(drive_path "$DEST_PATH/$(basename "$SRC_PATH")/")"
    else
        "${RSYNC[@]}" $DRY_RUN "$SRC_PATH" "$(drive_path "$DEST_PATH")"
    fi

    ((SYNCED++)) || true
done

# Write a per-machine manifest (built where the drive is mounted)
if [[ -z "$DRY_RUN" ]]; then
    on_drive bash -c '
        set -eo pipefail
        cd "$1"
        {
            echo "Last backup: $2"
            echo "Machine:     $3"
            echo "User:        $4"
            echo ""
            echo "Contents:"
            find . -not -path "*/lost+found/*" -not -name MANIFEST.txt -type f \
                | sed "s|^\./||" | sort
        } > MANIFEST.txt
    ' bash "$MACHINE_DIR" "$TIMESTAMP" "$HOST_ID" "${SUDO_USER:-$USER}"
fi

echo ""
echo "────────────────────────────────"
echo "  Machine: $HOST_ID"
echo "  Synced:  $SYNCED items"
echo "  Skipped: $SKIPPED (not found)"

if [[ -z "$DRY_RUN" ]]; then
    USED=$(on_drive df -h "$MOUNT_POINT" | awk 'NR==2{print $3}')
    AVAIL=$(on_drive df -h "$MOUNT_POINT" | awk 'NR==2{print $4}')
    echo "  Used:    $USED"
    echo "  Free:    $AVAIL"

    # Show all machines on this drive
    echo ""
    echo "  All machines on this drive:"
    load_machines
    print_machines "$HOST_ID"
fi

echo "────────────────────────────────"
echo ""
echo "Backup complete. Drive will be unmounted on exit."
