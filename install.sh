#!/usr/bin/env bash
# Install the lcars custom sidebar into cmux.
#
#   ./install.sh               copy lcars.js into ~/.config/cmux/sidebars
#   ./install.sh --select      also make lcars the left sidebar
#   ./install.sh --opencode    also install cmux's OpenCode integration, and
#                              patch it to name tabs and end closed sessions
#   ./install.sh --theme       also install the LCARS terminal colour theme
#                              and make it cmux's theme
#   ./install.sh --opencode-theme
#                              also install the LCARS OpenCode theme and make
#                              it OpenCode's theme
#   ./install.sh --claude-theme
#                              also install the LCARS Claude Code theme and
#                              make it Claude Code's theme
#   ./install.sh --codex-theme also install the LCARS Codex syntax theme and
#                              make it Codex's theme
#   ./install.sh --uninstall   undo the install: remove lcars, revert its
#                              OpenCode patch, clear the tab names it kept in
#                              workspaces, and put back the themes and
#                              settings it replaced
#   ./install.sh --uninstall --opencode
#                              also remove cmux's OpenCode integration, even
#                              if it was there before lcars
#
# Flags can be combined. Re-running is safe: an existing lcars.js that
# differs is backed up first. What each run changes is recorded in
# ~/.config/lcars so that --uninstall can put it back.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sidebars="${HOME}/.config/cmux/sidebars"
target="${sidebars}/lcars.js"

opencode_dir="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
plugins="$opencode_dir/plugins"
disabled="$(dirname "$plugins")/plugins-disabled"
tui="$plugins/cmux/tui.js"
patchfile="$here/opencode/cmux-tui.patch"
patch_marker="lcars-opencode-patch v2"
names_marker="lcars-tabs "

themes="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/themes"
theme_src="$here/theme/LCARS"
theme_target="$themes/LCARS"

oc_cli="$opencode_dir/cli.json"
oc_theme_src="$here/opencode/lcars.json"
oc_theme_target="$opencode_dir/themes/lcars.json"

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
claude_settings="$claude_dir/settings.json"
claude_theme_src="$here/claude/lcars.json"
claude_theme_target="$claude_dir/themes/lcars.json"

codex_dir="${CODEX_HOME:-$HOME/.codex}"
codex_config="$codex_dir/config.toml"
codex_theme_src="$here/codex/lcars.tmTheme"
codex_theme_target="$codex_dir/themes/lcars.tmTheme"

# Install record: plain key=value lines (never sourced) plus copies of the
# settings files lcars edits. Mode 700 because those copies may hold secrets.
state_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lcars"
state_file="$state_dir/install-state"
snap_dir="$state_dir/snapshots"
oc_configs="opencode.json opencode.jsonc tui.json tui.jsonc"
ov_light=""
ov_dark=""
oc_touched=0
oc_unchanged=""
app_recorded=0

select=0
opencode=0
theme=0
opencode_theme=0
claude_theme=0
codex_theme=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --select) select=1 ;;
    --opencode) opencode=1 ;;
    --theme) theme=1 ;;
    --opencode-theme) opencode_theme=1 ;;
    --claude-theme) claude_theme=1 ;;
    --codex-theme) codex_theme=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v cmux >/dev/null 2>&1; then
  echo "cmux CLI not found on PATH. Install cmux (https://cmux.com) and run this from a cmux terminal." >&2
  exit 1
fi

# --- install record -------------------------------------------------------

# state_get KEY: first value for KEY, or empty (status 0) when there is none.
state_get() {
  [[ -f "$state_file" ]] || return 0
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$state_file"
}

# state_all KEY: every value for KEY, one per line.
state_all() {
  [[ -f "$state_file" ]] || return 0
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2) }' "$state_file"
}

# state_has KEY: succeeds if KEY has a record, even an empty one.
state_has() {
  [[ -f "$state_file" ]] || return 1
  awk -v key="$1" 'index($0, key "=") == 1 { f = 1; exit } END { exit !f }' "$state_file"
}

# Creates the state dir, noting which of its parents didn't exist.
state_prepare() {
  if [[ -d "$state_dir" ]]; then return 0; fi
  local d missing=""
  d="$(dirname "$state_dir")"
  while [[ "$d" != "/" && "$d" != "." && ! -e "$d" && ! -L "$d" ]]; do
    missing="$missing$d"$'\n'
    d="$(dirname "$d")"
  done
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then printf 'created_dir=%s\n' "$d" >> "$state_file"; fi
  done <<<"$missing"
  return 0
}

# state_put KEY VALUE: sets KEY, replacing any older value.
state_put() {
  state_prepare
  local tmp
  tmp="$(mktemp "$state_dir/.tmp.XXXXXX")"
  if [[ -f "$state_file" ]]; then
    awk -v key="$1" 'index($0, key "=") != 1' "$state_file" > "$tmp"
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$state_file"
  rm -f "$tmp"
}

