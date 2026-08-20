#!/bin/bash
#
# alpsync — general-purpose bidirectional folder sync via unison (macOS + Linux)
#
# Single-file tool. Config files (*.conf) live in the same directory as this
# script. Run without arguments for a configuration menu (with an option to
# create a new config via wizard), or pass a config name/path directly:
#
#   ./alpsync.sh              Select configuration (or create a new one)
#   ./alpsync.sh <config>     Run a configuration (name, name.conf, or path)
#   ./alpsync.sh --help       Show help
#   ./alpsync.sh --version    Show version
#
# Sync method (proven over months of daily production use):
#   unison -auto -batch -times -perms 0 -rsrc false -prefer newer -confirmbigdel
#   First run per pair = UNION merge (no archive yet: nothing is deleted).
#   Later runs propagate changes and deletions both ways; conflicts resolve
#   to the newer file; mass deletions are guarded by -confirmbigdel.
#
# See README.md for usage and documentation.

set -euo pipefail

ALPSYNC_VERSION="0.1.0-beta"

# ==========================================================================
# Bootstrap
# ==========================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "alpsync: must be run with bash (./alpsync.sh)" >&2
  exit 2
fi

ALS_SCRIPT_PATH=""
ALS_SCRIPT_DIR=""

resolve_script_path() {
  local src="${BASH_SOURCE[0]}"
  local dir=""
  while [ -L "$src" ]; do
    dir=$(cd -P -- "$(dirname -- "$src")" && pwd -P)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  dir=$(cd -P -- "$(dirname -- "$src")" && pwd -P)
  ALS_SCRIPT_PATH="$dir/$(basename -- "$src")"
  ALS_SCRIPT_DIR="$dir"
}
resolve_script_path

# ==========================================================================
# State file — alpsync.state (archive registry + managed-package tracking)
# ==========================================================================

ALS_STATE_FILE=""
STATE_KEYS=()
STATE_VALS=()
STATE_VALUE=""

state_init() {
  ALS_STATE_FILE="$ALS_SCRIPT_DIR/alpsync.state"
}

state_load() {
  STATE_KEYS=()
  STATE_VALS=()
  [ -f "$ALS_STATE_FILE" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    STATE_KEYS+=("${line%%=*}")
    STATE_VALS+=("${line#*=}")
  done <"$ALS_STATE_FILE"
  return 0
}

state_save() {
  local tmp i
  tmp=$(mktemp "${TMPDIR:-/tmp}/alpsync-state.XXXXXX") || return 1
  {
    printf '# alpsync state file - managed by alpsync.sh.\n'
    printf '# Safe to delete; alpsync then forgets managed packages and archives.\n'
    for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
      printf '%s=%s\n' "${STATE_KEYS[$i]}" "${STATE_VALS[$i]}"
    done
  } >"$tmp" && mv "$tmp" "$ALS_STATE_FILE"
}

state_get() {
  local key="$1" i
  STATE_VALUE=""
  state_load
  for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
    if [ "${STATE_KEYS[$i]}" = "$key" ]; then
      STATE_VALUE="${STATE_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

state_set() {
  local key="$1" val="$2" i found=0
  state_load
  for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
    if [ "${STATE_KEYS[$i]}" = "$key" ]; then
      STATE_VALS[i]="$val"
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    STATE_KEYS+=("$key")
    STATE_VALS+=("$val")
  fi
  state_save
}

state_unset() {
  local key="$1" i
  state_load
  local -a nk=() nv=()
  for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
    if [ "${STATE_KEYS[$i]}" != "$key" ]; then
      nk+=("${STATE_KEYS[$i]}")
      nv+=("${STATE_VALS[$i]}")
    fi
  done
  STATE_KEYS=()
  STATE_VALS=()
  for i in ${nk[@]+"${!nk[@]}"}; do
    STATE_KEYS+=("${nk[$i]}")
    STATE_VALS+=("${nv[$i]}")
  done
  state_save
}

state_unset_prefix() {
  local pre="$1" i
  state_load
  local -a nk=() nv=()
  for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
    case "${STATE_KEYS[$i]}" in
      "$pre"*) ;;
      *)
        nk+=("${STATE_KEYS[$i]}")
        nv+=("${STATE_VALS[$i]}")
        ;;
    esac
  done
  STATE_KEYS=()
  STATE_VALS=()
  for i in ${nk[@]+"${!nk[@]}"}; do
    STATE_KEYS+=("${nk[$i]}")
    STATE_VALS+=("${nv[$i]}")
  done
  state_save
}

this_hostname() {
  hostname 2>/dev/null || uname -n
}

# Records a package installed by alpsync (prefix: UNISON|SSH).
mark_managed() {
  local prefix="$1" installer="$2" pkg="${3:-}"
  state_set "${prefix}_MANAGED" "1"
  state_set "${prefix}_INSTALLER" "$installer"
  state_set "${prefix}_INSTALL_HOST" "$(this_hostname)"
  state_set "${prefix}_INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -n "$pkg" ]; then
    state_set "${prefix}_PKG" "$pkg"
  fi
}

# True if a managed install belongs to THIS machine (protects a copied
# script directory from uninstalling packages on a different host).
managed_install_matches_host() {
  state_get "${1}_INSTALL_HOST"
  [ -n "$STATE_VALUE" ] || return 1
  [ "$(printf '%s' "$STATE_VALUE" | tr '[:upper:]' '[:lower:]')" \
    = "$(this_hostname | tr '[:upper:]' '[:lower:]')" ]
}

# Records a package installed by alpsync ON a remote host via SSH.
mark_remote_managed() {
  local installer="$1" target="$2"
  state_set "REMOTE_UNISON_MANAGED" "1"
  state_set "REMOTE_UNISON_INSTALLER" "$installer"
  state_set "REMOTE_UNISON_TARGET" "$target"
  state_set "REMOTE_UNISON_INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# ==========================================================================
# UI kit — Norton-Commander-style, pure bash + ANSI, non-TTY fallback
# ==========================================================================

C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_SEL=''

ui_init() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
    C_SEL=$'\033[7m'
  fi
}

is_tty() { [ -t 0 ]; }

