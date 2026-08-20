#!/bin/bash
#
# alpsync test suite — plain bash, no framework.
#
# Layers:
#   1. Syntax:        /bin/bash -n (bash 3.2) + shellcheck (if available)
#   2. Unit:          internal functions via ALS_TEST_HARNESS=1
#   3. Wizard e2e:    piped (non-TTY fallback) — creates a config
#   4. Local sync e2e: throwaway temp dirs, real unison runs
#   5. PATH helper:   alias append idempotency in a sandboxed $HOME
#
# Usage: tests/run-tests.sh

set -u

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/alpsync.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/alpsync-tests.XXXXXX")

PASS=0
FAIL=0

trap 'rm -rf "$WORK"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '        %s\n' "$2"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    fail "$3" "expected: [$2]  got: [$1]"
  fi
}

assert_rc() {
  if [ "$1" -eq "$2" ]; then
    ok "$3"
  else
    fail "$3" "expected rc $2, got $1"
  fi
}

assert_file() {
  if [ -f "$1" ]; then
    ok "$2"
  else
    fail "$2" "missing file: $1"
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

# --------------------------------------------------------------------------
section "1. Syntax"

if /bin/bash -n "$SCRIPT" >/dev/null 2>&1; then
  ok "/bin/bash -n (bash $(/bin/bash -c 'echo $BASH_VERSION'))"
else
  fail "/bin/bash -n"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT" >/dev/null 2>&1; then
    ok "shellcheck clean"
  else
    fail "shellcheck" "$(shellcheck "$SCRIPT" 2>&1 | head -n 5)"
  fi
else
  printf '  skip  shellcheck (not installed)\n'
fi

# --------------------------------------------------------------------------
section "2. Unit (internal functions)"

ALS_TEST_HARNESS=1
# shellcheck disable=SC1090
. "$SCRIPT"
# shellcheck disable=SC2034  # read by the sourced script
ALS_TEST_HARNESS=0
# Sourcing applied the script's set -euo pipefail to this shell; the suite
# manages its own failure accounting, so drop -e/-pipefail again.
set +e
set +o pipefail

# --- split_pair_line: all separator variants (plan §6.4)
split_pair_line "$HOME/tmp1 $HOME/tmp2"
assert_eq "$PAIR_LOCAL $PAIR_REMOTE" "$HOME/tmp1 $HOME/tmp2" "split: single space"

split_pair_line "$HOME/tmp1   $HOME/tmp2"
assert_eq "$PAIR_LOCAL $PAIR_REMOTE" "$HOME/tmp1 $HOME/tmp2" "split: multiple spaces"

split_pair_line "$(printf '%s\t%s' "$HOME/a" "$HOME/b")"
assert_eq "$PAIR_LOCAL $PAIR_REMOTE" "$HOME/a $HOME/b" "split: tab"

split_pair_line "$HOME/x,$HOME/y"
assert_eq "$PAIR_LOCAL $PAIR_REMOTE" "$HOME/x $HOME/y" "split: comma"

split_pair_line "$HOME/x;$HOME/y"
assert_eq "$PAIR_LOCAL $PAIR_REMOTE" "$HOME/x $HOME/y" "split: semicolon"

split_pair_line "/a/with space/b,/c/target"
assert_eq "$PAIR_LOCAL|$PAIR_REMOTE" "/a/with space/b|/c/target" "split: comma w/ space in path"

if split_pair_line "/a /b /c" 2>/dev/null; then
  fail "split: 3 fields must be rejected"
else
  ok "split: 3 fields must be rejected"
fi

if split_pair_line "/a|/b" 2>/dev/null; then
  fail "split: '|' must be rejected"
else
  ok "split: '|' must be rejected"
fi

if split_pair_line "/a," 2>/dev/null; then
  fail "split: empty remote must be rejected"
else
  ok "split: empty remote must be rejected"
fi

# --- expand_path (plan §5)
# shellcheck disable=SC2088  # literal '~/sub' is the test input
assert_eq "$(expand_path '~/sub')" "$HOME/sub" "expand: ~/sub"
assert_eq "$(expand_path '~')" "$HOME" "expand: ~"
assert_eq "$(expand_path '/abs/path')" "/abs/path" "expand: absolute unchanged"
assert_eq "$(expand_path 'rel/path')" "rel/path" "expand: relative unchanged"

# --- TCC denial detector (macOS privacy; real unison output shape)
TCCLOG="$WORK/tcc.log"
cat >"$TCCLOG" <<'EOF'
Unison 2.53.8 (ocaml 5.4.0): Contacting server...
Reconciling changes
         error            /
Error in scanning directory:
Operation not permitted [opendir(/Users/alice/Documents/inbox)]
0 items will be synced, 1 skipped
EOF
OS_KIND_SAVED="$OS_KIND"
OS_KIND="darwin"
if detect_tcc_denial "$TCCLOG"; then
  assert_eq "$TCC_DIR" "/Users/alice/Documents/inbox" "tcc: dir extracted from real output"
else
  fail "tcc: detector fires on darwin" "did not return 0"
fi
OS_KIND="linux"
if detect_tcc_denial "$TCCLOG"; then
  fail "tcc: detector must stay silent on linux"
else
  ok "tcc: detector must stay silent on linux"
fi
OS_KIND="$OS_KIND_SAVED"
printf 'Synchronization complete\n' >"$TCCLOG"
if detect_tcc_denial "$TCCLOG"; then
  fail "tcc: no false positive on clean output"
else
  ok "tcc: no false positive on clean output"
fi

# shellcheck disable=SC2088  # literal '~/Downloads' is the test input
assert_eq "$(normalize_remote_path '~/Downloads')" "Downloads" "norm: ~/Downloads → Downloads"
assert_eq "$(normalize_remote_path '~')" "" "norm: lone ~ → empty (remote home)"
assert_eq "$(normalize_remote_path '/srv/data')" "/srv/data" "norm: absolute unchanged"
assert_eq "$(normalize_remote_path 'Documents/x')" "Documents/x" "norm: relative unchanged"

# --- sanitize_name
assert_eq "$(sanitize_name 'My Config!')" "My_Config_" "sanitize: invalid chars"
assert_eq "$(sanitize_name 'valid-1.2_x')" "valid-1.2_x" "sanitize: valid name unchanged"

# --- ui_wrap_list: joins and wraps with indent (plan §6.5 display)
WL_OUT=$(ui_wrap_list "Name .DS_Store" "Name ._*" "Name .Spotlight-V100" \
  "Name .Trashes" "Name .Trash" "Name .fseventsd" \
  "Name .DocumentRevisions-V100" "Name .TemporaryItems" "Name .apdisk")
WL_LINES=$(printf '%s\n' "$WL_OUT" | wc -l | tr -d ' ')
WL_INDENT_OK=$(printf '%s\n' "$WL_OUT" | grep -c '^    ' || true)
if [ "$WL_LINES" -gt 1 ] && [ "$WL_INDENT_OK" = "$WL_LINES" ]; then
  ok "ui_wrap_list: wraps and indents all lines"
else
  fail "ui_wrap_list: wraps and indents all lines" "out: [$WL_OUT]"
fi
assert_eq "$(ui_wrap_list)" "" "ui_wrap_list: no args → empty"

# --- extract_quoted
extract_quoted '  "Name .venv"  "Path x" '
assert_eq "${#EXTRACTED[@]}|${EXTRACTED[0]}|${EXTRACTED[1]}" '2|Name .venv|Path x' "extract_quoted"

# --- load_config (local mode, both array styles)
CFGTEST="$WORK/unit.conf"
cat >"$CFGTEST" <<'EOF'
# comment
LABEL="unit label"
MODE="local"
PAIRS=(
  "/tmp/aaa|/tmp/bbb"
  "/tmp/ccc|/tmp/ddd"
)
EXTRA_IGNORES=(
  "Name .venv"
)
EOF
load_config "$CFGTEST"
assert_eq "$CFG_MODE" "local" "load: MODE"
assert_eq "$CFG_LABEL" "unit label" "load: LABEL"
assert_eq "${#CFG_PAIRS[@]}" "2" "load: PAIRS count"
assert_eq "${CFG_PAIRS[1]}" "/tmp/ccc|/tmp/ddd" "load: PAIRS entry"
assert_eq "${#CFG_EXTRA_IGNORES[@]}" "1" "load: EXTRA_IGNORES count"
assert_eq "$CFG_REMOTE_PORT" "22" "load: default port"

# single-line arrays
CFGTEST2="$WORK/unit2.conf"
cat >"$CFGTEST2" <<'EOF'
MODE="local"
PAIRS=("~/a|~/b")
EOF
load_config "$CFGTEST2"
# shellcheck disable=SC2088  # literal pair string is the expected value
assert_eq "${CFG_PAIRS[0]}" "~/a|~/b" "load: single-line array"

# invalid: missing MODE → exit 2 (subshell: load_config exits on error)
CFGTEST3="$WORK/unit3.conf"
printf 'PAIRS=("~/a|~/b")\n' >"$CFGTEST3"
( load_config "$CFGTEST3" >/dev/null 2>&1 )
assert_eq "$?" "2" "load: missing MODE → exit 2"

# invalid: MODE=ssh without host/user → exit 2
CFGTEST4="$WORK/unit4.conf"
printf 'MODE="ssh"\nPAIRS=("~/a|/b")\n' >"$CFGTEST4"
( load_config "$CFGTEST4" >/dev/null 2>&1 )
assert_eq "$?" "2" "load: ssh without host/user → exit 2"

# --- build_pair_args (proven flag set, plan §8)
CFG_MODE="local"
CFG_EXTRA_IGNORES=()
build_pair_args "/lroot" "/rroot" "testcfg-1"
found_label=""
found_prefer=""
i=0
while [ $i -lt ${#PAIR_ARGS[@]} ]; do
  if [ "${PAIR_ARGS[$i]}" = "-label" ]; then found_label="${PAIR_ARGS[$((i + 1))]}"; fi
  if [ "${PAIR_ARGS[$i]}" = "-prefer" ]; then found_prefer="${PAIR_ARGS[$((i + 1))]}"; fi
  i=$((i + 1))
done
assert_eq "$found_label" "testcfg-1" "args: unique -label"
assert_eq "$found_prefer" "newer" "args: -prefer newer"
assert_eq "${PAIR_ARGS[0]}|${PAIR_ARGS[1]}" "/lroot|/rroot" "args: roots first"

# ssh mode adds -servercmd
CFG_MODE="ssh"
# shellcheck disable=SC2034  # read by build_pair_args from the sourced script
CFG_REMOTE_UNISON="/usr/bin/unison"
build_pair_args "/l" "ssh://u@h/x" "t-1"
has_servercmd=0
for a in ${PAIR_ARGS[@]+"${PAIR_ARGS[@]}"}; do
  if [ "$a" = "-servercmd" ]; then has_servercmd=1; fi
done
assert_eq "$has_servercmd" "1" "args: ssh adds -servercmd"

# --- ssh_root_for
# shellcheck disable=SC2034  # read by ssh_root_for from the sourced script
CFG_REMOTE_USER="carol"
# shellcheck disable=SC2034
CFG_REMOTE_HOST="10.0.0.1"
CFG_REMOTE_PORT="22"
assert_eq "$(ssh_root_for "docs")" "ssh://carol@10.0.0.1/docs" "ssh root: relative"
assert_eq "$(ssh_root_for "/srv/data")" "ssh://carol@10.0.0.1//srv/data" "ssh root: absolute"
CFG_REMOTE_PORT="2222"
assert_eq "$(ssh_root_for "/srv/data")" "ssh://carol@10.0.0.1:2222//srv/data" "ssh root: custom port"

# --- builtin ignore DNA (plan §9)
found1=0
for pat in "${BUILTIN_IGNORE_PATTERNS[@]}"; do
  if [ "$pat" = "Name .DS_Store" ]; then found1=1; fi
done
assert_eq "$found1" "1" "builtin ignores include OS junk"
found_photo=0
for pat in "${BUILTIN_IGNORE_PATTERNS[@]}"; do
  if [ "$pat" = "Name Photos Library.photoslibrary" ]; then found_photo=1; fi
done
assert_eq "$found_photo" "1" "builtin ignores: Photos Library explicit"
found_exec=0
for pat in "${BUILTIN_IGNORE_PATTERNS[@]}"; do
  case "$pat" in
    "Name *.exe"|"Name *.dmg"|"Name *.app"|"Name *.pkg"|"Name *.msi") found_exec=1 ;;
  esac
done
assert_eq "$found_exec" "0" "builtin ignores: executables/installers removed"

# --------------------------------------------------------------------------
section "3. Wizard e2e (piped, non-TTY fallback)"

WB="$WORK/wizbox"
mkdir -p "$WB/home"
cp "$SCRIPT" "$WB/alpsync.sh"

# wizard input: menu "1" (new config) / name / label(empty→default) / ssh=n /
# one pair / empty / extra ignore / empty / create=y / path-setup=n
printf '1\nmyconf\n\nn\n%s %s\n\nName .venv\n\ny\nn\n' \
  "$WB/src" "$WB/dst" \
  | HOME="$WB/home" UNISON="$WB/home/.unison" bash "$WB/alpsync.sh" >"$WORK/wizard.out" 2>&1
rc=$?
assert_rc "$rc" "0" "wizard: runs rc 0"

CFGOUT="$WB/myconf.conf"
assert_file "$CFGOUT" "wizard: creates <name>.conf"

if grep -q 'MODE="local"' "$CFGOUT"; then ok "wizard: MODE=local"; else fail "wizard: MODE=local"; fi
if grep -qF "\"$WB/src|$WB/dst\"" "$CFGOUT"; then ok "wizard: pair written expanded"; else fail "wizard: pair written expanded"; fi
if grep -q 'Name .venv' "$CFGOUT"; then ok "wizard: extra ignore written"; else fail "wizard: extra ignore written"; fi
if grep -q 'LABEL="myconf"' "$CFGOUT"; then ok "wizard: label defaults to name"; else fail "wizard: label defaults to name"; fi

# ignore step shows the built-in defaults, grouped (plan §6.5)
if grep -q 'Name .DS_Store' "$WORK/wizard.out"; then
  ok "wizard: built-in junk ignores displayed"
else
  fail "wizard: built-in junk ignores displayed"
fi
if grep -q 'Name Photos Library.photoslibrary' "$WORK/wizard.out"; then
  ok "wizard: Photos Library entry displayed"
else
  fail "wizard: Photos Library entry displayed"
fi
if grep -q 'ALWAYS active' "$WORK/wizard.out"; then
  ok "wizard: defaults marked always-active"
else
  fail "wizard: defaults marked always-active"
fi
if grep -q 'NOT ignored by default' "$WORK/wizard.out"; then
  ok "wizard: installer hint shown"
else
  fail "wizard: installer hint shown"
fi
if grep -q 'Name \*\.exe' "$WORK/wizard.out" && grep -q 'executables and installers' "$WORK/wizard.out"; then
  fail "wizard: executables group must be gone from defaults display"
else
  ok "wizard: executables group must be gone from defaults display"
fi
if grep -q 'Extra ignores so far (1): Name .venv' "$WORK/wizard.out"; then
  ok "wizard: entered extra ignore echoed"
else
  fail "wizard: entered extra ignore echoed"
fi

# declined confirm → nothing written (menu now has 2 entries: myconf.conf + new)
printf '2\nother\n\nn\n%s %s\n\n\nn\n' "$WB/x" "$WB/y" \
  | HOME="$WB/home" UNISON="$WB/home/.unison" bash "$WB/alpsync.sh" >/dev/null 2>&1
rc=$?
assert_rc "$rc" "2" "wizard: cancelled → rc 2"
if [ -f "$WB/other.conf" ]; then fail "wizard: cancel must not write"; else ok "wizard: cancel must not write"; fi

# --------------------------------------------------------------------------
section "4. Local sync e2e (real unison runs)"

SB="$WORK/syncbox"
mkdir -p "$SB/home" "$SB/A" "$SB/B"
cp "$SCRIPT" "$SB/alpsync.sh"

cat >"$SB/e2e.conf" <<EOF
LABEL="e2e"
MODE="local"
PAIRS=(
  "$SB/A|$SB/B"
)
EOF

echo "content-one" >"$SB/A/f1.txt"
echo "content-two" >"$SB/B/f2.txt"

HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" e2e.conf </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "sync1: union run rc 0"
assert_file "$SB/A/f2.txt" "sync1: union B→A"
assert_file "$SB/B/f1.txt" "sync1: union A→B"
if grep -q '^AR:e2e|1=' "$SB/alpsync.state" 2>/dev/null; then
  ok "sync1: pair archives registered in alpsync.state"
else
  fail "sync1: pair archives registered in alpsync.state" "no AR:e2e|1= entry in $SB/alpsync.state"
fi

# change propagation + deletion propagation
echo "changed" >"$SB/A/f1.txt"
rm "$SB/A/f2.txt"
HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" e2e.conf </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "sync2: propagate run rc 0"
if grep -q 'changed' "$SB/B/f1.txt" 2>/dev/null; then ok "sync2: change A→B"; else fail "sync2: change A→B"; fi
if [ -f "$SB/B/f2.txt" ]; then fail "sync2: deletion A→B"; else ok "sync2: deletion A→B"; fi

# conflict → newer wins (-prefer newer)
echo "local-version" >"$SB/A/c.txt"
echo "remote-version" >"$SB/B/c.txt"
touch -t 202501011200.00 "$SB/A/c.txt"
touch -t 202601011200.00 "$SB/B/c.txt"
HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" e2e.conf </dev/null >/dev/null 2>&1
assert_eq "$?" "0" "sync3: conflict run rc 0"
if grep -q 'remote-version' "$SB/A/c.txt" 2>/dev/null; then ok "sync3: conflict resolved to newer"; else fail "sync3: conflict resolved to newer"; fi

# missing target: decline → pair skipped, rc 1
rm -rf "$SB/B"
printf 'n\n' | HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" e2e.conf >/dev/null 2>&1
assert_eq "$?" "1" "sync4: missing target declined → rc 1"
if [ -d "$SB/B" ]; then fail "sync4: declined must not create target"; else ok "sync4: declined must not create target"; fi

# missing target (never synced before): accept → created, union sync, rc 0
mkdir -p "$SB/C"
echo "fresh" >"$SB/C/new.txt"
printf 'PAIRS=(\n  "%s/C|%s/D"\n)\n' "$SB" "$SB" >"$SB/fresh.conf"
printf 'LABEL="f"\nMODE="local"\n' | cat - "$SB/fresh.conf" >"$SB/fresh.conf.tmp" && mv "$SB/fresh.conf.tmp" "$SB/fresh.conf"
printf 'y\n' | HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" fresh.conf >/dev/null 2>&1
assert_eq "$?" "0" "sync5: fresh target accepted → rc 0"
assert_file "$SB/D/new.txt" "sync5: files synced into created target"

# wiped target with sync history: -confirmbigdel guard aborts in batch mode
# (intended protection: an emptied replica is not silently refilled/deleted)
rm -rf "$SB/B"
printf 'y\n' | HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" e2e.conf >/dev/null 2>&1
assert_eq "$?" "1" "sync5b: wiped target guarded by -confirmbigdel → rc 1"
if [ -f "$SB/B/f1.txt" ] && [ ! -f "$SB/A/f1.txt" ]; then
  fail "sync5b: guard must not delete from A"
else
  ok "sync5b: source side untouched"
fi

# success message: blank line + message on stdout (clean config)
if HOME="$SB/home" UNISON="$SB/home/.unison" bash "$SB/alpsync.sh" fresh.conf </dev/null 2>/dev/null | grep -q 'Sync completed successfully'; then
  ok "sync6: success text"
else
  fail "sync6: success text"
fi

# unison archives live under the (sandboxed) UNISON dir — isolation base
n_arch=$(find "$SB/home/.unison" \( -name 'ar*' -o -name 'fp*' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_arch" -gt 0 ]; then
  ok "sync: unison archives created in isolation dir"
else
  fail "sync: unison archives created in isolation dir"
fi

# --------------------------------------------------------------------------
section "5. PATH helper (alias append, D9)"

PB="$WORK/pathbox"
mkdir -p "$PB/home"
cp "$SCRIPT" "$PB/alpsync.sh"

# shellcheck disable=SC2034
SHELL="/bin/zsh"
export HOME="$PB/home"

detect_rc_file
assert_eq "$RC_TARGET" "$PB/home/.zshrc" "path: zsh → ~/.zshrc"

# shellcheck disable=SC2034  # read by path_setup_append from the sourced script
ALS_SCRIPT_PATH="$PB/alpsync.sh"
path_setup_append "$RC_TARGET"
path_setup_append "$RC_TARGET"
count=$(grep -cF '# >>> alpsync >>>' "$PB/home/.zshrc")
assert_eq "$count" "1" "path: idempotent append"
if grep -qF "alias alpsync=\"$PB/alpsync.sh\"" "$PB/home/.zshrc"; then
  ok "path: alias line correct"
else
  fail "path: alias line correct"
fi

# --------------------------------------------------------------------------
section "6. State file & managed packages (unit)"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
OLDPATH="$PATH"

# --- state set/get/unset roundtrip (sandbox state file)
STDIR="$WORK/statebox"
mkdir -p "$STDIR"
ALS_STATE_FILE="$STDIR/alpsync.state"
rm -f "$ALS_STATE_FILE"
state_set UNISON_MANAGED 1
state_set UNISON_INSTALLER brew
state_set FOO alpha
state_set FOO beta
state_get FOO
assert_eq "$STATE_VALUE" "beta" "state: upsert overwrites"
state_get UNISON_MANAGED
assert_eq "$STATE_VALUE" "1" "state: get after multiple sets"
if state_get DOES_NOT_EXIST; then
  fail "state: unknown key returns rc 1"
else
  ok "state: unknown key returns rc 1"
fi
state_unset FOO
if state_get FOO; then
  fail "state: unset removes key"
else
  ok "state: unset removes key"
fi
state_get UNISON_MANAGED
assert_eq "$STATE_VALUE" "1" "state: unset leaves other keys"

# prefix unset (archive registry)
state_set "AR:cfg|1" "arAAA,fpBBB"
state_set "AR:cfg|2" "arCCC"
state_set "AR:other|1" "arKEEPME"
state_unset_prefix "AR:cfg|"
if state_get "AR:cfg|1"; then
  fail "state: unset_prefix removes registry keys"
else
  ok "state: unset_prefix removes registry keys"
fi
state_get "AR:other|1"
assert_eq "$STATE_VALUE" "arKEEPME" "state: unset_prefix spares other prefixes"

# --- host guard for managed packages
state_set UNISON_INSTALL_HOST "$(this_hostname)"
if managed_install_matches_host UNISON; then
  ok "managed: same host matches"
else
  fail "managed: same host matches"
fi
state_set UNISON_INSTALL_HOST "other-machine"
if managed_install_matches_host UNISON; then
  fail "managed: foreign host must not match"
else
  ok "managed: foreign host must not match"
fi

# --- installer -> remove command mapping
assert_eq "$(remove_cmd_for brew unison)" "brew uninstall unison" "remove cmd: brew"
assert_eq "$(remove_cmd_for apt-get unison)" "sudo apt-get remove -y unison" "remove cmd: apt-get"
assert_eq "$(remove_cmd_for pacman unison)" "sudo pacman -R --noconfirm unison" "remove cmd: pacman"
assert_eq "$(remove_cmd_for unknown unison)" "" "remove cmd: unknown installer"

# --- archive snapshot/record (override dir)
ARDIR="$WORK/archdir"
mkdir -p "$ARDIR"
ALS_UNISON_DIR_OVERRIDE="$ARDIR"
: >"$ARDIR/arOLD"; : >"$ARDIR/fpOLD"
SNAP_B="$WORK/snap.b"; SNAP_A="$WORK/snap.a"
archive_snapshot_file "$SNAP_B"
: >"$ARDIR/arNEW"; : >"$ARDIR/fpNEW"
archive_snapshot_file "$SNAP_A"
rm -f "$STDIR/alpsync.state"
registry_record_pair tcfg 1 "$SNAP_B" "$SNAP_A"
state_get "AR:tcfg|1"
assert_eq "$STATE_VALUE" "arNEW,fpNEW" "registry: records only new archives"
# second call records the new diff (run_sync guards first-run-only calling)
: >"$ARDIR/arTHIRD"
archive_snapshot_file "$SNAP_A"
registry_record_pair tcfg 1 "$SNAP_B" "$SNAP_A"
state_get "AR:tcfg|1"
assert_eq "$STATE_VALUE" "arNEW,arTHIRD,fpNEW" "registry: overwrite records newer diff (caller guards first run)"
# shellcheck disable=SC2034  # read via environment by subprocesses below
ALS_UNISON_DIR_OVERRIDE=""

# --------------------------------------------------------------------------
section "7. SSH diagnosis & remote install (stubbed ssh)"

# simple ssh stub: behaviour via ALS_SSH_MODE (ok|auth|refuse)
cat >"$STUBS/ssh" <<'EOF'
#!/bin/sh
case "${ALS_SSH_MODE:-refuse}" in
  ok)     exit 0 ;;
  auth)   echo "user@host: Permission denied (publickey)." >&2; exit 255 ;;
  *)      echo "ssh: connect to host h port 22: Connection refused" >&2; exit 255 ;;
esac
EOF
chmod +x "$STUBS/ssh"
PATH="$STUBS:$OLDPATH"
export ALS_SSH_MODE

ALS_SSH_MODE="refuse"
if ssh_connect_check "u@h"; then
  fail "ssh check: refused must fail"
else
  assert_eq "$SSH_CHECK_REASON" "unreachable" "ssh check: refused → unreachable"
fi
ALS_SSH_MODE="auth"
if ssh_connect_check "u@h"; then
  fail "ssh check: auth failure must fail"
else
  assert_eq "$SSH_CHECK_REASON" "auth" "ssh check: denied → auth"
fi
ALS_SSH_MODE="ok"
if ssh_connect_check "u@h:2222"; then
  ok "ssh check: ok passes (with port)"
else
  fail "ssh check: ok passes (with port)"
fi
unset ALS_SSH_MODE

# rich ssh stub: stateful fake remote for remote_install_unison
cat >"$STUBS/ssh" <<'EOF'
#!/bin/sh
LOG="${ALS_STUB_LOG:?stub log unset}"
echo "ssh:$*" >>"$LOG"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  *"uname -s"*)            echo "${ALS_FAKE_OS:-Linux}" ;;
  *"command -v brew"*)     exit 0 ;;
  *"for m in apt-get"*)    echo "${ALS_FAKE_MGR:-apt-get}" ;;
  *"apt-cache policy unison"*)
    echo "unison:"
    echo "  Installed: (none)"
    echo "  Candidate: ${ALS_FAKE_CAND:-2.53.4-1}"
    ;;
  *"for b in unison"*)
    if [ -f "${ALS_FAKE_MARK:-/nonexistent}" ]; then
      echo /usr/bin/unison
      exit 0
    fi
    exit 1
    ;;
  *"-version"*)            echo "unison version ${ALS_FAKE_VER:-2.53.4} (ocaml 5.2.0)" ;;
  *"install -y unison"*)   : >"${ALS_FAKE_MARK:?}"; exit 0 ;;
  *" true")                exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUBS/ssh"