# state_add KEY VALUE: appends a value unless that exact line is there.
state_add() {
  state_prepare
  if [[ -f "$state_file" ]] && grep -qxF -- "$1=$2" "$state_file"; then return 0; fi
  printf '%s=%s\n' "$1" "$2" >> "$state_file"
}

sha_of() {
  shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }' || true
}

# note_missing_dirs DIR: records DIR and each parent that doesn't exist yet,
# so --uninstall can remove them again if they end up empty.
note_missing_dirs() {
  local d="$1"
  while [[ -n "$d" && "$d" != "/" && "$d" != "." && ! -e "$d" && ! -L "$d" ]]; do
    state_add created_dir "$d"
    d="$(dirname "$d")"
  done
  return 0
}

mkdir_tracked() {
  note_missing_dirs "$1"
  mkdir -p "$1"
}

# snapshot_begin KEY FILE: keeps a byte copy of FILE (through symlinks)
# before lcars edits it. snapshot_end KEY FILE notes what lcars left behind.
snapshot_begin() {
  state_prepare
  mkdir -p "$snap_dir"
  chmod 700 "$snap_dir"
  if [[ -f "$2" ]]; then
    cat "$2" > "$snap_dir/$1"
    state_put "snap.$1.before" saved
  else
    rm -f "$snap_dir/$1"
    state_put "snap.$1.before" absent
  fi
}

snapshot_end() {
  state_put "snap.$1.sha" "$(sha_of "$2")"
}

# snapshot_write KEY FILE: puts the saved bytes back (cat keeps symlinks and
# mode), or removes FILE if it didn't exist.
snapshot_write() {
  case "$(state_get "snap.$1.before")" in
    saved)
      [[ -f "$snap_dir/$1" ]] || return 1
      cat "$snap_dir/$1" > "$2" ;;
    absent) rm -f "$2" ;;
    *) return 1 ;;
  esac
}

# restore_snapshot KEY FILE: restores FILE if nobody touched it since the
# install; otherwise fails and the caller falls back to editing the setting.
restore_snapshot() {
  state_has "snap.$1.sha" || return 1
  [[ "$(sha_of "$2")" == "$(state_get "snap.$1.sha")" ]] || return 1
  snapshot_write "$1" "$2"
}

# Prints the ids of workspaces whose description holds lcars's tab names.
lcars_named_workspaces() {
  cmux rpc workspace.list '{}' 2>/dev/null | osascript -l JavaScript -e '
    function run() {
      const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      const text = $.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding).js;
      const mark = "'"$names_marker"'";
      return (JSON.parse(text).workspaces || [])
        .filter((w) => (w.description || "").startsWith(mark))
        .map((w) => w.id).join("\n");
    }' 2>/dev/null || true
}

# Where cmux keeps the config that its theme override lives in.
cmux_config_path() {
  local p
  p="$(cmux themes list 2>/dev/null | sed -n 's/^Config: //p' | head -n1 || true)"
  echo "${p:-$HOME/Library/Application Support/com.cmuxterm.app/config.ghostty}"
}

# cmux_block_theme FILE: prints the theme set in cmux's override block (the
# lines between "# cmux themes start" and "# cmux themes end"). Fails if there
# is no block. `cmux themes list` can't tell an override from an inherited
# value, so the file is read directly.
cmux_block_theme() {
  [[ -f "$1" ]] || return 1
  awk '
    $0 == "# cmux themes start" { b = 1; f = 1; next }
    $0 == "# cmux themes end" { b = 0; next }
    b && /^[[:space:]]*theme[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v); print v; b = 0
    }
    END { exit !f }' "$1"
}

# parse_theme_value VALUE: sets ov_light and ov_dark from a ghostty theme value.
parse_theme_value() {
  local v="$1"
  local re_ld='^light:(.*),dark:(.*)$' re_dl='^dark:(.*),light:(.*)$'
  local re_l='^light:(.*)$' re_d='^dark:(.*)$'
  if [[ "$v" =~ $re_ld ]]; then
    ov_light="${BASH_REMATCH[1]}"; ov_dark="${BASH_REMATCH[2]}"
  elif [[ "$v" =~ $re_dl ]]; then
    ov_dark="${BASH_REMATCH[1]}"; ov_light="${BASH_REMATCH[2]}"
  elif [[ "$v" =~ $re_l ]]; then
    ov_light="${BASH_REMATCH[1]}"; ov_dark=""
  elif [[ "$v" =~ $re_d ]]; then
    ov_dark="${BASH_REMATCH[1]}"; ov_light=""
  else
    ov_light="$v"; ov_dark="$v"
  fi
}

