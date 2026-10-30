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
plugin to their OpenCode config and needs an OpenCode restart. Do not run it
without a yes.

If they agree:

```sh
"$tmp/lcars/install.sh" --opencode
```

Then tell them to restart OpenCode, and pass on the limits listed under
"OpenCode" in README.md (no tab names, resumed sessions show no status).

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

```sh
rm ~/.config/cmux/sidebars/lcars.js
```

Then pick another sidebar from the sidebar button's right-click menu. To remove
the OpenCode integration: `cmux hooks opencode uninstall`.