ui_msg()    { printf '%s\n' "$*"; }
ui_ok()     { printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
ui_warn()   { printf '%s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
ui_err()    { printf '%s✖ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
ui_hint()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

ui_header() {
  local title="$1" width=60 fill
  if [ "${#title}" -lt "$width" ]; then
    fill=$((width - ${#title} - 3))
  else
    fill=0
  fi
  printf '%s── %s%s%s ' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET$C_BOLD"
  printf '%*s' "$fill" '' | tr ' ' '─'
  printf '%s\n' "$C_RESET"
}

ui_separator() {
  printf '%s\n' "──────────────────────────────────────────"
}

# Draws a box of "Key : value" lines. $1 = title, rest = "Key:Value" lines.
ui_summary_box() {
  local title="$1"
  shift
  local -a rows=("$@")
  local inner=0 len key val w pad
  for row in "${rows[@]}"; do
    key="${row%%:*}"
    val="${row#*:}"
    len=$(( ${#key} + ${#val} + 3 ))
    if [ "$len" -gt "$inner" ]; then inner=$len; fi
  done
  if [ "${#title}" -gt "$inner" ]; then inner=${#title}; fi
  inner=$((inner + 2))
  local bar
  bar=$(printf '%*s' "$inner" '' | tr ' ' '─')
  printf '┌─ %s ' "$title"
  printf '%*s' "$((inner - ${#title} - 4))" '' | tr ' ' '─'
  printf '┐\n'
  for row in "${rows[@]}"; do
    key="${row%%:*}"
    val="${row#*:}"
    w=$((inner - ${#key} - ${#val} - 5))
    if [ "$w" -lt 0 ]; then w=0; fi
    pad=$(printf '%*s' "$w" '')
    printf '│ %s : %s%s │\n' "$key" "$val" "$pad"
  done
  printf '└%s┘\n' "$bar"
}

# Two-column pair preview table. Args: local1 … localN remote1 … remoteN.
ui_pairs_table() {
  local total=$#
  local nr=$((total / 2))
  local -a loc=() rem=()
  local i
  for ((i = 1; i <= nr; i++)); do
    loc+=("${!i}")
  done
  for ((i = nr + 1; i <= total; i++)); do
    rem+=("${!i}")
  done
  local w1=6 w2=6 bar1 bar2
  for ((i = 0; i < nr; i++)); do
    if [ "${#loc[$i]}" -gt "$w1" ]; then w1=${#loc[$i]}; fi
    if [ "${#rem[$i]}" -gt "$w2" ]; then w2=${#rem[$i]}; fi
  done
  bar1=$(printf '%*s' "$((w1 + 2))" '' | tr ' ' '─')
  bar2=$(printf '%*s' "$((w2 + 2))" '' | tr ' ' '─')
  printf '┌─ Local '
  printf '%*s' "$((w1 - 3))" '' | tr ' ' '─'
  printf '┬─ Remote '
  printf '%*s' "$((w2 - 3))" '' | tr ' ' '─'
  printf '┐\n'
  for ((i = 0; i < nr; i++)); do
    printf '│ %-*s │ %-*s │\n' "$w1" "${loc[$i]}" "$w2" "${rem[$i]}"
  done
  printf '└%s┴%s┘\n' "$bar1" "$bar2"
}

# Prints all arguments joined by double spaces, wrapped at ~66 columns
# with a 4-space indent (used to display grouped ignore patterns).
ui_wrap_list() {
  [ $# -gt 0 ] || return 0
  local indent='    ' line='' pat w
  for pat in "$@"; do
    w=$(( ${#line} + ${#pat} + 2 ))
    if [ -n "$line" ] && [ "$w" -gt 66 ]; then
      printf '%s%s\n' "$indent" "$line"
      line="$pat"
    else
      line="${line:+$line  }$pat"
    fi
  done
  [ -n "$line" ] && printf '%s%s\n' "$indent" "$line"
  return 0
}

MENU_RESULT=""
# Returns selected index in MENU_RESULT; rc 1 = cancelled.
ui_menu() {
  local title="$1"
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local sel=0 i key esc choice lines first=1

  if ! is_tty; then
    echo ""
    ui_msg "$title"
    for ((i = 0; i < n; i++)); do
      printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}"
    done
    while :; do
      printf 'Select [1-%d] (q=quit): ' "$n"
      choice=""
      if ! IFS= read -r choice && [ -z "$choice" ]; then
        echo ""
        return 1
      fi
      case "$choice" in
        q|Q) return 1 ;;
        ''|*[!0-9]*) ui_hint "Enter a number between 1 and $n." ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
            MENU_RESULT=$((choice - 1))
            return 0
          fi
          ui_hint "Enter a number between 1 and $n." ;;
      esac
    done
  fi

  while :; do
    if [ "$first" -eq 0 ]; then
      printf '\033[%dA\033[J' "$lines"
    fi
    first=0
    lines=1
    printf '%s\n' "$title"
    for ((i = 0; i < n; i++)); do
      if [ "$i" -eq "$sel" ]; then
        printf '%s → %s %s\n' "$C_SEL" "${items[$i]}" "$C_RESET"
      else
        printf '   %s\n' "${items[$i]}"
      fi
      lines=$((lines + 1))
    done
    printf '%s ↑/↓ or j/k move · Enter select · q quit%s\n' "$C_DIM" "$C_RESET"
    lines=$((lines + 1))
    key=""
    IFS= read -rsn1 key || return 1
    case "$key" in
      $'\033')
        esc=""
        IFS= read -rsn2 -t 1 esc || true
        case "$esc" in
          '[A') sel=$(((sel + n - 1) % n)) ;;
          '[B') sel=$(((sel + 1) % n)) ;;
        esac
        ;;
      j|J) sel=$(((sel + 1) % n)) ;;
      k|K) sel=$(((sel + n - 1) % n)) ;;
      '')  MENU_RESULT=$sel; printf '\n'; return 0 ;;
      q|Q) return 1 ;;
    esac
  done
}

INPUT_RESULT=""
# $1 prompt, $2 hint (optional), $3 default (optional). rc 1 = EOF/cancel.
ui_input() {
  local prompt="$1" hint="${2:-}" default="${3:-}"
  ui_msg "$prompt"
  if [ -n "$hint" ]; then ui_hint "$hint"; fi
  if [ -n "$default" ]; then
    printf '  [%s] > ' "$default"
  else
    printf '  > '
  fi
  INPUT_RESULT=""
  if ! IFS= read -r INPUT_RESULT && [ -z "$INPUT_RESULT" ]; then
    return 1
  fi
  if [ -z "$INPUT_RESULT" ]; then
    INPUT_RESULT="$default"
  fi
  return 0
}

# $1 question, $2 default (y|n). rc 0 = yes, rc 1 = no/EOF.
ui_confirm() {
  local q="$1" def="${2:-y}" ans
  while :; do
    if [ "$def" = "y" ]; then
      printf '%s [Y/n]: ' "$q"
    else
      printf '%s [y/N]: ' "$q"
    fi
    ans=""
    if ! IFS= read -r ans && [ -z "$ans" ]; then
      return 1
    fi
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      '')
        if [ "$def" = "y" ]; then return 0; fi
        return 1
        ;;
      *) ui_hint "Please answer y or n." ;;
    esac
  done
}

MULTILINE_RESULT=()
# $1 prompt, rest = hint lines shown above the input loop.
# Reads lines until an empty line; collected in MULTILINE_RESULT. rc 1 = EOF.
ui_multiline() {
  local prompt="$1"
  shift
  local line
  MULTILINE_RESULT=()
  ui_msg "$prompt"
  local h
  for h in "$@"; do
    ui_hint "  $h"
  done
  while :; do
    printf '  > '
    line=""
    if ! IFS= read -r line && [ -z "$line" ]; then
      return 1
    fi
    if [ -z "$line" ]; then
      return 0
    fi
    MULTILINE_RESULT+=("$line")
  done
}

# ==========================================================================
# Dependency layer — OS detection, unison/ssh checks, consent-based installs
# ==========================================================================

OS_KIND="" PKG_MGR=""

detect_os() {
  local k
  k=$(uname)
  case "$k" in
    Darwin) OS_KIND="darwin" ;;
    Linux)  OS_KIND="linux" ;;
    *)
      ui_err "Unsupported operating system: $k (supported: macOS, Linux)"
      exit 2
      ;;
  esac
  PKG_MGR=""
  local mgr
  for mgr in apt-get dnf yum pacman zypper apk; do
    if command -v "$mgr" >/dev/null 2>&1; then
      PKG_MGR="$mgr"
      break
    fi
  done
}

pkg_for_unison() {
  case "$PKG_MGR" in
    apt-get|dnf|yum|pacman|zypper|apk) printf '%s\n' "unison" ;;
    *) printf '%s\n' "" ;;
  esac
}

pkg_for_ssh() {
  case "$PKG_MGR" in
    apt-get|apk) printf '%s\n' "openssh-client" ;;
    dnf|yum)     printf '%s\n' "openssh-clients" ;;
    pacman)      printf '%s\n' "openssh" ;;
    zypper)      printf '%s\n' "openssh" ;;
    *)           printf '%s\n' "" ;;
  esac
}

UNISON_BIN=""

