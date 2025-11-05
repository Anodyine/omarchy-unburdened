#!/usr/bin/env bash
# prepare-snapper-minimal.sh
# Simple idempotent setup for Btrfs + Snapper + optional Limine integration.
# Run as root after Archinstall (root fs = btrfs, mounted at /).

set -euo pipefail

ROOT_DEV="/dev/nvme0n1p2"     # <-- change if your root partition differs
COMP_OPT="compress=zstd"

log(){ printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

log "Installing dependencies"
pacman -Sy --needed --noconfirm btrfs-progs snapper limine >/dev/null

# ---------------------------------------------------------------------------
# 1. Ensure @snapshots exists and is mounted at /.snapshots
# ---------------------------------------------------------------------------
log "Ensuring @snapshots subvolume and mount"
mkdir -p /mnt
mount -o subvolid=5 "$ROOT_DEV" /mnt
if ! btrfs subvolume list /mnt | grep -q "@snapshots"; then
  btrfs subvolume create /mnt/@snapshots >/dev/null
fi
umount /mnt

mkdir -p /.snapshots
UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
FSTAB_LINE="UUID=$UUID /.snapshots btrfs subvol=@snapshots,$COMP_OPT 0 0"
grep -q 'subvol=@snapshots' /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
mountpoint -q /.snapshots || mount /.snapshots

# ---------------------------------------------------------------------------
# 2. Minimal snapper config
# ---------------------------------------------------------------------------
log "Creating minimal snapper config"
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
EOF

chmod 600 /etc/snapper/configs/root
ln -sf /etc/snapper/configs/root /.snapshots/config

# ---------------------------------------------------------------------------
# 3. Verify snapper and seed initial snapshot
# ---------------------------------------------------------------------------
log "Verifying snapper config"
snapper -c root get-config || { echo "Snapper config invalid"; exit 1; }

log "Enabling snapper timers"
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null

if ! snapper -c root list 2>/dev/null | awk 'NR>2{ok=1}END{exit!ok}'; then
  log "Creating initial snapshot"
  snapper -c root create -d "Initial snapshot" >/dev/null
fi

# ---------------------------------------------------------------------------
# 4. Optional: limine-snapper-sync
# ---------------------------------------------------------------------------
if command -v limine-snapper-sync >/dev/null 2>&1; then
  log "Configuring limine-snapper-sync"
  cat > /etc/limine-snapper-sync.conf <<'EOF'
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
ENTRY_PREFIX="Omarchy Snapshot"
EOF
  limine-snapper-sync >/dev/null || true
else
  log "Skipping limine-snapper-sync (not installed)"
fi

log "Done!"
echo
echo "Check:"
echo "  snapper -c root get-config"
echo "  snapper -c root list"
echo "  grep -i snapshot /boot/limine.cfg || true"
