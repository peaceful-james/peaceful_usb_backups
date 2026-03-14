# Peaceful USB Backups

Encrypted, per-machine backup of dotfiles, credentials, and personal scripts to USB drives. Designed around the idea that you keep **two small storage devices** in different physical locations, each holding everything you'd need to rebuild your environment from scratch.

## Why

SSH keys, GPG keys, shell configs, Emacs setups, personal scripts — these accumulate over years and represent real, irreplaceable work. Cloud services help, but they're someone else's computer. This toolkit gives you offline, encrypted, physically distributed backups that don't depend on any service staying online.

## What's in the box

| File | Purpose |
|---|---|
| `luks-drive-setup.sh` | One-time drive setup: partitions a USB drive into an unencrypted exFAT daily-use partition and a LUKS-encrypted backup partition |
| `backup-to-usb.sh` | Syncs your dotfiles to the encrypted partition, organized by machine |
| `restore-from-usb.sh` | Interactive restore — pick a machine, pick categories, get your files back |
| `core-lib.sh` | Shared functions (LUKS helpers, machine ID, config parser) |
| `backup.conf` | Single config file defining what to back up and where to restore it |
| `.backupignore` | Patterns to exclude from backups (rsync syntax, works like `.gitignore`) |
| `CHEATSHEET.txt` | Quick-reference for accessing backups from a bare terminal — copied to the unencrypted partition during drive setup |

## Quick start

### 1. Set up a drive

Plug in a USB drive and find it with `lsblk`. Then:

```bash
sudo ./luks-drive-setup.sh /dev/sdX
```

This creates two partitions — 80% exFAT for daily use, 20% LUKS-encrypted for backups. Adjust the split with a second argument:

```bash
sudo ./luks-drive-setup.sh /dev/sdX 10    # 90% daily / 10% backup
```

You'll be prompted to set a LUKS passphrase. Do this for both drives.

If the USB is borked somehow, you might need to do this:

```
sudo sgdisk --zap-all /dev/sdX
sudo partprobe /dev/sdX
```

### 2. Edit the config

Review `backup.conf` and uncomment or add anything you need:

```
# Format: source_path : category : restore_path

.ssh                : ssh     : .ssh
.gnupg              : gpg     : .gnupg
.gitconfig          : git     : .gitconfig
.bashrc             : shell   : .bashrc
.emacs.d            : emacs   : .emacs.d
bin                 : scripts : bin
```

One file, three columns. Both scripts read from it.

### 3. Back up

```bash
./backup-to-usb.sh
```

That's it. The script will `sudo` itself, find the LUKS partition, prompt for your passphrase, sync everything, and cleanly unmount. Use `--dry-run` to preview.

### 4. Restore

```bash
./restore-from-usb.sh
```

Lists available machines, lets you pick one, then lets you choose which categories to restore (or all). Your existing files are saved to `~/.restore-backup-<timestamp>/` before anything is overwritten.

Other modes:

```bash
./restore-from-usb.sh --list                  # just show what's on the drive
./restore-from-usb.sh --from laptop-0036232   # non-interactive, restore everything
./restore-from-usb.sh --dry-run               # preview, no changes
```

## Drive layout

```
USB drive
├── Partition 1 "PLAINVIEW" (exFAT) — daily use, visible on any OS
└── Partition 2 "PEACEFUL_BACKUP" (LUKS) — encrypted backups
    ├── thinkpad-0036232/
    │   ├── ssh/.ssh/
    │   ├── gpg/.gnupg/
    │   ├── shell/.bashrc
    │   ├── emacs/.emacs.d/
    │   ├── scripts/bin/
    │   └── MANIFEST.txt
    └── desktop-0841903/
        ├── ssh/.ssh/
        ├── gpg/.gnupg/
        └── ...
```

Each machine gets its own directory, identified by `hostname-NNNNNNN` where the suffix is derived from the MAC address to avoid collisions.

## The rotation

Keep one drive at home, one somewhere else — office, a friend's house, a safe deposit box. Back up to whichever drive is at hand. Swap them periodically so both stay reasonably current.

## Dependencies

All standard Linux tools. Install any missing ones with:

```bash
# Debian/Ubuntu
sudo apt install gdisk cryptsetup exfatprogs e2fsprogs rsync

# Arch
sudo pacman -S gptfdisk cryptsetup exfatprogs e2fsprogs rsync

# Fedora
sudo dnf install gdisk cryptsetup exfatprogs e2fsprogs rsync
```

## Excluding files

Edit `.backupignore` to skip files and directories during backup. Uses rsync pattern syntax, which works like `.gitignore` for most cases:

```
.git
*.elc
__pycache__
*~
```

The file is optional — if absent, nothing is excluded. Only affects backups, not restores.

## Notes

- **Flash drive health**: USB drives degrade over time. Every year or two, verify both drives and consider replacing the physical media.
- **Machine ID override**: set `BACKUP_HOST=myname` to use a custom identifier instead of the auto-generated one.
- **All seven files must live in the same directory.**
- The setup script refuses to format any device with active mount points, and warns if the device doesn't report USB transport.
- The backup and restore scripts handle already-unlocked drives gracefully — no need to close and reopen.