# fake local unison (version provider)
cat >"$STUBS/unison" <<'EOF'
#!/bin/sh
echo "unison version 2.53.8 (ocaml 5.4.0)"
exit 0
EOF
chmod +x "$STUBS/unison"
UNISON_BIN="$STUBS/unison"
STLOG="$WORK/stub.log"
: >"$STLOG"
export ALS_STUB_LOG="$STLOG"

# happy path: apt would install 2.53.4 → matches local 2.53 → installs
RSTATE="$WORK/remote.state"
rm -f "$RSTATE" "$WORK/fake-mark"
ALS_STATE_FILE="$RSTATE"
export ALS_FAKE_OS="Linux" ALS_FAKE_MGR="apt-get" ALS_FAKE_CAND="2.53.4-1" ALS_FAKE_MARK="$WORK/fake-mark"
if remote_install_unison "carol@remote"; then
  ok "remote install: version match → installed"
else
  fail "remote install: version match → installed"
fi
if grep -q 'sudo apt-get install -y unison' "$STLOG"; then
  ok "remote install: correct install command issued"
else
  fail "remote install: correct install command issued" "log: $(cat "$STLOG")"
fi
state_get REMOTE_UNISON_MANAGED
assert_eq "$STATE_VALUE" "1" "remote install: marked managed in state"
state_get REMOTE_UNISON_TARGET
assert_eq "$STATE_VALUE" "carol@remote" "remote install: target recorded"

