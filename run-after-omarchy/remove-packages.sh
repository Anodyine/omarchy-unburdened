#!/usr/bin/env bash
set -euo pipefail

# remove-packages.sh — removes all packages listed in removed-packages.list
# Usage: sudo ./remove-packages.sh

LIST="./packages.list"

if [[ ! -f "$LIST" ]]; then
  echo "Error: $LIST not found."
  exit 1
fi

# read packages, ignore comments/empty lines
mapfile -t pkgs < <(grep -Ev '^\s*#|^\s*$' "$LIST")

if [[ ${#pkgs[@]} -eq 0 ]]; then
  echo "No packages listed in $LIST"
  exit 0
fi

echo "[INFO] Checking which listed packages are installed..."
installed_pkgs=()
for pkg in "${pkgs[@]}"; do
  if pacman -Qq "$pkg" &>/dev/null; then
    installed_pkgs+=("$pkg")
  else
    echo "[SKIP] $pkg not installed"
  fi
done

if [[ ${#installed_pkgs[@]} -eq 0 ]]; then
  echo "[INFO] None of the listed packages are installed. Nothing to remove."
  exit 0
fi

echo "[INFO] Removing: ${installed_pkgs[*]}"
sudo pacman -Rns --noconfirm "${installed_pkgs[@]}"

echo "[INFO] Removing orphaned dependencies (if any)..."
orphans=$(pacman -Qtdq 2>/dev/null || true)
if [[ -n "$orphans" ]]; then
  sudo pacman -Rns --noconfirm $orphans
  echo "[INFO] Removed orphans: $orphans"
else
  echo "[INFO] No orphans found."
fi

echo "[INFO] Cleaning package cache (keeping last 3 versions)..."
sudo paccache -rk3 2>/dev/null || true

echo "[DONE] Package removal complete."
