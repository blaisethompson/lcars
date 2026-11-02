#!/usr/bin/env bash
# Round-trip harness for lcars install.sh: install, then --uninstall, in a fake HOME.
#
#   tests/run.sh [FILTER]
#
# FILTER: exact scenario name, else substring match. Env: INSTALLER (default
# this checkout's install.sh), KEEP=1 to keep temp roots.
# Runs only against stubs (cmux, defaults, opencode); never touches the real HOME.

TESTS="$(cd "$(dirname "$0")" && pwd)"
STUBS="$TESTS/stubs"
INSTALLER="${INSTALLER:-$(cd "$TESTS/.." && pwd)/install.sh}"
REPO="$(dirname "$INSTALLER")"
SAFE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
FILTER="${1:-}"

abort() { echo "ABORT: $*" >&2; exit 99; }

# --- guard -----------------------------------------------------------------
# $1 = "home" additionally requires HOME to be the scenario's fake home.
guard() {
  local c p
  for c in cmux defaults opencode; do
    p="$(command -v "$c" 2>/dev/null)" || abort "$c not found on PATH"
    [[ "$p" == "$STUBS/"* ]] || abort "$c resolves to $p, not the stubs dir"
  done
  if [[ "${1:-}" == home ]]; then
    [[ -n "${ROOT:-}" && "$HOME" == "$ROOT/home" && "$ROOT" == /*/lcars-test.* ]] || abort "HOME=$HOME is not under the temp root"
    [[ "$XDG_CONFIG_HOME" == "$HOME/.config" && "$OPENCODE_CONFIG_DIR" == "$HOME/.config/opencode" ]] || abort "config dirs are not under the fake HOME"
  fi
}
for v in $(env | sed -n 's/^\(CMUX_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
export PATH="$SAFE_PATH"
guard
[[ -x "$STUBS/cmux" && -x "$STUBS/defaults" && -x "$STUBS/opencode" ]] || abort "stubs missing"
# Stands in for cmux's unpatched tui.js: the "before" side of lcars's patch,
# which is all that patching it needs.
UNPATCHED="$(mktemp "${TMPDIR:-/tmp}/lcars-tui.XXXXXX")" || abort "mktemp failed"
trap 'rm -f "$UNPATCHED"' EXIT
sed -n 's/^[ -]//p' "$REPO/opencode/cmux-tui.patch" | grep -v '^-- tui\.js$' > "$UNPATCHED"
patch --dry-run --silent "$UNPATCHED" < "$REPO/opencode/cmux-tui.patch" >/dev/null || abort "patch doesn't apply to the fixture"
[[ -f "$INSTALLER" ]] || abort "missing $INSTALLER"

FULL=(--select --opencode --theme --opencode-theme --claude-theme --codex-theme)

# --- scenario plumbing -------------------------------------------------------
fail() { printf '%s\n' "$*" >> "$ROOT/failures"; }

N=0
inst_as() { # SCRIPT ARGS...  (sets LAST_OUT, LAST_RC; fails the scenario on nonzero)
  local script="$1"; shift
  guard home
  N=$((N + 1)); LAST_OUT="$ROOT/out.$N"
  echo "\$ install.sh $*" > "$LAST_OUT"
  env -i HOME="$HOME" PATH="$SAFE_PATH" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    OPENCODE_CONFIG_DIR="$OPENCODE_CONFIG_DIR" LCARS_TEST_ROOT="$ROOT" \
    LCARS_TUI_UNPATCHED="$UNPATCHED" TMPDIR="$ROOT/tmp" LANG=en_US.UTF-8 \
    bash "$script" "$@" >> "$LAST_OUT" 2>&1
  LAST_RC=$?
  [[ $LAST_RC -eq 0 ]] || fail "install.sh $* exited $LAST_RC (see $LAST_OUT)"
  return 0
}
inst() { inst_as "$INSTALLER" "$@"; }

log_mark() { LOGMARK=$(( $(wc -l < "$ROOT/cmux.log") )); }
log_after() { tail -n +$((LOGMARK + 1)) "$ROOT/cmux.log"; }
log_has() { log_after | grep -qxF -- "$1"; }
assert_log_has() { log_has "$1" || fail "cmux log lacks: $1"; }
assert_log_lacks_re() { # REGEX DESC
  local m; m="$(log_after | grep -E -- "$1")" && fail "unexpected cmux call(s) ($2): $m"; return 0; }
assert_out_has() { grep -Eq -- "$1" "$LAST_OUT" || fail "output of ${LAST_OUT##*/} lacks /$1/"; }
assert_out_lacks() { grep -Eq -- "$1" "$LAST_OUT" && fail "output of ${LAST_OUT##*/} has /$1/"; return 0; }
assert_file_has() { grep -Eq -- "$2" "$1" 2>/dev/null || fail "$1 lacks /$2/"; }
assert_file_lacks() { [[ -f "$1" ]] && grep -Eqi -- "$2" "$1" && fail "$1 has /$2/"; return 0; }
assert_exists() { [[ -e "$1" || -L "$1" ]] || fail "missing: $1"; }
assert_absent() { [[ -e "$1" || -L "$1" ]] && fail "should not exist: $1"; return 0; }

links() { (cd "$1" && find . -type l | sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done); }
emptydirs() { (cd "$1" && find . -type d -empty | sort); }

assert_identical() { # [EXPECTED_DIR]  compares it with the current HOME
  local exp="${1:-$ROOT/before}" d b
  d="$(diff -r "$exp" "$HOME" 2>&1)" || fail "tree differs from expected (diff -r expected home):
$d"
  d="$(diff <(links "$exp") <(links "$HOME") 2>&1)" || fail "symlinks differ:
$d"
  d="$(diff <(emptydirs "$exp") <(emptydirs "$HOME") 2>&1)" || fail "empty directories differ:
$d"
  b="$(find "$HOME" -name '*.bak' 2>/dev/null)"
  [[ -z "$b" ]] || fail "stranded backups: $b"
  return 0
}

common_checks() {
  [[ ! -s "$ROOT/defaults.log" ]] || fail "defaults write/delete attempted: $(cat "$ROOT/defaults.log")"
  grep -q '^UNEXPECTED' "$ROOT/cmux.log" && fail "unexpected cmux calls: $(grep '^UNEXPECTED' "$ROOT/cmux.log")"
  return 0
}

snap_before() { rm -rf "$ROOT/before"; cp -a "$HOME" "$ROOT/before"; }
mk_expected() { rm -rf "$ROOT/expected"; cp -a "$ROOT/before" "$ROOT/expected"; }
expect_pref_lcars() { # --select can't be undone to the built-in sidebar (no defaults write)
  mkdir -p "$ROOT/expected/.fake-prefs"; echo cmux.sidebar.custom.lcars > "$ROOT/expected/.fake-prefs/sidebar"; }

reset_machine() { # wipe HOME and per-machine logs, then make the base layout
  rm -rf "$HOME" "$ROOT/before" "$ROOT/expected" "$ROOT/ghostty-created-by-set" "$ROOT/cmux.log" "$ROOT/defaults.log"
  : > "$ROOT/cmux.log"
  mkdir -p "$HOME/Library/Application Support/com.cmuxterm.app"
}

make_existing() {
  mkdir -p "$(dirname "$GCFG")" "$HOME/.fake-prefs" "$SIDEBARS" "$(dirname "$T_GHOSTTY")" \
    "$(dirname "$T_OC")" "$(dirname "$T_CLAUDE")" "$(dirname "$T_CODEX")" "$HOME/.claude" "$HOME/.codex"
  printf 'font-size = 13\nsurface-tab-bar-font-size = 11\n\n# cmux themes start\ntheme = light:Catppuccin Latte,dark:Catppuccin Mocha\n# cmux themes end\n' > "$GCFG"
  echo cmux.sidebar.custom.other > "$HOME/.fake-prefs/sidebar"
  printf '// my other sidebar\n' > "$SIDEBARS/other.js"
  printf '// my own sidebar\n' > "$SIDEBARS/lcars.js"
  printf 'palette = 0=#111111\n' > "$T_GHOSTTY"
  printf '{"theme":{"primary":"#ffffff"}}\n' > "$T_OC"
  printf '{"name":"Mine","base":"dark"}\n' > "$T_CLAUDE"
  printf '<plist><dict>my theme</dict></plist>\n' > "$T_CODEX"
  printf '{\n    "theme": {\n        "name": "dark"\n    },\n    "other": 1\n}' > "$OC_CLI"
  printf '{ "theme":"dark",   "model" : "opus",\n\t"env":{"A":"1"} }\n' > "$CL_SET"
  printf '# my codex config\nmodel = "gpt-5"\n\n[tui]\nnotifications = true\ntheme = "ansi"\nanimations = false\n\n# projects\n[projects."/tmp/x"]\ntrust_level = "trusted"\n' > "$CX_CFG"
}

# Adds a line after the first line of a JSON file (an extra top-level key).
json_add_key() { awk 'NR == 1 { print; print "  \"extra_key\": true,"; next } { print }' "$1" > "$1.new" && cat "$1.new" > "$1" && rm "$1.new"; }

# --- scenarios ----------------------------------------------------------------
sc_fresh() {
  snap_before
  inst "${FULL[@]}"
  inst --uninstall
  assert_out_has 'Default Workspaces'
  mk_expected; expect_pref_lcars
  assert_identical "$ROOT/expected"
}

sc_existing() {
  make_existing; snap_before
  inst "${FULL[@]}"
  log_mark
  inst --uninstall
  assert_identical
  local a='themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"' b='themes set --dark "Catppuccin Mocha" --light "Catppuccin Latte"'
  grep -qxF -e "$a" "$ROOT/cmux.log" || grep -qxF -e "$b" "$ROOT/cmux.log" || fail "cmux log lacks: $a"
  local l o
  l="$(grep -nxF 'sidebar select lcars' "$ROOT/cmux.log" | tail -n1 | cut -d: -f1)"
  o="$(grep -nxF 'sidebar select other' "$ROOT/cmux.log" | tail -n1 | cut -d: -f1)"
  { [[ -n "$l" && -n "$o" ]] && [[ $o -gt $l ]]; } || fail "'sidebar select other' not after 'sidebar select lcars' (lcars@${l:-none} other@${o:-none})"
}

sc_rerun() {
  local kind
  for kind in fresh existing; do
    reset_machine
    [[ $kind == existing ]] && make_existing
    snap_before
    inst "${FULL[@]}"
    local s1 s2 bad
    s1="$(grep -E '^(app\.[a-z]+\.before|cmux_theme\.(override|light|dark)|sidebar\.before)=' "$XDG_CONFIG_HOME/lcars/install-state" 2>/dev/null | sort)"
    [[ -f "$XDG_CONFIG_HOME/lcars/install-state" ]] || fail "$kind: no install-state after first install"
    [[ $kind == fresh || -n "$s1" ]] || fail "$kind: no before-records after first install"
    sleep 1
    inst "${FULL[@]}"
    s2="$(grep -E '^(app\.[a-z]+\.before|cmux_theme\.(override|light|dark)|sidebar\.before)=' "$XDG_CONFIG_HOME/lcars/install-state" 2>/dev/null | sort)"
    [[ "$s1" == "$s2" ]] || fail "$kind: records changed on re-run:
--- first
$s1
--- second
$s2"
    bad="$(printf '%s\n' "$s2" | grep -Ei '=(lcars|custom:lcars|cmux\.sidebar\.custom\.lcars)$')"
    [[ -z "$bad" ]] || fail "$kind: a record now holds LCARS: $bad"
    inst --uninstall
    mk_expected; [[ $kind == fresh ]] && expect_pref_lcars
    assert_identical "$ROOT/expected"
  done
}

mk_old_repo() { # temp copy of the repo whose files differ (a "previous version")
  OLD="$ROOT/oldrepo"; rm -rf "$OLD"; mkdir -p "$OLD"
  cp "$REPO/install.sh" "$REPO/lcars.js" "$OLD/"
  cp -R "$REPO/opencode" "$REPO/claude" "$REPO/codex" "$REPO/theme" "$OLD/"
  printf '\n// previous version\n' >> "$OLD/lcars.js"
  printf '\n# previous version\n' >> "$OLD/theme/LCARS"
  printf '\n' >> "$OLD/opencode/lcars.json"; printf ' \n' >> "$OLD/claude/lcars.json"
  printf '\n<!-- previous version -->\n' >> "$OLD/codex/lcars.tmTheme"
  for f in lcars.js theme/LCARS opencode/lcars.json claude/lcars.json codex/lcars.tmTheme; do
    cmp -s "$OLD/$f" "$REPO/$f" && fail "old copy of $f is not different"
  done
  return 0
}

sc_upgrade() {
  mk_old_repo
  reset_machine; make_existing; snap_before
  inst_as "$OLD/install.sh" "${FULL[@]}"
  inst "${FULL[@]}"
  assert_out_lacks 'Backed up'
  inst --uninstall
  mk_expected; assert_identical "$ROOT/expected"

  reset_machine; make_existing; snap_before
  inst_as "$OLD/install.sh" "${FULL[@]}"
  inst --uninstall
  assert_identical
}

sc_no_state() {
  make_existing
  inst "${FULL[@]}"
  rm -rf "$XDG_CONFIG_HOME/lcars"
  log_mark
  inst --uninstall
  local n; n="$(grep -ci 'install record' "$LAST_OUT")"
  [[ "$n" == 1 ]] || fail "expected exactly one 'install record' notice, saw $n"
  assert_out_has 'no record of the previous theme'
  assert_out_has "Pick another sidebar"
  assert_log_has 'themes clear'
  assert_log_lacks_re '^themes set' 'themes set during no-state uninstall'
  assert_absent "$XDG_CONFIG_HOME/lcars"
  assert_absent "$SIDEBARS/lcars.js"
  assert_absent "$T_GHOSTTY"; assert_absent "$T_OC"; assert_absent "$T_CLAUDE"; assert_absent "$T_CODEX"
  assert_file_lacks "$OC_CLI" lcars; assert_file_has "$OC_CLI" '"other"'
  assert_file_lacks "$CL_SET" lcars; assert_file_has "$CL_SET" '"model"'
  assert_file_lacks "$CX_CFG" 'theme[[:space:]]*=[[:space:]]*"lcars"'; assert_file_has "$CX_CFG" 'projects'
  assert_file_lacks "$GCFG" 'LCARS'
}

sc_edited_after() {
  make_existing
  inst "${FULL[@]}"
  local t baks=""
  for t in "$T_GHOSTTY" "$T_OC" "$T_CLAUDE" "$T_CODEX"; do
    printf '\n# edited by user\n' >> "$t"
    baks="$baks$(ls "$t".*.bak 2>/dev/null) "
    ls "$t".*.bak >/dev/null 2>&1 || fail "no .bak was made for $t at install"
  done
  inst --uninstall
  for t in "$T_GHOSTTY" "$T_OC" "$T_CLAUDE" "$T_CODEX"; do
    assert_file_has "$t" 'edited by user'
    assert_out_has "Kept $t"
    ls "$t".*.bak >/dev/null 2>&1 || fail "backup of $t was deleted"
    local b; for b in $(ls "$t".*.bak 2>/dev/null); do
      grep -qF "$b" "$LAST_OUT" || fail "output does not name the backup $b"
    done
  done
}

sc_changed_after() {
  make_existing
  inst "${FULL[@]}"
  sed 's/"custom:lcars"/"light"/' "$CL_SET" > "$CL_SET.new" && cat "$CL_SET.new" > "$CL_SET" && rm "$CL_SET.new"
  json_add_key "$CL_SET"
  sed 's/"lcars"/"tokyonight"/' "$OC_CLI" > "$OC_CLI.new" && cat "$OC_CLI.new" > "$OC_CLI" && rm "$OC_CLI.new"
  sed 's/^theme = .*/theme = light:Foo,dark:Foo/' "$GCFG" > "$GCFG.new" && cat "$GCFG.new" > "$GCFG" && rm "$GCFG.new"
  echo cmux.sidebar.custom.other > "$HOME/.fake-prefs/sidebar"
  log_mark
  inst --uninstall
  assert_log_lacks_re '^(themes (clear|set)|sidebar select)' 'user choices must be left alone'
  assert_file_has "$CL_SET" '"theme": *"light"'; assert_file_has "$CL_SET" 'extra_key'
  assert_file_has "$OC_CLI" '"tokyonight"'
  assert_file_has "$GCFG" 'theme = light:Foo,dark:Foo'
  assert_file_has "$HOME/.fake-prefs/sidebar" '^cmux.sidebar.custom.other$'
}

sc_key_level() {
  make_existing; snap_before
  inst "${FULL[@]}"
  json_add_key "$CL_SET"; json_add_key "$OC_CLI"
  awk '{ print } /^theme *= *"lcars"/ { print "newkey = 1" }' "$CX_CFG" > "$CX_CFG.new" && cat "$CX_CFG.new" > "$CX_CFG" && rm "$CX_CFG.new"
  inst --uninstall
  assert_file_has "$CL_SET" '"theme" *: *"dark"'; assert_file_has "$CL_SET" 'extra_key'; assert_file_lacks "$CL_SET" 'custom:lcars'
  assert_file_has "$OC_CLI" '"name" *: *"dark"'; assert_file_has "$OC_CLI" 'extra_key'; assert_file_lacks "$OC_CLI" lcars
  assert_file_has "$CX_CFG" '^theme = "ansi"$'; assert_file_has "$CX_CFG" '^newkey = 1$'
  local ln lt la
  ln="$(grep -n '^notifications' "$CX_CFG" | cut -d: -f1)"; lt="$(grep -n '^theme' "$CX_CFG" | cut -d: -f1)"; la="$(grep -n '^animations' "$CX_CFG" | cut -d: -f1)"
  { [[ -n "$ln" && -n "$lt" && -n "$la" && $ln -lt $lt && $lt -lt $la ]]; } || fail "codex theme line is not in its original place (notifications@$ln theme@$lt animations@$la)"
  assert_absent "$XDG_CONFIG_HOME/lcars"
  local b; b="$(find "$HOME" -name '*.bak')"; [[ -z "$b" ]] || fail "stranded backups: $b"
}

sc_symlinked_settings() {
  make_existing
  mkdir -p "$HOME/dotfiles"
  mv "$CL_SET" "$HOME/dotfiles/claude-settings.json"
  ln -s ../dotfiles/claude-settings.json "$CL_SET"
  snap_before
  inst "${FULL[@]}"
  [[ -L "$CL_SET" ]] || fail "settings.json stopped being a symlink after install"
  assert_file_has "$HOME/dotfiles/claude-settings.json" 'custom:lcars'
  inst --uninstall
  [[ -L "$CL_SET" ]] || fail "settings.json is not a symlink after uninstall"
  assert_identical
}

oc_prestage() { # pre-existing cmux OpenCode integration, made by the stub
  cp -a "$HOME" "$ROOT/base"
  cmux hooks opencode install --yes >/dev/null
  cmp -s "$HOME/.config/opencode/plugins/cmux/tui.js" "$UNPATCHED" || fail "stub did not install the unpatched tui.js"
}

sc_opencode_preexisting() {
  oc_prestage; snap_before
  local dis="$HOME/.config/opencode/plugins-disabled"
  log_mark
  inst --opencode
  grep -q 'lcars-opencode-patch' "$HOME/.config/opencode/plugins/cmux/tui.js" || fail "tui.js was not patched by install"
  inst --uninstall
  assert_log_lacks_re '^hooks opencode uninstall' 'integration was there before; plain uninstall must keep it'
  cmp -s "$HOME/.config/opencode/plugins/cmux/tui.js" "$UNPATCHED" || fail "tui.js is not the unpatched bytes"
  assert_out_has 'Duplicate plugin ID'
  mk_expected
  mkdir -p "$ROOT/expected/.config/opencode/plugins-disabled"
  mv "$ROOT/expected/.config/opencode/plugins/cmux-feed.js" "$ROOT/expected/.config/opencode/plugins/cmux-session.js" "$ROOT/expected/.config/opencode/plugins-disabled/"
  assert_identical "$ROOT/expected"
  assert_exists "$dis/cmux-feed.js"; assert_exists "$dis/cmux-session.js"
}

sc_opencode_flag() {
  oc_prestage; snap_before
  inst --opencode
  inst --uninstall --opencode
  local o="$HOME/.config/opencode"
  assert_absent "$o/plugins/cmux"; assert_absent "$o/plugins"; assert_absent "$o/plugins-disabled"; assert_absent "$o/opencode.json"
  rm -rf "$ROOT/expected"; cp -a "$ROOT/base" "$ROOT/expected"; mkdir -p "$ROOT/expected/.config/opencode"
  assert_identical "$ROOT/expected"
}

sc_opencode_fresh_plain() {
  snap_before
  inst --opencode
  assert_exists "$HOME/.config/opencode/plugins/cmux"
  inst --uninstall
  assert_absent "$HOME/.config/opencode/plugins/cmux"
  assert_identical
}

sc_opencode_json_existing() {
  local v
  for v in unchanged edited; do
    reset_machine
    mkdir -p "$OPENCODE_CONFIG_DIR"
    printf '{ "model" : "anthropic/x",\n    "theme":"dark" }' > "$OPENCODE_CONFIG_DIR/opencode.json"
    snap_before
    inst --opencode
    assert_file_has "$OPENCODE_CONFIG_DIR/opencode.json" './plugins/cmux'
    if [[ $v == edited ]]; then
      json_add_key "$OPENCODE_CONFIG_DIR/opencode.json"
      inst --uninstall
      assert_out_has "Kept .*opencode\.json"
      assert_file_has "$OPENCODE_CONFIG_DIR/opencode.json" 'extra_key'
      assert_file_lacks "$OPENCODE_CONFIG_DIR/opencode.json" './plugins/cmux'
      assert_absent "$OPENCODE_CONFIG_DIR/plugins"
    else
      inst --uninstall
      assert_identical
    fi
  done
}

sc_partial() {
  make_existing; snap_before
  inst --theme
  grep -q '^app\.' "$XDG_CONFIG_HOME/lcars/install-state" 2>/dev/null && fail "state has app.* records after a --theme-only install"
  log_mark
  inst --uninstall
  assert_log_lacks_re '^hooks' 'no OpenCode work expected'
  assert_identical
}

sc_no_change_no_state() {
  mkdir -p "$SIDEBARS"; cp "$REPO/lcars.js" "$SIDEBARS/lcars.js"
  snap_before
  inst
  assert_absent "$XDG_CONFIG_HOME/lcars"
  assert_identical
}

sc_one_sided_theme() {
  local c="$HOME/Library/Application Support/com.cmuxterm.app/config.ghostty"
  printf '# cmux themes start\ntheme = light:Solo Theme\n# cmux themes end\n' > "$c"
  snap_before
  inst --theme
  log_mark
  inst --uninstall
  assert_log_has 'themes clear'
  assert_file_lacks "$c" 'LCARS'
  assert_file_has "$c" 'Solo Theme'
}

sc_never_selected_quiet() {
  snap_before
  inst
  inst --uninstall
  assert_out_lacks 'right-click|Pick another'
  assert_identical
}

sc_opencode_disabled_kept() {
  oc_prestage
  mkdir -p "$OPENCODE_CONFIG_DIR/plugins-disabled"
  mv "$OPENCODE_CONFIG_DIR/plugins/cmux-session.js" "$OPENCODE_CONFIG_DIR/plugins/cmux-feed.js" "$OPENCODE_CONFIG_DIR/plugins-disabled/"
  snap_before
  inst --opencode
  inst --uninstall
  assert_out_has "Left cmux's OpenCode integration in place"
  assert_exists "$OPENCODE_CONFIG_DIR/plugins-disabled/cmux-session.js"
  assert_identical
}

sc_select_missing() {
  make_existing
  inst --select
  rm "$SIDEBARS/other.js"
  log_mark
  inst --uninstall
  assert_log_lacks_re '^sidebar select' 'other.js is gone; nothing to select'
  assert_out_has 'other'
}

SCENARIOS="fresh existing rerun upgrade no-state edited-after changed-after key-level symlinked-settings opencode-preexisting opencode-flag opencode-fresh-plain opencode-json-existing partial no-change-no-state select-missing one-sided-theme never-selected-quiet opencode-disabled-kept"

run_scenario() {
  local name="$1" fn
  fn="sc_$(echo "$name" | tr - _)"
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lcars-test.XXXXXX")" || abort "mktemp failed"
  ROOT="$(cd "$ROOT" && pwd)"
  (
    export LCARS_TEST_ROOT="$ROOT" LCARS_TUI_UNPATCHED="$UNPATCHED"
    export HOME="$ROOT/home" PATH="$SAFE_PATH"
    export XDG_CONFIG_HOME="$HOME/.config" OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
    unset CLAUDE_CONFIG_DIR CODEX_HOME
    GCFG="$HOME/Library/Application Support/com.cmuxterm.app/config.ghostty"
    SIDEBARS="$HOME/.config/cmux/sidebars"
    T_GHOSTTY="$XDG_CONFIG_HOME/ghostty/themes/LCARS"
    T_OC="$OPENCODE_CONFIG_DIR/themes/lcars.json"
    T_CLAUDE="$HOME/.claude/themes/lcars.json"
    T_CODEX="$HOME/.codex/themes/lcars.tmTheme"
    OC_CLI="$OPENCODE_CONFIG_DIR/cli.json"; CL_SET="$HOME/.claude/settings.json"; CX_CFG="$HOME/.codex/config.toml"
    mkdir -p "$ROOT/tmp"
    guard home
    reset_machine
    "$fn"
    common_checks
  )
  local rc=$?
  if [[ -s "$ROOT/failures" || $rc -ne 0 ]]; then
    echo "FAIL $name"
    [[ $rc -eq 0 ]] || echo "  scenario function exited $rc"
    sed 's/^/  /' "$ROOT/failures" 2>/dev/null
    local f; for f in "$ROOT"/out.*; do [[ -f "$f" ]] || continue; echo "  --- ${f##*/}"; head -n 40 "$f" | sed 's/^/  | /'; done
    echo "  (kept $ROOT)"
    return 1
  fi
  echo "PASS $name"
  [[ -n "${KEEP:-}" ]] || rm -rf "$ROOT"
  return 0
}

list=""
for s in $SCENARIOS; do [[ "$s" == "$FILTER" ]] && list="$s"; done
if [[ -z "$list" ]]; then
  for s in $SCENARIOS; do case "$s" in *"$FILTER"*) list="$list $s" ;; esac; done
fi
[[ -n "$list" ]] || { echo "no scenario matches '$FILTER'; have: $SCENARIOS" >&2; exit 2; }

pass=0; failn=0
for s in $list; do
  if run_scenario "$s"; then pass=$((pass + 1)); else failn=$((failn + 1)); fi
done
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
