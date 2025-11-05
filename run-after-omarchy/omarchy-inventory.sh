#!/usr/bin/env bash
# omarchy-inventory.sh
set -euo pipefail

timestamp="$(date +%Y%m%d-%H%M%S)"
outdir="$HOME/omarchy-inventory/$timestamp"
mkdir -p "$outdir"

log(){ printf "[INV] %s\n" "$*"; }

# ---------- pacman (native + foreign) ----------
log "Collecting pacman package lists"
# All installed (names only)
pacman -Qq            | sort -u > "$outdir/pacman_all.txt"
# Explicitly installed by user (top level)
pacman -Qqe           | sort -u > "$outdir/pacman_explicit.txt"
# Explicit and not required by others (useful to see big top-level adds)
pacman -Qet           | sort -u > "$outdir/pacman_explicit_not_required.txt"
# Dependencies (not explicitly installed)
pacman -Qqd          | sort -u > "$outdir/pacman_deps.txt" || true
# Foreign packages (AUR or manual)
pacman -Qqm           | sort -u > "$outdir/pacman_foreign.txt" || true
# Native only (repo packages)
pacman -Qqn           | sort -u > "$outdir/pacman_native.txt" || true

# Sizes for quick triage (top 50)
log "Collecting size info"
{ 
  pacman -Qi | awk '
    BEGIN{pkg="";size=0}
    /^Name/{pkg=$3}
    /^Installed Size/{ 
      # normalize units to KiB
      s=$4; u=$5;
      if(u=="MiB") v=s*1024;
      else if(u=="GiB") v=s*1024*1024;
      else if(u=="KiB") v=s;
      else v=s;
      printf "%-40s %12.0f KiB\n", pkg, v
    }' | sort -k2 -nr | head -n 50
} > "$outdir/pacman_top_sizes.txt"

# Potential orphans (not needed by any installed pkg)
log "Collecting orphaned dependencies"
pacman -Qtdq > "$outdir/pacman_orphans.txt" 2>/dev/null || true

# ---------- helpers (yay/paru) ----------
log "Collecting AUR helper states if present"
if command -v yay >/dev/null 2>&1; then
  yay -Qm   | sort -u > "$outdir/yay_foreign_detail.txt" || true
  yay -Qi $(yay -Qmq 2>/dev/null) > "$outdir/yay_foreign_qi.txt" 2>/dev/null || true
fi
if command -v paru >/dev/null 2>&1; then
  paru -Qm  | sort -u > "$outdir/paru_foreign_detail.txt" || true
  paru -Qi $(paru -Qmq 2>/dev/null) > "$outdir/paru_foreign_qi.txt" 2>/dev/null || true
fi

# ---------- flatpak ----------
if command -v flatpak >/dev/null 2>&1; then
  log "Collecting Flatpak lists"
  flatpak list --app --columns=application,ref,origin,installation > "$outdir/flatpak_apps.tsv" || true
  flatpak remotes --columns=name,url > "$outdir/flatpak_remotes.tsv" || true
else
  log "Flatpak not installed"
fi

# ---------- snap (rare on Arch, but check) ----------
if command -v snap >/dev/null 2>&1; then
  log "Collecting Snap list"
  snap list > "$outdir/snap_list.txt" || true
fi

# ---------- web apps and .desktop entries ----------
log "Scanning for Chromium based web apps and Omarchy web entries"
apps_dir_user="$HOME/.local/share/applications"
apps_dir_sys="/usr/share/applications"
# Look for chromium --app=, brave --app=, or strings that look like Omarchy web shortcuts
grep -RIlE 'Exec=.*(chromium|google-chrome|brave).*--app=' "$apps_dir_user" "$apps_dir_sys" 2>/dev/null \
  | sort -u > "$outdir/webapps_desktop_files.txt" || true

# Try to capture Omarchy-tagged desktop files too (adjust pattern if your build uses a tag)
grep -RIlE '(Omarchy Web App|omarchy-webapp|omarchy)' "$apps_dir_user" "$apps_dir_sys" 2>/dev/null \
  | sort -u > "$outdir/webapps_desktop_files_omarchy_tag.txt" || true

# Dump summaries of discovered .desktop files
{
  while IFS= read -r f; do
    echo "---- $f ----"
    sed -n '1,120p' "$f" | sed 's/\r$//'
    echo
  done < "$outdir/webapps_desktop_files.txt"
} > "$outdir/webapps_desktop_files_summary.txt" 2>/dev/null || true

# ---------- enabled services and autostart ----------
log "Collecting enabled services"
systemctl list-unit-files --state=enabled --type=service > "$outdir/systemd_enabled_services.txt"
systemctl --user list-unit-files --state=enabled --type=service > "$outdir/systemd_user_enabled_services.txt" || true

log "Collecting autostart entries"
mkdir -p "$outdir/autostart"
ls -la "$HOME/.config/autostart" > "$outdir/autostart/user_autostart_ls.txt" 2>/dev/null || true
ls -la /etc/xdg/autostart > "$outdir/autostart/system_autostart_ls.txt" 2>/dev/null || true
grep -RIl . "$HOME/.config/autostart" 2>/dev/null | xargs -r sed -n '1,120p' > "$outdir/autostart/user_autostart_contents.txt" 2>/dev/null || true

# ---------- waybar modules that may pull deps ----------
log "Collecting Waybar config references"
if [[ -d "$HOME/.config/waybar" ]]; then
  grep -RIn . "$HOME/.config/waybar" > "$outdir/waybar_config_grep.txt" || true
fi

# ---------- hyprland exec-once (to see what gets started) ----------
if [[ -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  log "Collecting Hyprland exec-once entries"
  grep -En '^\s*exec-once\s*=' "$HOME/.config/hypr/hyprland.conf" > "$outdir/hypr_exec_once.txt" || true
fi

# ---------- summary ----------
log "Done. Inventory saved to: $outdir"

echo
echo "Next steps:"
echo "1) Review $outdir/pacman_explicit_not_required.txt and $outdir/pacman_foreign.txt for top-level adds."
echo "2) Review Flatpaks in $outdir/flatpak_apps.tsv."
echo "3) Review Chromium web apps in $outdir/webapps_desktop_files_summary.txt."
echo "4) Share the directory path with me and I will generate a precise debloat script."

