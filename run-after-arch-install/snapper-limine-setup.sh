# Sets up dependencies for limine snapper integration
# This allows omarchy to create snapshots that can be booted into 
# as a fallback if the primary boot option stops working.

set -euo pipefail

sudo pacman -S snapper btrfs-progs limine-snapper-sync
sudo snapper -c root create-config /
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null
sudo snapper -c root create -d "Initial snapshot" >/dev/null
sudo snapper -c root list