ensure_unison_local() {
  if command -v unison >/dev/null 2>&1; then
    UNISON_BIN=$(command -v unison)
    return 0
  fi
  echo ""
  ui_warn "unison is required but not installed."

  if [ "$OS_KIND" = "darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
      if ui_confirm "Install unison now with 'brew install unison'?" "y"; then
        if brew install unison; then
          state_init
          mark_managed UNISON brew
        fi
      else
        dep_declined "brew install unison"
      fi
    else
      ui_msg "Homebrew is required to install unison on macOS."
      ui_msg "alpsync never installs Homebrew automatically. Run this yourself:"
      ui_msg ""
      ui_msg "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      ui_msg "  brew install unison"
      exit 3
    fi
  else
    if [ -n "$PKG_MGR" ]; then
      local pkg
      pkg=$(pkg_for_unison)
      if ui_confirm "Install unison now with 'sudo $PKG_MGR install -y $pkg'?" "y"; then
        if sudo "$PKG_MGR" install -y "$pkg"; then
          state_init
          mark_managed UNISON "$PKG_MGR" "$pkg"
        fi
      else
        dep_declined "sudo $PKG_MGR install -y $pkg"
      fi
    else
      ui_msg "No supported package manager found (apt/dnf/yum/pacman/zypper/apk)."
      ui_msg "Install unison manually, then run alpsync again:"
      ui_msg "  https://github.com/bcpierce003/unison/wiki/Downloading-Unison"
      exit 3
    fi
  fi

  if command -v unison >/dev/null 2>&1; then
    UNISON_BIN=$(command -v unison)
    ui_ok "unison installed: $UNISON_BIN"
    return 0
  fi
  ui_err "unison still not found after installation attempt."
  exit 3
}

ensure_ssh_client() {
  if command -v ssh >/dev/null 2>&1; then
    return 0
  fi
  echo ""
  ui_warn "An SSH client is required for this configuration but is not installed."
  if [ "$OS_KIND" = "darwin" ]; then
    ui_msg "Install the macOS Command Line Tools, then run alpsync again:"
    ui_msg "  xcode-select --install"
    exit 3
  fi
  if [ -n "$PKG_MGR" ]; then
    local pkg
    pkg=$(pkg_for_ssh)
    if ui_confirm "Install an SSH client now with 'sudo $PKG_MGR install -y $pkg'?" "y"; then
      if sudo "$PKG_MGR" install -y "$pkg"; then
        state_init
        mark_managed SSH "$PKG_MGR" "$pkg"
      fi
    else
      dep_declined "sudo $PKG_MGR install -y $pkg"
    fi
  else
    ui_msg "No supported package manager found. Install openssh manually, then run alpsync again."
    exit 3
  fi
  if command -v ssh >/dev/null 2>&1; then
    ui_ok "SSH client installed."
    return 0
  fi
  ui_err "SSH client still not found after installation attempt."
  exit 3
}

dep_declined() {
  ui_err "Dependency installation declined. Install manually, then run alpsync again:"
  ui_msg "  $1"
  exit 3
}

# Prints "major.minor" of a unison binary. $1 = binary, $2 = "" | remote spec
unison_version() {
  local bin="$1" remote="${2:-}" out
  if [ -n "$remote" ]; then
    out=$(ssh_target "$remote" "$bin -version" 2>/dev/null) || out=""
  else
    out=$("$bin" -version 2>/dev/null) || out=""
  fi
  printf '%s\n' "$out" | sed -n '1s/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# ==========================================================================
# Config — discovery, parsing, validation, helpers
# ==========================================================================

CONFIG_FILES=()

discover_configs() {
  CONFIG_FILES=()
  local f
  for f in "$ALS_SCRIPT_DIR"/*.conf; do
    if [ -f "$f" ]; then
      CONFIG_FILES+=("$f")
    fi
  done
}

EXTRACTED=()
# Extracts all "..." strings from $1 into EXTRACTED.
extract_quoted() {
  local rest="$1" m
  EXTRACTED=()
  while [[ "$rest" =~ \"([^\"]*)\" ]]; do
    m="${BASH_REMATCH[1]}"
    EXTRACTED+=("$m")
    rest="${rest#*\""$m"\"}"
  done
}

expand_path() {
  case "$1" in
    '~')    printf '%s\n' "$HOME" ;;
    '~'/*)  printf '%s/%s\n' "$HOME" "${1#'~'/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# SSH remote-path normalization: unison ssh:// roots are relative to the
# remote home directory, so a leading '~/' (or a lone '~') must be stripped.
# Applied when writing configs and again at sync time (hand-edited configs).
normalize_remote_path() {
  case "$1" in
    '~')    printf '' ;;
    '~'/*)  printf '%s' "${1#'~'/}" ;;
    *)      printf '%s' "$1" ;;
  esac
}

trim_var() {
  local v=""
  IFS=$' \t' read -r v <<<"$1" || true
  TRIMMED="$v"
}

sanitize_name() {
  printf '%s' "$1" | sed -e 's/[^A-Za-z0-9._-]/_/g' -e 's/^\.*//'
}

is_dir_empty() {
  [ -d "$1" ] || return 2
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

# CFG_* globals set by load_config
CFG_LABEL="" CFG_MODE="" CFG_NAME=""
CFG_REMOTE_HOST="" CFG_REMOTE_USER="" CFG_REMOTE_PORT="" CFG_REMOTE_UNISON=""
CFG_PAIRS=()
CFG_EXTRA_IGNORES=()

load_config() {
  local f="$1" line key val in_array="" m
  CFG_NAME=$(basename -- "$f" .conf)
  CFG_LABEL="$CFG_NAME"
  CFG_MODE=""
  CFG_REMOTE_HOST="" CFG_REMOTE_USER="" CFG_REMOTE_PORT="" CFG_REMOTE_UNISON=""
  CFG_PAIRS=()
  CFG_EXTRA_IGNORES=()

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if [ -n "$in_array" ]; then
      case "$line" in
        *')'*)
          m="${line%%)*}"
          if [ -n "$m" ]; then
            extract_quoted "$m"
            if [ "$in_array" = "PAIRS" ]; then
              CFG_PAIRS+=("${EXTRACTED[@]+${EXTRACTED[@]}}")
            else
              CFG_EXTRA_IGNORES+=("${EXTRACTED[@]+${EXTRACTED[@]}}")
            fi
          fi
          in_array=""
          continue
          ;;
      esac
      extract_quoted "$line"
      if [ "$in_array" = "PAIRS" ]; then
        CFG_PAIRS+=("${EXTRACTED[@]+${EXTRACTED[@]}}")
      else
        CFG_EXTRA_IGNORES+=("${EXTRACTED[@]+${EXTRACTED[@]}}")
      fi
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$key" in
        LABEL)         CFG_LABEL="${val%\"}"; CFG_LABEL="${CFG_LABEL#\"}" ;;
        MODE)          trim_var "$val"; CFG_MODE=$(printf '%s' "$TRIMMED" | tr -d '"' | tr '[:upper:]' '[:lower:]') ;;
        REMOTE_HOST)   CFG_REMOTE_HOST="${val%\"}"; CFG_REMOTE_HOST="${CFG_REMOTE_HOST#\"}" ;;
        REMOTE_USER)   CFG_REMOTE_USER="${val%\"}"; CFG_REMOTE_USER="${CFG_REMOTE_USER#\"}" ;;
        REMOTE_PORT)   CFG_REMOTE_PORT="${val%\"}"; CFG_REMOTE_PORT="${CFG_REMOTE_PORT#\"}" ;;
        REMOTE_UNISON) CFG_REMOTE_UNISON="${val%\"}"; CFG_REMOTE_UNISON="${CFG_REMOTE_UNISON#\"}" ;;
        PAIRS|EXTRA_IGNORES)
          val="${val#\(}"
          val="${val%\)}"
          extract_quoted "$val"
          if [ "${#EXTRACTED[@]}" -gt 0 ]; then
            if [ "$key" = "PAIRS" ]; then
              CFG_PAIRS+=("${EXTRACTED[@]}")
            else
              CFG_EXTRA_IGNORES+=("${EXTRACTED[@]}")
            fi
          else
            in_array="$key"
          fi
          ;;
        *) ;; # unknown keys are ignored (forward compatibility)
      esac
    fi
  done <"$f"

  if [ -z "$CFG_MODE" ]; then
    ui_err "Config error in $f: MODE is missing (expected 'ssh' or 'local')."
    exit 2
  fi
  if [ "$CFG_MODE" != "ssh" ] && [ "$CFG_MODE" != "local" ]; then
    ui_err "Config error in $f: MODE must be 'ssh' or 'local' (got '$CFG_MODE')."
    exit 2
  fi
  if [ "$CFG_MODE" = "ssh" ]; then
    if [ -z "$CFG_REMOTE_HOST" ] || [ -z "$CFG_REMOTE_USER" ]; then
      ui_err "Config error in $f: MODE=ssh requires REMOTE_HOST and REMOTE_USER."
      exit 2
    fi
  fi
  if [ -z "$CFG_REMOTE_PORT" ]; then
    CFG_REMOTE_PORT="22"
  fi
  case "$CFG_REMOTE_PORT" in
    ''|*[!0-9]*) ui_err "Config error in $f: REMOTE_PORT must be numeric."; exit 2 ;;
  esac
  if [ "${#CFG_PAIRS[@]}" -eq 0 ]; then
    ui_err "Config error in $f: PAIRS is empty — nothing to sync."
    exit 2
  fi
  local p l r
  for p in "${CFG_PAIRS[@]}"; do
    case "$p" in
      *'|'*'|'*) ui_err "Config error in $f: pair '$p' must contain exactly one '|'."; exit 2 ;;
    esac
    l="${p%%|*}"
    r="${p#*|}"
    trim_var "$l"; l="$TRIMMED"
    trim_var "$r"; r="$TRIMMED"
    if [ -z "$l" ] || [ -z "$r" ]; then
      ui_err "Config error in $f: pair '$p' has an empty side."
      exit 2
    fi
  done
}

resolve_config_arg() {
  local name="$1" cand
  for cand in "$name" "$ALS_SCRIPT_DIR/$name" "$ALS_SCRIPT_DIR/$name.conf"; do
    if [ -f "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  ui_err "Configuration not found: $name"
  ui_msg "Looked for: ./$name, $ALS_SCRIPT_DIR/$name, $ALS_SCRIPT_DIR/$name.conf"
  exit 2
}

# Wizard input parsing: separators , ; or whitespace (D1: empty line ends).
PAIR_LOCAL="" PAIR_REMOTE="" SPLIT_ERR=""

split_pair_line() {
  local raw="$1"
  local -a f
  PAIR_LOCAL="" PAIR_REMOTE="" SPLIT_ERR=""
  case "$raw" in
    *'|'*) SPLIT_ERR="'|' is reserved — use space, comma or semicolon."; return 1 ;;
  esac
  if [[ "$raw" == *,* ]]; then
    PAIR_LOCAL="${raw%%,*}"
    PAIR_REMOTE="${raw#*,}"
  elif [[ "$raw" == *';'* ]]; then
    PAIR_LOCAL="${raw%%;*}"
    PAIR_REMOTE="${raw#*;}"
  else
    read -r -a f <<<"$raw"
    if [ "${#f[@]}" -ne 2 ]; then
      SPLIT_ERR="Expected exactly '<local> <remote>'. Paths with spaces need ',' or ';' as separator."
      return 1
    fi
    PAIR_LOCAL="${f[0]}"
    PAIR_REMOTE="${f[1]}"
  fi
  trim_var "$PAIR_LOCAL"; PAIR_LOCAL="$TRIMMED"
  trim_var "$PAIR_REMOTE"; PAIR_REMOTE="$TRIMMED"
  if [ -z "$PAIR_LOCAL" ] || [ -z "$PAIR_REMOTE" ]; then
    SPLIT_ERR="Both sides of the pair are required."
    return 1
  fi
  return 0
}

# ==========================================================================
# Built-in ignore patterns (D4 — battle-tested DNA from the legacy scripts)
# ==========================================================================

# Grouped so the wizard can display them by category (plan §6.5);
# BUILTIN_IGNORE_PATTERNS is the flat list the sync engine consumes.

BUILTIN_IGNORE_JUNK=(
  "Name .DS_Store"
  "Name ._*"
  "Name .Spotlight-V100"
  "Name .Trashes"
  "Name .Trash"
  "Name .fseventsd"
  "Name .DocumentRevisions-V100"
  "Name .TemporaryItems"
  "Name .apdisk"
  "Name .localized"
  "Name .directory"
  "Name .Trash-*"
  "Name lost+found"
  "Name Thumbs.db"
  "Name *.swp"
  "Name *~"
)

