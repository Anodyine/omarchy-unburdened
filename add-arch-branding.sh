#!/usr/bin/env bash
# add-arch-branding.sh
# Installs Arch branding assets: screensaver text and Plymouth splash logo.

set -euo pipefail

info() { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

install_arch_screensaver() {
  local src="${HOME}/repos/omarchy-setup/reference-files/screensaver.txt"
  local dest="${HOME}/.config/omarchy/branding/screensaver.txt"

  info "Installing Arch screensaver text..."

  if [[ ! -f "$src" ]]; then
    warn "Source file not found: $src"
    return 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    info "Screensaver already up to date."
  else
    if [[ -f "$dest" ]]; then
      cp "$dest" "${dest}.bak.$(date +%Y%m%d-%H%M%S)"
      info "Backed up existing screensaver.txt"
    fi
    cp "$src" "$dest"
    info "Installed new screensaver.txt"
  fi
}

install_arch_splash_logo() {
  local src="${HOME}/repos/omarchy-unburdened/reference-files/logo.png"
  local dest="/usr/share/plymouth/themes/omarchy/logo.png"

  info "Installing Arch splash logo..."

  if [[ ! -f "$src" ]]; then
    warn "Source file not found: $src"
    return 1
  fi

  if [[ -f "$dest" ]] && sudo cmp -s "$src" "$dest"; then
    info "Logo already up to date."
  else
    if [[ -f "$dest" ]]; then
      sudo cp "$dest" "${dest}.bak.$(date +%Y%m%d-%H%M%S)"
      info "Backed up existing logo.png"
    fi
    sudo install -D -m 0644 "$src" "$dest"
    sudo plymouth-set-default-theme omarchy
    info "Installed new logo.png rebuilding initramfs"
    sudo limine-mkinitcpio -P
    info "Installed new logo.png."
  fi
}

main() {
  install_arch_screensaver
  install_arch_splash_logo
  info "Branding applied."
}

main "$@"