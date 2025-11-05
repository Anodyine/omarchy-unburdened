#!/usr/bin/env bash
# prepare-snapper-and-limine.sh
# Idempotent setup for Btrfs + Snapper + Limine snapshot entries.
# No calls to `snapper create-config` to avoid "creating btrfs subvolume .snapshots failed".

set -euo pipefail
umask 077

log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
snapper_sees_root(){ snapper list-configs 2>/dev/null | grep -Eq '^[[:space:]]*root[[:space:]]*\|' ; }

[[ $EUID -eq 0 ]] || die "Run as root"

FSTYPE="$(findmnt -no FSTYPE / || true)"
[[ "$FSTYPE" == "btrfs" ]] || die "Root filesystem is not btrfs"

# Detect root block dev and bracketed subvol for /
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

# Ensure @snapshots exists at top-level and mount /.snapshots
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

# Bootstrap Snapper config without create-config
log 'Bootstrapping Snapper root config (SUBVOLUME="/") without create-config'
install -d -m 755 /etc/snapper/configs
install -d -m 750 /.snapshots
chown root:root /.snapshots

ROOT_CFG="/etc/snapper/configs/root"
if [[ -f /usr/share/snapper/config-templates/default && ! -f "$ROOT_CFG" ]]; then
  install -m 600 /usr/share/snapper/config-templates/default "$ROOT_CFG"
fi
# If still missing or to normalize, write minimal config
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
  # Ensure desired key=values exist or are updated
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
  chmod 600 "$ROOT_CFG"
fi

# Point /.snapshots/config at the config file
ln -sfn "$ROOT_CFG" /.snapshots/config

# Verify Snapper sees the config (no create-config anywhere)
if ! snapper_sees_root; then
  # Helpful diagnostics before failing
  snapper list-configs || true
  ls -l /etc/snapper/configs /etc/snapper/configs/root /.snapshots /.snapshots/config || true
  findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS /
