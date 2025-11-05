#!/usr/bin/env bash
# btrfs-3step.sh

# ==============================================================================
# HOW TO USE THIS SCRIPT (Arch ISO + Btrfs 3-step: partition -> format -> layout)
# ==============================================================================
# Summary:
#   Prepare a disk for an Arch install with a minimal Btrfs layout.
#   Subvols: @ (root), @home, @log, @cache, @snapshots
#   Mounts to /mnt so you can use archinstall Manual.
#
# Assumptions:
#   - You are booted into the Arch ISO.
#   - Target disk is /dev/nvme0n1 (change if different).
#   - You want a configurable FAT32 EFI partition and the rest Btrfs.
#
# Fetch on ISO:
#   curl -LO https://raw.githubusercontent.com/<user>/<repo>/main/path/btrfs-3step.sh
#   chmod +x btrfs-3step.sh
#   mv btrfs-3step.sh /root/ && cd /root
#
# Networking on ISO (if needed):
#   iwctl
#   ping archlinux.org
#
# Safety checks before starting:
#   lsblk -f
#   mount | grep nvme0n1 || true
#   swapoff -a
#   umount -R /mnt 2>/dev/null || true
#
# Optional full wipe of old signatures and GPT (DESTROYS DATA):
#   wipefs -a /dev/nvme0n1
#   # sgdisk -Z /dev/nvme0n1
#   partprobe /dev/nvme0n1
#
# Step 1: Partition (DESTROYS DATA ON THE DISK)
#   sudo /root/btrfs-3step.sh -s partition -d /dev/nvme0n1 [-S 5] [-F]
#   Examples:
#     # default 5 GiB ESP
#     sudo /root/btrfs-3step.sh -s partition -d /dev/nvme0n1
#     # custom float size ESP
#     sudo /root/btrfs-3step.sh -s partition -d /dev/nvme0n1 -S 5.5
#     # overwrite existing partitions
#     sudo /root/btrfs-3step.sh -s partition -d /dev/nvme0n1 -F -S 8
#
# Step 2: Format
#   sudo /root/btrfs-3step.sh -s format \
#        -d /dev/nvme0n1 \
#        -e /dev/nvme0n1p1 \
#        -b /dev/nvme0n1p2 \
#        [-L ARCH-BTRFS] [-E BOOT]
#
# Step 3: Layout and Mounts
#   sudo /root/btrfs-3step.sh -s layout \
#        -e /dev/nvme0n1p1 \
#        -b /dev/nvme0n1p2 \
#        [-C zstd:3] [-L ARCH-BTRFS] [-F]
#
# Notes:
#   - Default EFI size is 5 GiB. Use -S to change. -S accepts positive integers or decimals in GiB.
#   - Compression default is zstd:3.
#   - This script does not set up swap.
# ==============================================================================

set -euo pipefail

# Defaults
BTRFS_LABEL="ARCH-BTRFS"
EFI_LABEL="BOOT"
COMPRESS_OPT="zstd:3"
FORCE="no"
BOOT_SIZE_GIB="5"   # default EFI size (GiB). Supports floats.

# Inputs
STEP=""            # partition | format | layout
DISK=""            # e.g. /dev/nvme0n1
EFI_PART=""        # e.g. /dev/nvme0n1p1
BTRFS_PART=""      # e.g. /dev/nvme0n1p2

