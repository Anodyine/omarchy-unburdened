#!/usr/bin/env bash
set -euo pipefail

APPS_USER="$HOME/.local/share/applications"
OMARCHY_LOCAL="$HOME/.local/share/omarchy/applications"
MODE="dry"
BACKUP=false

usage(){ echo "Usage: $0 [--apply] [--backup] <remove-webapps.list>"; exit 1; }

# parse flags
args=(); for a in "$@"; do
  case "$a" in --apply) MODE="apply";; --backup) BACKUP=true;; -h|--help) usage;; *) args+=("$a");; esac
done; set -- "${args[@]}"
[[ $# -eq 1 ]] || usage
LIST="$1"; [[ -f "$LIST" ]] || { echo "Missing list file: $LIST"; exit 1; }

norm(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+//g; s/\.desktop$//'; }

declare -A targets=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
  k="$(norm "$line")"; [[ -n "$k" ]] && targets["$k"]=1
done < "$LIST"

echo "[INFO] Targets:"; for k in "${!targets[@]}"; do echo "  - $k"; done; echo

# collect user .desktop webapps
mapfile -t desks_user < <(find "$APPS_USER" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null || true)
to_rm_user=()
for f in "${desks_user[@]}"; do
  base_no_ext="${f##*/}"; base_no_ext="${base_no_ext%.desktop}"
  nb="$(norm "$base_no_ext")"
  name_line="$(sed -n 's/^Name=\(.*\)$/\1/p' "$f" | head -n1 | tr -d '\r' || true)"
  nn="$(norm "$name_line")"
  exec_line="$(sed -n 's/^Exec=\(.*\)$/\1/p' "$f" | head -n1 | tr -d '\r' || true)"
  match=false; [[ -n "$nb" && -n "${targets[$nb]+x}" ]] && match=true
  [[ -n "$nn" && -n "${targets[$nn]+x}" ]] && match=true
  looks_web=false; echo "$exec_line" | grep -qiE '(^|[[:space:]])(https?://|--app=)' && looks_web=true
  if $match && $looks_web; then to_rm_user+=("$f"); fi
done
mapfile -t to_rm_user < <(printf "%s\n" "${to_rm_user[@]}" | sort -u)

# collect omarchy-local .desktop (exact filename match only, e.g., typora.desktop)
to_rm_omarchy=()
if [[ -d "$OMARCHY_LOCAL" ]]; then
  mapfile -t desks_om < <(find "$OMARCHY_LOCAL" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null || true)
  for f in "${desks_om[@]}"; do
    base_no_ext="${f##*/}"; base_no_ext="${base_no_ext%.desktop}"
    nb="$(norm "$base_no_ext")"
    if [[ -n "$nb" && -n "${targets[$nb]+x}" ]]; then to_rm_omarchy+=("$f"); fi
  done
  mapfile -t to_rm_omarchy < <(printf "%s\n" "${to_rm_omarchy[@]}" | sort -u)
fi

echo "[PLAN] User webapp .desktop to remove: ${#to_rm_user[@]}"; printf '  %s\n' "${to_rm_user[@]:-}"
echo "[PLAN] Omarchy-local .desktop to remove: ${#to_rm_omarchy[@]}"; printf '  %s\n' "${to_rm_omarchy[@]:-}"
echo

if [[ "$MODE" = "dry" ]]; then
  echo "[DRY-RUN] No files deleted."; command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true; exit 0
fi

if $BACKUP && { [[ ${#to_rm_user[@]} -gt 0 ]] || [[ ${#to_rm_omarchy[@]} -gt 0 ]]; }; then
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$HOME/webapps-backup-$ts.tgz"
  tar -czf "$out" \
    $(printf '%s\n' "${to_rm_user[@]}"     | sed "s|^$APPS_USER/||" | xargs -r -I{} echo "-C" "$APPS_USER" "{}") \
    $(printf '%s\n' "${to_rm_omarchy[@]}"  | sed "s|^$OMARCHY_LOCAL/||" | xargs -r -I{} echo "-C" "$OMARCHY_LOCAL" "{}") 2>/dev/null || true
  echo "[BACKUP] Saved to $out"
fi

for f in "${to_rm_user[@]}"; do rm -f -- "$f"; done
for f in "${to_rm_omarchy[@]}"; do rm -f -- "$f"; done

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true
echo "[DONE] Removed ${#to_rm_user[@]} user entries and ${#to_rm_omarchy[@]} omarchy-local entries."
