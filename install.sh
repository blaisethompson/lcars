#!/usr/bin/env bash
# Install the lcars custom sidebar into cmux.
#
#   ./install.sh               copy lcars.js into ~/.config/cmux/sidebars
#   ./install.sh --select      also make lcars the left sidebar
#   ./install.sh --opencode    also install cmux's OpenCode integration
#
# Flags can be combined. Re-running is safe: an existing lcars.js that
# differs is backed up first.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sidebars="${HOME}/.config/cmux/sidebars"
target="${sidebars}/lcars.js"

select=0
opencode=0
for arg in "$@"; do
  case "$arg" in
    --select) select=1 ;;
    --opencode) opencode=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v cmux >/dev/null 2>&1; then
  echo "cmux CLI not found on PATH. Install cmux (https://cmux.com) and run this from a cmux terminal." >&2
  exit 1
fi

mkdir -p "$sidebars"
if [[ -f "$target" ]] && ! cmp -s "$here/lcars.js" "$target"; then
  backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
  cp "$target" "$backup"
  echo "Backed up existing lcars.js to $backup"
fi
cp "$here/lcars.js" "$target"
echo "Installed $target"

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
    plugins="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/plugins"
    disabled="$(dirname "$plugins")/plugins-disabled"
    if [[ -d "$plugins/cmux" ]]; then
      for f in cmux-feed.js cmux-session.js; do
        if [[ -f "$plugins/$f" ]] && grep -q "cmux" "$plugins/$f"; then
          mkdir -p "$disabled"
          mv "$plugins/$f" "$disabled/$f"
          echo "Moved duplicate $plugins/$f to $disabled/"
        fi
      done
    fi
    echo "OpenCode integration installed. Restart OpenCode for it to take effect."
  fi
fi

if [[ $select -eq 0 ]]; then
  echo "Done. Use it with: cmux sidebar select lcars (or right-click the sidebar button and choose lcars)."
else
  echo "Done. lcars is now your left sidebar."
fi
