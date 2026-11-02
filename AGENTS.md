# Installing lcars (instructions for agents)

You have been asked to install **lcars**, a custom sidebar for the cmux
terminal app. Follow these steps in order.

If you were asked to change lcars's text sizes instead, go to
[Adjusting text sizes](#adjusting-text-sizes).

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

## 5. Ask about the terminal theme (optional)

Ask the user whether they want the LCARS terminal theme: a black background,
peach text and the sidebar's colours for the ANSI colours. Explain that it
changes how every cmux terminal looks (light and dark), and that
uninstalling switches back. Do not run it without a yes.

If they agree:

```sh
"$tmp/lcars/install.sh" --theme
```

(Or add `--theme` to the command in step 3 if you are asking up front.) Do not
edit `~/.config/cmux/cmux.json`. If they also want cmux's own highlights in the
same orange, point them to the `app.accentColor` option in README.md.

## 6. Ask about the agent themes (optional)

lcars has LCARS themes for three coding agents. Check which are installed
(`command -v opencode`, `command -v claude`, `command -v codex`) and, in one
question, ask the user which of those they want themed:

- **OpenCode** (`--opencode-theme`): the whole interface, in black, amber and
  peach.
- **Claude Code** (`--claude-theme`): the whole interface, in the same colours.
- **Codex** (`--codex-theme`): only syntax highlighting in code blocks and
  diffs; Codex has no other colour themes.

Explain that each replaces that agent's current theme, and that they can
switch back from the agent's theme menu (`/themes` in OpenCode, `/theme` in
Claude Code and Codex). Do not run any without a yes, and pass only the flags
they chose, for example:

```sh
"$tmp/lcars/install.sh" --opencode-theme --claude-theme
```

If the output says it couldn't edit a settings file, tell them to pick LCARS
from that agent's theme menu. Otherwise tell them to restart those agents to
see the themes. (Antigravity / `agy` has no custom theme files; its default
`"terminal"` colour scheme inherits the LCARS terminal theme from step 5.)

## 7. Verify

- `cmux sidebar validate lcars` prints `OK lcars`.
- If `--theme` was used, `cmux themes list | head -3` shows `Current light: LCARS`.
- For each agent theme flag used, the output says `Set … theme to …`.
- If `--select` was used, the left sidebar shows workspace cards with a
  **Workspaces** header and an **Auto** button. Ask the user to confirm, or
  take a screenshot with `cmux shot --label lcars` and look at the left edge.

## 8. Clean up

```sh
rm -rf "$tmp"
```

## Adjusting text sizes

If you are asked to make lcars's text bigger or smaller, edit the installed
sidebar, `~/.config/cmux/sidebars/lcars.js`. Near the top are `FONT_SCALE`,
which multiplies everything, and `TEXT_SIZES`, which has a size in points and a
plain-English `label` for each kind of text. Match what the user asks for to a
label. "Everything bigger" means `FONT_SCALE`; a single kind means its `size`.
Bars, icons and dots follow on their own, so don't change anything else.

```sh
f=$(realpath ~/.config/cmux/sidebars/lcars.js)            # keeps a symlink intact
grep -n -A15 '^const FONT_SCALE' "$f"                     # current values
sed -i '' 's/^const FONT_SCALE = .*/const FONT_SCALE = 1.2;/' "$f"
sed -i '' '/id: "title"/s/size: [0-9.]*/size: 18/' "$f"
cmux sidebar validate lcars                               # must say OK
```

cmux reloads the sidebar when the file is saved. If `validate` reports an
error, fix it straight away: until then the sidebar shows that error instead of
the workspaces. Look at the result with `cmux shot --label lcars` if you can.

- If `TEXT_SIZES` isn't there, the installed copy predates this feature. Tell
  the user, and with their yes, update it by following steps 2 and 3 first.
- If the file is a symlink (`ls -l`), it is a development setup and the edit
  changes their checkout. Tell them it will show up in `git status`.
- A scale from 0.8 to 1.6 is what the header's menu allows. Larger sizes work,
  but more text gets cut short unless the sidebar is widened.
- Sizes set from the header's right-click menu aren't stored anywhere you can
  read, and are lost when you save the file. The menu shows the current values,
  so ask the user for them if they want to keep them.

Tell the user two things about edits: re-running `install.sh` replaces them
(the old file is kept as a `.bak`, and the output names it), and uninstall keeps
the edited file and says so, so it needs deleting by hand afterwards.

## Uninstall

If you are asked to uninstall lcars or revert its changes, get a fresh copy
as in step 2 (the uninstaller needs the patch file to revert it), then:

```sh
"$tmp/lcars/install.sh" --uninstall
```

Install records what it changes in `~/.config/lcars/` (`install-state` plus
`snapshots/`), outside the checkout, so a fresh clone works. Uninstall uses it
to restore: cmux's previous light and dark themes, each agent's previous
theme, backed-up theme files, the previous custom sidebar selection, and
OpenCode's config files. A setting the user changed since the install is left
alone. A theme file the user edited is kept, and the output says where the
original is. It also removes `~/.config/cmux/sidebars/lcars.js` (or the
symlink, in a development setup), reverts lcars's patch to cmux's OpenCode
plugin, and clears the OpenCode tab names lcars kept in workspace descriptions
(descriptions the user wrote are left alone). It never touches `cmux.json`.
The output says what was restored, reset or kept.

If there is no record (an older lcars version, or the files were removed), it
prints a notice and resets themes to the defaults instead of previous values.

One step is by hand: cmux has no command for going back to its built-in
sidebar, so the output tells you what to pick. Pass it on: right-click the
sidebar button and choose "Default Workspaces" (or another sidebar).

OpenCode integration (cmux's own plugin): if the install record shows lcars
brought it, plain `--uninstall` already removes it, with
`cmux hooks opencode uninstall`. If it was there before lcars, or there is no
record, it stays and only lcars's patch is reverted. Ask the user only in
those cases, and the output says which applies: do they also want it removed
(it reports OpenCode status to cmux's own sidebar)? Only if they say yes:

```sh
"$tmp/lcars/install.sh" --uninstall --opencode
```

Duplicate plugin files the installer moved to
`~/.config/opencode/plugins-disabled/` are not moved back, because OpenCode v2
refuses to start with them ("Duplicate plugin ID: cmux.server"). If cmux's
install upgraded a plugin that already existed, the upgrade stays.

Then clean up as in step 8, and tell the user to do any by-hand step the
output named, and to restart OpenCode if it was touched. Check that
`cmux sidebar validate lcars` no longer finds lcars.
