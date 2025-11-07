sudo pacman -S snapper btrfs-progs limine-snapper-sync
sudo snapper -c root create-config /
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null
sudo snapper -c root create -d "Initial snapshot" >/dev/null
sudo snapper -c root list