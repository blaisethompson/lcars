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
#   ./install.sh --uninstall   remove lcars, revert its OpenCode patch, clear
#                              the tab names it kept in workspaces and reset
#                              the LCARS themes
#   ./install.sh --uninstall --opencode
#                              also remove cmux's OpenCode integration
#
# Flags can be combined. Re-running is safe: an existing lcars.js that
# differs is backed up first.

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
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v cmux >/dev/null 2>&1; then
  echo "cmux CLI not found on PATH. Install cmux (https://cmux.com) and run this from a cmux terminal." >&2
  exit 1
fi

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

# Resets cmux's theme if it is LCARS, and removes the theme file if it is
# still the one this repo ships.
uninstall_theme() {
  local list light dark
  list="$(cmux themes list 2>/dev/null || true)"
  light="$(sed -n 's/^Current light: //p' <<<"$list" | head -n1)"
  dark="$(sed -n 's/^Current dark: //p' <<<"$list" | head -n1)"
  if [[ "$light" == "LCARS" || "$dark" == "LCARS" ]]; then
    cmux themes clear >/dev/null
    if [[ "$light" == "LCARS" && "$dark" == "LCARS" ]]; then
      echo "Reset cmux's theme (it was LCARS)"
    else
      echo "Reset cmux's light and dark themes (LCARS was one of them; clear resets both)"
    fi
  fi

  if [[ -f "$theme_target" ]]; then
    if cmp -s "$theme_src" "$theme_target"; then
      rm "$theme_target"
      echo "Removed $theme_target"
    else
      echo "Kept $theme_target: it differs from lcars's theme"
    fi
  fi
}

