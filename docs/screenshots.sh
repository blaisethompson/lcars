#!/usr/bin/env bash
# Regenerate the README screenshots from sample workspaces.
#
#   docs/screenshots.sh [sidebar width in points, default 288]
#
# Builds a copy of lcars.js that reads docs/demo-data.js instead of cmux's
# live workspaces, selects it as the left sidebar, captures it, then selects
# lcars again. The third shot (docs/lcars-theme.png) is the whole window: it
# opens a temporary "Apple Pay checkout" workspace running docs/terminal-demo.sh
# and needs the LCARS terminal theme to be cmux's current theme. Afterwards the
# temporary workspace is closed and the workspace you had selected is back.
# Run it from a cmux terminal with the cmux window in front.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
width="${1:-288}"
demo="${HOME}/.config/cmux/sidebars/lcars-demo.js"
export CMUX_QUIET=1

temp_ref=""
temp_ws=""
orig_ws=""

# workspace_id <ref>: the id of a workspace, waiting a moment for it to appear
workspace_id() {
  local i id
  for i in 1 2 3 4 5 6 7 8 9 10; do
    id="$(cmux rpc workspace.list '{}' | jq -r --arg r "$1" '.workspaces[] | select(.ref == $r) | .id')"
    [[ -z "$id" ]] || { echo "$id"; return; }
    sleep 0.3
  done
}

restore() {
  if [[ -n "$temp_ref" ]]; then
    temp_ws="$(workspace_id "$temp_ref")"
    [[ -z "$temp_ws" ]] || cmux rpc workspace.close "{\"workspace_id\":\"$temp_ws\",\"force\":true}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$orig_ws" ]]; then
    cmux select-workspace --workspace "$orig_ws" >/dev/null 2>&1 || true
  fi
  rm -f "$demo"
  cmux sidebar select lcars >/dev/null || true
}
trap restore EXIT

# build_demo <selected workspace id>: write the demo sidebar and validate it
build_demo() {
  {
    sed "s/__SELECTED__/$1/" "$here/docs/demo-data.js"
    sed 's/data\.workspaces()/demoWorkspaces()/g' "$here/lcars.js"
  } > "$demo"
  cmux sidebar validate lcars-demo >/dev/null
}

# shoot <selected workspace id> <output png>
shoot() {
  build_demo "$1"
  cmux sidebar select lcars-demo >/dev/null
  sleep 2
  # Working marks turn one step per second; shoot just before the next step,
  # once the last one has settled, so they are caught upright.
  perl -MTime::HiRes=time,sleep -e 'sleep(1.8 - (time - int(time)))'
  cmux shot --region "0,30,${width},560" --out "$2" >/dev/null
  echo "Wrote $2"
}

shoot checkout "$here/docs/needs-input.png"
shoot search "$here/docs/opencode-tabs.png"

# The whole window: demo sidebar, LCARS terminal theme, staged demo terminal.
theme_shot() {
  local out="$here/docs/lcars-theme.png" list ref
  list="$(cmux themes list | head -3)"
  if ! grep -q '^Current light: LCARS$' <<<"$list" || ! grep -q '^Current dark: LCARS$' <<<"$list"; then
    echo "Skipping $out: the LCARS terminal theme is not cmux's current theme." >&2
    echo "Install it with ./install.sh --theme, then run this again." >&2
    exit 1
  fi

  orig_ws="$(cmux rpc workspace.list '{}' | jq -r '.workspaces[] | select(.selected) | .id' | head -n1)"
  ref="$(cmux new-workspace --name "Apple Pay checkout" --cwd "$HOME" --focus true \
    --command "bash $here/docs/terminal-demo.sh" | awk '/^OK /{print $2}')"
  [[ -n "$ref" ]] || { echo "Could not create the demo workspace" >&2; exit 1; }
  temp_ref="$ref"
  cmux select-workspace --workspace "$temp_ref" >/dev/null

  build_demo checkout
  cmux sidebar select lcars-demo >/dev/null
  sleep 3
  perl -MTime::HiRes=time,sleep -e 'sleep(1.8 - (time - int(time)))'
  cmux shot --max-width 1600 --out "$out"
}

theme_shot
