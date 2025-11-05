#!/usr/bin/env bash
# prepare-snapper-and-limine.sh
# Idempotent setup for Btrfs + Snapper + Limine snapshot entries.
# Compatible with Archinstall-style Btrfs layouts using @ and @snapshots.
# No calls to `snapper create-config` (avoids subvolume exists errors).

set -euo pipefail
umask 077

log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root"

FSTYPE="$(findmnt -no FSTYPE / || true)"
[[ "$FSTYPE" == "btrfs" ]] || die "Root filesystem is not btrfs"

# Detect root device and subvol
ROOT_SRC_RAW="$(findmnt -o SOURCE -n /)"          # e.g. /dev/nvme0n1p2[/@]
ROOT_SRC_DEV="${ROOT_SRC_RAW%%[*}"                 # -> /dev/nvme0n1p2
ROOT_SUBVOL_BRACKET="$(sed -n 's/.*\[\(.*\)\].*/\1/p' <<<"$ROOT_SRC_RAW")"
[[ -z "$ROOT_SUBVOL_BRACKET" ]] && ROOT_SUBVOL_BRACKET="/"

# Keep compression option
ROOT_OPTS="$(findmnt -no OPTIONS / || true)"
COMP_OPT="compress=zstd"
if [[ "$ROOT_OPTS" =~ (compress(-force)?=[^,[:space:]]+) ]]; then
  COMP_OPT="${BASH_REMATCH[1]}"
fi

log "Installing required packages (btrfs-progs, snapper, limine)"
pacman -Sy --needed --noconfirm btrfs-progs snapper limine >/dev/null

# Try to install limine-snapper-sync (repo or AUR)
if ! have limine-snapper-sync; then
  pacman -S --needed --noconfirm limine-snapper-sync >/dev/null 2>&1 || true
  have yay  && ! have limine-snapper-sync && yay  -S --needed --noconfirm limine-snapper-sync || true
  have paru && ! have limine-snapper-sync && paru -S --needed --noconfirm limine-snapper-sync || true
fi

# Ensure @snapshots subvolume exists and mount /.snapshots
log "Ensuring @snapshots subvolume exists and /.snapshots is mounted"
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
grep -qE '^[^#]+\s+\/\.snapshots\s+btrfs\s+.*subvol=@snapshots' /etc/fstab 2>/dev/null || echo "$FSTAB_LINE" >> /etc/fstab
mountpoint -q /.snapshots || mount /.snapshots

# --- SNAPper config ---
log 'Bootstrapping Snapper root config using actual subvolume path'
install -d -m 755 /etc/snapper/configs
install -d -m 750 /.snapshots
chown root:root /.snapshots

ROOT_CFG="/etc/snapper/configs/root"

write_minimal_cfg () {
  cat > "$ROOT_CFG" <<EOF
# snapper config for root
SUBVOLUME="${ROOT_SUBVOL_BRACKET}"
SNAPSHOT_ROOT="/.snapshots"
FSTYPE="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
EOF
}

# If a template exists and no config yet, start from it then normalize keys
if [[ -f /usr/share/snapper/config-templates/default && ! -f "$ROOT_CFG" ]]; then
  install -m 600 /usr/share/snapper/config-templates/default "$ROOT_CFG"
fi
[[ -f "$ROOT_CFG" ]] || write_minimal_cfg

# Ensure desired key=values exist or are updated
ensure_kv () {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ROOT_CFG"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ROOT_CFG"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$ROOT_CFG"
  fi
}

ensure_kv SUBVOLUME      "${ROOT_SUBVOL_BRACKET}"   # e.g. "/@"
ensure_kv SNAPSHOT_ROOT  "/.snapshots"
ensure_kv FSTYPE         "btrfs"
ensure_kv TIMELINE_CREATE "yes"
ensure_kv TIMELINE_CLEANUP "yes"
ensure_kv NUMBER_CLEANUP  "yes"
chmod 600 "$ROOT_CFG"

# Point /.snapshots/config at the config file
ln -sfn "$ROOT_CFG" /.snapshots/config

# Verify using snapper itself
if ! snapper -c root get-config >/dev/null 2>&1; then
  echo
  echo "=== Diagnostics: Snapper couldn't read 'root' config ==="
  echo "-- list-configs --"; snapper list-configs || true
  echo "-- files --"; ls -l /etc/snapper/configs /etc/snapper/configs/root /.snapshots /.snapshots/config || true
  echo "-- mounts --"; findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS / /.snapshots || true
  echo "-- subvolume show / --"; btrfs subvolume show / || true
  echo "-- config --"; sed -n '1,200p' /etc/snapper/configs/root || true
  die "Snapper did not recognize the 'root' config."
fi

# --- Enable timers and seed snapshot ---
log "Enabling Snapper timers"
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null

if ! snapper -c root list 2>/dev/null | awk 'NR>2{ok=1} END{exit !ok}'; then
  log "Creating initial root snapshot"
  snapper -c root create -d "Initial snapshot" >/dev/null
fi

# --- Limine integration ---
if have limine-snapper-sync; then
  log "Configuring limine-snapper-sync and generating Limine entries"
  SNAP_SRC_RAW="$(findmnt -o SOURCE -n /.snapshots || true)"
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
echo "  snapper -c root get-config"
echo "  snapper list-configs"
echo "  snapper -c root list"
echo "  grep -i snapshot /boot/limine.cfg || true"