# json_setting FILE KEY [VALUE]: prints the string at KEY (dotted, such as
# theme.name) in a JSON file, or with VALUE sets it; an empty VALUE removes
# it, and any object left empty. Exits 3 if the file isn't plain JSON (it may
# have comments), leaving it untouched. A missing file reads as {}.
json_setting() {
  osascript -l JavaScript - "$@" <<'JS' 2>/dev/null
    function run(argv) {
      const [path, key, ...rest] = argv;
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

# codex_theme [NAME]: prints the theme in the [tui] table of Codex's
# config.toml, or with NAME sets it; an empty NAME removes it.
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
  local name="$1" tmp
  mkdir -p "$codex_dir"
  touch "$codex_config"
  tmp="$(mktemp)"
  awk -v name="$name" '
    function emit() { if (name != "" && !done) { print "theme = \"" name "\""; done = 1 } }
    /^[[:space:]]*\[/ {
      if (tui) emit()
      tui = ($0 ~ /^[[:space:]]*\[tui\][[:space:]]*(#.*)?$/)
      if (tui) seen = 1
      print; if (tui) emit(); next
    }
    tui && /^[[:space:]]*theme[[:space:]]*=/ { next }
    { print }
    END { if (!seen && name != "") { print ""; print "[tui]"; emit() } }
  ' "$codex_config" > "$tmp"
  cat "$tmp" > "$codex_config"
  rm "$tmp"
}

# install_file SRC TARGET LABEL: copies a theme file into place, backing up a
# different existing one.
install_file() {
  local src="$1" target="$2" label="$3" backup
  mkdir -p "$(dirname "$target")"
  if cmp -s "$src" "$target" 2>/dev/null; then
    echo "$target is already up to date"
    return
  fi
  if [[ -f "$target" ]]; then
    backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$target" "$backup"
    echo "Backed up existing $label to $backup"
  fi
  cp "$src" "$target"
  echo "Installed $target"
}

# remove_file SRC TARGET: removes an installed theme file unless it was edited.
remove_file() {
  local src="$1" target="$2"
  [[ -f "$target" ]] || return 0
  if cmp -s "$src" "$target"; then
    rm "$target"
    rmdir "$(dirname "$target")" 2>/dev/null || true
    echo "Removed $target"
  else
    echo "Kept $target: it differs from lcars's theme"
  fi
}

# Switch each app back to its default theme if it is lcars's, and remove the
# theme files that are still the ones this repo ships.
uninstall_app_themes() {
  local current
  if current="$(json_setting "$oc_cli" theme.name)" && [[ "$current" == "lcars" ]]; then
    json_setting "$oc_cli" theme.name "" >/dev/null
    echo "Reset OpenCode's theme in $oc_cli (it was lcars)"
  fi
  remove_file "$oc_theme_src" "$oc_theme_target"

  if current="$(json_setting "$claude_settings" theme)" && [[ "$current" == "custom:lcars" ]]; then
    json_setting "$claude_settings" theme "" >/dev/null
    echo "Reset Claude Code's theme in $claude_settings (it was LCARS)"
  fi
  remove_file "$claude_theme_src" "$claude_theme_target"

  if [[ "$(codex_theme)" == "lcars" ]]; then
    codex_theme ""
    echo "Reset Codex's theme in $codex_config (it was lcars)"
  fi
  remove_file "$codex_theme_src" "$codex_theme_target"
}

if [[ $uninstall -eq 1 ]]; then
  if [[ -L "$target" || -f "$target" ]]; then
    rm "$target"
    echo "Removed $target"
  fi

  if [[ -f "$tui" ]] && grep -q "$patch_marker" "$tui"; then
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

  if [[ $opencode -eq 1 ]]; then
    cmux hooks opencode uninstall --yes
    for f in cmux-feed.js cmux-session.js; do
      if [[ -f "$disabled/$f" ]] && grep -q "cmux" "$disabled/$f"; then
        rm "$disabled/$f"
        echo "Removed $disabled/$f"
      fi
    done
    rmdir "$disabled" 2>/dev/null || true
  fi

  uninstall_theme
  uninstall_app_themes

  echo "Done. Pick another sidebar from the sidebar button's right-click menu, and restart OpenCode."
  exit 0
fi

mkdir -p "$sidebars"
if [[ "$here/lcars.js" -ef "$target" ]]; then
  # A development setup that links the sidebar to this checkout.
  echo "$target already points at this checkout"
else
  if [[ -f "$target" ]] && ! cmp -s "$here/lcars.js" "$target"; then
    backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$target" "$backup"
    echo "Backed up existing lcars.js to $backup"
  fi
  cp "$here/lcars.js" "$target"
  echo "Installed $target"
fi

cmux sidebar validate lcars

if [[ $select -eq 1 ]]; then
  cmux sidebar select lcars
fi

if [[ $opencode -eq 1 ]]; then
  if ! command -v opencode >/dev/null 2>&1; then
    echo "opencode not found on PATH; skipping the OpenCode step." >&2
  else
    cmux hooks opencode install --yes

    # cmux also writes single-file plugins that duplicate the plugins/cmux
    # folder. OpenCode v2 rejects them ("Duplicate plugin ID: cmux.server"),
    # so move them aside when the folder plugin is present.
    if [[ -d "$plugins/cmux" ]]; then
      for f in cmux-feed.js cmux-session.js; do
        if [[ -f "$plugins/$f" ]] && grep -q "cmux" "$plugins/$f"; then
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
  mkdir -p "$themes"
  if [[ -f "$theme_target" ]] && ! cmp -s "$theme_src" "$theme_target"; then
    backup="${theme_target}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$theme_target" "$backup"
    echo "Backed up existing LCARS theme to $backup"
  fi
  if cmp -s "$theme_src" "$theme_target" 2>/dev/null; then
    echo "$theme_target is already up to date"
  else
    cp "$theme_src" "$theme_target"
    echo "Installed $theme_target"
  fi
  cmux themes set LCARS
  echo "Set the cmux theme to LCARS. Undo with: cmux themes clear"
fi

if [[ $opencode_theme -eq 1 ]]; then
  install_file "$oc_theme_src" "$oc_theme_target" "OpenCode lcars theme"
  if previous="$(json_setting "$oc_cli" theme.name)"; then
    [[ "$previous" != "lcars" ]] || previous=""
    json_setting "$oc_cli" theme.name lcars >/dev/null
    echo "Set OpenCode's theme to lcars${previous:+ (it was $previous)}. Undo with /themes in OpenCode."
  else
    echo "Couldn't edit $oc_cli (it has comments or isn't valid JSON); pick lcars with /themes in OpenCode." >&2
  fi
fi

if [[ $claude_theme -eq 1 ]]; then
  install_file "$claude_theme_src" "$claude_theme_target" "Claude Code LCARS theme"
  if previous="$(json_setting "$claude_settings" theme)"; then
    [[ "$previous" != "custom:lcars" ]] || previous=""
    json_setting "$claude_settings" theme custom:lcars >/dev/null
    echo "Set Claude Code's theme to LCARS${previous:+ (it was ${previous#custom:})}. Undo with /theme in Claude Code."
  else
    echo "Couldn't edit $claude_settings (it has comments or isn't valid JSON); pick LCARS with /theme in Claude Code." >&2
  fi
fi

if [[ $codex_theme -eq 1 ]]; then
  install_file "$codex_theme_src" "$codex_theme_target" "Codex LCARS theme"
  previous="$(codex_theme)"
  [[ "$previous" != "lcars" ]] || previous=""
  codex_theme lcars
  echo "Set Codex's syntax theme to lcars${previous:+ (it was $previous)}. Undo with /theme in Codex."
fi

if [[ $select -eq 0 ]]; then
  echo "Done. Use it with: cmux sidebar select lcars (or right-click the sidebar button and choose lcars)."
else
  echo "Done. lcars is now your left sidebar."
fi