usage() {
  cat <<EOF
Usage:
  $0 -s partition -d /dev/DISK [-S <efi_size_gib>] [-F]
  $0 -s format    -d /dev/DISK -e /dev/ESP -b /dev/BTRFS [-L ARCH-BTRFS] [-E BOOT]
  $0 -s layout    -e /dev/ESP -b /dev/BTRFS [-C zstd:3] [-L ARCH-BTRFS] [-F]

Options:
  -s  step: partition | format | layout
  -d  disk device, e.g. /dev/nvme0n1 (partition, format)
  -e  EFI partition, e.g. /dev/nvme0n1p1 (format, layout)
  -b  Btrfs partition, e.g. /dev/nvme0n1p2 (format, layout)
  -S  EFI partition size in GiB (positive number, accepts decimals; default: ${BOOT_SIZE_GIB})
  -L  Btrfs label (default: ${BTRFS_LABEL})
  -E  EFI label (default: ${EFI_LABEL})
  -C  Btrfs compress option (default: ${COMPRESS_OPT})
  -F  force where applicable (ignore some safety checks)

Examples:
  $0 -s partition -d /dev/nvme0n1              # 5 GiB ESP
  $0 -s partition -d /dev/nvme0n1 -S 5.5       # 5.5 GiB ESP
  $0 -s format -d /dev/nvme0n1 -e /dev/nvme0n1p1 -b /dev/nvme0n1p2
  $0 -s layout -e /dev/nvme0n1p1 -b /dev/nvme0n1p2
EOF
  exit 1
}

req() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
die() { echo "Error: $*" >&2; exit 1; }
is_block() { [[ -b "$1" ]]; }

is_positive_number() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN {exit !($1 > 0)}"
}

assert_disk_unused() {
  local disk="$1"
  if lsblk -nr "$disk" | grep -q part; then
    echo "Warning: $disk already has partitions."
    [[ "$FORCE" == "yes" ]] || die "Use -F to proceed anyway."
  fi
}

print_partitions() {
  local disk="$1"
  echo "== parted print =="
  parted -s "$disk" print || true
  echo
  echo "== lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL =="
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$disk"
}

print_filesystems() {
  echo "== lsblk -f =="
  lsblk -f
}

print_mounts() {
  echo "== findmnt under /mnt =="
  findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt || true
}

make_dirs() {
  mkdir -p /mnt
  mkdir -p /mnt/btrfs-root
  mkdir -p /mnt/{home,var/log,var/cache,.snapshots,boot}
}

# Parse args
while getopts ":s:d:e:b:S:L:E:C:F" opt; do
  case "$opt" in
    s) STEP="$OPTARG" ;;
    d) DISK="$OPTARG" ;;
    e) EFI_PART="$OPTARG" ;;
    b) BTRFS_PART="$OPTARG" ;;
    S) BOOT_SIZE_GIB="$OPTARG" ;;
    L) BTRFS_LABEL="$OPTARG" ;;
    E) EFI_LABEL="$OPTARG" ;;
    C) COMPRESS_OPT="$OPTARG" ;;
    F) FORCE="yes" ;;
    *) usage ;;
  esac
done

[[ -n "$STEP" ]] || usage

#####################################
# Step: partition
#####################################
do_partition() {
  req parted
  [[ -n "$DISK" ]] || die "-d /dev/DISK is required"
  is_block "$DISK" || die "$DISK is not a block device"
  assert_disk_unused "$DISK"

  is_positive_number "$BOOT_SIZE_GIB" || die "-S must be a positive number in GiB. Got: $BOOT_SIZE_GIB"

  echo "Partitioning $DISK into ${BOOT_SIZE_GIB}GiB ESP + rest Btrfs"
  parted --script "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${BOOT_SIZE_GIB}GiB" \
    set 1 esp on \
    mkpart primary btrfs "${BOOT_SIZE_GIB}GiB" 100%

  echo "Partitioning complete."
  print_partitions "$DISK"
}