BUILTIN_IGNORE_MEDIA=(
  # macOS media libraries (permission-locked, huge, platform-specific).
  # "Photos Library.photoslibrary" is explicit in addition to the glob:
  # belt and suspenders for the default library name.
  "Name *.photoslibrary"
  "Name Photos Library.photoslibrary"
  "Name *.photolibrary"
  "Name *.aplibrary"
  "Name Photo Booth Library"
  "Name *.musiclibrary"
  "Name *.itl"
  "Name *.itdb"
  "Name iTunes Library.xml"
  "Name iTunes Music Library.xml"
)

# NOTE: OS-specific executables/installers (*.exe, *.dmg, *.app, …) are
# deliberately NOT default-ignored: installers may be exactly what a user
# wants to keep safe. The wizard mentions them as optional extra ignores.

BUILTIN_IGNORE_PATTERNS=(
  "${BUILTIN_IGNORE_JUNK[@]}"
  "${BUILTIN_IGNORE_MEDIA[@]}"
)

# ==========================================================================
# SSH helpers
# ==========================================================================

REM_USER="" REM_HOST="" REM_PORT=""

# Splits "user@host[:port]" into REM_USER / REM_HOST / REM_PORT.
split_remote_spec() {
  local spec="$1"
  REM_HOST="${spec#*@}"
  REM_USER="${spec%%@*}"
  REM_PORT="22"
  if [[ "$REM_HOST" == *:* && "$REM_HOST" != *:*:* ]]; then
    REM_PORT="${REM_HOST##*:}"
    REM_HOST="${REM_HOST%:*}"
  fi
}

# Runs a command on the configured remote. $1 = remote spec "user@host[:port]"
ssh_target() {
  local remote="$1" cmd="$2"
  split_remote_spec "$remote"
  ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$REM_PORT" "$REM_USER@$REM_HOST" "$cmd"
}

# Connectivity + auth check. rc 0 = ok; otherwise SSH_CHECK_REASON is
# "auth" (reachable, key auth failed) or "unreachable" (network/sshd).
SSH_CHECK_REASON=""
ssh_connect_check() {
  local remote="$1" err rc low
  SSH_CHECK_REASON=""
  err=$(ssh_target "$remote" "true" 2>&1 >/dev/null) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  low=$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')
  case "$low" in
    *'permission denied'*) SSH_CHECK_REASON="auth" ;;
    *)                     SSH_CHECK_REASON="unreachable" ;;
  esac
  return 1
}

# Prints a differentiated diagnosis for a failed ssh_connect_check.
print_ssh_diag() {
  local remote="$1"
  split_remote_spec "$remote"
  if [ "$SSH_CHECK_REASON" = "auth" ]; then
    ui_err "SSH server on $remote answered, but key authentication failed."
    ui_msg "Set up passwordless SSH, then run alpsync again:"
    ui_msg "  ssh-keygen -t ed25519"
    ui_msg "  ssh-copy-id -p $REM_PORT $remote"
  else
    ui_err "Cannot reach $remote - no SSH server answering (network, port or sshd issue)."
    ui_msg "Check host name, port $REM_PORT and that the remote SSH server is running."
    ui_msg "Try manually:  ssh -p $REM_PORT $remote"
  fi
}

REMOTE_DETECT_OUT=""
# Finds unison on the remote. rc 0 + path in REMOTE_DETECT_OUT.
remote_detect_unison() {
  # shellcheck disable=SC2016  # single quotes are intentional: runs remotely
  REMOTE_DETECT_OUT=$(ssh_target "$1" 'for b in unison /usr/bin/unison /usr/local/bin/unison /opt/homebrew/bin/unison; do command -v "$b" && exit 0; done; exit 1' 2>/dev/null | tail -n 1)
  trim_var "$REMOTE_DETECT_OUT"
  REMOTE_DETECT_OUT="$TRIMMED"
  [ -n "$REMOTE_DETECT_OUT" ]
}

REMOTE_OS="" REMOTE_PKG_MGR=""
remote_detect_env() {
  REMOTE_OS=$(ssh_target "$1" 'uname -s' 2>/dev/null | tail -n 1 | tr -d '\r\n')
  if [ "$REMOTE_OS" = "Darwin" ]; then
    REMOTE_PKG_MGR=""
    if ssh_target "$1" 'command -v brew >/dev/null 2>&1' >/dev/null 2>&1; then
      REMOTE_PKG_MGR="brew"
    fi
  else
    # shellcheck disable=SC2016  # single quotes are intentional: runs remotely
    REMOTE_PKG_MGR=$(ssh_target "$1" 'for m in apt-get dnf yum pacman zypper apk; do command -v "$m" >/dev/null 2>&1 && { echo "$m"; exit 0; }; done; exit 1' 2>/dev/null | tail -n 1 | tr -d '\r\n')
  fi
}

# Best-effort version the remote package manager would install ("X.Y…").
remote_pkg_version() {
  local out=""
  case "$2" in
    apt-get) out=$(ssh_target "$1" 'apt-cache policy unison 2>/dev/null' 2>/dev/null) ;;
    dnf|yum) out=$(ssh_target "$1" "$2 info unison 2>/dev/null" 2>/dev/null) ;;
    pacman)  out=$(ssh_target "$1" 'pacman -Si unison 2>/dev/null' 2>/dev/null) ;;
    zypper)  out=$(ssh_target "$1" 'zypper info unison 2>/dev/null' 2>/dev/null) ;;
    *)       out="" ;;
  esac
  printf '%s' "$out" \
    | sed -n -e 's/^[[:space:]]*Candidate[[:space:]]*:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p' \
             -e 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p' \
    | head -n 1
}

# Install/remove command string per package manager (never executed blind).
remove_cmd_for() {
  case "$1" in
    brew)    printf 'brew uninstall %s' "$2" ;;
    apt-get) printf 'sudo apt-get remove -y %s' "$2" ;;
    dnf)     printf 'sudo dnf remove -y %s' "$2" ;;
    yum)     printf 'sudo yum remove -y %s' "$2" ;;
    pacman)  printf 'sudo pacman -R --noconfirm %s' "$2" ;;
    zypper)  printf 'sudo zypper --non-interactive remove %s' "$2" ;;
    apk)     printf 'sudo apk del %s' "$2" ;;
    *)       printf '' ;;
  esac
}

# Executes a removal locally via the recorded installer.
exec_remove() {
  local installer="$1" pkg="$2"
  case "$installer" in
    brew)    brew uninstall "$pkg" ;;
    apt-get) sudo apt-get remove -y "$pkg" ;;
    dnf)     sudo dnf remove -y "$pkg" ;;
    yum)     sudo yum remove -y "$pkg" ;;
    pacman)  sudo pacman -R --noconfirm "$pkg" ;;
    zypper)  sudo zypper --non-interactive remove "$pkg" ;;
    apk)     sudo apk del "$pkg" ;;
    *)       ui_warn "Unknown installer '$installer'."; return 1 ;;
  esac
}

# Installs unison on the remote (caller asks for consent first).
# rc 0 = installed and detected. Refuses wrong-version distro packages.
remote_install_unison() {
  local remote="$1" lxy cand cmd
  remote_detect_env "$remote"
  if [ -z "$REMOTE_PKG_MGR" ]; then
    ui_err "No supported package manager found on $remote."
    if [ "$REMOTE_OS" = "Darwin" ]; then
      ui_msg "alpsync never installs Homebrew automatically. Install it there, then:"
      ui_msg "  brew install unison"
    else
      ui_msg "Install unison on $remote manually, then run alpsync again:"
      ui_msg "  https://github.com/bcpierce003/unison/wiki/Downloading-Unison"
    fi
    return 1
  fi

  lxy=$(unison_version "$UNISON_BIN" "")
  if [ "$REMOTE_PKG_MGR" != "brew" ] && [ -n "$lxy" ]; then
    cand=$(remote_pkg_version "$remote" "$REMOTE_PKG_MGR")
    if [ -n "$cand" ] && [ "$cand" != "$lxy" ]; then
      ui_warn "The repository on $remote would install unison $cand, but the local version is $lxy."
      ui_msg "Unison requires identical X.Y versions on both sides - not installing a mismatched one."
      ui_msg "Get $lxy onto $remote, e.g. via:"
      case "$REMOTE_PKG_MGR" in
        apt-get)
          ui_msg "  - Debian backports / a newer Ubuntu release, or"
          ;;
        *)
          ui_msg "  - a newer distribution repository, or"
          ;;
      esac
      ui_msg "  - opam: opam install unison   (see unison wiki), or"
      ui_msg "  - Homebrew on Linux: https://docs.brew.sh/Homebrew_on_Linux"
      return 1
    fi
  fi

  case "$REMOTE_PKG_MGR" in
    brew)    cmd="brew install unison" ;;
    apt-get) cmd="sudo apt-get install -y unison" ;;
    dnf)     cmd="sudo dnf install -y unison" ;;
    yum)     cmd="sudo yum install -y unison" ;;
    pacman)  cmd="sudo pacman -S --noconfirm unison" ;;
    zypper)  cmd="sudo zypper --non-interactive install unison" ;;
    apk)     cmd="sudo apk add unison" ;;
  esac
  ui_msg "Running on $remote:  $cmd"
  ui_hint "A remote sudo password prompt may appear - type it live; it is never stored."
  split_remote_spec "$remote"
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$REM_PORT" "$REM_USER@$REM_HOST" -t "$cmd"; then
    ui_err "Remote installation failed."
    return 1
  fi
  if ! remote_detect_unison "$remote"; then
    ui_err "unison still not found on $remote after installation."
    return 1
  fi
  state_init
  mark_remote_managed "$REMOTE_PKG_MGR" "$remote"
  ui_ok "unison installed on $remote: $REMOTE_DETECT_OUT"
  return 0
}

