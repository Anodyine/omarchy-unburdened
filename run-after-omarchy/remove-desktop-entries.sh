#!/usr/bin/env bash
set -euo pipefail

APPS_USER="$HOME/.local/share/applications"
MODE="dry"  # default: dry-run

usage(){ echo "Usage: $0 [--apply] <desktop-entries.list>"; exit 1; }

# parse flags
args=(); for a in "$@"; do
  case "$a" in --apply) MODE="apply";; -h|--help) usage;; *) args+=("$a");; esac
done; set -- "${args[@]}"

[[ $# -eq 1 ]] || usage
LIST="$1"
[[ -f "$LIST" ]] || { echo "Missing list file: $LIST"; exit 1; }

# normalize helper
norm(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+//g; s/\.desktop$//'; }

# load targets
declare -A targets=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
  k="$(norm "$line")"; [[ -n "$k" ]] && targets["$k"]=1
done < "$LIST"

echo "[INFO] Targets:"; for k in "${!targets[@]}"; do echo "  - $k"; done; echo

# scan user desktop entries
mapfile -t desks < <(find "$APPS_USER" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null || true)
to_remove=()

for f in "${desks[@]}"; do
  base_no_ext="${f##*/}"; base_no_ext="${base_no_ext%.desktop}"
  nb="$(norm "$base_no_ext")"
  name_line="$(sed -n 's/^Name=\(.*\)$/\1/p' "$f" | head -n1 || true)"
  nn="$(norm "$name_line")"
  if [[ -n "$nb" && -n "${targets[$nb]+x}" ]] || [[ -n "$nn" && -n "${targets[$nn]+x}" ]]; then
    to_remove+=("$f")
  fi
done

# clean out any blanks before counting
mapfile -t to_remove < <(printf "%s\n" "${to_remove[@]}" | grep -v '^$' | sort -u)

count="${#to_remove[@]}"
echo "[PLAN] ${count} file(s) in $APPS_USER will be removed:"
[[ $count -gt 0 ]] && printf '  %s\n' "${to_remove[@]}"
echo

if [[ "$MODE" = "dry" ]]; then
  echo "[DRY-RUN] No files deleted."
  update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true
  exit 0
fi

# apply
if [[ $count -gt 0 ]]; then
  for f in "${to_remove[@]}"; do rm -f -- "$f"; done
fi
update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true
echo "[DONE] Removed ${count} file(s) and refreshed launcher index."