# Records cmux's theme override before `cmux themes set LCARS` replaces it.
record_cmux_theme() {
  local value
  if value="$(cmux_block_theme "$(cmux_config_path)")" && [[ -n "$value" ]]; then
    parse_theme_value "$value"
    # Already LCARS (a re-run): keep the older record.
    if [[ "$ov_light" == "LCARS" && "$ov_dark" == "LCARS" ]]; then return 0; fi
    state_put cmux_theme.override 1
    state_put cmux_theme.light "$ov_light"
    state_put cmux_theme.dark "$ov_dark"
  else
    state_put cmux_theme.override 0
  fi
  return 0
}

# Puts cmux's theme back if it is still LCARS, and removes the theme file if
# it is still the one this repo ships.
uninstall_theme() {
  local list light dark a b desc
  list="$(cmux themes list 2>/dev/null || true)"
  light="$(sed -n 's/^Current light: //p' <<<"$list" | head -n1)"
  dark="$(sed -n 's/^Current dark: //p' <<<"$list" | head -n1)"
  if [[ "$light" == "LCARS" || "$dark" == "LCARS" ]]; then
    a="$(state_get cmux_theme.light)"
    b="$(state_get cmux_theme.dark)"
    # A side changed since the install keeps its current value.
    if [[ "$light" != "LCARS" ]]; then a="$light"; fi
    if [[ "$dark" != "LCARS" ]]; then b="$dark"; fi
    if [[ "$(state_get cmux_theme.override)" == "1" && ( -n "$a" || -n "$b" ) ]]; then
      desc=""
      if [[ -n "$a" && -n "$b" ]]; then
        cmux themes set --light "$a" --dark "$b" >/dev/null
      else
        # A one-sided override: setting one side alone would leave LCARS on
        # the other, so clear first.
        cmux themes clear >/dev/null
        if [[ -n "$a" ]]; then
          cmux themes set --light "$a" >/dev/null
        else
          cmux themes set --dark "$b" >/dev/null
        fi
      fi
      if [[ -n "$a" ]]; then desc="light: $a"; fi
      if [[ -n "$b" ]]; then desc="${desc:+$desc, }dark: $b"; fi
      echo "Restored cmux's theme ($desc)"
    else
      cmux themes clear >/dev/null
      if [[ "$light" == "LCARS" && "$dark" == "LCARS" ]]; then
        echo "Reset cmux's theme (it was LCARS)"
      else
        echo "Reset cmux's light and dark themes (LCARS was one of them; clear resets both)"
      fi
    fi
  fi

  uninstall_file "$theme_src" "$theme_target" ghostty theme
}

# cmux's selected sidebar; empty if never chosen (the default).
sidebar_current() {
  defaults read com.cmuxterm.app cmuxExtensionSidebarProviderId 2>/dev/null || true
}

# cmux can only select custom sidebars from the CLI, so going back to a
# built-in one is left to the user.
uninstall_sidebar_selection() {
  local now before name
  now="$(sidebar_current)"
  if [[ -n "$now" && "$now" != "cmux.sidebar.custom.lcars" ]]; then return 0; fi
  if ! state_has sidebar.before; then
    # Never selected, so it's on the default and there's nothing to do.
    if [[ -z "$now" ]]; then return 0; fi
    echo "Pick another sidebar from the sidebar button's right-click menu."
    return 0
  fi
  before="$(state_get sidebar.before)"
  case "$before" in
    cmux.sidebar.custom.*)
      name="${before#cmux.sidebar.custom.}"
      if compgen -G "$sidebars/$name.*" >/dev/null; then
        if cmux sidebar select "$name" >/dev/null 2>&1; then
          echo "Selected your previous sidebar, $name"
        else
          echo "Couldn't select $name; pick it from the sidebar button's right-click menu."
        fi
      else
        echo "Your previous sidebar ($name) is gone. Pick another from the sidebar button's right-click menu."
      fi ;;
    ""|cmux.sidebar.default)
      echo "cmux has no command for going back to its built-in sidebar. Right-click the sidebar button and choose \"Default Workspaces\"." ;;
    cmux.sidebar.conversations)
      echo "cmux has no command for going back to its built-in sidebar. Right-click the sidebar button and choose \"Coding-agent sessions\"." ;;
    cmux.sidebar.extensions)
      echo "cmux has no command for going back to its built-in sidebar. Right-click the sidebar button and choose \"Extension Sidebar\"." ;;
    *)
      echo "cmux has no command for going back to $before. Right-click the sidebar button and pick it." ;;
  esac
}

