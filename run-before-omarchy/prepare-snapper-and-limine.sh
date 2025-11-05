#!/usr/bin/env bash
# prepare-snapper-and-limine.sh
# Idempotent setup for Btrfs + Snapper + Limine snapshot entries.
# - No use of `snapper create-config`
# - SUBVOLUME="/" for the root config
# - /.snapshots mounted from top-level @snapshots
# - Verifies config with `snapper -c root get-config`
# - Seeds an initial snapshot if missing

set -euo pipefail
umask 077

log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root"

# Sanity: root must be btrfs
FSTYPE="$(findmnt -no FSTYPE / || true)"
[[ "$FSTYPE" == "btrfs" ]] || die "Root filesystem is not btrfs"

# Detect root block device and bracketed subvolume for /
ROOT_SRC_RAW="$(findmnt -o SOURCE -n /)"          # e.g. /dev/nvme0n1p2[/@]
ROOT_SRC_DEV="${ROOT_SRC_RAW%%[*}"                 # -> /dev/nvme0n1p2
ROOT_SUBVOL_BRACKET="$(sed -n 's/.*\[\(.*\)\].*/\1/p' <<<"$ROOT_SRC_RAW")"
[[ -z "$ROOT_SUBVOL_BRACKET" ]] && ROOT_SUBVOL_BRACKET="/"

# Preserve existing compress option if present
ROOT_OPTS="$(findmnt -no OPTIONS / || true)"
COMP_OPT="compress=zstd"
if [[ "$ROOT_OPTS" =~ (compress(-force)?=[^,[:space:]]+) ]]; then
  COMP_OPT="${BASH_REMATCH[1]}"
fi

log "Installing packages (btrfs-progs, snapper, limine)"
pacman -Sy --needed --noconfirm btrfs-progs snapper limine >/dev/null

# Optional: install limine-snapper-sync if available
if ! have limine-snapper-sync; then
  pacman -S --needed --noconfirm limine-snapper-sync >/dev/null 2>&1 || true
  have yay  && ! have limine-snapper-sync && yay  -S --needed --noconfirm limine-snapper-sync || true
  have paru && ! have limine-snapper-sync && paru -S --needed --noconfirm limine-snapper-sync || true
fi

# Ensure @snapshots exists at top-level and mount /.snapshots with same compression
log "Ensuring @snapshots exists and /.snapshots is mounted"
TMPMNT="/mnt/.btrfs-top"
mkdir -p "$TMPMNT"
if ! mountpoint -q "$TMPMNT"; then
  mount -o subvolid=5 "$ROOT_SRC_DEV" "$TMPMNT"
fi
[[ -d "$TMPMNT/@snapshots" ]] || btrfs subvolume create "$TMPMNT/@snapshots" >/dev/null
umount "$TMPMNT" || true
rmdir "$TMPMNT" || true

mkdir -p /.snapshots
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC_DEV" 2>/dev/null || true)"
FSTAB_SRC="${ROOT_UUID:+UUID=$ROOT_UUID}"; FSTAB_SRC="${FSTAB_SRC:-$ROOT_SRC_DEV}"
FSTAB_LINE="$FSTAB_SRC /.snapshots btrfs subvol=@snapshots,$COMP_OPT 0 0"
# Append fstab line once
if ! grep -qE '^[^#]+\s+\/\.snapshots\s+btrfs\s+.*subvol=@snapshots' /etc/fstab 2>/dev/null; then
  echo "$FSTAB_LINE" >> /etc/fstab
fi
mountpoint -q /.snapshots || mount /.snapshots

# Bootstrap Snapper root config without create-config
log 'Writing Snapper root config (SUBVOLUME="/")'
install -d -m 755 /etc/snapper/configs
install -d -m 750 /.snapshots
chown root:root /.snapshots

ROOT_CFG="/etc/snapper/configs/root"

# Use template if present, else write minimal config
if [[ ! -f "$ROOT_CFG" && -f /usr/share/snapper/config-templates/default ]]; then
  install -m 600 /usr/share/snapper/config-templates/default "$ROOT_CFG"
fi
if [[ ! -f "$ROOT_CFG" ]]; then
  cat > "$ROOT_CFG" <<'EOF'
# snapper config for root
SUBVOLUME="/"
FSTYPE="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
EOF
else
  # Normalize key values
  ensure_kv () {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ROOT_CFG"; then
      sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ROOT_CFG"
    else
      printf '%s="%s"\n' "$key" "$val" >> "$ROOT_CFG"
    fi
  }
  ensure_kv SUBVOLUME "/"
  ensure_kv FSTYPE "btrfs"
  ensure_kv TIMELINE_CREATE "yes"
  ensure_kv TIMELINE_CLEANUP "yes"
  ensure_kv NUMBER_CLEANUP "yes"
fi

# Correct ownership and perms that Snapper expects
chown root:root /etc/snapper /etc/snapper/configs "$ROOT_CFG" /.snapshots
chmod 755 /etc/snapper /etc/snapper/configs
chmod 750 /.snapshots
chmod 600 "$ROOT_CFG"

# Ensure /.snapshots/config symlink points to root config
ln -sfn "$ROOT_CFG" /.snapshots/config

# Verify Snapper recognizes the config using snapper itself
log "Verifying Snapper can read the 'root' config"
if ! snapper -c root get-config >/dev/null 2>&1; then
  echo
  echo "=== Diagnostics: Snapper could not read 'root' config ==="
  echo "-- list-configs --"
  snapper list-configs || true
  echo "-- files --"
  ls -l /etc/snapper/configs /etc/snapper/configs/root /.snapshots /.snapshots/config || true
  echo "-- mounts --"
  findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS / /.snapshots || true
  echo "-- config --"
  sed -n '1,200p' /etc/snapper/configs/root || true
  die "Snapper did not recognize the 'root' config."
fi

log "Enabling Snapper timers"
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null

# Ensure at least one root snapshot exists
if ! snapper -c root list 2>/dev/null | awk 'NR>2{ok=1} END{exit !ok}'; then
  log "Creating initial root snapshot"
  snapper -c root create -d "Initial snapshot" >/dev/null
fi

# Configure limine-snapper-sync with subvolume paths and generate entries
if have limine-snapper-sync; then
  log "Configuring limine-snapper-sync"
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
  log "limine-snapper-sync not installed. Skipping Limine entry generation"
fi

log "Done"
echo "Check:"
echo "  snapper -c root get-config"
echo "  snapper -c root list"
echo "  grep -i snapshot /boot/limine.cfg || true"