#####################################
# Step: format
#####################################
do_format() {
  req mkfs.vfat
  req mkfs.btrfs
  [[ -n "$DISK" ]] || die "-d /dev/DISK is required (for reporting)"
  [[ -n "$EFI_PART" ]] || die "-e /dev/ESP is required"
  [[ -n "$BTRFS_PART" ]] || die "-b /dev/BTRFS is required"

  is_block "$EFI_PART" || die "$EFI_PART not a block device"
  is_block "$BTRFS_PART" || die "$BTRFS_PART not a block device"

  echo "Formatting EFI partition $EFI_PART as FAT32 label=$EFI_LABEL"
  mkfs.vfat -F32 -n "$EFI_LABEL" "$EFI_PART"

  echo "Formatting Btrfs partition $BTRFS_PART label=$BTRFS_LABEL"
  mkfs.btrfs -L "$BTRFS_LABEL" "$BTRFS_PART"

  echo "Format complete."
  print_filesystems
  print_partitions "$DISK"
}

#####################################
# Step: layout (subvols + mounts)
#####################################
do_layout() {
  req blkid
  req btrfs
  req mount
  req umount
  req findmnt

  [[ -n "$EFI_PART" ]] || die "-e /dev/ESP is required"
  [[ -n "$BTRFS_PART" ]] || die "-b /dev/BTRFS is required"
  is_block "$EFI_PART" || die "$EFI_PART not a block device"
  is_block "$BTRFS_PART" || die "$BTRFS_PART not a block device"

  if mountpoint -q /mnt; then
    echo "/mnt is already mounted."
    [[ "$FORCE" == "yes" ]] || die "Unmount /mnt or use -F to proceed."
  fi
  if [[ -d /mnt && -n "$(ls -A /mnt 2>/dev/null || true)" ]]; then
    echo "/mnt is not empty."
    [[ "$FORCE" == "yes" ]] || die "Clean /mnt or use -F to proceed."
  fi

  make_dirs

  local fstype
  fstype="$(blkid -s TYPE -o value "$BTRFS_PART" || true)"
  [[ "$fstype" == "btrfs" ]] || die "$BTRFS_PART is not Btrfs"

  echo "Mounting raw Btrfs at /mnt/btrfs-root to create subvolumes"
  mount -t btrfs "$BTRFS_PART" /mnt/btrfs-root

  # Set label if empty
  local label
  label="$(blkid -s LABEL -o value "$BTRFS_PART" || true)"
  if [[ -z "$label" ]]; then
    echo "Setting Btrfs label to $BTRFS_LABEL"
    btrfs filesystem label /mnt/btrfs-root "$BTRFS_LABEL"
  else
    echo "Btrfs label detected: $label"
  fi

  # Create subvolumes idempotently
  create_sv() {
    local name="$1"
    if btrfs subvolume show "/mnt/btrfs-root/$name" >/dev/null 2>&1; then
      echo "Subvolume exists: $name"
    else
      echo "Creating subvolume: $name"
      btrfs subvolume create "/mnt/btrfs-root/$name" >/dev/null
    fi
  }

  create_sv "@"
  create_sv "@home"
  create_sv "@log"
  create_sv "@cache"
  create_sv "@snapshots"

  umount /mnt/btrfs-root

  local mopts="rw,noatime,compress=${COMPRESS_OPT},ssd,space_cache=v2,discard=async"

  echo "Mounting subvol=@ to /mnt"
  mount -o "subvol=@,${mopts}" "$BTRFS_PART" /mnt

  mkdir -p /mnt/{home,var/log,var/cache,.snapshots,boot}

  echo "Mounting subvols..."
  mount -o "subvol=@home,${mopts}"      "$BTRFS_PART" /mnt/home
  mount -o "subvol=@log,${mopts}"       "$BTRFS_PART" /mnt/var/log
  mount -o "subvol=@cache,${mopts}"     "$BTRFS_PART" /mnt/var/cache
  mount -o "subvol=@snapshots,${mopts}" "$BTRFS_PART" /mnt/.snapshots

  echo "Mounting EFI to /mnt/boot"
  mount "$EFI_PART" /mnt/boot

  echo "Layout complete."
  print_mounts
}

# Dispatch
case "$STEP" in
  partition) do_partition ;;
  format)    do_format ;;
  layout)    do_layout ;;
  *) usage ;;
esac
