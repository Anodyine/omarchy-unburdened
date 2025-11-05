#!/usr/bin/env bash
# prepare-snapper-and-limine.sh
# Idempotent setup for Btrfs + Snapper + Limine snapshot entries without forcing
# `snapper create-config` when /.snapshots already exists or is a mount.

set -euo pipefail

log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
snapper_has_root(){ snapper list-configs 2>/dev/null | grep -Eq '^[[:space:]]*root[[:space:]]*\|' ; }

[[ $EUID -eq 0 ]] || die "Run as root"

FSTYPE="$(findmnt -no FSTYPE / || true)"
[[ "$FSTYPE" == "btrfs" ]] || die "Root filesystem is not btrfs"

# Detect root device and subvol for /
ROOT_SRC_RAW="$(findmnt -o SOURCE -n /)"          # e.g. /dev/nvme0n1p2[/@]
ROOT_SRC_DEV="${ROOT_SRC_RAW%%[*}"                 # -> /dev/nvme0n1p2
ROOT_SUBVOL_BRACKET="$(sed -n 's/.*\[\(.*\)\].*/\1/p' <<<"$ROOT_SRC_RAW")"
[[ -z "$ROOT_SUBVOL_BRACKET" ]] && ROOT_SUBVOL_BRACKET="/"

# Keep existing compress option if present
ROOT_OPTS="$(findmnt -no OPTIONS / || true)"
COMP_OPT="compress=zstd"
if [[ "$ROOT_OPTS" =~ (compress(-force)?=[^,[:space:]]+) ]]; then
  COMP_OPT="${BASH_REMATCH[1]}"
fi

log "Installing required packages (btrfs-progs, snapper, limine)"
pacman -Sy --needed --noconfirm btrfs-progs snapper limine >/dev/null

# Try to install limine-snapper-sync (repo first, else AUR if helper exists)
if ! have limine-snapper-sync; then
  pacman -S --needed --noconfirm limine-snapper-sync >/dev/null 2>&1 || true
  have yay  && ! have limine-snapper-sync && yay  -S --needed --noconfirm limine-snapper-sync || true
  have paru && ! have limine-snapper-sync && paru -S --needed --noconfirm limine-snapper-sync || true
fi

# Ensure @snapshots subvol exists at top-level and mount /.snapshots
log "Ensuring @snapshots subvolume exists and /.snapshots is mounted"
TMPMNT="/mnt/.btrfs-top"
mkdir -p "$TMPMNT"
mountpoint -q "$TMPMNT" || mount -o subvolid=5 "$ROOT_SRC_DEV" "$TMPMNT"
[[ -d "$TMPMNT/@snapshots" ]] || btrfs subvolume create "$TMPMNT/@snapshots" >/dev/null
umount "$TMPMNT" || true
rmdir "$TMPMNT" || true

mkdir -p /.snapshots
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC_DEV" 2>/dev/null || true)"
FSTAB_SRC="${ROOT_UUID:+UUID=$ROOT_UUID}"; FSTAB_SRC="${FSTAB_SRC:-$ROOT_SRC_DEV}"
FSTAB_LINE="$FSTAB_SRC /.snapshots btrfs subvol=@snapshots,$COMP_OPT 0 0"
grep -qE '^[^#]+\s+\/\.snapshots\s+btrfs\s+.*subvol=@snapshots' /etc/fstab 2>/dev/null || echo "$FSTAB_LINE" >> /etc/fstab
mountpoint -q /.snapshots || mount /.snapshots

# Bootstrap Snapper config WITHOUT calling create-config if /.snapshots exists
log 'Ensuring Snapper root config exists (SUBVOLUME="/") without create-config'
install -d -m 755 /etc/snapper/configs
install -d -m 750 /.snapshots
chown root:root /.snapshots

ROOT_CFG="/etc/snapper/configs/root"
# Create config file if missing
if [[ ! -f "$ROOT_CFG" ]]; then
  cat > "$ROOT_CFG" <<'EOF'
# snapper config for root (root subvolume is "/")
SUBVOLUME="/"
FSTYPE="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
EOF
fi
chmod 600 "$ROOT_CFG"

# Ensure /.snapshots/config symlink points to the root config
ln -sfn "$ROOT_CFG" /.snapshots/config

# Re-check that snapper recognizes the config
if ! snapper_has_root; then
  # Only as a fallback, attempt create-config IF /.snapshots is not a mount
  if ! mountpoint -q /.snapshots; then
    log "Fallback: running 'snapper -c root create-config /' because /.snapshots is not a mount"
    snapper -c root create-config / >/dev/null
    ln -sfn "$ROOT_CFG" /.snapshots/config
  fi
fi

# Final verification
if ! snapper_has_root; then
  snapper list-configs || true
  findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS /.snapshots || true
  die "Snapper did not recognize the 'root' config."
fi

log "Enabling Snapper timers"
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null

# Seed an initial snapshot if none exists
if ! snapper -c root list 2>/dev/null | awk 'NR>2{ok=1} END{exit !ok}'; then
  log "Creating initial root snapshot"
  snapper -c root create -d "Initial snapshot" >/dev/null
fi

# Configure limine-snapper-sync with subvolume paths
if have limine-snapper-sync; then
  log "Configuring limine-snapper-sync and generating Limine entries"
  SNAP_SRC_RAW="$(findmnt -o SOURCE -n /.snapshots || true)"   # e.g. /dev/nvme0n1p2[/@snapshots]
  SNAP_SUBVOL_BRACKET="$(sed -n 's/.*\[\(.*\)\].*/\1/p' <<<"$SNAP_SRC_RAW")"
  [[ -z "$SNAP_SUBVOL_BRACKET" ]] && SNAP_SUBVOL_BRACKET="/@snapshots"

  cat > /etc/limine-snapper-sync.conf <<EOF
ROOT_SUBVOLUME_PATH="${ROOT_SUBVOL_BRACKET}"
ROOT_SNAPSHOTS_PATH="${SNAP_SUBVOL_BRACKET}"
ENTRY_PREFIX="Omarchy Snapshot"
EOF
  limine-snapper-sync >/dev/null || true
else
  log "limine-snapper-sync not available; skipping Limine entry generation"
fi

log "Done"
echo "Check:"
echo "  snapper list-configs     # should show: root | /"
echo "  snapper -c root list     # shows snapshots"
echo "  grep -i snapshot /boot/limine.cfg || true"