# json_setting FILE KEY [VALUE]: prints the string at KEY (dotted, such as
# theme.name) in a JSON file, or with VALUE sets it; an empty VALUE removes
# it, and any object left empty. Exits 3 if the file isn't plain JSON (it may
# have comments), leaving it untouched. A missing file reads as {}.
json_setting() {
  osascript -l JavaScript - "$@" <<'JS' 2>/dev/null
    function run(argv) {
      const [rawPath, key, ...rest] = argv;
      // Write through a symlink instead of replacing it.
      const path = $(rawPath).stringByResolvingSymlinksInPath.js;
      const fm = $.NSFileManager.defaultManager;
      let config = {};
      if (fm.fileExistsAtPath(path)) {
        const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
        try { config = JSON.parse(text); } catch (e) { $.exit(3); }
      }
      const parts = key.split(".");
      const last = parts.pop();
      if (rest.length === 0) {
        let node = config;
        for (const p of parts) node = node && typeof node === "object" ? node[p] : undefined;
        const value = node && typeof node === "object" ? node[last] : undefined;
        return typeof value === "string" ? value : "";
      }
      const value = rest[0];
      const chain = [config];
      for (const p of parts) {
        const parent = chain[chain.length - 1];
        if (!parent[p] || typeof parent[p] !== "object") {
          if (!value) return "";
          parent[p] = {};
        }
        chain.push(parent[p]);
      }
      if (value) {
        chain[chain.length - 1][last] = value;
      } else {
        delete chain[chain.length - 1][last];
        for (let i = parts.length - 1; i >= 0; i--) {
          if (Object.keys(chain[i + 1]).length > 0) break;
          delete chain[i][parts[i]];
        }
      }
      $(JSON.stringify(config, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
      return value;
    }
JS
}

# codex_theme [NAME [DROP_TABLE]]: prints the theme in the [tui] table of
# Codex's config.toml, or with NAME sets it (in place if there is a theme
# line, else right after the [tui] header); an empty NAME removes it, and
# with DROP_TABLE also an empty [tui] header lcars added, and the blank line
# before it.
codex_theme() {
  if [[ $# -eq 0 ]]; then
    [[ -f "$codex_config" ]] || return 0
    awk '/^[[:space:]]*\[/ { tui = ($0 ~ /^[[:space:]]*\[tui\][[:space:]]*(#.*)?$/) }
      tui && /^[[:space:]]*theme[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        gsub(/^["\x27]|["\x27]$/, "", v); print v; exit
      }' "$codex_config"
    return 0
  fi
  local name="$1" drop="${2:-}" tmp
  if [[ -z "$name" && ! -f "$codex_config" ]]; then return 0; fi
  if [[ -n "$name" ]]; then
    mkdir_tracked "$codex_dir"
    touch "$codex_config"
  fi
  tmp="$(mktemp)"
  # Two passes: the first learns whether [tui] has a theme line.
  awk -v name="$name" -v drop="$drop" '
    function istui(l) { return l ~ /^[[:space:]]*\[tui\][[:space:]]*(#.*)?$/ }
    function out(s) { L[++n] = s }
    FNR == 1 { tui = 0 }
    FNR == NR {
      if ($0 ~ /^[[:space:]]*\[/) tui = istui($0)
      else if (tui && $0 ~ /^[[:space:]]*theme[[:space:]]*=/) has = 1
      next
    }
    /^[[:space:]]*\[/ {
      tui = istui($0); if (tui) seen = 1
      out($0)
      if (tui && !has && name != "") { out("theme = \"" name "\""); done = 1 }
      next
    }
    tui && /^[[:space:]]*theme[[:space:]]*=/ {
      if (name != "" && !done) { out("theme = \"" name "\""); done = 1 }
      next
    }
    { out($0) }
    END {
      if (!seen && name != "") { if (n > 0) out(""); out("[tui]"); out("theme = \"" name "\"") }
      if (name == "" && drop != "") {
        for (i = 1; i <= n; i++) if (istui(L[i])) { h = i; break }
        if (h) {
          e = n + 1
          for (j = h + 1; j <= n; j++) if (L[j] ~ /^[[:space:]]*\[/) { e = j; break }
          blank = 1
          for (j = h + 1; j < e; j++) if (L[j] !~ /^[[:space:]]*$/) blank = 0
          if (blank) {
            s = h; if (h > 1 && L[h - 1] ~ /^[[:space:]]*$/) s = h - 1
            for (j = s; j < e; j++) skip[j] = 1
          }
        }
      }
      for (i = 1; i <= n; i++) if (!skip[i]) print L[i]
    }
  ' "$codex_config" "$codex_config" > "$tmp"
  cat "$tmp" > "$codex_config"
  rm -f "$tmp"
}

# install_file SRC TARGET LABEL KEY: copies a file into place. A different
# existing file is backed up first; the install record (file.KEY.*) notes what
# --uninstall should put back.
install_file() {
  local src="$1" target="$2" label="$3" key="$4" backup recorded
  mkdir_tracked "$(dirname "$target")"
  recorded="$(state_get "file.$key.sha")"
  if cmp -s "$src" "$target" 2>/dev/null; then
    echo "$target is already up to date"
    if [[ -n "$recorded" ]]; then state_put "file.$key.sha" "$(sha_of "$src")"; fi
    return 0
  fi
  if [[ -f "$target" && -n "$recorded" && "$(sha_of "$target")" == "$recorded" ]]; then
    # Our own older version: nothing of the user's to back up.
    state_put "file.$key.sha" "$(sha_of "$src")"
    cp "$src" "$target"
    echo "Updated $target"
    return 0
  fi
  if [[ -f "$target" ]]; then
    backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$target" "$backup"
    echo "Backed up existing $label to $backup"
    if [[ -z "$(state_get "file.$key.before")" ]] && ! grep -qi lcars "$target"; then
      state_put "file.$key.before" "$backup"
    else
      state_add extra_backup "$backup"
    fi
  elif [[ -z "$(state_get "file.$key.before")" ]]; then
    state_put "file.$key.before" absent
  fi
  state_put "file.$key.sha" "$(sha_of "$src")"
  cp "$src" "$target"
  echo "Installed $target"
}

# uninstall_file SRC TARGET KEY WHAT: removes an installed file unless it was
# edited, and puts back the file it replaced. WHAT is "theme" or "sidebar".
uninstall_file() {
  local src="$1" target="$2" key="$3" what="$4" before sha
  before="$(state_get "file.$key.before")"
  sha="$(state_get "file.$key.sha")"
  if [[ ! -f "$target" && ! -L "$target" ]]; then return 0; fi
  if [[ "$what" == "sidebar" && -z "$sha" && -z "$before" ]]; then
    rm -f "$target"
    echo "Removed $target"
    return 0
  fi
  if [[ "$what" == "sidebar" && -L "$target" ]] || cmp -s "$src" "$target" \
    || { [[ -n "$sha" ]] && [[ "$(sha_of "$target")" == "$sha" ]]; }; then
    rm -f "$target"
    if [[ -n "$before" && "$before" != "absent" ]]; then
      if [[ -f "$before" ]]; then
        mv "$before" "$target"
        echo "Restored $target from $before"
      else
        echo "Removed $target"
        echo "The original of $target ($before) is gone, so it can't be restored."
      fi
    else
      echo "Removed $target"
    fi
    if [[ "$what" != "sidebar" && ! -f "$state_file" ]]; then
      rmdir "$(dirname "$target")" 2>/dev/null || true
    fi
  else
    echo "Kept $target: it differs from lcars's $what"
    if [[ -n "$before" && "$before" != "absent" && -f "$before" ]]; then
      echo "The original is at $before"
    fi
  fi
  return 0
}

# Lists backups of edited files that a re-install replaced; they're never deleted.
list_extra_backups() {
  local p
  while IFS= read -r p; do
    if [[ -n "$p" && -e "$p" ]]; then echo "Left $p: an edited file a re-install replaced"; fi
  done < <(state_all extra_backup)
  return 0
}

# Per-app settings: where the theme lives, and how to read and set it.
app_file() {
  case "$1" in
    opencode) echo "$oc_cli" ;;
    claude) echo "$claude_settings" ;;
    codex) echo "$codex_config" ;;
  esac
}

app_get() {
  case "$1" in
    opencode) json_setting "$oc_cli" theme.name ;;
    claude) json_setting "$claude_settings" theme ;;
    codex) codex_theme ;;
  esac
}

# app_set APP VALUE [DROP_TABLE]: an empty VALUE removes the setting.
app_set() {
  case "$1" in
    opencode) json_setting "$oc_cli" theme.name "$2" >/dev/null ;;
    claude) json_setting "$claude_settings" theme "$2" >/dev/null ;;
    codex) codex_theme "$2" "${3:-}" ;;
  esac
}

