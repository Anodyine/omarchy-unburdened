#!/usr/bin/env bash
# add-arch-branding.sh
# Installs Omarchy branding assets: about.txt, screensaver text, Plymouth splash logo, and Waybar icon patch.

set -euo pipefail

info() { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATIC_DIR="static"

get_ref_dir() {
  if [[ -d "${SCRIPT_DIR}/${STATIC_DIR}" ]]; then
    printf "%s\n" "${SCRIPT_DIR}/${STATIC_DIR}"
  elif [[ -d "${HOME}/repos/omarchy-setup/${STATIC_DIR}" ]]; then
    printf "%s\n" "${HOME}/repos/omarchy-setup/${STATIC_DIR}"
  else
    err "Could not find ${STATIC_DIR} directory"
    return 1
  fi
}

install_omarchy_about() {
  local ref_dir
  ref_dir="$(get_ref_dir)" || return 1

  local src="${ref_dir}/about.txt"
  local dest="${HOME}/.config/omarchy/branding/about.txt"

  info "Installing Omarchy about.txt..."

  if [[ ! -f "$src" ]]; then
    warn "Source file not found: $src"
    return 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    info "about.txt already up to date."
    return 0
  fi

  if [[ -f "$dest" ]]; then
    cp -a "$dest" "${dest}.bak.$(date +%Y%m%d-%H%M%S)"
    info "Backed up existing about.txt"
  fi

  cp -f -- "$src" "$dest"
  chmod 0644 "$dest" || true
  info "Installed new about.txt"
}

install_omarchy_screensaver() {
  local ref_dir
  ref_dir="$(get_ref_dir)" || return 1

  local src="${ref_dir}/screensaver.txt"
  local dest="${HOME}/.config/omarchy/branding/screensaver.txt"

  info "Installing Omarchy screensaver text..."

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
    chmod 0644 "$dest" || true
    info "Installed new screensaver.txt"
  fi
}

install_omarchy_splash_logo() {
  local ref_dir
  ref_dir="$(get_ref_dir)" || return 1

  local src="${ref_dir}/logo.png"
  local dest="/usr/share/plymouth/themes/omarchy/logo.png"

  info "Installing Omarchy splash logo..."

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

update_waybar_arch_icon() {
  local config="$HOME/.config/waybar/config.jsonc"
  local backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
  # Glyph can be overridden via env var if you prefer a different icon
  local icon="${WAYBAR_ARCH_ICON:-}"  # Arch logo (Nerd Font)

  info "Updating Waybar Omarchy icon to Arch logo..."

  if [[ ! -f "$config" ]]; then
    warn "Waybar config not found: $config"
    return 1
  fi

  # If the omarchy block already has the desired icon, exit early
  if awk -v want="$icon" '
      BEGIN{inblk=0; depth=0; found=0}
      /"custom\/omarchy"[[:space:]]*:[[:space:]]*\{/ {
        inblk=1
        s=$0; opens=gsub(/{/,"{",s); s=$0; closes=gsub(/}/,"}",s)
        depth += opens - closes
        next
      }
      inblk {
        if ($0 ~ /"format"[[:space:]]*:/ && $0 ~ want) { found=1 }
        s=$0; opens=gsub(/{/,"{",s); s=$0; closes=gsub(/}/,"}",s)
        depth += opens - closes
        if (depth<=0) inblk=0
      }
      END{ exit(found?0:1) }
    ' "$config"; then
    info "Arch logo already set in Waybar omarchy block."
    return 0
  fi

  cp "$config" "$backup"
  info "Backed up Waybar config to $backup"

  awk -v icon="$icon" '
    BEGIN { inblk=0; depth=0 }
    {
      line=$0
      if (!inblk) {
        if (line ~ /"custom\/omarchy"[[:space:]]*:[[:space:]]*\{/) {
          inblk=1
          # update depth using non-destructive counts
          s=line; opens=gsub(/{/,"{",s); s=line; closes=gsub(/}/,"}",s)
          depth += opens - closes
          print line
          next
        }
        print line
        next
      }

      # Inside the custom/omarchy block only
      if (line ~ /"format"[[:space:]]*:/) {
        # Replace just this format value
        sub(/"format"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"format\": \"" icon "\"", line)
      }

      # Maintain depth strictly within this block
      s=line; opens=gsub(/{/,"{",s); s=line; closes=gsub(/}/,"}",s)
      depth += opens - closes
      if (depth <= 0) { inblk=0 }

      print line
    }
  ' "$backup" > "$config"

  info "Waybar Omarchy icon updated to: $icon"
}


main() {
  install_omarchy_about
  install_omarchy_screensaver
  install_omarchy_splash_logo
  update_waybar_arch_icon
  info "Branding applied."
}

main "$@"
