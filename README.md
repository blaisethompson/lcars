# lcars

A custom sidebar for [cmux](https://cmux.com) that shows every workspace as a
card: its name, folder and git branch, what its coding agents are doing, and a
row of tiles for its terminals. Workspaces that need you expand on their own.

<img src="docs/needs-input.png" alt="lcars with an agent waiting for input" width="420">

## Install

### Ask your agent

Paste this to Claude Code, OpenCode or any coding agent running in cmux:

> Install the lcars cmux sidebar: clone
> `https://github.com/blaisethompson/lcars` and follow its AGENTS.md.

The agent installs the sidebar, makes it your left sidebar, and asks before
setting up the optional OpenCode integration.

### By hand

```sh
git clone https://github.com/blaisethompson/lcars.git
cd lcars
./install.sh --select
```

`./install.sh` without `--select` only installs it; pick it later with
`cmux sidebar select lcars` or from the sidebar button's right-click menu.

## What it shows

Each workspace is a card in LCARS colours, with its own colour bar down the
left side:

- **Name**, with a pin icon and a red unread-count readout. A workspace still
  named after its path shows as its folder, like `orders/`.
- **Folder and branch**, with a gold dot when the working tree has
  uncommitted changes.
- **Agent status**: red *Needs input*, amber *Working* (with how long), or
  periwinkle *Idle*. When a workspace has several agent sessions, each gets
  its own line.
- **Last agent message**.
- **Terminal tiles**: one per terminal, named after it, with the agent's mark
  in the middle: an orange ✱ for Claude, ▣ for OpenCode, ◆ for anything else.
  The mark turns while the agent works, fades when it is idle, and the tile
  gets a red border when it needs input. A red dot marks unread
  notifications, and the focused terminal is highlighted.

Compact rows show the same marks at the end of the row, on red when the agent
needs input.

Claude Code doesn't report an interrupted turn (Esc), so a mark keeps turning
and the card says *Working* until your next prompt.

Click a card to switch to it, click a tile to jump to that terminal, drag
cards to reorder them, and right-click for pin, mark read, move and close.

**Close…** turns the card into a "Close <name>?" row: ↩ puts the card back,
the red × closes the workspace. It asks every time because a sidebar can't
tell whether a workspace has something running, and the confirmed close ends
any running processes, like closing from cmux's own sidebar.

### Modes

The button at the top right cycles through:

- **Auto** (default): workspaces are compact two-line rows, and the current
  workspace plus any that need you (unread notifications or an agent waiting
  for input) expand into full cards.
- **Compact**: every workspace is a two-line row.
- **Full**: every workspace is a full card.

The mode resets to Auto when cmux reloads the sidebar.

## OpenCode (optional)

Claude Code reports its status to cmux out of the box. OpenCode needs cmux's
plugin first:

```sh
./install.sh --opencode
```

then restart OpenCode. This runs `cmux hooks opencode install` and moves aside
two duplicate plugin files it also writes, which OpenCode v2 otherwise lists
as failed with "Duplicate plugin ID: cmux.server". They go to
`~/.config/opencode/plugins-disabled/`.

<img src="docs/opencode-tabs.png" alt="lcars showing two OpenCode tabs" width="420">

What to expect:

- **OpenCode tabs show as "Tab 1", "Tab 2".** cmux's plugin reports a status
  for each tab but not its name, so lines are numbered. The numbering may not
  match OpenCode's tab order.
- **Clicking a tab line can't switch OpenCode's tab.** It jumps to the
  terminal OpenCode runs in; tabs live inside OpenCode.
- **Reopened sessions show no status.** A session resumed with
  `opencode -s <id>` or from the session list keeps pointing at the OpenCode
  process that created it, so cmux reports it as ended. New sessions work.

For the best result, run **one OpenCode session per cmux terminal** instead of
using OpenCode's tabs: press ⌘T (new terminal) or ⌘D (split), then run
`opencode`. Each session then gets its own tile, named after the session, and
clicking it takes you straight there.

To remove the integration: `cmux hooks opencode uninstall`.

## Uninstall

```sh
rm ~/.config/cmux/sidebars/lcars.js
```

and choose another sidebar from the sidebar button's right-click menu.

## Credits

Inspired by the minimap sidebar in [montty](https://github.com/tednaleid/montty)
by Ted Naleid.
