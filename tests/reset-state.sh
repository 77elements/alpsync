#!/bin/bash
#
# tests/reset-state.sh — dev-only helper to undo manual test runs of alpsync
# on the real system.
#
#   --mark            set the time marker (run BEFORE a manual test)
#   --archives        delete unison archives NEWER than the marker, with
#                     listing + confirmation (older/production archives are
#                     never touched)
#   --configs         delete *.conf next to alpsync.sh (listing + confirm)
#   --alias           remove the alpsync marker block from shell rc files
#   --dirs p1 [p2..]  remove throwaway test directories (confirm)
#
# NEVER run --archives without a preceding --mark in the same test session.

set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
MARKER="${ALPSYNC_TEST_MARKER:-$HOME/.alpsync-test-marker}"
ALS_MARKER_BEGIN="# >>> alpsync >>>"
# shellcheck disable=SC2034  # documentation of the closing marker
ALS_MARKER_END="# <<< alpsync <<<"

unison_dirs() {
  local d
  for d in "${UNISON:-}" "$HOME/.unison" "$HOME/Library/Application Support/Unison"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      printf '%s\n' "$d"
    fi
  done
  return 0
}

confirm() {
  local ans
  printf '%s [y/N]: ' "$1"
  IFS= read -r ans || return 1
  case "$ans" in
    y|Y|yes) return 0 ;;
    *)       return 1 ;;
  esac
}

cmd_mark() {
  : >"$MARKER"
  echo "Marker set: $MARKER ($(date))"
  echo "Run your manual alpsync test now; later: $0 --archives"
}

cmd_archives() {
  if [ ! -f "$MARKER" ]; then
    echo "No marker found ($MARKER)."
    echo "Run '$0 --mark' BEFORE the test you want to undo." >&2
    exit 2
  fi
  local d f total=0
  local -a victims=()
  while IFS= read -r d; do
    while IFS= read -r f; do
      victims+=("$f")
    done < <(find "$d" -maxdepth 1 \( -name 'ar*' -o -name 'fp*' \) -newer "$MARKER" 2>/dev/null)
  done < <(unison_dirs)
  if [ "${#victims[@]}" -eq 0 ]; then
    echo "No unison archives newer than the marker. Nothing to do."
    return 0
  fi
  echo "Archives newer than $(date -r "$MARKER" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo marker):"
  for f in "${victims[@]}"; do
    echo "  $f"
    total=$((total + 1))
  done
  if confirm "Delete these $total archive file(s)?"; then
    rm -f "${victims[@]}"
    echo "Deleted."
  else
    echo "Aborted - nothing deleted."
  fi
}

cmd_configs() {
  local f n=0
  local -a confs=()
  for f in "$ROOT"/*.conf; do
    [ -f "$f" ] || continue
    confs+=("$f")
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    echo "No config files in $ROOT."
    return 0
  fi
  echo "Config files in $ROOT:"
  for f in "${confs[@]}"; do
    echo "  $f"
  done
  if confirm "Delete these $n config file(s)?"; then
    rm -f "${confs[@]}"
    echo "Deleted."
  else
    echo "Aborted - nothing deleted."
  fi
}

cmd_alias() {
  local f tmp found=0
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$f" ] || continue
    grep -qF "$ALS_MARKER_BEGIN" "$f" 2>/dev/null || continue
    found=1
    echo "Cleaning: $f"
    tmp=$(mktemp "${TMPDIR:-/tmp}/alpsync-reset.XXXXXX") || exit 1
    awk '
      /^# >>> alpsync >>>[[:space:]]*$/ { skip = 1 }
      skip == 0 { print }
      /^# <<< alpsync <<<[[:space:]]*$/ { skip = 0 }
    ' "$f" >"$tmp" && cat "$tmp" >"$f"
    rm -f "$tmp"
  done
  [ "$found" -eq 1 ] || echo "No alpsync alias block found."
}

cmd_dirs() {
  if [ $# -eq 0 ]; then
    echo "Usage: $0 --dirs <path> [path..]" >&2
    exit 2
  fi
  local d
  for d in "$@"; do
    if [ ! -e "$d" ]; then
      echo "skip (missing): $d"
      continue
    fi
    if confirm "Remove directory '$d'?"; then
      rm -rf "$d"
      echo "Removed: $d"
    fi
  done
}

case "${1:-}" in
  --mark)     cmd_mark ;;
  --archives) cmd_archives ;;
  --configs)  cmd_configs ;;
  --alias)    cmd_alias ;;
  --dirs)     shift; cmd_dirs "$@" ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
