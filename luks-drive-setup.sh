#!/usr/bin/env bash
set -euo pipefail

# luks-drive-setup.sh
# One-time setup: partitions a USB drive into:
#   Partition 1: Unencrypted (exFAT) for daily use
#   Partition 2: LUKS-encrypted (ext4) for backups
#
# WARNING: This will DESTROY all data on the target device.
#
# Usage: sudo ./luks-drive-setup.sh /dev/sdX [backup_percent]
#   backup_percent: how much of the drive to reserve for encrypted backup (default: 20)
#
# Examples:
#   sudo ./luks-drive-setup.sh /dev/sdb        # 20% encrypted, 80% open
#   sudo ./luks-drive-setup.sh /dev/sdb 30     # 30% encrypted, 70% open

DEVICE="${1:-}"
BACKUP_PCT="${2:-20}"
OPEN_PCT=$(( 100 - BACKUP_PCT ))
LABEL_OPEN="PLAINVIEW"
LABEL_BACKUP="PEACEFUL_BACKUP"

# Check for required tools
MISSING=()
for cmd in sgdisk wipefs cryptsetup mkfs.exfat mkfs.ext4; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Error: missing required tools: ${MISSING[*]}"
    echo ""
    echo "On Debian/Ubuntu:  sudo apt install gdisk cryptsetup exfatprogs e2fsprogs"
    echo "On Arch:           sudo pacman -S gptfdisk cryptsetup exfatprogs e2fsprogs"
    echo "On Fedora:         sudo dnf install gdisk cryptsetup exfatprogs e2fsprogs"
    exit 1
fi

if [[ -z "$DEVICE" ]]; then
    echo "Usage: sudo $0 /dev/sdX [backup_percent]"
    echo ""
    echo "  backup_percent: % of drive for encrypted backup (default: 20)"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E 'usb|NAME'
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: must run as root (sudo)."
    exit 1
fi

# Detect if user passed a partition instead of the whole device
DEV_TYPE=$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null || true)
if [[ "$DEV_TYPE" == "part" ]]; then
    # Strip trailing partition number(s) or pN suffix to suggest the parent device
    PARENT=$(lsblk -dn -o PKNAME "$DEVICE" 2>/dev/null || true)
    echo "Error: $DEVICE is a partition, not a whole device."
    echo "You need to pass the entire drive, e.g.:  sudo $0 /dev/${PARENT:-sdX}"
    exit 1
fi

# Validate percentage
if [[ ! "$BACKUP_PCT" =~ ^[0-9]+$ ]] || (( BACKUP_PCT < 5 || BACKUP_PCT > 95 )); then
    echo "Error: backup_percent must be a number between 5 and 95."
    exit 1
fi

# Safety check: refuse if anything on this device is currently mounted or used as swap
MOUNTED=$(lsblk -ln -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -E '^(/|\[SWAP\])' || true)
if [[ -n "$MOUNTED" ]]; then
    echo "Error: $DEVICE has active mount points:"
    echo "$MOUNTED"
    echo "Unmount them first, or check that this is the right device. Refusing."
    exit 1
fi

# Warn (but don't block) if the device isn't detected as USB transport
TRANSPORT=$(lsblk -dn -o TRAN "$DEVICE" 2>/dev/null || true)
if [[ "$TRANSPORT" != "usb" ]]; then
    echo "Warning: $DEVICE transport is '${TRANSPORT:-unknown}', not 'usb'."
    echo "This might not be a removable USB drive."
    read -p "Continue anyway? (yes/no): " TRAN_CONFIRM
    if [[ "$TRAN_CONFIRM" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Get drive size for display
DRIVE_SIZE=$(lsblk -b -d -n -o SIZE "$DEVICE" 2>/dev/null || echo 0)
DRIVE_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $DRIVE_SIZE / 1073741824}")

echo "=========================================="
echo " WARNING: ALL DATA ON $DEVICE WILL BE LOST"
echo "=========================================="
echo ""
lsblk "$DEVICE"
echo ""
echo "Drive size:  ${DRIVE_SIZE_GB} GB"
echo "Layout:"
echo "  Partition 1 (exFAT, \"$LABEL_OPEN\"):  ${OPEN_PCT}% — daily use, visible everywhere"
echo "  Partition 2 (LUKS, \"$LABEL_BACKUP\"): ${BACKUP_PCT}% — encrypted backups"
echo ""
read -p "Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# Helper: determine partition path for a given number
part_path() {
    local dev="$1" num="$2"
    if [[ "$dev" =~ [0-9]$ ]]; then
        echo "${dev}p${num}"
    else
        echo "${dev}${num}"
    fi
}

echo ""
echo "[1/5] Wiping partition table..."
wipefs -a "$DEVICE"
sgdisk --zap-all "$DEVICE"

# Partition 1: first OPEN_PCT% of the disk
# Partition 2: remainder
echo "[2/5] Creating partitions (${OPEN_PCT}% / ${BACKUP_PCT}% split)..."

# sgdisk doesn't support %, so calculate the size ourselves
TOTAL_SECTORS=$(sgdisk -p "$DEVICE" 2>/dev/null | awk '/^Disk.*sectors/{print $3}')
PART1_SECTORS=$(( TOTAL_SECTORS * OPEN_PCT / 100 ))

sgdisk -n "1:0:+${PART1_SECTORS}" -t 1:0700 "$DEVICE"    # 0700 = Microsoft basic data (exFAT)
sgdisk -n "2:0:0"                 -t 2:8309 "$DEVICE"    # 8309 = Linux LUKS
partprobe "$DEVICE"
sleep 2

PART1=$(part_path "$DEVICE" 1)
PART2=$(part_path "$DEVICE" 2)

echo "[3/5] Formatting daily-use partition (exFAT)..."
mkfs.exfat -n "$LABEL_OPEN" "$PART1"

echo "[4/5] Setting up LUKS encryption on backup partition..."
echo "  You will be asked to set a passphrase. Choose something strong and memorable."
echo ""
cryptsetup luksFormat --type luks2 --label "$LABEL_BACKUP" "$PART2"

echo ""
echo "[5/5] Opening and formatting encrypted partition (ext4)..."
cryptsetup luksOpen "$PART2" backup_setup
mkfs.ext4 -L "$LABEL_BACKUP" /dev/mapper/backup_setup

# Set ownership to the invoking user so backups don't end up owned by root
SETUP_MNT=$(mktemp -d)
mount /dev/mapper/backup_setup "$SETUP_MNT"
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$SETUP_MNT"
umount "$SETUP_MNT"
rmdir "$SETUP_MNT"

cryptsetup luksClose backup_setup

echo ""
echo "============================================"
echo " Done! Drive layout:"
echo "   ${PART1}  →  exFAT  \"${LABEL_OPEN}\"    (daily use)"
echo "   ${PART2}  →  LUKS   \"${LABEL_BACKUP}\"  (encrypted)"
echo ""
echo " For backups, run: ./backup-to-usb.sh"
echo "============================================"
