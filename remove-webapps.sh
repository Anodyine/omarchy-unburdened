#!/usr/bin/env bash
set -euo pipefail

APPS_USER="$HOME/.local/share/applications"
MODE="dry"       # default: dry-run
BACKUP=false

usage() {
  echo "Usage: $0 [--apply] [--backup] <remove-webapps.list>"
  echo "  --apply   actually remove files (otherwise dry-run)"
  echo "  --backup  save a tar.gz of matched .desktop files before removal"
  exit 1
}

# Parse flags
args=()
for a in "$@"; do
  case "$a" in
    --apply) MODE="apply" ;;
    --backup) BACKUP=true ;;
    -h|--help) usage ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"

[[ $# -eq 1 ]] || usage
LIST="$1"
[[ -f "$LIST" ]] || { echo "Missing list file: $LIST"; exit 1; }

# Normalize helper: lowercase, strip spaces and ".desktop"
norm() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+//g; s/\.desktop$//'; }

# Load target names
declare -A targets=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
  key="$(norm "$line")"
  [[ -n "$key" ]] && targets["$key"]=1
done < "$LIST"

echo "[INFO] Targets:"
for k in "${!targets[@]}"; do echo "  - $k"; done
echo

# Collect matching desktop files
mapfile -t desks < <(find "$APPS_USER" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null || true)
to_remove=()

for f in "${desks[@]}"; do
  base_no_ext="${f##*/}"; base_no_ext="${base_no_ext%.desktop}"
  nb="$(norm "$base_no_ext")"
  name_line="$(sed -n 's/^Name=\(.*\)$/\1/p' "$f" | head -n1 | tr -d '\r' || true)"
  nn="$(norm "$name_line")"
  exec_line="$(sed -n 's/^Exec=\(.*\)$/\1/p' "$f" | head -n1 | tr -d '\r' || true)"

  match=false
  [[ -n "$nb" && -n "${targets[$nb]+x}" ]] && match=true
  [[ -n "$nn" && -n "${targets[$nn]+x}" ]] && match=true

  looks_web=false
  if echo "$exec_line" | grep -qiE '(^|[[:space:]])(https?://|--app=)'; then
    looks_web=true
  fi

  if $match && $looks_web; then
    to_remove+=("$f")
  fi
done

# Deduplicate
mapfile -t to_remove < <(printf "%s\n" "${to_remove[@]}" | sort -u)

echo "[PLAN] Matched ${#to_remove[@]} .desktop file(s) in $APPS_USER:"
printf '  %s\n' "${to_remove[@]:-}"
echo

if [[ "$MODE" = "dry" ]]; then
  echo "[DRY-RUN] No files will be deleted."
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true
  exit 0
fi

if $BACKUP && [[ ${#to_remove[@]} -gt 0 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$HOME/webapps-backup-$ts.tgz"
  tar -C "$APPS_USER" -czf "$out" $(printf '%s\n' "${to_remove[@]}" | xargs -I{} basename "{}")
  echo "[BACKUP] Saved to $out"
fi

for f in "${to_remove[@]}"; do
  rm -f -- "$f"
done
echo "[DONE] Removed ${#to_remove[@]} .desktop file(s)."

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_USER" >/dev/null 2>&1 || true
echo "[INFO] Launcher index refreshed."