# mismatch path: apt would install 2.48 → refused, nothing installed
: >"$STLOG"
rm -f "$RSTATE" "$WORK/fake-mark"
ALS_STATE_FILE="$RSTATE"
export ALS_FAKE_CAND="2.48.4-1"
if remote_install_unison "carol@remote"; then
  fail "remote install: version mismatch must be refused"
else
  ok "remote install: version mismatch must be refused"
fi
if grep -q 'install -y unison' "$STLOG"; then
  fail "remote install: no install command on mismatch"
else
  ok "remote install: no install command on mismatch"
fi
state_get REMOTE_UNISON_MANAGED
assert_eq "$STATE_VALUE" "" "remote install: mismatch not marked managed"
unset ALS_STUB_LOG ALS_FAKE_OS ALS_FAKE_MGR ALS_FAKE_CAND ALS_FAKE_MARK
PATH="$OLDPATH"
# shellcheck disable=SC2034  # cleanup; read by sourced functions
UNISON_BIN=""
ALS_STATE_FILE=""

# --------------------------------------------------------------------------
section "8. Wizard e2e SSH (stubbed remote) & uninstall e2e"

# --- wizard with SSH mode + successful "test connection now"
WBS="$WORK/wizssh"
mkdir -p "$WBS/home"
cp "$SCRIPT" "$WBS/alpsync.sh"
PATH="$STUBS:$OLDPATH"
export ALS_STUB_LOG="$WORK/wizssh-stub.log"
: >"$ALS_STUB_LOG"
# shellcheck disable=SC2034  # consumed by the ssh stub subprocess
export ALS_FAKE_OS="Linux" ALS_FAKE_MGR="apt-get" ALS_FAKE_MARK="$WBS/fake-installed"
: >"$ALS_FAKE_MARK"
# pair with '~/Downloads' remote: wizard must store it normalized (no '~/')
printf '1\nsshconf\n\ny\nremote\ndev\n22\n\ny\n%s ~/Downloads\n\n\ny\nn\n' \
  "$WBS/src" \
  | HOME="$WBS/home" UNISON="$WBS/home/.unison" bash "$WBS/alpsync.sh" >/dev/null 2>&1
