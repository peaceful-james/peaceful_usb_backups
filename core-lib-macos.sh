#!/usr/bin/env bash
# core-lib-macos.sh — macOS versions of the drive functions in core-lib.sh
# This file is sourced by core-lib.sh on macOS, not executed directly.
#
# macOS cannot read LUKS or ext4. So the encrypted partition is handed to a
# small Linux VM (Lima, see peaceful-lima.yaml), which unlocks and mounts it.
# The VM has no shared folders and never sees your files. This script pushes
# and pulls them with rsync over SSH instead.
#
# Everything here must work with the bash 3.2 that ships with macOS.

LUKS_GPT_TYPE="CA7D7CCB-63ED-4C53-861C-1742536059CC"   # "Linux LUKS", as set by luks-drive-setup.sh
LIMA_INSTANCE="peaceful"
LIMA_TEMPLATE="$SCRIPT_DIR/peaceful-lima.yaml"
LIMA_DIR="${LIMA_HOME:-$HOME/.lima}/$LIMA_INSTANCE"
LIMA_SSH_CONFIG="$LIMA_DIR/ssh.config"
LIMA_SSH_HOST="lima-$LIMA_INSTANCE"
LIMA_SUDOERS="/etc/sudoers.d/lima"
LOCK_DIR="${TMPDIR:-/tmp}/peaceful-backup.lock"

# Lima only opens a disk through a root-owned helper. If Lima was installed
# somewhere you can write to (Homebrew), its docs have you unpack a second
# copy under /opt/lima, so prefer that one. Override with LIMACTL=...
if [[ -z "${LIMACTL:-}" ]]; then
    if [[ -x /opt/lima/bin/limactl ]]; then
        LIMACTL=/opt/lima/bin/limactl
    else
        LIMACTL=limactl
    fi
fi

_SSH=(ssh -F "$LIMA_SSH_CONFIG" -o LogLevel=ERROR -o ConnectTimeout=10)
_VM_STARTED=false
_WE_LOCKED=false

# ─── Small replacements ─────────────────────────────────────────

# On Linux the script re-runs itself under sudo. Here it is the opposite:
# Lima refuses to run as root, and nothing else needs it.
ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "Error: on macOS, run this as your normal user (no sudo)."
        exit 1
    fi
}