CFG_REMOTE_SPEC=""

preflight_ssh() {
  local remote="$CFG_REMOTE_SPEC" rver lver
  echo ""
  ui_msg "Checking SSH connection to $remote ..."
  if ! ssh_connect_check "$remote"; then
    print_ssh_diag "$remote"
    exit 1
  fi
  ui_ok "SSH connection OK."

  if [ -z "$CFG_REMOTE_UNISON" ]; then
    ui_msg "Detecting unison on $remote ..."
    if ! remote_detect_unison "$remote"; then
      ui_warn "No unison found on $remote."
      if ui_confirm "Install unison on $remote now?" "y"; then
        if remote_install_unison "$remote" && remote_detect_unison "$remote"; then
          CFG_REMOTE_UNISON="$REMOTE_DETECT_OUT"
        else
          ui_err "Remote unison is not available - cannot sync."
          ui_msg "Install unison on $remote (same X.Y version as local), then run alpsync again."
          exit 1
        fi
      else
        ui_err "Remote unison is required for SSH sync."
        ui_msg "Install it on $remote, then run alpsync again:"
        ui_msg "  https://github.com/bcpierce003/unison/wiki/Downloading-Unison"
        exit 1
      fi
    else
      CFG_REMOTE_UNISON="$REMOTE_DETECT_OUT"
    fi
  fi
  ui_ok "Remote unison: $CFG_REMOTE_UNISON"

  rver=$(unison_version "$CFG_REMOTE_UNISON" "$remote")
  lver=$(unison_version "$UNISON_BIN" "")
  if [ -n "$rver" ] && [ -n "$lver" ] && [ "$rver" != "$lver" ]; then
    ui_warn "Unison version mismatch: local $lver vs remote $rver."
    ui_hint "Unison requires the same X.Y version (e.g. 2.53.x) on both sides."
  fi
}

# ==========================================================================
# Sync engine
# ==========================================================================

PAIR_ARGS=()

build_pair_args() {
  local lroot="$1" rroot="$2" label="$3" pat
  PAIR_ARGS=("$lroot" "$rroot"
    -auto -batch
    -times
    -perms 0
    -rsrc false
    -prefer newer
    -confirmbigdel
    -label "$label"
  )
  for pat in "${BUILTIN_IGNORE_PATTERNS[@]}"; do
    PAIR_ARGS+=(-ignore "$pat")
  done
  if [ "${#CFG_EXTRA_IGNORES[@]}" -gt 0 ]; then
    for pat in "${CFG_EXTRA_IGNORES[@]}"; do
      PAIR_ARGS+=(-ignore "$pat")
    done
  fi
  if [ "$CFG_MODE" = "ssh" ]; then
    PAIR_ARGS+=(-servercmd "$CFG_REMOTE_UNISON")
  fi
}

ssh_root_for() {
  local p="$1" host_part
  host_part="$CFG_REMOTE_USER@$CFG_REMOTE_HOST"
  if [ "$CFG_REMOTE_PORT" != "22" ]; then
    host_part="$host_part:$CFG_REMOTE_PORT"
  fi
  printf 'ssh://%s/%s' "$host_part" "$p"
}

shorten_home() {
  case "$1" in
    "$HOME"*) printf '~%s' "${1#"$HOME"}" ;;
    *)        printf '%s' "$1" ;;
  esac
}

# --- Unison archive registry (D10) -----------------------------------------
# Unison archive files are hash names without any readable label, so
# alpsync diffs the archive directory around a pair's FIRST run and records
# the new files per config+pair in alpsync.state. --uninstall then removes
# exactly those files - never guessed ones.