assert_eq "$?" "0" "wizard ssh: runs rc 0"
if grep -q 'MODE="ssh"' "$WBS/sshconf.conf" 2>/dev/null; then
  ok "wizard ssh: MODE=ssh written"
else
  fail "wizard ssh: MODE=ssh written"
fi
if grep -q 'REMOTE_HOST="remote"' "$WBS/sshconf.conf" 2>/dev/null; then
  ok "wizard ssh: REMOTE_HOST written"
else
  fail "wizard ssh: REMOTE_HOST written"
fi
if grep -qF "|Downloads\"" "$WBS/sshconf.conf" 2>/dev/null; then
  ok "wizard ssh: remote path normalized (~/ stripped)"
else
  fail "wizard ssh: remote path normalized (~/ stripped)" "$(cat "$WBS/sshconf.conf" 2>/dev/null)"
fi
# shellcheck disable=SC2088  # literal '~/' is what must NOT appear
if grep -q '~/Downloads' "$WBS/sshconf.conf" 2>/dev/null; then
  fail "wizard ssh: no literal '~/' left in config"
else
  ok "wizard ssh: no literal '~/' left in config"
fi
unset ALS_STUB_LOG ALS_FAKE_OS ALS_FAKE_MGR ALS_FAKE_MARK
PATH="$OLDPATH"

