echo '=== Mounts (root and .snapshots) ==='
findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS / /.snapshots || true
echo

echo '=== Is /.snapshots a mountpoint? ==='
mountpoint -q /.snapshots && echo "YES: /.snapshots is a mountpoint" || echo "NO: /.snapshots is not a mountpoint"
stat -c 'mode=%a owner=%U:%G type=%F' /.snapshots || true
ls -lad /.snapshots || true
echo

echo '=== Root source and subvolume (bracketed) ==='
ROOT_SRC_RAW="$(findmnt -o SOURCE -n / || true)"; echo "ROOT_SRC_RAW=$ROOT_SRC_RAW"
ROOT_DEV="${ROOT_SRC_RAW%%[*}"; echo "ROOT_DEV=$ROOT_DEV"
ROOT_SUBVOL_BRACKET="$(sed -n 's/.*\[\(.*\)\].*/\1/p' <<<"$ROOT_SRC_RAW")"; echo "ROOT_SUBVOL_BRACKET=${ROOT_SUBVOL_BRACKET:-/}"
echo

echo '=== Btrfs subvols on the root device (top 200) ==='
btrfs subvolume list -o "$ROOT_DEV" 2>/dev/null | head -n 200 || true
echo

echo '=== Does /@/.snapshots exist and what is it? ==='
if [[ -e /@/.snapshots ]]; then
  echo "Exists: /@/.snapshots"
  ls -lad /@/.snapshots || true
  btrfs subvolume show /@/.snapshots 2>/dev/null || echo "Not a subvolume (or not accessible)"
else
  echo "Missing: /@/.snapshots"
fi
echo

echo '=== Snapper configs that Snapper sees ==='
snapper list-configs || true
echo

echo '=== Current config file contents (if present) ==='
if [[ -f /etc/snapper/configs/root ]]; then
  sed -n '1,200p' /etc/snapper/configs/root
else
  echo "/etc/snapper/configs/root not found"
fi
echo

echo '=== /.snapshots/config symlink target (if present) ==='
if [[ -L /.snapshots/config || -e /.snapshots/config ]]; then
  ls -l /.snapshots/config || true
  readlink -f /.snapshots/config || true
else
  echo "No /.snapshots/config present"
fi
echo

echo '=== fstab entries mentioning .snapshots ==='
grep -nE '^[^#].*\s/\.snapshots\s' /etc/fstab || echo "No fstab line for /.snapshots"
echo

echo '=== Can Snapper read the root config? ==='
snapper -c root get-config; echo "exit=$?"
echo
