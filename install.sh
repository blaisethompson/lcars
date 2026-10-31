#!/usr/bin/env bash
# Install the lcars custom sidebar into cmux.
#
#   ./install.sh               copy lcars.js into ~/.config/cmux/sidebars
#   ./install.sh --select      also make lcars the left sidebar
#   ./install.sh --opencode    also install cmux's OpenCode integration, and
#                              patch it to name tabs and end closed sessions
#   ./install.sh --uninstall   remove lcars, revert its OpenCode patch and
#                              clear the tab names it kept in workspaces
#   ./install.sh --uninstall --opencode
#                              also remove cmux's OpenCode integration
#
# Flags can be combined. Re-running is safe: an existing lcars.js that
# differs is backed up first.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sidebars="${HOME}/.config/cmux/sidebars"
target="${sidebars}/lcars.js"

plugins="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/plugins"
disabled="$(dirname "$plugins")/plugins-disabled"
tui="$plugins/cmux/tui.js"
patchfile="$here/opencode/cmux-tui.patch"
patch_marker="lcars-opencode-patch v2"
names_marker="lcars-tabs "

select=0
opencode=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --select) select=1 ;;
    --opencode) opencode=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if [[ $select -eq 0 ]]; then
  echo "Done. Use it with: cmux sidebar select lcars (or right-click the sidebar button and choose lcars)."
else
  echo "Done. lcars is now your left sidebar."
fi