# --- uninstall e2e (piped): alias, config selection, archives, managed pkgs
UB="$WORK/uninbox"
UB_HOME="$WORK/unin-home"
UB_ARCH="$WORK/unin-archives"
mkdir -p "$UB" "$UB_HOME" "$UB_ARCH"
cp "$SCRIPT" "$UB/alpsync.sh"
printf 'LABEL="d"\nMODE="local"\nPAIRS=(\n  "%s/x|%s/y"\n)\n' "$UB" "$UB" >"$UB/del.conf"
printf 'LABEL="k"\nMODE="local"\nPAIRS=(\n  "%s/kx|%s/ky"\n)\n' "$UB" "$UB" >"$UB/keep.conf"
{
  echo "# user zshrc line"
  echo "# >>> alpsync >>>"
  echo "alias alpsync=\"/some/where/alpsync.sh\""
  echo "# <<< alpsync <<<"
  echo "# another user line"
} >"$UB_HOME/.zshrc"
: >"$UB_ARCH/arDEL"; : >"$UB_ARCH/fpDEL2"; : >"$UB_ARCH/arKEEP"; : >"$UB_ARCH/arFOREIGN"
{
  echo "AR:del|1=arDEL,fpDEL2"
  echo "AR:keep|1=arKEEP"
  echo "UNISON_MANAGED=1"
  echo "UNISON_INSTALLER=brew"
  echo "UNISON_INSTALL_HOST=$(this_hostname)"
  echo "REMOTE_UNISON_MANAGED=1"
  echo "REMOTE_UNISON_INSTALLER=apt-get"
  echo "REMOTE_UNISON_TARGET=carol@remote:22"
} >"$UB/alpsync.state"