# Same shape as on Linux ("name-0123456"), but the suffix comes from the
# hardware UUID: macOS changes the Wi-Fi MAC address from network to network.
machine_id() {
    local name uuid hex

    name=$(scutil --get LocalHostName 2>/dev/null) || name=$(hostname -s)
    uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}') || uuid=""
    hex="${uuid//-/}"

    if [[ ${#hex} -ge 5 ]]; then
        # Last 5 hex digits = 20 bits, the same range as the Linux suffix
        printf '%s-%07d\n' "$name" "$(( 16#${hex: -5} ))"
    else
        echo "$name"
    fi
}

list_devices() { diskutil list external physical; }

# Looks for a partition of type "Linux LUKS" on an external disk and prints
# its raw device, e.g. /dev/rdisk2s2. Needs no root.
# To skip the search:  BACKUP_DEVICE=/dev/rdisk2s2 ./backup-to-usb.sh
find_luks_partition() {
    local id content

    if [[ -n "${BACKUP_DEVICE:-}" ]]; then
        echo "$BACKUP_DEVICE"
        return 0
    fi

    for id in $(diskutil list external physical 2>/dev/null \
                | awk '$NF ~ /^disk[0-9]+s[0-9]+$/ {print $NF}'); do
        content=$(diskutil info -plist "/dev/$id" 2>/dev/null \
                  | plutil -extract Content raw - 2>/dev/null) || continue
        if [[ "$content" == "$LUKS_GPT_TYPE" ]]; then
            echo "/dev/r$id"
            return 0
        fi
    done
    return 1
}

# ─── Talking to the VM ──────────────────────────────────────────

# _sq STR — STR as one single-quoted shell word.
# (The quote and its replacement must be in variables: bash 3.2 gets
# ${s//\'/...} wrong when they are written inline.)
_sq() {
    local s="$1" sq="'" rep="'\\''"
    printf "'%s'" "${s//$sq/$rep}"
}

# _guest_cmd CMD... — the command line to run CMD as root in the VM
_guest_cmd() {
    local line="sudo" arg
    for arg in "$@"; do
        line="$line $(_sq "$arg")"
    done
    printf '%s' "$line"
}

# Runs CMD as root in the VM. It never reads the script's own input, and
# its exit status is CMD's. If ssh itself fails (255) the script stops:
# a lost connection must never be mistaken for "file not found".
on_drive() {
    local rc=0
    "${_SSH[@]}" -T "$LIMA_SSH_HOST" "$(_guest_cmd "$@")" </dev/null || rc=$?
    if [[ $rc -eq 255 ]]; then
        echo "Error: lost contact with the Linux helper VM." >&2
        exit 1
    fi
    return $rc
}

# rsync reaches the drive over the same SSH connection.
#   --no-D          skip sockets and device files (must come after -a)
#   --numeric-ids   store your numeric user and group id, as on Linux
#   RSYNC_OLD_ARGS  keeps a newer rsync from re-quoting the remote path
export RSYNC_OLD_ARGS=1
RSYNC=(rsync -a --no-D --numeric-ids
       -e "ssh -F '$LIMA_SSH_CONFIG' -o LogLevel=ERROR"
       --rsync-path="sudo rsync")

# The path is quoted because the VM's shell reads it once more.
drive_path() { printf '%s:%s\n' "$LIMA_SSH_HOST" "$(_sq "$1")"; }

pull_file() { "${RSYNC[@]}" "$(drive_path "$1")" "$2"; }

# ─── The VM itself ──────────────────────────────────────────────

_vm_status() {
    "$LIMACTL" list --format '{{.Status}}' "$LIMA_INSTANCE" 2>/dev/null || true
}

_vm_stop() {
    "$LIMACTL" stop "$LIMA_INSTANCE" >/dev/null 2>&1 && return 0
    "$LIMACTL" stop --force "$LIMA_INSTANCE" >/dev/null 2>&1 || true
    return 1
}

# Prints how to let Lima open PART. Lima's rule lists exact device paths,
# so the ones already granted are kept.
_sudoers_help() {
    local part="$1" devices

    devices=$( { grep -oE '/dev/r?disk[0-9]+(s[0-9]+)*' "$LIMA_SUDOERS" 2>/dev/null; echo "$part"; } \
               | sort -u | tr '\n' ',' )
    devices="${devices%,}"

    echo ""
    echo "Lima may only open a disk that you have allowed it to. To allow $part"
    echo "(run these yourself, and read the file before installing it):"
    echo ""
    echo "  $LIMACTL sudoers --block-device=$devices > ~/lima-sudoers"
    echo "  cat ~/lima-sudoers && visudo -cf ~/lima-sudoers"
    echo "  sudo install -o root -g wheel -m 0444 ~/lima-sudoers $LIMA_SUDOERS && rm ~/lima-sudoers"
    echo ""
    echo "The rule gives Lima raw access to that disk slot, so never list your"
    echo "system disk. It has to be installed again after every Lima upgrade."
}

# Checks everything the VM needs, and creates it on first use.
_vm_require() {
    local part="$1" version out

    if ! command -v "$LIMACTL" >/dev/null 2>&1; then
        echo "Error: Lima is not installed. On macOS the drive is opened in a Linux VM"
        echo "managed by Lima (2.3 or newer):  sudo port install lima   or   brew install lima"
        exit 1
    fi

    version=$("$LIMACTL" --version 2>/dev/null | awk '{print $NF}')
    if ! echo "$version" | awk -F. '{exit !($1 > 2 || ($1 == 2 && $2 >= 3))}'; then
        echo "Error: Lima 2.3 or newer is needed (found: ${version:-unknown})."
        exit 1
    fi

    if ! grep -qsE "[[:space:]]${part}(,|[[:space:]]|\$)" "$LIMA_SUDOERS"; then
        echo "Error: Lima is not allowed to open $part yet."
        _sudoers_help "$part"
        exit 1
    fi

    if [[ ! -f "$LIMA_DIR/lima.yaml" ]]; then
        echo "Creating the Linux helper VM (one time; downloads about 350 MB)..."
        if ! out=$("$LIMACTL" create --name="$LIMA_INSTANCE" --tty=false "$LIMA_TEMPLATE" 2>&1); then
            echo "$out" | tail -5
            echo "Error: could not create the helper VM."
            exit 1
        fi
    fi
}

# Only one run at a time: two would share the VM, and the first to finish
# would stop it under the other. A lock left by a dead run is taken over.
_take_lock() {
    local pid=""

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || pid=""
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Error: another backup or restore is already running (process $pid)."
            exit 1
        fi
    fi
    echo $$ > "$LOCK_DIR/pid"
    _WE_LOCKED=true
}

# ─── Open and close ─────────────────────────────────────────────

open_and_mount() {
    local part="$1" dev status out

    dev="/dev/disk/by-id/virtio-$(basename "$part")"

    _vm_require "$part"
    _take_lock

    # We hold the lock, so a VM that is not stopped was left by a run that died.
    status=$(_vm_status)
    if [[ "$status" != "Stopped" ]]; then
        echo "The helper VM was left ${status:-in an unknown state} by an earlier run. Resetting it."
        _vm_stop || true
    fi

    # "edit" and "start" are separate on purpose: "edit --start" skips the
    # start when the device is the same as last time.
    "$LIMACTL" edit --tty=false --set ".blockDevices = [\"$part\"]" "$LIMA_INSTANCE" >/dev/null 2>&1

    echo "Starting the Linux helper VM..."
    _VM_STARTED=true          # set first: an interrupted start must still be stopped
    if ! out=$("$LIMACTL" start --tty=false "$LIMA_INSTANCE" 2>&1); then
        echo "$out" | tail -5
        echo "Error: the helper VM did not start. Full log: $LIMA_DIR/ha.stderr.log"
        _sudoers_help "$part"
        exit 1
    fi

    if ! on_drive cryptsetup isLuks "$dev"; then
        echo "Error: $part did not reach the VM as a LUKS volume."
        exit 1
    fi

    # cryptsetup asks for the passphrase itself, so it never passes through
    # this script. EscapeChar=none: otherwise ssh would swallow a passphrase
    # that starts with "~".
    echo "Opening encrypted drive (enter passphrase)..."
    if ! "${_SSH[@]}" -t -o EscapeChar=none "$LIMA_SSH_HOST" \
            "$(_guest_cmd cryptsetup luksOpen "$dev" "$MAPPER_NAME")"; then
        echo "Error: could not unlock the drive."
        exit 1
    fi

    on_drive mkdir -p "$MOUNT_POINT"
    on_drive mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"
    echo "Mounted at $MOUNT_POINT (inside the helper VM)"
    echo ""
}

# Always locks the drive and stops the VM, whatever state the run ended in.
# The drive is never left unlocked in a VM running in the background.
cleanup_mount() {
    set +e                          # a failing step must not skip the rest
    trap '' INT TERM HUP            # nor may a second Ctrl-C

    if $_VM_STARTED; then
        local closed=false
        echo ""
        echo "Cleaning up..."

        # ssh directly, not on_drive: on_drive exits when the VM is unreachable.
        if "${_SSH[@]}" -T "$LIMA_SSH_HOST" "$(_guest_cmd bash -c '
                sync
                if mountpoint -q "$1"; then umount "$1" || exit 1; fi
                if [[ -e "/dev/mapper/$2" ]]; then cryptsetup luksClose "$2" || exit 1; fi
            ' bash "$MOUNT_POINT" "$MAPPER_NAME")" </dev/null >/dev/null 2>&1; then
            closed=true
        fi

        # A normal VM shutdown unmounts cleanly too, so that also counts.
        if _vm_stop; then closed=true; fi

        if $closed; then
            echo "Drive safely closed. Eject the stick in Finder before unplugging it."
        else
            echo "WARNING: could not confirm the drive was closed cleanly."
            echo "Before unplugging, run:  $LIMACTL stop --force $LIMA_INSTANCE"
        fi
    fi

    if $_WE_LOCKED; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
    return 0
}