# record_app_before APP CURRENT LCARS_VALUE: notes the theme lcars is about to
# replace, unless it is already lcars's. Sets app_recorded.
record_app_before() {
  app_recorded=0
  if [[ "$2" == "$3" ]]; then return 0; fi
  state_put "app.$1.before" "$2"
  snapshot_begin "$1" "$(app_file "$1")"
  app_recorded=1
}

# uninstall_app_theme APP LABEL LCARS_VALUE LCARS_NAME: puts back an app's
# previous theme if it is still lcars's.
uninstall_app_theme() {
  local app="$1" label="$2" lcars_val="$3" lcars_name="$4" file current before drop="" cleaned
  file="$(app_file "$app")"
  if ! current="$(app_get "$app")" || [[ "$current" != "$lcars_val" ]]; then return 0; fi
  if ! state_has "app.$app.before"; then
    app_set "$app" ""
    echo "Reset $label in $file (it was $lcars_name; no record of the previous theme)"
    return 0
  fi
  before="$(state_get "app.$app.before")"
  if ! restore_snapshot "$app" "$file"; then
    if [[ "$app" == "codex" && "$(state_get app.codex.created_table)" == "1" ]]; then drop=1; fi
    app_set "$app" "$before" "$drop"
    if [[ -z "$before" && "$(state_get "snap.$app.before")" == "absent" && -f "$file" ]]; then
      cleaned="$(tr -d '[:space:]' < "$file")"
      if [[ -z "$cleaned" || ( "$app" != "codex" && "$cleaned" == "{}" ) ]]; then rm -f "$file"; fi
    fi
  fi
  if [[ -n "$before" ]]; then
    echo "Restored $label in $file to $before"
  else
    echo "Reset $label in $file (it was $lcars_name)"
  fi
}