cat >"$STUBS/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >>"${ALS_STUB_LOG:?}"
exit 0
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"${ALS_STUB_LOG:?}"
exit 0
EOF
cat >"$STUBS/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >>"${ALS_STUB_LOG:?}"
exit 0
EOF
chmod +x "$STUBS/brew" "$STUBS/sudo" "$STUBS/ssh"
STLOG2="$WORK/unin-stub.log"
: >"$STLOG2"
export ALS_STUB_LOG="$STLOG2"

UNIN_OUT="$WORK/unin.out"
printf 'y\n1\ny\ny\nn\nn\ny\n' \
  | HOME="$UB_HOME" ALS_UNISON_DIR_OVERRIDE="$UB_ARCH" PATH="$STUBS:$OLDPATH" \
    bash "$UB/alpsync.sh" --uninstall >"$UNIN_OUT" 2>&1
assert_eq "$?" "0" "uninstall: runs rc 0"
if [ -d "$UB" ]; then
  fail "uninstall: script directory removed"
else
  ok "uninstall: script directory removed"
fi
if grep -qF '# >>> alpsync >>>' "$UB_HOME/.zshrc"; then
  fail "uninstall: alias block removed from rc file"
else
  ok "uninstall: alias block removed from rc file"
fi
if grep -q '# user zshrc line' "$UB_HOME/.zshrc" && grep -q '# another user line' "$UB_HOME/.zshrc"; then
  ok "uninstall: user rc lines preserved"
