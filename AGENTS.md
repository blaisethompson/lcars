# Installing lcars (instructions for agents)

You have been asked to install **lcars**, a custom sidebar for the cmux
terminal app. Follow these steps in order.

## 1. Check prerequisites

- `cmux` must be on `PATH` (`command -v cmux`). If it is missing, stop and tell
  the user that lcars needs cmux (https://cmux.com).
- Custom sidebars must be enabled. They are on by default; if
  `cmux sidebar validate` reports them disabled, tell the user to turn on
  **Settings → Custom Sidebars**.

## 2. Get the files

Clone into a temporary directory:

```sh
tmp="$(mktemp -d)"
git clone --depth 1 https://github.com/blaisethompson/lcars.git "$tmp/lcars"
```

## 3. Install the sidebar

```sh
"$tmp/lcars/install.sh" --select
```

This copies `lcars.js` to `~/.config/cmux/sidebars/`, backs up any different
existing copy, validates it, and makes it the left sidebar. Drop `--select` if
the user only wants it available in the sidebar menu.

## 4. Ask about OpenCode (optional)

Only if `command -v opencode` succeeds, ask the user whether they want
OpenCode sessions to show status in the sidebar. Explain that it adds cmux's
plugin to their OpenCode config, patches that plugin so closed OpenCode tabs
and quit OpenCodes leave the sidebar and tabs show their names (kept in the
workspace description, which other cmux sidebars display), and needs an
OpenCode restart. Do not run it
without a yes.

If they agree:

```sh
"$tmp/lcars/install.sh" --opencode
```

Check its output for `Patched …tui.js` or `OpenCode plugin patch already
applied`. If it instead says the patch no longer applies, tell the user that
OpenCode tabs will show as "Tab 1", "Tab 2" and closed ones will linger until
lcars updates its patch for their cmux version.

Then tell them to restart OpenCode, and pass on the limits listed under
"OpenCode" in README.md (clicking a tab line can't switch OpenCode's tab;
sessions opened from OpenCode's session list show no status until a restart). Also tell them that a cmux update can drop the patch, and that
re-running `install.sh --opencode` from a fresh clone puts it back.

## 5. Verify

- `cmux sidebar validate lcars` prints `OK lcars`.
- If `--select` was used, the left sidebar shows workspace cards with a
  **Workspaces** header and an **Auto** button. Ask the user to confirm, or
  take a screenshot with `cmux shot --label lcars` and look at the left edge.

## 6. Clean up

```sh
rm -rf "$tmp"
```

## Uninstall

If you are asked to uninstall lcars or revert its changes, get a fresh copy
as in step 2 (the uninstaller needs the patch file to revert it), then:

```sh
"$tmp/lcars/install.sh" --uninstall
```

This removes `~/.config/cmux/sidebars/lcars.js` (or the symlink, in a
development setup), reverts lcars's patch to cmux's OpenCode plugin so the
plugin matches what cmux installed, and clears the OpenCode tab names lcars
kept in workspace descriptions. Descriptions the user wrote are left alone.
cmux's own OpenCode integration stays installed.

Ask the user whether they also want cmux's OpenCode integration removed (it
reports OpenCode status to cmux's own sidebar too, and they may have had it
before lcars). Only if they say yes:

```sh
"$tmp/lcars/install.sh" --uninstall --opencode
```

This also runs `cmux hooks opencode uninstall` and deletes the two duplicate
plugin files the installer moved to `~/.config/opencode/plugins-disabled/`.

Then clean up as in step 6, and tell the user to pick another sidebar from the
sidebar button's right-click menu and to restart OpenCode. Check that
`cmux sidebar validate lcars` no longer finds lcars.