unison_archive_dirs() {
  if [ -n "${ALS_UNISON_DIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$ALS_UNISON_DIR_OVERRIDE"
    return 0
  fi
  local d
  for d in "${UNISON:-}" "$HOME/.unison" "$HOME/Library/Application Support/Unison"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      printf '%s\n' "$d"
    fi
  done
  return 0
}

archive_snapshot_file() {
  local d f
  : >"$1"
  while IFS= read -r d; do
    for f in "$d"/ar* "$d"/fp*; do
      if [ -f "$f" ]; then
        printf '%s\n' "$(basename -- "$f")"
      fi
    done
  done < <(unison_archive_dirs) >"$1"
  return 0
}

registry_record_pair() { # cfg idx before-file after-file
  local key="AR:$1|$2" before="$3" after="$4" b new=""
  while IFS= read -r b; do
    if ! grep -qxF "$b" "$before" 2>/dev/null; then
      new="${new:+$new,}$b"
    fi
  done <"$after"
  [ -n "$new" ] || return 0
  state_set "$key" "$new"
  return 0
}

# Detects macOS TCC folder protection in captured unison output: the
# privacy framework denies opendir() on protected folders (Documents,
# Desktop, Downloads) per responsible app, producing
#   "Error in scanning directory: Operation not permitted [opendir(...)]"
# Returns 0 and fills TCC_DIR when the signature is found on darwin.
TCC_DIR=""
detect_tcc_denial() {
  local log="$1"
  TCC_DIR=""
  [ "$OS_KIND" = "darwin" ] || return 1
  if grep -q 'Operation not permitted \[opendir(' "$log" 2>/dev/null; then
    TCC_DIR=$(sed -n 's/.*Operation not permitted \[opendir(\([^)]*\))\].*/\1/p' "$log" 2>/dev/null | head -n 1)
    return 0
  fi
  return 1
}

print_tcc_hint() {
  echo ""
  ui_warn "macOS privacy protection blocked reading a local folder."
  [ -n "$TCC_DIR" ] && ui_msg "  Affected directory: $TCC_DIR"
  ui_msg "  The permission belongs to your TERMINAL APP (not to alpsync or unison)."
  ui_msg "  Fix (once) — pick either:"
  ui_msg "    a) System Settings → Privacy & Security → Files and Folders →"
  ui_msg "       <your terminal app> → enable 'Documents' (or 'Desktop'/'Downloads'),"
  ui_msg "       or grant Full Disk Access to the terminal app."
  ui_msg "    b) System Settings → Privacy & Security → Full Disk Access → add the"
  ui_msg "       unison binary itself (⌘⇧G → ${UNISON_BIN:-unison}) — works from any terminal."
  ui_msg "  Then restart the terminal app and re-run alpsync."
  ui_hint "  Note: an 'on' toggle can be stale after an app update — if in doubt, remove"
  ui_hint "  and re-add the entry. Failed pairs re-sync safely as a first-run union."
}

run_sync() {
  local total=${#CFG_PAIRS[@]} idx=0 pair l r lroot rroot
  local -a failed=()
  local lbl lshort rshort q remote_test
  local pairlog
  local snap_b="${TMPDIR:-/tmp}/alpsync-snap-b.$$" snap_a="${TMPDIR:-/tmp}/alpsync-snap-a.$$"
  local reg_has
  trap 'rm -f "$snap_b" "$snap_a"' EXIT
  state_init

  echo ""
  ui_header "alpsync — $CFG_LABEL"

  if [ "$CFG_MODE" = "ssh" ]; then
    ensure_ssh_client
    CFG_REMOTE_SPEC="$CFG_REMOTE_USER@$CFG_REMOTE_HOST:$CFG_REMOTE_PORT"
    preflight_ssh
  fi

  ui_msg "Mode:   $CFG_MODE"
  if [ "$CFG_MODE" = "ssh" ]; then
    ui_msg "Remote: $CFG_REMOTE_SPEC"
  fi
  ui_msg "Pairs:  $total"
  echo ""

  for pair in "${CFG_PAIRS[@]}"; do
    idx=$((idx + 1))
    l="${pair%%|*}"
    r="${pair#*|}"
    if [ "$CFG_MODE" = "ssh" ]; then
      r=$(normalize_remote_path "$r")
    fi
    lroot=$(expand_path "$l")
    lbl=$(sanitize_name "$CFG_NAME")-$idx

    ui_separator
    if [ "$CFG_MODE" = "ssh" ]; then
      rroot=$(ssh_root_for "$r")
      lshort=$(shorten_home "$lroot")
      rshort="$CFG_REMOTE_USER@$CFG_REMOTE_HOST:$r"
      ui_msg "▶ [$idx/$total] $lshort  →  $rshort"
      mkdir -p "$lroot"
      # Ask before creating a missing remote root (avoids surprises from typos).
      q=$(printf '%q' "$r")
      if [[ "$r" == /* ]]; then
        remote_test="[ -d $q ]"
      else
        remote_test="[ -d \"\$HOME\"/$q ]"
      fi
      if ! ssh_target "$CFG_REMOTE_SPEC" "$remote_test" >/dev/null 2>&1; then
        if ui_confirm "Remote directory '$r' does not exist on $CFG_REMOTE_HOST. Create it?" "y"; then
          if [[ "$r" == /* ]]; then
            ssh_target "$CFG_REMOTE_SPEC" "mkdir -p $q" >/dev/null 2>&1 || true
          else
            ssh_target "$CFG_REMOTE_SPEC" "mkdir -p \"\$HOME\"/$q" >/dev/null 2>&1 || true
          fi
        else
          ui_warn "Skipping pair $idx/$total (remote directory missing)."
          failed+=("$lshort → $rshort (remote dir missing)")
          continue
        fi
      fi
    else
      rroot=$(expand_path "$r")
      lshort=$(shorten_home "$lroot")
      rshort=$(shorten_home "$rroot")
      ui_msg "▶ [$idx/$total] $lshort  →  $rshort"
      mkdir -p "$lroot"
      # Missing/empty target = likely unmounted share → ask (D6).
      if [ ! -d "$rroot" ] || is_dir_empty "$rroot"; then
        if ui_confirm "Target '$rshort' is missing or empty (unmounted share?). Use/create it anyway?" "n"; then
          mkdir -p "$rroot"
        else
          ui_warn "Skipping pair $idx/$total (target missing or empty)."
          failed+=("$lshort → $rshort (target missing/empty)")
          continue
        fi
      fi
    fi

    build_pair_args "$lroot" "$rroot" "$lbl"
    reg_has=0
    if state_get "AR:$CFG_NAME|$idx" && [ -n "$STATE_VALUE" ]; then
      reg_has=1
    else
      archive_snapshot_file "$snap_b"
    fi
    pairlog="${TMPDIR:-/tmp}/alpsync-pair-$$-$idx.log"
    if unison "${PAIR_ARGS[@]}" 2>&1 | tee "$pairlog"; then
      ui_ok "$lshort → $rshort done"
    else
      local code=$?
      ui_warn "$lshort → $rshort finished with issues (unison exit $code) — continuing"
      failed+=("$lshort → $rshort (exit $code)")
      if detect_tcc_denial "$pairlog"; then
        print_tcc_hint
      fi
    fi
    rm -f "$pairlog"
    if [ "$reg_has" -eq 0 ]; then
      archive_snapshot_file "$snap_a"
      registry_record_pair "$CFG_NAME" "$idx" "$snap_b" "$snap_a"
    fi
  done

  echo ""
  ui_separator
  if [ "${#failed[@]}" -eq 0 ]; then
    echo ""
    ui_ok "Sync completed successfully."
    exit 0
  fi
  ui_warn "Done, but these pairs had issues:"
  local f
  for f in "${failed[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
}

# ==========================================================================
# PATH helper — optional post-wizard alias (D9)
# ==========================================================================

RC_TARGET=""

detect_rc_file() {
  local shell_bin
  shell_bin=$(basename -- "${SHELL:-/bin/sh}")
  RC_TARGET=""
  case "$shell_bin" in
    zsh)  RC_TARGET="$HOME/.zshrc" ;;
    bash)
      RC_TARGET="$HOME/.bashrc"
      # macOS Terminal runs login shells: .bash_profile wins if it exists
      # and does not source .bashrc.
      if [ "$OS_KIND" = "darwin" ] && [ -f "$HOME/.bash_profile" ] \
         && ! grep -q 'bashrc' "$HOME/.bash_profile" 2>/dev/null; then
        RC_TARGET="$HOME/.bash_profile"
      fi
      ;;
    *) RC_TARGET="" ;;
  esac
}

ALS_MARKER_BEGIN="# >>> alpsync >>>"
ALS_MARKER_END="# <<< alpsync <<<"

path_setup_append() {
  local rc="$1"
  touch "$rc"
  if grep -qF "$ALS_MARKER_BEGIN" "$rc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$ALS_MARKER_BEGIN"
    printf 'alias alpsync="%s"\n' "$ALS_SCRIPT_PATH"
    printf '%s\n' "$ALS_MARKER_END"
  } >>"$rc"
}

# Prints existing rc files that contain the alpsync marker block.
rc_files_for_alias() {
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$f" ] && grep -qF "$ALS_MARKER_BEGIN" "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  done
  return 0
}

# Deletes the marker block (inclusive) from $1, preserving file permissions.
remove_alias_block() {
  local f="$1" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/alpsync-rc.XXXXXX") || return 1
  awk '
    /^# >>> alpsync >>>[[:space:]]*$/ { skip = 1 }
    skip == 0 { print }
    /^# <<< alpsync <<<[[:space:]]*$/ { skip = 0 }
  ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$f"
  rm -f "$tmp"
}

# ==========================================================================
# Uninstall — "./alpsync.sh --uninstall" checklist (D10)
# Nothing is removed silently; every step asks. Homebrew, sshd and any
# package alpsync did not install itself are never touched.
# ==========================================================================

installer_available() {
  command -v "$1" >/dev/null 2>&1
}

# Prints basenames in the script dir alpsync does not know/manage.
script_dir_unknown_entries() {
  local f b
  for f in "$ALS_SCRIPT_DIR"/* "$ALS_SCRIPT_DIR"/.[!.]* "$ALS_SCRIPT_DIR"/..?*; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      continue
    fi
    b=$(basename -- "$f")
    case "$b" in
      alpsync.sh|alpsync.state|README.md|IMPLEMENTATION_PLAN.md|AGENTS.md|LICENSE|tests|.DS_Store) continue ;;
      *.conf) continue ;;
      *) printf '%s\n' "$b" ;;
    esac
  done
  return 0
}

uninstall_run() {
  local f i k cfg installer rinstaller rtarget parent unknown
  local -a rcs=() items=() names=() del_confs=() victims=()

  echo ""
  ui_header "alpsync — uninstall"
  ui_hint "Every step asks for confirmation. Nothing is removed silently."

  # -- 1) shell alias ------------------------------------------------------
  echo ""
  ui_msg "Step 1/7: shell alias"
  while IFS= read -r f; do
    rcs+=("$f")
  done < <(rc_files_for_alias)
  if [ "${#rcs[@]}" -eq 0 ]; then
    ui_hint "No alpsync alias found in shell rc files."
  else
    for f in "${rcs[@]}"; do
      ui_msg "  found: $f"
    done
    if ui_confirm "Remove the alpsync alias block from these files?" "y"; then
      for f in "${rcs[@]}"; do
        if remove_alias_block "$f"; then
          ui_ok "cleaned: $f"
        else
          ui_warn "could not clean: $f"
        fi
      done
    fi
  fi

  # -- 2) configuration files ----------------------------------------------
  echo ""
  ui_msg "Step 2/7: configuration files"
  discover_configs
  del_confs=()
  if [ "${#CONFIG_FILES[@]}" -eq 0 ]; then
    ui_hint "No *.conf files found."
  else
    items=()
    names=()
    for f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"}; do
      items+=("$(basename -- "$f")")
      names+=("$(basename -- "$f" .conf)")
    done
    items+=("‹ ALL configurations ›")
    ui_msg "Selected configurations are deleted; their unison archives too (step 3)."
    if ui_menu "Remove which configurations?" "${items[@]}"; then
      if [ "$MENU_RESULT" -eq $((${#items[@]} - 1)) ]; then
        del_confs=(${names[@]+"${names[@]}"})
      else
        del_confs=("${names[$MENU_RESULT]}")
      fi
    fi
    if [ "${#del_confs[@]}" -gt 0 ]; then
      local list=""
      for cfg in ${del_confs[@]+"${del_confs[@]}"}; do
        list="$list $cfg.conf"
      done
      if ui_confirm "Delete these files?$list" "y"; then
        for cfg in ${del_confs[@]+"${del_confs[@]}"}; do
          rm -f "$ALS_SCRIPT_DIR/$cfg.conf"
        done
        ui_ok "configuration files deleted"
      else
        del_confs=()
      fi
    fi
  fi

  # -- 3) unison archives (registry-based, never guessed) -------------------
  echo ""
  ui_msg "Step 3/7: unison archives"
  state_load
  victims=()
  for cfg in ${del_confs[@]+"${del_confs[@]}"}; do
    local found_any=0
    local -a files=()
    for i in ${STATE_KEYS[@]+"${!STATE_KEYS[@]}"}; do
      k="${STATE_KEYS[$i]}"
      case "$k" in
        "AR:$cfg|"*)
          found_any=1
          files=()
          IFS=',' read -ra files <<<"${STATE_VALS[$i]}"
          local fn d got
          for fn in ${files[@]+"${files[@]}"}; do
            got=""
            while IFS= read -r d; do
              if [ -f "$d/$fn" ]; then
                victims+=("$d/$fn")
                got=1
              fi
            done < <(unison_archive_dirs)
            if [ -z "$got" ]; then
              ui_hint "  registered archive already gone: $fn"
            fi
          done
          ;;
      esac
    done
    if [ "$found_any" -eq 0 ]; then
      ui_hint "no archive registry entries for '$cfg' (nothing recorded on first sync)"
    fi
  done
  if [ "${#victims[@]}" -gt 0 ]; then
    for f in "${victims[@]}"; do
      ui_msg "  archive: $f"
    done
    if ui_confirm "Delete these unison archives? (those pairs then re-sync as a fresh union merge)" "y"; then
      rm -f "${victims[@]}"
      ui_ok "unison archives deleted"
    fi
  else
    ui_hint "No registered unison archives to delete."
  fi
  for cfg in ${del_confs[@]+"${del_confs[@]}"}; do
    state_unset_prefix "AR:$cfg|"
  done

  # -- 4) local unison package ----------------------------------------------
  echo ""
  ui_msg "Step 4/7: local unison package"
  if state_get UNISON_MANAGED && [ "$STATE_VALUE" = "1" ] && managed_install_matches_host UNISON; then
    state_get UNISON_INSTALLER
    installer="$STATE_VALUE"
    ui_warn "unison on this machine was installed by alpsync (via $installer)."
    ui_warn "Other tools may use unison too - removing it affects them as well."
    if ui_confirm "Uninstall local unison now?" "n"; then
      if installer_available "$installer"; then
        if exec_remove "$installer" unison; then
          ui_ok "local unison removed"
        else
          ui_warn "removal command failed"
        fi
      else
        ui_hint "Installer '$installer' is gone. Remove manually:"
        ui_msg "  $(remove_cmd_for "$installer" unison)"
      fi
    fi
    state_unset UNISON_MANAGED
    state_unset UNISON_INSTALLER
    state_unset UNISON_INSTALL_HOST
    state_unset UNISON_INSTALL_DATE
    state_unset UNISON_PKG
  else
    ui_hint "unison was not installed by alpsync on this machine - leaving it alone."
  fi

  # -- 5) local ssh client ---------------------------------------------------
  echo ""
  ui_msg "Step 5/7: local SSH client"
  if state_get SSH_MANAGED && [ "$STATE_VALUE" = "1" ] && managed_install_matches_host SSH; then
    state_get SSH_INSTALLER
    installer="$STATE_VALUE"
    state_get SSH_PKG
    local spkg="$STATE_VALUE"
    [ -n "$spkg" ] || spkg="openssh-client"
    ui_warn "The SSH client ($spkg) on this machine was installed by alpsync (via $installer)."
    ui_warn "ssh is used by many other tools - removing it affects them as well."
    if ui_confirm "Uninstall the local SSH client now?" "n"; then
      if installer_available "$installer"; then
        if exec_remove "$installer" "$spkg"; then
          ui_ok "local SSH client removed"
        else
          ui_warn "removal command failed"
        fi
      else
        ui_hint "Installer '$installer' is gone. Remove manually:"
        ui_msg "  $(remove_cmd_for "$installer" "$spkg")"
      fi
    fi
    state_unset SSH_MANAGED
    state_unset SSH_INSTALLER
    state_unset SSH_INSTALL_HOST
    state_unset SSH_INSTALL_DATE
    state_unset SSH_PKG
  else
    ui_hint "The SSH client was not installed by alpsync - leaving it alone."
  fi

  # -- 6) remote unison ------------------------------------------------------
  echo ""
  ui_msg "Step 6/7: unison on remote host"
  if state_get REMOTE_UNISON_MANAGED && [ "$STATE_VALUE" = "1" ]; then
    state_get REMOTE_UNISON_INSTALLER
    rinstaller="$STATE_VALUE"
    state_get REMOTE_UNISON_TARGET
    rtarget="$STATE_VALUE"
    ui_warn "unison on $rtarget was installed by alpsync (via $rinstaller)."
    if ui_confirm "Uninstall unison on $rtarget too?" "n"; then
      split_remote_spec "$rtarget"
      if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$REM_PORT" "$REM_USER@$REM_HOST" -t "$(remove_cmd_for "$rinstaller" unison)"; then
        ui_ok "remote unison removed"
      else
        ui_hint "Could not remove it on the remote. Remove manually there:"
        ui_msg "  $(remove_cmd_for "$rinstaller" unison)"
      fi
    fi
    state_unset REMOTE_UNISON_MANAGED
    state_unset REMOTE_UNISON_INSTALLER
    state_unset REMOTE_UNISON_TARGET
    state_unset REMOTE_UNISON_INSTALL_DATE
  else
    ui_hint "No alpsync-managed unison on a remote host."
  fi

  # -- 7) alpsync program directory -----------------------------------------
  echo ""
  ui_msg "Step 7/7: alpsync program directory"
  unknown=$(script_dir_unknown_entries)
  if [ -n "$unknown" ]; then
    ui_warn "$ALS_SCRIPT_DIR contains files alpsync does not manage:"
    printf '%s' "$unknown" | sed 's/^/  /'
    ui_hint "alpsync will not delete this directory - remove it yourself if you want."
  else
    ui_msg "Directory $ALS_SCRIPT_DIR contains only alpsync files:"
    (cd "$ALS_SCRIPT_DIR" && ls -A) 2>/dev/null | sed 's/^/  /'
    if ui_confirm "Delete the alpsync directory $ALS_SCRIPT_DIR (including this script)?" "n"; then
      parent=$(dirname -- "$ALS_SCRIPT_DIR")
      cd "$parent" 2>/dev/null || cd "$HOME"
      if rm -rf "$ALS_SCRIPT_DIR"; then
        printf 'alpsync removed. Bye.\n'
        exit 0
      fi
      ui_err "Failed to remove $ALS_SCRIPT_DIR - remove it manually."
    fi
  fi

  echo ""
  ui_ok "Uninstall finished."
  exit 0
}

maybe_path_setup() {
  if command -v alpsync >/dev/null 2>&1; then
    return 0
  fi
  detect_rc_file
  if [ -z "$RC_TARGET" ]; then
    echo ""
    ui_hint "To run alpsync from anywhere, add this line to your shell config:"
    ui_hint "  alias alpsync=\"$ALS_SCRIPT_PATH\""
    return 0
  fi
  if grep -qF "$ALS_MARKER_BEGIN" "$RC_TARGET" 2>/dev/null; then
    return 0
  fi
  echo ""
  if ! ui_confirm "Add the command 'alpsync' to your shell ($RC_TARGET) so you can run it from anywhere?" "n"; then
    return 0
  fi
  path_setup_append "$RC_TARGET"
  ui_ok "Alias added to $RC_TARGET"
  ui_hint "Run 'source $RC_TARGET' or open a new terminal, then use: alpsync"
}

# ==========================================================================
# Wizard — create a new configuration (§6 of the plan)
# ==========================================================================

WIZ_NAME="" WIZ_LABEL="" WIZ_MODE="" WIZ_HOST="" WIZ_USER="" WIZ_PORT="" WIZ_RUNISON=""
WIZ_PAIRS=() WIZ_LOCALS=() WIZ_REMOTES=() WIZ_IGNORES=()

wizard_cancel() {
  echo ""
  ui_msg "Wizard cancelled — nothing was written."
  ui_msg "Run alpsync again to start over."
  exit 2
}

wizard_ask_name() {
  local name=""
  while :; do
    if ! ui_input "Configuration name:" "File <name>.conf will be created in: $ALS_SCRIPT_DIR"; then
      wizard_cancel
    fi
    name="$INPUT_RESULT"
    case "$name" in
      *.conf) name="${name%.conf}" ;;
    esac
    if [ -z "$name" ]; then
      ui_warn "Name must not be empty."
      continue
    fi
    case "$name" in
      */*|*' '*|*$'\t'*|*'|'*)
        ui_warn "Name must not contain '/', spaces or '|'."
        continue
        ;;
    esac
    if [ "$name" != "$(sanitize_name "$name")" ]; then
      ui_warn "Name may only contain A-Z a-z 0-9 . _ -"
      continue
    fi
    if [ -f "$ALS_SCRIPT_DIR/$name.conf" ]; then
      if ! ui_confirm "$name.conf already exists. Overwrite it?" "n"; then
        continue
      fi
    fi
    WIZ_NAME="$name"
    return 0
  done
}

wizard_ask_mode() {
  if ui_confirm "Sync over SSH?" "y"; then
    WIZ_MODE="ssh"
    ensure_ssh_client
    while :; do
      if ! ui_input "Remote host (IP or name):" "" ; then wizard_cancel; fi
      if [ -n "$INPUT_RESULT" ]; then WIZ_HOST="$INPUT_RESULT"; break; fi
      ui_warn "Host must not be empty."
    done
    while :; do
      if ! ui_input "Remote user:" "" "$USER"; then wizard_cancel; fi
      if [ -n "$INPUT_RESULT" ]; then WIZ_USER="$INPUT_RESULT"; break; fi
      ui_warn "User must not be empty."
    done
    while :; do
      if ! ui_input "SSH port:" "" "22"; then wizard_cancel; fi
      case "$INPUT_RESULT" in
        ''|*[!0-9]*) ui_warn "Port must be numeric."; continue ;;
      esac
      WIZ_PORT="$INPUT_RESULT"
      break
    done
    if ! ui_input "Remote unison path:" "Empty = auto-detect on first sync"; then wizard_cancel; fi
    WIZ_RUNISON="$INPUT_RESULT"

    # Optional immediate test (informational; configuring offline stays allowed).
    if ui_confirm "Test the connection to $WIZ_USER@$WIZ_HOST now?" "y"; then
      local spec="$WIZ_USER@$WIZ_HOST:$WIZ_PORT"
      state_init
      if ssh_connect_check "$spec"; then
        ui_ok "Connection OK."
        if remote_detect_unison "$spec"; then
          ui_ok "Remote unison found: $REMOTE_DETECT_OUT"
          local rver lver
          rver=$(unison_version "$REMOTE_DETECT_OUT" "$spec")
          lver=$(unison_version "$UNISON_BIN" "")
          if [ -n "$rver" ] && [ -n "$lver" ] && [ "$rver" != "$lver" ]; then
            ui_warn "Unison version mismatch: local $lver vs remote $rver."
            ui_hint "Unison requires the same X.Y version (e.g. 2.53.x) on both sides."
          fi
        else
          ui_warn "No unison found on $WIZ_USER@$WIZ_HOST."
          if ui_confirm "Install unison on $WIZ_USER@$WIZ_HOST now?" "n"; then
            if remote_install_unison "$spec" && remote_detect_unison "$spec"; then
              ui_ok "Remote unison ready: $REMOTE_DETECT_OUT"
            else
              ui_hint "Install it there later - alpsync checks again before syncing."
            fi
          else
            ui_hint "alpsync will offer the installation again before the first sync."
          fi
        fi
      else
        print_ssh_diag "$spec"
        ui_hint "You can keep this configuration anyway and test again later."
      fi
    fi
  else
    WIZ_MODE="local"
  fi
}

wizard_ask_pairs() {
  WIZ_PAIRS=() WIZ_LOCALS=() WIZ_REMOTES=()
  local raw l r lxp rxp seen dup
  echo ""
  ui_msg "Directory mapping — one pair per line."
  ui_hint "  Format: <local><SEP><remote>   SEP = spaces, tab, ',' or ';'"
  ui_hint "  Paths with spaces must use ',' or ';'.  '~' expands to $HOME."
  ui_hint "  Finish with an EMPTY line (just press Enter)."
  while :; do
    printf '  > '
    raw=""
    if ! IFS= read -r raw && [ -z "$raw" ]; then
      wizard_cancel
    fi
    if [ -z "$raw" ]; then
      if [ "${#WIZ_PAIRS[@]}" -eq 0 ]; then
        ui_warn "At least one pair is required."
        continue
      fi
      break
    fi
    if ! split_pair_line "$raw"; then
      ui_warn "$SPLIT_ERR"
      continue
    fi
    l="$PAIR_LOCAL"
    r="$PAIR_REMOTE"
    case "$l$r" in
      *'|'*) ui_warn "'|' is not allowed in paths."; continue ;;
    esac
    lxp=$(expand_path "$l")
    rxp="$r"
    dup=0
    for seen in ${WIZ_LOCALS[@]+"${WIZ_LOCALS[@]}"}; do
      if [ "$seen" = "$lxp" ]; then
        dup=1
        break
      fi
    done
    if [ "$dup" -eq 1 ]; then
      ui_warn "Local path already mapped: $lxp"
      continue
    fi
    if [ "$WIZ_MODE" = "local" ]; then
      rxp=$(expand_path "$r")
    else
      # ssh: unison roots are relative to the remote home — strip '~/'
      rxp=$(normalize_remote_path "$r")
    fi
    if [ ! -d "$lxp" ]; then
      ui_hint "Note: $lxp does not exist yet — it will be created at sync time."
    fi
    WIZ_LOCALS+=("$lxp")
    WIZ_REMOTES+=("$rxp")
    WIZ_PAIRS+=("$lxp|$rxp")
    echo ""
    ui_pairs_table "${WIZ_LOCALS[@]}" "${WIZ_REMOTES[@]}"
    echo ""
  done
}

wizard_ask_ignores() {
  WIZ_IGNORES=()
  local pat
  echo ""
  ui_msg "Ignore patterns"
  echo ""
  ui_hint "These defaults are ALWAYS active for every pair — nothing to enter for them:"
  echo ""
  printf '  %s\n' "OS junk (Finder/Explorer/system droppings):"
  ui_wrap_list "${BUILTIN_IGNORE_JUNK[@]}"
  echo ""
  printf '  %s\n' "macOS media libraries (permission-locked, huge, platform-specific):"
  ui_wrap_list "${BUILTIN_IGNORE_MEDIA[@]}"
  echo ""
  ui_msg "Extra patterns for THIS configuration (optional) — same style as the directory mapping:"
  ui_hint "  One unison pattern per line: 'Name <what>' or 'Path <what>'"
  ui_hint "  Examples: 'Name node_modules', 'Name .venv', 'Path secret-stuff'"
  ui_hint "  Note: executables/installers (*.exe, *.dmg, *.pkg …) are NOT ignored by default —"
  ui_hint "  add e.g. 'Name *.dmg' here if you do not want them synced."
  ui_hint "  Finish with an EMPTY line (just press Enter)."
  while :; do
    printf '  > '
    pat=""
    if ! IFS= read -r pat && [ -z "$pat" ]; then
      wizard_cancel
    fi
    if [ -z "$pat" ]; then
      return 0
    fi
    trim_var "$pat"
    pat="$TRIMMED"
    if [ -z "$pat" ]; then
      return 0
    fi
    WIZ_IGNORES+=("$pat")
    if [ "${#WIZ_IGNORES[@]}" -eq 1 ]; then
      ui_hint "  Extra ignores so far (1): $pat"
    else
      local joined="${WIZ_IGNORES[0]}"
      local j
      for j in "${WIZ_IGNORES[@]:1}"; do
        joined="$joined  $j"
      done
      ui_hint "  Extra ignores so far (${#WIZ_IGNORES[@]}): $joined"
    fi
  done
}

wizard_summary_and_write() {
  local target="—" i row
  if [ "$WIZ_MODE" = "ssh" ]; then
    target="$WIZ_USER@$WIZ_HOST:$WIZ_PORT"
  fi
  echo ""
  ui_summary_box "Configuration summary" \
    "Name:${WIZ_NAME}" \
    "Label:${WIZ_LABEL}" \
    "Mode:${WIZ_MODE}" \
    "Remote:${target}" \
    "Pairs:${#WIZ_PAIRS[@]}" \
    "Extra ignores:${#WIZ_IGNORES[@]}"
  echo ""
  ui_pairs_table "${WIZ_LOCALS[@]}" "${WIZ_REMOTES[@]}"
  echo ""
  if ! ui_confirm "Create this configuration?" "y"; then
    wizard_cancel
  fi

  local f="$ALS_SCRIPT_DIR/$WIZ_NAME.conf"
  {
    printf '# alpsync configuration\n'
    printf 'LABEL="%s"\n' "$WIZ_LABEL"
    printf 'MODE="%s"\n' "$WIZ_MODE"
    if [ "$WIZ_MODE" = "ssh" ]; then
      printf 'REMOTE_HOST="%s"\n' "$WIZ_HOST"
      printf 'REMOTE_USER="%s"\n' "$WIZ_USER"
      printf 'REMOTE_PORT="%s"\n' "$WIZ_PORT"
      if [ -n "$WIZ_RUNISON" ]; then
        printf 'REMOTE_UNISON="%s"\n' "$WIZ_RUNISON"
      fi
    fi
    printf 'PAIRS=(\n'
    for i in ${WIZ_PAIRS[@]+"${WIZ_PAIRS[@]}"}; do
      printf '  "%s"\n' "$i"
    done
    printf ')\n'
    if [ "${#WIZ_IGNORES[@]}" -gt 0 ]; then
      printf 'EXTRA_IGNORES=(\n'
      for i in ${WIZ_IGNORES[@]+"${WIZ_IGNORES[@]}"}; do
        printf '  "%s"\n' "$i"
      done
      printf ')\n'
    fi
  } >"$f"
  ui_ok "Configuration written: $f"
  echo ""
  ui_msg "Start alpsync again to run your sync, or run \"./alpsync.sh $WIZ_NAME.conf\" directly."
  maybe_path_setup
}

wizard_run() {
  echo ""
  ui_header "alpsync $ALPSYNC_VERSION — new configuration"
  wizard_ask_name
  if ! ui_input "Label (shown during sync):" "" "$WIZ_NAME"; then wizard_cancel; fi
  WIZ_LABEL="$INPUT_RESULT"
  wizard_ask_mode
  wizard_ask_pairs
  wizard_ask_ignores
  wizard_summary_and_write
}

# ==========================================================================
# Main
# ==========================================================================

usage() {
  cat <<EOF
alpsync — bidirectional folder sync via unison (macOS + Linux)

Usage:
  ./alpsync.sh              Select a configuration (or create a new one)
  ./alpsync.sh <config>     Run a configuration (name, name.conf, or path)
  ./alpsync.sh --uninstall  Remove alpsync step by step (asks per step)
  ./alpsync.sh --help       Show this help
  ./alpsync.sh --version    Show version

Configurations (*.conf) live in the same directory as the script.
First sync per pair merges both sides (union, nothing is deleted);
later runs sync changes and deletions in both directions.

Exit codes: 0 ok · 1 sync issues · 2 usage/config error · 3 dependencies.
EOF
}

main_menu() {
  discover_configs
  local -a items=() f
  for f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"}; do
    items+=("$(basename -- "$f")")
  done
  items+=("‹ New configuration… ›")
  echo ""
  ui_header "alpsync $ALPSYNC_VERSION — select configuration"
  if ! ui_menu "Which configuration should run?" "${items[@]}"; then
    ui_msg "Bye."
    exit 0
  fi
  if [ "$MENU_RESULT" -eq $((${#items[@]} - 1)) ]; then
    wizard_run
    exit 0
  fi
  load_config "${CONFIG_FILES[$MENU_RESULT]}"
  run_sync
}

main() {
  local arg=""
  if [ $# -gt 1 ]; then
    usage >&2
    exit 2
  fi
  if [ $# -eq 1 ]; then
    arg="$1"
  fi
  case "$arg" in
    --help|-h)    usage; exit 0 ;;
    --version|-V) printf 'alpsync %s\n' "$ALPSYNC_VERSION"; exit 0 ;;
    --uninstall)
      ui_init
      detect_os
      state_init
      uninstall_run
      ;;
  esac

  ui_init
  detect_os
  state_init
  ensure_unison_local

  if [ -n "$arg" ]; then
    local cfgfile
    cfgfile=$(resolve_config_arg "$arg")
    load_config "$cfgfile"
    run_sync
  fi

  main_menu
}

state_init
if [ "${ALS_TEST_HARNESS:-0}" != "1" ]; then
  main "$@"
fi