else
  fail "uninstall: user rc lines preserved"
fi
if grep -q 'cleaned:' "$UNIN_OUT"; then
  ok "uninstall: alias cleanup reported"
else
  fail "uninstall: alias cleanup reported"
fi
if grep -q 'configuration files deleted' "$UNIN_OUT"; then
  ok "uninstall: config deletion reported"
else
  fail "uninstall: config deletion reported"
fi
if grep -q 'unison archives deleted' "$UNIN_OUT"; then
  ok "uninstall: archive deletion reported"
else
  fail "uninstall: archive deletion reported"
fi
if grep -q 'was installed by alpsync (via brew)' "$UNIN_OUT"; then
  ok "uninstall: managed local unison offered"
else
  fail "uninstall: managed local unison offered"
fi
if grep -q 'was installed by alpsync (via apt-get)' "$UNIN_OUT"; then
  ok "uninstall: managed remote unison offered"
else
  fail "uninstall: managed remote unison offered"
fi
if [ -s "$STLOG2" ]; then
  fail "uninstall: declined steps must not run commands" "log: $(cat "$STLOG2")"
else
  ok "uninstall: declined steps must not run commands"
fi
# archives: selected config's gone, others kept (checked before dir removal)
# → rebuild scenario without self-removal for archive assertions
UB2="$WORK/uninbox2"
UB2_ARCH="$WORK/uninbox2-archives"
mkdir -p "$UB2/home" "$UB2_ARCH"
cp "$SCRIPT" "$UB2/alpsync.sh"
printf 'LABEL="d"\nMODE="local"\nPAIRS=(\n  "%s/x|%s/y"\n)\n' "$UB2" "$UB2" >"$UB2/del.conf"
printf 'LABEL="k"\nMODE="local"\nPAIRS=(\n  "%s/kx|%s/ky"\n)\n' "$UB2" "$UB2" >"$UB2/keep.conf"
: >"$UB2_ARCH/arDEL"; : >"$UB2_ARCH/fpDEL2"; : >"$UB2_ARCH/arKEEP"; : >"$UB2_ARCH/arFOREIGN"
: >"$UB2/strange-user-file"
{
  echo "AR:del|1=arDEL,fpDEL2"
  echo "AR:keep|1=arKEEP"
} >"$UB2/alpsync.state"
printf '1\ny\ny\n' \
  | HOME="$UB2/home" ALS_UNISON_DIR_OVERRIDE="$UB2_ARCH" PATH="$STUBS:$OLDPATH" \
    bash "$UB2/alpsync.sh" --uninstall >"$WORK/unin2.out" 2>&1
assert_eq "$?" "0" "uninstall (no managed pkgs): runs rc 0"
if [ -f "$UB2_ARCH/arDEL" ] || [ -f "$UB2_ARCH/fpDEL2" ]; then
  fail "uninstall: selected config's archives deleted"
else
  ok "uninstall: selected config's archives deleted"
fi
assert_file "$UB2_ARCH/arKEEP" "uninstall: unselected config's archives kept"
assert_file "$UB2_ARCH/arFOREIGN" "uninstall: foreign archives kept"
if grep -q 'was not installed by alpsync' "$WORK/unin2.out"; then
  ok "uninstall: unmanaged packages skipped"
else
  fail "uninstall: unmanaged packages skipped"
fi
if [ -f "$UB2/keep.conf" ] && [ ! -f "$UB2/del.conf" ]; then
  ok "uninstall: only selected config deleted"
else
  fail "uninstall: only selected config deleted"
fi
if grep -q 'alpsync will not delete this directory' "$WORK/unin2.out" && [ -f "$UB2/strange-user-file" ]; then
  ok "uninstall: refuses self-removal with unknown files present"
else
  fail "uninstall: refuses self-removal with unknown files present"
fi
unset ALS_STUB_LOG
PATH="$OLDPATH"

# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