# Put each app's theme back if it is lcars's, and remove the theme files that
# are still the ones this repo ships.
uninstall_app_themes() {
  uninstall_app_theme opencode "OpenCode's theme" lcars lcars
  uninstall_file "$oc_theme_src" "$oc_theme_target" opencode-theme theme

  uninstall_app_theme claude "Claude Code's theme" custom:lcars LCARS
  uninstall_file "$claude_theme_src" "$claude_theme_target" claude-theme theme

  uninstall_app_theme codex "Codex's theme" lcars lcars
  uninstall_file "$codex_theme_src" "$codex_theme_target" codex-theme theme
}

# --- OpenCode integration -------------------------------------------------

# Succeeds if cmux's OpenCode integration is already there.
oc_integration_present() {
  local f
  if [[ -f "$plugins/cmux/.cmux-owned" ]] && grep -q cmux-opencode-tui-plugin-ownership-marker "$plugins/cmux/.cmux-owned"; then
    return 0
  fi
  for f in "$plugins/cmux-session.js" "$disabled/cmux-session.js"; do
    if [[ -f "$f" ]] && grep -q cmux-opencode-session-plugin-marker "$f"; then return 0; fi
  done
  for f in "$plugins/cmux-feed.js" "$disabled/cmux-feed.js"; do
    if [[ -f "$f" ]] && grep -q cmux-feed-plugin-marker "$f"; then return 0; fi
  done
  return 1
}

# record_oc_configs TMPDIR: after cmux's install, snapshots (from the copies in
# TMPDIR) the OpenCode config files it changed or created.
record_oc_configs() {
  local tmp="$1" n file
  for n in $oc_configs; do
    file="$opencode_dir/$n"
    [[ -f "$file" ]] || continue
    if state_has "snap.oc.$n.before"; then continue; fi
    if [[ -f "$tmp/$n" ]] && cmp -s "$tmp/$n" "$file"; then continue; fi
    state_prepare
    mkdir -p "$snap_dir"
    chmod 700 "$snap_dir"
    if [[ -f "$tmp/$n" ]]; then
      cat "$tmp/$n" > "$snap_dir/oc.$n"
      state_put "snap.oc.$n.before" saved
    else
      state_put "snap.oc.$n.before" absent
    fi
    state_put "snap.oc.$n.sha" "$(sha_of "$file")"
  done
  return 0
}

# Prints the OpenCode config files that are as cmux's install left them.
oc_unchanged_files() {
  local n
  for n in $oc_configs; do
    state_has "snap.oc.$n.sha" || continue
    if [[ "$(sha_of "$opencode_dir/$n")" == "$(state_get "snap.oc.$n.sha")" ]]; then echo "$n"; fi
  done
  return 0
}

# Puts back the config files cmux's OpenCode install changed, if nobody has
# edited them since. Run after `cmux hooks opencode uninstall`, which may
# rewrite them, using the list taken before.
restore_oc_configs() {
  local n file
  for n in $oc_configs; do
    state_has "snap.oc.$n.before" || continue
    file="$opencode_dir/$n"
    case " $oc_unchanged " in
      *" $n "*)
        if snapshot_write "oc.$n" "$file"; then
          if [[ "$(state_get "snap.oc.$n.before")" == "absent" ]]; then
            echo "Removed $file (it didn't exist before the install)"
          else
            echo "Restored $file"
          fi
        fi ;;
      *) echo "Kept $file: it changed since the install" ;;
    esac
  done
  return 0
}

# Removes the install record, and the directories lcars made that are empty.
forget_install() {
  local dirs d
  dirs="$(state_all created_dir | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)"
  rm -rf "$state_dir"
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then rmdir "$d" 2>/dev/null || true; fi
  done <<<"$dirs"
  return 0
}

