#!/usr/bin/env bash
# Regenerate the README screenshots from sample workspaces.
#
#   docs/screenshots.sh [sidebar width in points, default 288]
#
# Builds a copy of lcars.js that reads docs/demo-data.js instead of cmux's
# live workspaces, selects it as the left sidebar, captures it, then selects
# lcars again. Run it from a cmux terminal with the cmux window in front.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
width="${1:-288}"
demo="${HOME}/.config/cmux/sidebars/lcars-demo.js"
export CMUX_QUIET=1

restore() {
  rm -f "$demo"
  cmux sidebar select lcars >/dev/null || true
}
trap restore EXIT

# shoot <selected workspace id> <output png>
shoot() {
  {
    sed "s/__SELECTED__/$1/" "$here/docs/demo-data.js"
    sed 's/data\.workspaces()/demoWorkspaces()/g' "$here/lcars.js"
  } > "$demo"
  cmux sidebar validate lcars-demo >/dev/null
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
