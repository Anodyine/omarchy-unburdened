#!/usr/bin/env bash
# fix-snapper-layout-and-limine.sh
# Align Archinstall-style Btrfs with Snapper's canonical layout:
# - Root subvolume: /@  (mounted at /)
# - Snapshots path:  /@/.snapshots  (not a separate @snapshots mount)
# Then set up Snapper + limine-snapper-sync.

set -euo pipefail
log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root"

# Sanity: root on btrfs and find the block device for /
[[ "$(findmnt -no FSTYPE /)" == "btrfs" ]] || die "Root filesystem is not btrfs"
ROOT_SRC_RAW="$(findmnt -o SOURCE -n /)"          # e.g. /dev/nvme0n1p2[/@]
ROOT_DEV="${ROOT_SRC_RAW%%[*}"                     # /dev/nvme0n1p2
[[ -b "$ROOT_DEV" ]] || die "Could not resolve root block device"

# 1) If a separate /.snapshots mount exists, unmount it and remove its fstab line
if findmnt -no SOURCE /.snapshots >/dev/null 2>&1; then
  log "Unmounting existing /.snapshots mount so Snapper can own /@/.snapshots"
  umount /.snapshots || true
fi

if [[ -f /etc/fstab ]]; then
  # Remove any line that mounts btrfs on /.snapshots (conservative)
  if grep -qE '^[^#]+\s+\/\.snapshots\s+btrfs' /etc/fstab; then
    log "Removing stale /.snapshots btrfs mount from /etc/fstab"
    cp -a /etc/fstab /etc/fstab.bak.$(date +%Y%m%d-%H%M%S)
    awk '!($2=="/.snapshots" && $3=="btrfs")' /etc/fstab > /etc/fstab.new
    mv /etc/fstab.new /etc/fstab
  fi
fi

# Ensure /.snapshots exists as a plain directory in / (which is /@)
mkdir -p /.snapshots
chown root:root /.snapshots
chmod 750 /.snapshots

# 2) Packages
log "Installing snapper and limine (if missing)"
pacman -Sy --needed --noconfirm btrfs-progs snapper limine >/dev/null

# 3) Create a standard Snapper config for root (this creates /@/.snapshots as a subvolume)
if ! snapper -c root get-config >/dev/null 2>&1; then
  log "Creating Snapper config for / (this will create /@/.snapshots)"
  # If a leftover config file or link exists, remove it so create-config can proceed cleanly
  rm -f /etc/snapper/configs/root /.snapshots/config 2>/dev/null || true
  snapper -c root create-config /    # canonical as per manual/ArchWiki
fi

# Harden config options (idempotent)
CFG="/etc/snapper/configs/root"
[[ -f "$CFG" ]] || die "Snapper root config missing after create-config"
chmod 600 "$CFG"
ensure_kv () {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CFG"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CFG"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CFG"
  fi
}
ensure_kv FSTYPE "btrfs"
ensure_kv TIMELINE_CREATE "yes"
ensure_kv TIMELINE_CLEANUP "yes"
ensure_kv NUMBER_CLEANUP "yes"

# Re-link /.snapshots/config (snapper usually does this, make sure it exists)
ln -sfn "$CFG" /.snapshots/config

# Verify the canonical layout now works
log "Verifying Snapper config with canonical layout"
snapper -c root get-config >/dev/null 2>&1 || die "Snapper still does not recognize 'root'"

# 4) Timers and initial snapshot
log "Enabling snapper timers"
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null

if ! snapper -c root list 2>/dev/null | awk 'NR>2{ok=1} END{exit !ok}'; then
  log "Creating initial root snapshot"
  snapper -c root create -d "Initial snapshot"
fi

# 5) limine-snapper-sync (defaults assume /@ and /@/.snapshots)
if ! have limine-snapper-sync; then
  pacman -S --needed --noconfirm limine-snapper-sync >/dev/null 2>&1 || true
fi

if have limine-snapper-sync; then
  log "Configuring limine-snapper-sync (defaults: /@ and /@/.snapshots)"
  # You can omit the conf file, defaults match our layout. Write one explicitly for clarity:
  cat > /etc/limine-snapper-sync.conf <<'EOF'
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@/.snapshots"
ENTRY_PREFIX="Omarchy Snapshot"
EOF
  limine-snapper-sync >/dev/null || true
else
  log "limine-snapper-sync not available; skipping Limine entry generation"
fi

log "Done"
echo "Check:"
echo "  snapper -c root get-config"
echo "  snapper list-configs"
echo "  snapper -c root list | head"
echo "  grep -i snapshot /boot/limine.cfg || true"
