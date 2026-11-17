#!/usr/bin/env bash
set -euo pipefail

# restore-from-usb.sh
# Restores backed-up files from a LUKS-encrypted USB drive.
#
# Usage:
#   ./restore-from-usb.sh                     # interactive: pick machine and what to restore
#   ./restore-from-usb.sh --list              # just list available machines
#   ./restore-from-usb.sh --from <machine>    # restore everything from a specific machine
#   ./restore-from-usb.sh --dry-run [...]     # preview only, no changes
#
# Files are restored to $HOME. Existing files are backed up to
# $HOME/.restore-backup-<timestamp>/ before being overwritten.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/core-lib.sh"

# ─── Parse arguments ────────────────────────────────────────────

DRY_RUN=""
LIST_ONLY=false
FROM_MACHINE=""

# Parsed inside a function so the script's own "$@" stays intact:
# ensure_root re-runs the script under sudo and must pass the same options on.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN="--dry-run"; shift ;;
            --list)     LIST_ONLY=true; shift ;;
            --from)     FROM_MACHINE="$2"; shift 2 ;;
            *)          echo "Unknown option: $1"; exit 1 ;;
        esac
    done
}
parse_args "$@"

ensure_root "$@"

if [[ -n "$DRY_RUN" ]]; then
    echo "*** DRY RUN — no files will be changed ***"
    echo ""
fi

if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(eval echo "~$SUDO_USER")
else
    REAL_HOME="$HOME"
fi
REAL_USER="${SUDO_USER:-$USER}"

# Hand restored files back to the real user. Only needed when running as
# root (Linux). On macOS the script runs as you, so the files are already
# yours, and there is no group named after the user to chown to.
restore_owner() {
    if [[ $EUID -eq 0 ]]; then
        chown -R "$REAL_USER:$REAL_USER" "$1"
    fi
}

load_config

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

# ─── Discover available machines ────────────────────────────────
# Anything that touches the drive goes through on_drive / drive_path
# (see core-lib.sh), so the same code works when the drive is in a VM.

load_machines