if [[ $uninstall -eq 1 ]]; then
  if [[ ! -f "$state_file" ]]; then
    echo "No install record in $state_dir (installed by an older lcars), so themes go back to their defaults, not to their previous values."
  fi

  # While lcars.js still exists, so the old sidebar can be selected again.
  uninstall_sidebar_selection
  uninstall_file "$here/lcars.js" "$target" sidebar sidebar

  # Before anything below rewrites them.
  oc_unchanged="$(oc_unchanged_files | tr '\n' ' ')"

  if [[ -f "$tui" ]] && grep -q "$patch_marker" "$tui"; then
    oc_touched=1
    if patch -R --dry-run --silent "$tui" < "$patchfile" >/dev/null 2>&1; then
      patch -R --silent --no-backup-if-mismatch "$tui" < "$patchfile"
      echo "Reverted lcars's patch to $tui"
    else
      # Patched by a different lcars version: let cmux rewrite its plugin.
      cmux hooks opencode install --yes >/dev/null
      echo "Reinstalled cmux's unpatched OpenCode plugin"
    fi
  fi

  # A running OpenCode clears its own names when the patch unloads; this
  # catches the rest, such as names left by an OpenCode that crashed.
  sleep 1
  while read -r id; do
    [[ -n "$id" ]] || continue
    cmux workspace-action --workspace "$id" --action clear-description >/dev/null
    echo "Cleared OpenCode tab names from workspace $id"
  done < <(lcars_named_workspaces)

  # lcars brought the integration if it wasn't there before; removing that
  # is undoing lcars's change.
  remove_integration=0
  if [[ $opencode -eq 1 ]]; then
    remove_integration=1
  elif [[ "$(state_get opencode.integration_before)" == "0" ]]; then
    remove_integration=1
    echo "Removing cmux's OpenCode integration: lcars installed it."
  fi
  if [[ $remove_integration -eq 1 ]]; then
    oc_touched=1
    cmux hooks opencode uninstall --yes
    restore_oc_configs
    for f in cmux-feed.js cmux-session.js; do
      if [[ -f "$disabled/$f" ]] && grep -q "cmux" "$disabled/$f"; then
        rm "$disabled/$f"
        echo "Removed $disabled/$f"
      fi
    done
    rmdir "$disabled" 2>/dev/null || true
  else
    if oc_integration_present; then
      echo "Left cmux's OpenCode integration in place: it was there before lcars, or there's no record. Add --opencode to remove it."
    fi
    moved_any=0
    for f in cmux-feed.js cmux-session.js; do
      [[ "$(state_get "opencode.moved.$f")" == "1" ]] || continue
      moved_any=1
      [[ -f "$disabled/$f" ]] || continue
      if [[ "$(state_get "opencode.existed.$f")" == "1" ]]; then
        echo "Left $disabled/$f in place: moving it back would make OpenCode v2 fail with \"Duplicate plugin ID: cmux.server\". It's a copy of what was in $plugins."
      elif grep -q "cmux" "$disabled/$f"; then
        rm "$disabled/$f"
        echo "Removed $disabled/$f"
      fi
    done
    if [[ $moved_any -eq 1 ]]; then rmdir "$disabled" 2>/dev/null || true; fi
  fi

  uninstall_theme
  uninstall_app_themes

  list_extra_backups
  forget_install

  if [[ $oc_touched -eq 1 ]]; then
    echo "Done. Restart OpenCode."
  else
    echo "Done."
  fi
  exit 0
fi

mkdir_tracked "$sidebars"
if [[ "$here/lcars.js" -ef "$target" ]]; then
  # A development setup that links the sidebar to this checkout.
  echo "$target already points at this checkout"
else
  install_file "$here/lcars.js" "$target" "lcars.js" sidebar
fi

cmux sidebar validate lcars

if [[ $select -eq 1 ]]; then
  sidebar_now="$(sidebar_current)"
  if [[ "$sidebar_now" != "cmux.sidebar.custom.lcars" ]]; then
    state_put sidebar.before "$sidebar_now"
  fi
  cmux sidebar select lcars
fi

