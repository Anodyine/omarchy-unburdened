set -euo pipefail

echo "== Detect root subvolume path =="
ROOT_PATH="$(btrfs subvolume show / | sed -n 's/^Path:[[:space:]]*\(.*\)$/\1/p')"
# ROOT_PATH is something like "/" or "@"
case "$ROOT_PATH" in
  "" ) echo "Could not detect root subvolume path"; exit 1 ;;
  "/" ) SNAP_DIR="/.snapshots" ; SUBVOL_FOR_CFG="/" ;;
  * )  SNAP_DIR="/${ROOT_PATH}/.snapshots" ; SUBVOL_FOR_CFG="/${ROOT_PATH}" ;;
esac
echo "Root subvolume path: $ROOT_PATH"
echo "Snapshots dir should be a subvolume at: $SNAP_DIR"
echo

echo "== Ensure $SNAP_DIR is a Btrfs subvolume =="
if btrfs subvolume show "$SNAP_DIR" >/dev/null 2>&1; then
  echo "$SNAP_DIR already a subvolume"
elif [[ -e "$SNAP_DIR" ]]; then
  echo "$SNAP_DIR exists but is not a subvolume"
  # Must be empty to replace directly, else move it aside
  if [[ -z "$(ls -A "$SNAP_DIR")" ]]; then
    rmdir "$SNAP_DIR"
  else
    mv "$SNAP_DIR" "${SNAP_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  btrfs subvolume create "$SNAP_DIR" >/dev/null
  echo "Created subvolume: $SNAP_DIR"
else
  mkdir -p "$(dirname "$SNAP_DIR")"
  btrfs subvolume create "$SNAP_DIR" >/dev/null
  echo "Created subvolume: $SNAP_DIR"
fi
chmod 750 "$SNAP_DIR"
chown root:root "$SNAP_DIR"
echo

echo "== Install snapper if needed =="
pacman -Sy --needed --noconfirm snapper btrfs-progs >/dev/null
install -d -m 755 /etc/snapper/configs
CFG=/etc/snapper/configs/root

echo "== Write snapper root config =="
cat > "$CFG" <<EOF
SUBVOLUME="${SUBVOL_FOR_CFG}"
SNAPSHOT_ROOT="${SNAP_DIR}"
FSTYPE="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
EOF
chmod 600 "$CFG"
ln -sfn "$CFG" /.snapshots/config 2>/dev/null || true  # optional convenience if /.snapshots exists
echo

echo "== Verify config =="
snapper -c root get-config
echo "OK: snapper sees 'root'"