if [[ ${#MACHINES[@]} -eq 0 ]]; then
    echo "No machine backups found on this drive."
    exit 0
fi

THIS_MACHINE="$(machine_id)"

echo "Available machine backups:"
echo ""
print_machines "$THIS_MACHINE" numbered
echo ""

if $LIST_ONLY; then
    exit 0
fi

# ─── Select machine ─────────────────────────────────────────────

SELECTED=""

if [[ -n "$FROM_MACHINE" ]]; then
    # Validate the --from argument
    for m in "${MACHINES[@]}"; do
        if [[ "$m" == "$FROM_MACHINE" ]]; then
            SELECTED="$FROM_MACHINE"
            break
        fi
    done
    if [[ -z "$SELECTED" ]]; then
        echo "Error: No backup found for '$FROM_MACHINE'."
        exit 1
    fi
else
    # Interactive selection
    while true; do
        read -p "Restore from which machine? (1-${#MACHINES[@]}, or 'q' to quit): " CHOICE
        if [[ "$CHOICE" == "q" ]]; then
            echo "Aborted."
            exit 0
        fi
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#MACHINES[@]} )); then
            SELECTED="${MACHINES[$((CHOICE-1))]}"
            break
        fi
        echo "Invalid choice."
    done
fi

SOURCE_DIR="$MOUNT_POINT/$SELECTED"

echo ""
echo "Restoring from: $SELECTED"
echo ""

# ─── Show what's available and let user pick ─────────────────────

# Discover the backup categories (top-level subdirectories)
CATEGORIES=()
CAT_NAMES=$(drive_subdirs "$SOURCE_DIR")
while IFS= read -r name; do
    if [[ -n "$name" ]]; then CATEGORIES+=("$name"); fi
done <<< "$CAT_NAMES"

if [[ ${#CATEGORIES[@]} -eq 0 ]]; then
    echo "No backup data found in $SELECTED."
    exit 0
fi

echo "Available categories:"
for i in "${!CATEGORIES[@]}"; do
    cat="${CATEGORIES[$i]}"
    count=$(on_drive find "$SOURCE_DIR/$cat" -type f | wc -l | tr -d ' ')
    echo "  $((i+1))) $cat ($count files)"
done
echo "  a) all"
echo ""

RESTORE_CATS=()

read -p "Restore which? (e.g. '1,3' or 'a' for all, 'q' to quit): " CAT_CHOICE

if [[ "$CAT_CHOICE" == "q" ]]; then
    echo "Aborted."
    exit 0
elif [[ "$CAT_CHOICE" == "a" ]]; then
    RESTORE_CATS=("${CATEGORIES[@]}")
else
    IFS=',' read -ra PICKS <<< "$CAT_CHOICE"
    # PICKS is empty if you just press Enter. Before bash 4.4, expanding an
    # empty array is an error under "set -u", hence the ${PICKS[@]+...} form.
    for pick in ${PICKS[@]+"${PICKS[@]}"}; do
        pick=$(echo "$pick" | tr -d ' ')
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#CATEGORIES[@]} )); then
            RESTORE_CATS+=("${CATEGORIES[$((pick-1))]}")
        else
            echo "Skipping invalid choice: $pick"
        fi
    done
fi

if [[ ${#RESTORE_CATS[@]} -eq 0 ]]; then
    echo "Nothing selected."
    exit 0
fi

echo ""
echo "Will restore: ${RESTORE_CATS[*]}"

# ─── Safety: back up existing files before overwriting ───────────

SAFETY_DIR="$REAL_HOME/.restore-backup-$(date '+%Y%m%d-%H%M%S')"

echo ""
echo "Existing files will be saved to: $SAFETY_DIR"
read -p "Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ─── Restore ─────────────────────────────────────────────────────
# Walk config entries for each selected category.
# The config tells us exactly where each item should be restored to.

RESTORED=0

for cat in "${RESTORE_CATS[@]}"; do
    echo ""
    echo "  [$cat]"

    # Find all config entries belonging to this category
    for i in "${!CONF_CATEGORIES[@]}"; do
        [[ "${CONF_CATEGORIES[$i]}" == "$cat" ]] || continue

        SRC_NAME="${CONF_SOURCES[$i]}"
        RESTORE_REL="${CONF_RESTORES[$i]}"
        BASENAME="$(basename "$SRC_NAME")"

        # On the drive, directories are stored as category/basename/...
        # and files as category/basename
        DRIVE_PATH="$SOURCE_DIR/$cat/$BASENAME"

        if ! on_drive test -e "$DRIVE_PATH"; then
            continue
        fi

        DEST_PATH="$REAL_HOME/$RESTORE_REL"

        echo "    $cat/$BASENAME → ~/$RESTORE_REL"

        if on_drive test -d "$DRIVE_PATH"; then
            # Back up existing directory
            if [[ -e "$DEST_PATH" && -z "$DRY_RUN" ]]; then
                mkdir -p "$(dirname "$SAFETY_DIR/$RESTORE_REL")"
                cp -a "$DEST_PATH" "$SAFETY_DIR/$RESTORE_REL"
            fi

            if [[ -z "$DRY_RUN" ]]; then
                mkdir -p "$DEST_PATH"
                "${RSYNC[@]}" --delete "$(drive_path "$DRIVE_PATH/")" "$DEST_PATH/"
                restore_owner "$DEST_PATH"
            fi
            ((RESTORED++)) || true
        else
            # Back up existing file
            if [[ -e "$DEST_PATH" && -z "$DRY_RUN" ]]; then
                mkdir -p "$(dirname "$SAFETY_DIR/$RESTORE_REL")"
                cp -a "$DEST_PATH" "$SAFETY_DIR/$RESTORE_REL"
            fi

            if [[ -z "$DRY_RUN" ]]; then
                mkdir -p "$(dirname "$DEST_PATH")"
                pull_file "$DRIVE_PATH" "$DEST_PATH"
                restore_owner "$DEST_PATH"
            fi
            ((RESTORED++)) || true
        fi
    done
done

echo ""
echo "────────────────────────────────"
echo "  Restored: $RESTORED files from $SELECTED"
if [[ -d "$SAFETY_DIR" ]]; then
    echo "  Previous files saved in: $SAFETY_DIR"
fi
echo "────────────────────────────────"
echo ""
echo "Restore complete. Drive will be unmounted on exit."