if [[ $opencode -eq 1 ]]; then
  if ! command -v opencode >/dev/null 2>&1; then
    echo "opencode not found on PATH; skipping the OpenCode step." >&2
  else
    # First write wins: a re-run would see lcars's own install.
    if ! state_has opencode.integration_before; then
      if oc_integration_present; then
        state_put opencode.integration_before 1
      else
        state_put opencode.integration_before 0
      fi
      for f in cmux-feed.js cmux-session.js; do
        if grep -Eqs 'cmux-[a-z-]*plugin-marker' "$plugins/$f" "$disabled/$f"; then
          state_put "opencode.existed.$f" 1
        fi
      done
    fi
    note_missing_dirs "$plugins"
    note_missing_dirs "$disabled"
    note_missing_dirs "$opencode_dir"
    oc_tmp="$(mktemp -d)"
    for f in $oc_configs; do
      if [[ -f "$opencode_dir/$f" ]]; then cp "$opencode_dir/$f" "$oc_tmp/$f"; fi
    done

    cmux hooks opencode install --yes

    record_oc_configs "$oc_tmp"
    rm -rf "$oc_tmp"

    # cmux also writes single-file plugins that duplicate the plugins/cmux
    # folder. OpenCode v2 rejects them ("Duplicate plugin ID: cmux.server"),
    # so move them aside when the folder plugin is present.
    if [[ -d "$plugins/cmux" ]]; then
      for f in cmux-feed.js cmux-session.js; do
        if [[ -f "$plugins/$f" ]] && grep -q "cmux" "$plugins/$f"; then
          state_put "opencode.moved.$f" 1
          mkdir -p "$disabled"
          mv "$plugins/$f" "$disabled/$f"
          echo "Moved duplicate $plugins/$f to $disabled/"
        fi
      done
    fi

    # cmux's plugin only ends a session when it is deleted or archived, so
    # closed tabs and quit OpenCodes stay "idle" in the sidebar for good, and
    # it never tells cmux a session's name. The patch fixes both (see
    # README.md). Reinstalling the plugin drops it; re-running this puts it back.
    if [[ ! -f "$tui" ]]; then
      echo "No $tui; skipping the OpenCode plugin patch." >&2
    elif grep -q "$patch_marker" "$tui"; then
      echo "OpenCode plugin patch already applied."
    elif patch --dry-run --silent "$tui" < "$patchfile" >/dev/null 2>&1; then
      patch --silent --no-backup-if-mismatch "$tui" < "$patchfile"
      echo "Patched $tui to name OpenCode tabs and end closed sessions."
    else
      echo "cmux's OpenCode plugin changed, so lcars's patch no longer applies." >&2
      echo "OpenCode tabs will show as \"Tab 1\", \"Tab 2\", and closed ones will linger." >&2
    fi
    echo "OpenCode integration installed. Restart OpenCode for it to take effect."
  fi
fi

if [[ $theme -eq 1 ]]; then
  install_file "$theme_src" "$theme_target" "LCARS theme" ghostty
  record_cmux_theme
  cmux themes set LCARS
  echo "Set the cmux theme to LCARS. Undo with: ./install.sh --uninstall"
fi

if [[ $opencode_theme -eq 1 ]]; then
  install_file "$oc_theme_src" "$oc_theme_target" "OpenCode lcars theme" opencode-theme
  if previous="$(json_setting "$oc_cli" theme.name)"; then
    record_app_before opencode "$previous" lcars
    [[ "$previous" != "lcars" ]] || previous=""
    json_setting "$oc_cli" theme.name lcars >/dev/null
    if [[ $app_recorded -eq 1 ]]; then snapshot_end opencode "$oc_cli"; fi
    echo "Set OpenCode's theme to lcars${previous:+ (it was $previous)}. Undo with /themes in OpenCode."
  else
    echo "Couldn't edit $oc_cli (it has comments or isn't valid JSON); pick lcars with /themes in OpenCode." >&2
  fi
fi

if [[ $claude_theme -eq 1 ]]; then
  install_file "$claude_theme_src" "$claude_theme_target" "Claude Code LCARS theme" claude-theme
  if previous="$(json_setting "$claude_settings" theme)"; then
    record_app_before claude "$previous" custom:lcars
    [[ "$previous" != "custom:lcars" ]] || previous=""
    json_setting "$claude_settings" theme custom:lcars >/dev/null
    if [[ $app_recorded -eq 1 ]]; then snapshot_end claude "$claude_settings"; fi
    echo "Set Claude Code's theme to LCARS${previous:+ (it was ${previous#custom:})}. Undo with /theme in Claude Code."
  else
    echo "Couldn't edit $claude_settings (it has comments or isn't valid JSON); pick LCARS with /theme in Claude Code." >&2
  fi
fi

if [[ $codex_theme -eq 1 ]]; then
  install_file "$codex_theme_src" "$codex_theme_target" "Codex LCARS theme" codex-theme
  previous="$(codex_theme)"
  record_app_before codex "$previous" lcars
  # Uninstall removes a [tui] table that this run adds.
  if [[ $app_recorded -eq 1 ]] && ! grep -Eq '^[[:space:]]*\[tui\][[:space:]]*(#.*)?$' "$codex_config" 2>/dev/null; then
    state_put app.codex.created_table 1
  fi
  [[ "$previous" != "lcars" ]] || previous=""
  codex_theme lcars
  if [[ $app_recorded -eq 1 ]]; then snapshot_end codex "$codex_config"; fi
  echo "Set Codex's syntax theme to lcars${previous:+ (it was $previous)}. Undo with /theme in Codex."
fi

if [[ $select -eq 0 ]]; then
  echo "Done. Use it with: cmux sidebar select lcars (or right-click the sidebar button and choose lcars)."
else
  echo "Done. lcars is now your left sidebar."
fi
