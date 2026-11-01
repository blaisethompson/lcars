// lcars: workspace cards with name, folder and branch, the live agent's
// status and last message, and a minimap row with one tile per terminal.
// Click a card to select the workspace, a tile to focus that terminal, and
// drag cards to reorder. Right-click a card for pin, mark read, new tab, move and close.
//
// https://github.com/blaisethompson/lcars
//
// Open as a pane:      cmux sidebar open lcars
// Use as left sidebar: cmux sidebar select lcars

// ---------------------------------------------------------------------------
// Palette and constants
// ---------------------------------------------------------------------------

// LCARS panel colours. Colour means status, and shape means which agent:
// amber is working, periwinkle idle, red needs input (also unread and close),
// and gold marks a branch with uncommitted changes. Those four are reserved
// for that, so workspaces are coloured only from PALETTE, which keeps clear
// of them. The header blocks are chrome, not data, and may use any colour.
const LCARS = {
  amber: "#FF9900",
  peach: "#FFCC99",
  lavender: "#CC99CC",
  periwinkle: "#9999FF",
  ice: "#99CCFF",
  gold: "#FFCC66",
  mauve: "#CC6699",
  slate: "#9999CC",
  teal: "#66CCCC",
  sage: "#99CC99",
  red: "#FF5555",
};

// Workspace colours. Left out on purpose: peach (too close to gold), salmon
// and tan (too close to amber) and slate (too close to periwinkle).
const PALETTE = [
  LCARS.lavender, LCARS.ice, LCARS.mauve, LCARS.teal, LCARS.sage,
];

const STATUS = {
  needs_input: { label: "Needs input", color: LCARS.red, rank: 3 },
  working: { label: "Working", color: LCARS.amber, rank: 2 },
  idle: { label: "Idle", color: LCARS.periwinkle, rank: 1 },
};

// The mark's shape says which agent it is; its colour says what the agent is
// doing (STATUS[...].color), so the mark, the status dot and the status text
// always agree. A tile also gets a red border when its agent needs input.
// `step` is the glyph's symmetry angle: a working mark turns one step per
// clock tick, so it always comes to rest looking upright.
const AGENTS = {
  claude: { glyph: "✱", step: 60 },
  opencode: { glyph: "▣", step: 90 },
  // A ⬢ character sits off its own centre and wobbles as it turns, so
  // Codex's hexagon is the SF Symbol, which turns about its middle. Symbols
  // draw larger than these characters, hence the smaller size.
  codex: { symbol: "hexagon.fill", step: 60, scale: 0.65 },
  antigravity: { symbol: "sparkle", step: 90, scale: 0.75 },
};
const OTHER_AGENT = { glyph: "◆", step: 90 };
const agentMark = (a) => AGENTS[a?.kind] ?? OTHER_AGENT;
const markSize = (a, size) => Math.round(size * (agentMark(a).scale ?? 1));

// An agent's mark at `size`: its character, or its SF Symbol when it has one.
// The two share one rotation, applied by the caller.
function markView(agent, size, color) {
  const mark = () => (agent() ? agentMark(agent()) : null);
  return ZStack({}, [
    Text(() => (mark() && !mark().symbol ? mark().glyph : ""))
      .font(size).weight("bold").color(color),
    when(() => mark()?.symbol ?? null, "symbol", (name) =>
      Image(() => name()).font(() => markSize(agent(), size)).weight("bold").color(color)),
  ]);
}

// An idle mark is already periwinkle, so it only needs a little softening to
// sit back from working and needs-input marks; any lower and it is hard to read.
const IDLE_OPACITY = 0.75;

// Claude Code doesn't report an interrupted turn, so an agent can stay
// "working" until the next prompt. Hooks fire on every tool call, so a
// working agent that has been silent this long is shown as quiet: dimmer
// amber, and its mark stops turning, but it is never called idle, since a
// long build or a long reply is silent too.
const QUIET_AFTER = 120;

// cmux never hears that OpenCode quit, so its sessions stay "idle" after
// the terminal is back at a shell. OpenCode titles its terminal "OC | …"
// while it runs; hide its sessions in a terminal that no longer says so.
const OPENCODE_TITLE = /^OC \||opencode/i;

// lcars's OpenCode plugin patch keeps each open tab's name in the workspace
// description as "lcars-tabs {sessionID: title}". lcars never shows the
// description, so the map stays out of sight.
const TAB_NAMES_MARK = "lcars-tabs ";

const MAX_TILES = 3;

// A workspace's colour stripe, and the gap from it to the text.
const STRIPE = 6;
const ELBOW_INSET = STRIPE + 8;
const ELBOW_RADIUS = 5;

// Radius of an LCARS pill end, and the height of the header blocks.
const BAR = 20;
const PILL = BAR / 2;

const WHITE = "#FFFFFF";

// Typeface rule: every word is monospaced, like a console readout. The
// agent marks are not, so their size and centre don't depend on the font.

// Alpha suffixes for `tint`, named by where they are used.
const ALPHA = {
  faint: "0A",   // resting hover on a card
  row: "0F",     // hover on a session row
  wash: "1F",    // selected card, close bar, button fill
  rest: "21",    // tile in an unfocused terminal
  focused: "38", // focused tile in an unselected workspace
  edge: "40",    // tile border
  hover: "4D",   // tile hover
  button: "33",  // button hover
  live: "59",    // live tile; plain mini tile at rest
  lit: "B3",     // focused plain mini tile
  strong: "D9",  // title lettering, live tile border, close button
  quiet: "A6",   // amber for a quiet agent: calmer than working
};

// ---------------------------------------------------------------------------
// Pure data helpers
// ---------------------------------------------------------------------------

const epoch = () => data.clock()?.epoch ?? 0;
const findWorkspace = (id) => (data.workspaces() ?? []).find((x) => x.id === id);

// `color` at one of the ALPHA opacities.
const tint = (color, alpha) => color + alpha;

function quiet(a) {
  if (a?.status !== "working") return false;
  const last = Math.max(a.lastActivityAt ?? 0, a.sinceEpoch ?? 0);
  return last > 0 && epoch() - last > QUIET_AFTER;
}

// What to call an agent and which colour to give it. A quiet agent keeps
// amber, since it may still be working, but at reduced strength.
function statusOf(a) {
  if (quiet(a)) return { label: "Quiet", color: tint(LCARS.amber, ALPHA.quiet) };
  const meta = STATUS[a?.status];
  return { label: meta?.label ?? "", color: meta?.color ?? "clear" };
}

// Rotation binding for a tile's mark. There are no timers, so it turns one
// step per ~1s clock tick while the agent works; the angle only grows, so
// the spring never spins backwards, and it holds still otherwise.
function spin(agent) {
  let angle = 0;
  let tick = null;
  return () => {
    const a = agent();
    const now = Math.floor(epoch());
    if (a?.status === "working" && !quiet(a) && now !== tick) {
      if (tick !== null) angle += agentMark(a).step;
      tick = now;
    } else if (a?.status !== "working" || quiet(a)) {
      tick = null;
    }
    return angle;
  };
}

// Renders `view(value)` only while `value()` is truthy.
function when(value, key, view) {
  return ForEach(
    { items: () => (value() ? [value()] : []), key: () => key },
    (v) => view(v)
  );
}

function capitalise(s) {
  return s ? s[0].toUpperCase() + s.slice(1) : "";
}

function basename(path) {
  if (!path) return "";
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || path;
}

function hashColor(key) {
  let h = 0;
  for (let i = 0; i < key.length; i += 1) h = (h * 31 + key.charCodeAt(i)) | 0;
  return PALETTE[Math.abs(h) % PALETTE.length];
}

// Black or white, whichever reads better on `hex`: workspace colours set
// in cmux can be dark, unlike the LCARS ones.
function inkOn(hex) {
  let h = /^#([0-9a-f]{3,8})$/i.exec(hex ?? "")?.[1] ?? "";
  if (h.length === 3) h = h.replace(/./g, "$&$&");
  if (h.length < 6) return "black";
  const lum = [0, 2, 4].map((i) => {
    const c = parseInt(h.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  });
  const l = 0.2126 * lum[0] + 0.7152 * lum[1] + 0.0722 * lum[2];
  return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? "black" : "white";
}

function accent(w) {
  if (!w) return "#7f7f7f";
  return w.color || hashColor(w.id);
}

function elapsed(since) {
  const s = Math.max(0, Math.floor(epoch() - since));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  return h < 24 ? h + "h" : Math.floor(h / 24) + "d";
}

function liveAgents(w) {
  return (w?.agents ?? []).filter((a) => {
    if (!STATUS[a.status]) return false;
    if (a.kind !== "opencode") return true;
    const tab = (w?.tabs ?? []).find((t) => t.id === a.panelId);
    return !tab || OPENCODE_TITLE.test(tab.title ?? "");
  });
}

function agentForTab(w, tab) {
  const live = liveAgents(w).filter((a) => a.panelId === tab?.id);
  live.sort((a, b) => STATUS[b.status].rank - STATUS[a.status].rank);
  return live[0] ?? null;
}

// Parsed tab names, kept by description so each is parsed once, however
// many agents ask. The cache is cleared before it can grow large.
const tabNameCache = new Map();

function tabNames(w) {
  const d = w?.description ?? "";
  if (!d.startsWith(TAB_NAMES_MARK)) return {};
  let names = tabNameCache.get(d);
  if (!names) {
    try { names = JSON.parse(d.slice(TAB_NAMES_MARK.length)) ?? {}; } catch (e) { names = {}; }
    if (tabNameCache.size > 32) tabNameCache.clear();
    tabNameCache.set(d, names);
  }
  return names;
}

function agentName(w, a) {
  return a.title || tabNames(w)[a.id] || "";
}

// One entry per live agent session, labelled with its name when one is known
// and otherwise by the terminal it runs in. A lone session falls back to the
// agent itself ("Claude") before the terminal, since the terminal's title
// is often just a path or a command. Unnamed OpenCode tabs sharing a
// terminal are numbered in a stable order.
function sessions(w) {
  const live = liveAgents(w).slice().sort((a, b) => (a.id < b.id ? -1 : 1));
  const tabs = w?.tabs ?? [];
  const perPanel = new Map();
  for (const a of live) perPanel.set(a.panelId, (perPanel.get(a.panelId) ?? 0) + 1);
  const terminals = perPanel.size;
  const seen = new Map();
  return live.map((a) => {
    const tab = tabs.find((t) => t.id === a.panelId);
    const n = (seen.get(a.panelId) ?? 0) + 1;
    seen.set(a.panelId, n);
    const where = tab ? tabLabel(w, tab) : (a.name || a.kind || "agent");
    let label = where;
    const name = agentName(w, a);
    if (!name && live.length === 1) label = a.name || capitalise(a.kind) || where;
    else if (name) label = terminals > 1 ? name + " · " + where : name;
    else if (perPanel.get(a.panelId) > 1) label = terminals > 1 ? "Tab " + n + " · " + where : "Tab " + n;
    return { key: a.id, agent: a, label };
  });
}

function sessionAge(a) {
  if (quiet(a)) return elapsed(Math.max(a.lastActivityAt ?? 0, a.sinceEpoch ?? 0));
  if (a.status !== "idle" && a.sinceEpoch) return elapsed(a.sinceEpoch);
  return a.lastActivityAt ? elapsed(a.lastActivityAt) : "";
}

function cleanMessage(text) {
  if (!text) return "";
  const t = String(text).trim();
  if (!t || t.startsWith("<")) return "";
  return t.replace(/\s+/g, " ");
}

// Agents decorate their terminal titles: OpenCode prefixes "OC | ", and
// Codex animates a braille spinner (⠋ ⠙ ⠹ …) in front while it works. The
// turning mark already says both, so they are left off wherever a title is shown.
const cleanTitle = (title) => String(title ?? "")
  .replace(/^[\s\u2800-\u28FF]+/, "")
  .replace(/^OC\s*\|\s*/, "")
  .trim();

// A workspace still named after its path reads as "folder/". A workspace
// cmux names from its terminal title can carry OpenCode's prefix. The sidebar
// isn't told whether a title was typed by hand, so the prefix goes either way.
function workspaceTitle(w) {
  const title = cleanTitle(w?.title);
  if (!title) return basename(w?.directory) + "/";
  if (title.startsWith("~/") || title.startsWith("/")) return basename(title) + "/";
  return title;
}

function tabLabel(w, t) {
  const title = cleanTitle(t?.title);
  if (!title) return "terminal";
  if (title.startsWith("~/") || title.startsWith("/")) return basename(title);
  return title;
}

function wantsAttention(w) {
  if (!w) return false;
  if (w.unread > 0) return true;
  return liveAgents(w).some((a) => a.status === "needs_input");
}

function expanded(w) {
  const m = mode().id;
  if (m === "full") return true;
  if (m === "compact") return false;
  return !!w?.selected || wantsAttention(w);
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Sidebars can't show a dialog, and cmux refuses to close a workspace with a
// running process unless the call is forced. "Close…" asks here instead, and
// the confirmed close is forced like the built-in sidebar's.
const [closing, setClosing] = signal(null);

// "auto" expands the selected workspace and any that want attention.
const MODES = [
  { id: "auto", label: "Auto", icon: "sparkles" },
  { id: "compact", label: "List", icon: "list.bullet" },
  { id: "full", label: "Full", icon: "rectangle.grid.1x2" },
];
const [modeIndex, setModeIndex] = signal(0);
const mode = () => MODES[modeIndex()];

// ---------------------------------------------------------------------------
// View components
// ---------------------------------------------------------------------------

// Focus a terminal by its surface; without one, select its workspace.
function focusTerminal(w, surfaceId) {
  if (surfaceId) cmux("surface.focus", { surface_id: surfaceId, workspace_id: w().id });
  else cmux("workspace.select", { workspace_id: w().id });
}

function sessionRow(w, s) {
  const meta = () => statusOf(s().agent);
  return HStack({ spacing: 6 }, [
    Circle({ size: 6 }).fill(() => meta().color),
    Text(() => s().label)
      .font(11).monospaced().color("secondary")
      .lineLimit(1).truncation("tail"),
    Spacer({ minLength: 4 }),
    Text(() => meta().label).font(10).monospaced().color(() => meta().color).fixedSize(),
    Text(() => sessionAge(s().agent))
      .font(10).monospaced()
      .color(() => (quiet(s().agent) ? meta().color : "tertiary"))
      .fixedSize(),
  ])
    .paddingHorizontal(4)
    .paddingVertical(2)
    .cornerRadius(4)
    .hoverBackground(tint(WHITE, ALPHA.row))
    .cursor("pointer")
    .onTap(() => focusTerminal(w, s().agent.surfaceId));
}

// A one-line tile (about 30pt tall) per terminal: the agent's mark in its status colour at the
// leading edge, the terminal's name, then the unread dot. One line keeps the
// card short. A tile with no agent gives the mark's slot to the name rather
// than reserving it: tiles sit side by side, not stacked, so there is nothing
// to line up with, and with three tiles across every character counts.
function tile(w, t) {
  const agent = () => agentForTab(w(), t());
  const focused = () => !!t()?.focused;
  const live = () => focused() && !!w()?.selected;
  const needsInput = () => agent()?.status === "needs_input";
  return HStack({ spacing: 4 }, [
    // Fixed square, so the label doesn't shift as the mark turns.
    markView(agent, 17, () => (agent() ? statusOf(agent()).color : "clear"))
      .opacity(() => (agent()?.status === "idle" ? IDLE_OPACITY : 1))
      .frame(() => ({ width: agent() ? 20 : 0, height: 20 }))
      .rotation(spin(agent)),
    Text(() => tabLabel(w(), t()))
      .font(10).monospaced()
      .lineLimit(1)
      .truncation("tail")
      .color(() => (live() ? "primary" : "secondary")),
    Spacer({ minLength: 0 }),
    // A tile that needs input already has a red border, so no dot there.
    Circle({ size: 6 }).fill(() => (t()?.hasUnread && !needsInput() ? LCARS.red : "clear")),
  ])
    // Padding sets the height (the 20pt mark slot plus 5 above and below);
    // a frame height here doesn't stretch an HStack.
    .paddingHorizontal(6)
    .paddingVertical(5)
    .frame({ maxWidth: "infinity" })
    .background(() => tint(accent(w()), live() ? ALPHA.live : focused() ? ALPHA.focused : ALPHA.rest))
    .borderColor(() =>
      needsInput() ? LCARS.red : tint(accent(w()), live() ? ALPHA.strong : ALPHA.edge))
    .borderWidth(() => (live() || needsInput() ? 2 : 1))
    .cornerRadius(6)
    .hoverBackground(() => tint(accent(w()), ALPHA.hover))
    .cursor("pointer")
    .onTap(() => focusTerminal(w, t()?.surfaceId));
}

// Unread count as an LCARS readout: a squared red block with black digits.
function unreadBlock(w, size) {
  const n = () => w()?.unread ?? 0;
  return Text(() => (n() > 0 ? String(n()).padStart(2, "0") : ""))
    .font(size).weight("bold").monospaced().color("black")
    .paddingHorizontal(() => (n() > 0 ? 4 : 0))
    .paddingVertical(() => (n() > 0 ? 1 : 0))
    .background(() => (n() > 0 ? LCARS.red : null))
    .cornerRadius(3)
    .fixedSize()
    .layoutPriority(2);
}

// ⌘1–⌘9 select the first nine workspaces; show which is which.
function shortcutHint(w, size, color = "secondary") {
  const i = () => w()?.index ?? 9;
  return Text(() => (i() < 9 ? "⌘" + (i() + 1) : ""))
    .font(size).monospaced().color(color)
    .lineLimit(1).fixedSize().layoutPriority(2);
}


// The workspace's title bar, laid over the top of the stripe: its name, then
// `trailing` (pin, unread, ⌘ hint) at the far end. When selected the stripe
// turns right behind it and runs the full width, an LCARS elbow, with
// everything in black (or white on a dark colour) and a pill end at the
// right. The lettering stays in line with the rows below either way.
//
// The bar is a pill, `height` tall, with a small rounded block laid over its
// left end so the elbow's outer corner keeps ELBOW_RADIUS. An invisible strut
// sets the height, as in barBlock, and the text has no padding of its own, so
// the bar is exactly `height` and the block matches it.
function titleBar(w, size, height, trailing) {
  const selected = () => !!w()?.selected;
  const fill = () => (selected() ? accent(w()) : "clear");
  const cap = height / 2;
  const corner = RoundedRectangle({ cornerRadius: ELBOW_RADIUS })
    .fill(fill)
    .frame({ width: 3 * cap, height });
  const pill = HStack({ spacing: 0 }, [
    Rectangle().fill("clear").frame({ width: 0, height }),
    Text(() => workspaceTitle(w()))
      .font(size).weight("bold").monospaced()
      .lineLimit(1).truncation("tail").marquee()
      .color(() => (selected() ? inkOn(accent(w())) : tint(WHITE, ALPHA.strong))),
    Spacer({ minLength: 0 }),
    ...trailing,
  ])
    .paddingLeading(ELBOW_INSET - cap)
    .paddingTrailing(() => (selected() ? cap - 2 : 0))
    .frame({ maxWidth: "infinity" })
    .background(fill)
    .cornerRadius(cap);
  // The block reaches past the pill's round end, so its own rounded right
  // corners sit under the pill's straight edge and leave no notch.
  return HStack({ spacing: -2 * cap }, [corner, pill]);
}

// Ink for the pin and ⌘ hint: on the bar when selected, `rest` otherwise.
function barInk(w, rest) {
  return () => (w()?.selected ? inkOn(accent(w())) : rest);
}


// The workspace's colour stripe. `topInset` is the gap above it; when the
// workspace is selected the stripe starts lower, below the elbow's rounded
// corner, so that shows.
function stripe(w, topInset) {
  const selected = () => !!w()?.selected;
  return RoundedRectangle({ cornerRadius: STRIPE / 2 })
    .fill(() => accent(w()))
    .frame({ width: STRIPE })
    .paddingTop(() => (selected() ? topInset + ELBOW_RADIUS : topInset));
}

// Minimap: one tile per terminal (up to MAX_TILES), then "+N" for the rest.
function minimap(w, tileFn, spacing, fontSize) {
  const extra = () => Math.max(0, (w()?.tabs?.length ?? 0) - MAX_TILES);
  return HStack({ spacing }, [
    ForEach(
      { items: () => (w()?.tabs ?? []).slice(0, MAX_TILES), key: (t) => t.id },
      (t) => tileFn(w, t)
    ),
    when(() => (extra() > 0 ? "+" + extra() : ""), "extra", (n) =>
      Text(() => n()).font(fontSize).monospaced().color("secondary").fixedSize()
    ),
  ]);
}

function card(w) {
  const selected = () => !!w()?.selected;
  const folder = () => basename(w()?.directory);
  const branch = () => (w()?.branch ? w().branch : "");
  const message = () => cleanMessage(w()?.latestMessage);

  const body = VStack({ spacing: 4 }, [
    // Title row: name, then pin / unread badge.
    titleBar(w, 15, 22, [
      when(() => (w()?.pinned ? "pin" : ""), "pin", () =>
        Image("pin.fill").font(9).color(barInk(w, "tertiary")).paddingLeading(6)
      ),
      unreadBlock(w, 10).paddingLeading(() => ((w()?.unread ?? 0) > 0 ? 6 : 0)),
      shortcutHint(w, 10, barInk(w, "secondary"))
        .paddingLeading(() => ((w()?.index ?? 9) < 9 ? 6 : 0)),
    ]),
    VStack({ spacing: 4 }, [
      // Folder and branch.
      HStack({ spacing: 4 }, [
        Image("folder").font(9).color("tertiary"),
        Text(folder).font(11).monospaced().color("secondary").lineLimit(1).truncation("tail"),
        Image("arrow.triangle.branch").font(9).color("tertiary")
          .opacity(() => (branch() ? 1 : 0)),
        Text(branch).font(11).monospaced().color("secondary")
          .lineLimit(1).truncation("middle"),
        Circle({ size: 5 }).fill(() => (branch() && w()?.dirty ? LCARS.gold : "clear")),
        Spacer({ minLength: 0 }),
      ]),

      // Live agent sessions: one line each.
      VStack({ spacing: 1 }, [
        ForEach(
          { items: () => sessions(w()), key: (s) => s.key },
          (s) => sessionRow(w, s)
        ),
      ]),

      // Last agent message.
      when(message, "message", (m) =>
        HStack({ spacing: 0 }, [
          Text(() => m()).font(11).monospaced().color("secondary").lineLimit(2).truncation("tail"),
          Spacer({ minLength: 0 }),
        ])
      ),

      // Minimap: one tile per terminal.
      minimap(w, tile, 4, 10),
    ]).paddingLeading(ELBOW_INSET),
  ])
    .paddingVertical(6)
    .paddingTrailing(6)
    .frame({ maxWidth: "infinity" });

  // The body is laid over the stripe so the elbow can grow out of it.
  return HStack({ spacing: -STRIPE }, [
    stripe(w, 6).paddingBottom(6),
    body,
  ])
    .paddingLeading(6)
    .cornerRadius(8)
    .background(() => (selected() ? tint(accent(w()), ALPHA.wash) : null))
    .hoverBackground(() => (selected() ? tint(accent(w()), ALPHA.wash) : tint(WHITE, ALPHA.faint)))
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu(cardMenu(w));
}

function cardMenu(w) {
  return [
    Button(() => (w()?.pinned ? "Unpin" : "Pin"), () =>
      cmux("workspace.action", { action: w()?.pinned ? "unpin" : "pin", workspace_id: w().id })),
    Button(() => (w()?.unread > 0 ? "Mark as Read" : "Mark as Unread"), () =>
      cmux("workspace.action", { action: w()?.unread > 0 ? "mark_read" : "mark_unread", workspace_id: w().id })),
    Button("New Tab", () =>
      cmux("surface.create", { workspace_id: w().id, focus: true })),
    Divider(),
    Button("Move to Top", () =>
      cmux("workspace.action", { action: "move_top", workspace_id: w().id })),
    Button("Move Up", () =>
      cmux("workspace.action", { action: "move_up", workspace_id: w().id })),
    Button("Move Down", () =>
      cmux("workspace.action", { action: "move_down", workspace_id: w().id })),
    Divider(),
    Button("Close…", () => setClosing(w().id)).destructive(),
  ];
}

function closeConfirm(w) {
  const button = (icon, color, fill, hover, onTap) =>
    Image(icon).font(10).weight("bold").color(color)
      .paddingHorizontal(8).paddingVertical(4)
      .fixedSize()
      .background(fill)
      .hoverBackground(hover)
      .cornerRadius(6)
      .cursor("pointer")
      .onTap(onTap);
  return HStack({ spacing: 6 }, [
    RoundedRectangle({ cornerRadius: 2 })
      .fill(LCARS.red)
      .frame({ width: 6, height: 26 }),
    Text(() => "Close " + workspaceTitle(w()) + "?")
      .font(12).weight("semibold").monospaced()
      .lineLimit(1).truncation("tail"),
    Spacer({ minLength: 4 }),
    button("arrow.uturn.backward", "secondary", tint(WHITE, ALPHA.wash), tint(WHITE, ALPHA.button), () => setClosing(null)),
    button("xmark", "white", tint(LCARS.red, ALPHA.strong), LCARS.red, () => {
      setClosing(null);
      cmux("workspace.close", { workspace_id: w().id, force: true });
    }),
  ])
    .paddingVertical(5)
    .paddingHorizontal(6)
    .cornerRadius(7)
    .background(tint(LCARS.red, ALPHA.wash))
    .frame({ maxWidth: "infinity" });
}

// Compact minimap tiles all share one square slot, so marks fall in the same
// columns whatever they hold. A terminal running an agent shows that agent's
// mark in its status colour (black on a red square when it needs input); any
// other terminal is a smaller square in the workspace tint, centred in the
// slot. Both are brighter on the workspace's focused tab and dimmer at rest.
const SLOT = 16;
const PLAIN = 8;
const MINI_GAP = 2;
const MINI_REST_OPACITY = 0.5;

function miniTile(w, t) {
  const agent = () => agentForTab(w(), t());
  const focused = () => !!t()?.focused;
  const needsInput = () => agent()?.status === "needs_input";
  // The shapes give the slot its size; an empty Text alone collapses to
  // nothing, which hid plain terminals' squares.
  return ZStack([
    RoundedRectangle({ cornerRadius: 3 })
      .fill(() => (needsInput() ? LCARS.red : "clear"))
      .frame({ width: SLOT, height: SLOT }),
    RoundedRectangle({ cornerRadius: 2 })
      .fill(() => (agent() ? "clear" : tint(accent(w()), focused() ? ALPHA.lit : ALPHA.live)))
      .frame({ width: PLAIN, height: PLAIN }),
    // Large enough to see turn, small enough to fit the slot once turned.
    markView(agent, 14, () => (needsInput() ? "black" : agent() ? statusOf(agent()).color : "clear"))
      .opacity(() => (focused() || needsInput() ? 1 : MINI_REST_OPACITY))
      .rotation(spin(agent)),
  ])
    .borderColor(() => (t()?.hasUnread ? LCARS.red : "clear"))
    .borderWidth(1)
    .cornerRadius(3)
    .cursor("pointer")
    .onTap(() => focusTerminal(w, t()?.surfaceId));
}

// The compact minimap: up to MAX_TILES slots at the right of the second row,
// so the last slot is always in the same column while rows with fewer
// terminals leave the rest of the width to the folder and branch. When there
// are more terminals than slots, the last slot holds "+N" instead of a tile.
function miniMap(w) {
  const count = () => w()?.tabs?.length ?? 0;
  const extra = () => (count() > MAX_TILES ? count() - (MAX_TILES - 1) : 0);
  return HStack({ spacing: MINI_GAP }, [
    ForEach(
      { items: () => (w()?.tabs ?? []).slice(0, extra() > 0 ? MAX_TILES - 1 : MAX_TILES), key: (t) => t.id },
      (t) => miniTile(w, t)
    ),
    when(() => (extra() > 0 ? "+" + extra() : ""), "extra", (n) =>
      ZStack([
        Rectangle().fill("clear").frame({ width: SLOT, height: SLOT }),
        Text(() => n()).font(9).monospaced().color("secondary").fixedSize(),
      ])
    ),
  ])
    .fixedSize()
    .layoutPriority(2);
}

function compactCard(w) {
  const selected = () => !!w()?.selected;
  const folder = () => basename(w()?.directory);
  const branch = () => (w()?.branch ? w().branch : "");

  return HStack({ spacing: -STRIPE }, [
    stripe(w, 0),
    VStack({ spacing: 2 }, [
      // Pin, unread and ⌘ hint take no room, gaps included, until they show,
      // so the name keeps the width.
      titleBar(w, 13, 18, [
        when(() => (w()?.pinned ? "pin" : ""), "pin", () =>
          Image("pin.fill").font(8).color(barInk(w, "tertiary")).paddingLeading(5)
        ),
        unreadBlock(w, 9).paddingLeading(() => ((w()?.unread ?? 0) > 0 ? 5 : 0)),
        shortcutHint(w, 9, barInk(w, "secondary"))
          .paddingLeading(() => ((w()?.index ?? 9) < 9 ? 5 : 0)),
      ]),
      // As on a full card, with the folder and branch icons left out for
      // lack of room; each truncates on its own so neither disappears on a
      // narrow sidebar, and the minimap sits at the right end.
      HStack({ spacing: 4 }, [
        Text(folder)
          .font(10).monospaced().color("secondary")
          .lineLimit(1).truncation("tail"),
        Text(() => (branch() ? "·" : ""))
          .font(10).monospaced().color("secondary").fixedSize(),
        Text(branch)
          .font(10).monospaced().color("secondary")
          .lineLimit(1).truncation("middle"),
        when(() => (branch() && w()?.dirty ? "dirty" : ""), "dirty", () =>
          Circle({ size: 5 }).fill(LCARS.gold).fixedSize()
        ),
        Spacer({ minLength: 0 }),
        miniMap(w),
      ]).paddingLeading(ELBOW_INSET),
    ]).frame({ maxWidth: "infinity" }),
  ])
    .paddingVertical(5)
    .paddingHorizontal(6)
    .cornerRadius(7)
    .background(() => (selected() ? tint(accent(w()), ALPHA.wash) : null))
    .hoverBackground(() => (selected() ? tint(accent(w()), ALPHA.wash) : tint(WHITE, ALPHA.faint)))
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu(cardMenu(w));
}

// Every header block is exactly the bar's height, so the edges run straight
// across where blocks meet; padding around the text alone leaves them a point
// or two short of the bar. A frame height on text is ignored, so an invisible
// zero-width strut, which as a shape does keep its frame, sets the height.
function barBlock(content, fill) {
  return HStack({ spacing: 0 }, [
    Rectangle().fill("clear").frame({ width: 0, height: BAR }),
    content,
  ]).background(fill);
}

// An LCARS block in `fill`: a pill-ended `content`, with a square block laid
// over one inner end to square it off. `squareFirst` puts the square at the
// left, where the block meets the bar; otherwise it ends the block at the right.
function pillBlock(fill, content, squareFirst) {
  const square = Rectangle().fill(fill).frame({ width: PILL, height: BAR });
  const pill = barBlock(content, fill).cornerRadius(PILL);
  return HStack({ spacing: -PILL }, squareFirst ? [square, pill] : [pill, square]);
}

// The mode button as an LCARS block in `fill`: square at the left, where
// it meets the bar, and a pill end at the right.
function modeBlock(fill) {
  return pillBlock(fill,
    HStack({ spacing: 4 }, [
      Image(() => mode().icon).font(10).weight("bold").color("black"),
      Text(() => mode().label.toUpperCase()).font(10).weight("bold").monospaced().color("black")
        .lineLimit(1).fixedSize(),
    ])
      .paddingLeading(PILL)
      .paddingTrailing(10)
      .fixedSize(),
    true);
}

// Live agents across every workspace with `status`; quiet agents are left out, so
// "working" means working right now.
function agentCount(status) {
  let n = 0;
  for (const w of data.workspaces() ?? []) {
    for (const a of liveAgents(w)) {
      if (a.status === status && !quiet(a)) n += 1;
    }
  }
  return n;
}

// A header readout like the count block: black bold digits on solid colour,
// square ends, with a small SF Symbol ahead of them so it isn't just a number.
// The symbol is an Image, not a character in the string, because a font's ▶
// sits off the digits' centre line; an Image is centred on them. Absent (no
// block, no gap) while the count is zero.
function readoutBlock(count, icon, fill, onTap) {
  return when(() => (count() > 0 ? count() : 0), icon, (n) => {
    const block = HStack({ spacing: 2 }, [
      Image(icon).font(7).weight("bold").color("black"),
      Text(() => String(n()).padStart(2, "0"))
        .font(11).weight("bold").monospaced().color("black")
        .lineLimit(1),
    ])
      .paddingHorizontal(5)
      .fixedSize();
    const filled = barBlock(block, fill);
    return onTap ? filled.cursor("pointer").onTap(onTap) : filled;
  });
}

// Jump to the first workspace with an agent waiting on the user.
function selectNeedsInput() {
  const w = (data.workspaces() ?? []).find((x) =>
    liveAgents(x).some((a) => a.status === "needs_input"));
  if (w) cmux("workspace.select", { workspace_id: w.id });
}

// An LCARS header bar: solid colour blocks with black lettering, pill ends
// on the outside and square ends where blocks meet.
function header() {
  return HStack({ spacing: 3 }, [
    pillBlock(LCARS.amber,
      Text("WORKSPACES").font(11).weight("bold").monospaced().color("black").lineLimit(1)
        .paddingLeading(10).paddingTrailing(PILL)
        .fixedSize(),
      false),
    barBlock(
      Text(() => String((data.workspaces() ?? []).length).padStart(2, "0"))
        .font(11).weight("bold").monospaced().color("black")
        .paddingHorizontal(5)
        .fixedSize(),
      LCARS.peach),
    // Needs-input and working readouts, each only while there are any; the
    // lavender filler gives up the room, so the mode button is never squeezed.
    readoutBlock(() => agentCount("needs_input"), "exclamationmark", LCARS.red, selectNeedsInput),
    readoutBlock(() => agentCount("working"), "play.fill", LCARS.amber, null),
    Rectangle().fill(LCARS.lavender).frame({ maxWidth: "infinity", height: BAR }),
    // The lit copy shows on hover. A square block under each pill's inner
    // end squares it off, so it is drawn in the same colour as the pill.
    ZStack({}, [modeBlock(LCARS.slate), modeBlock(LCARS.periwinkle).showOnHover()])
      .cursor("pointer")
      .onTap(() => setModeIndex((modeIndex() + 1) % MODES.length)),
  ]).frame({ height: BAR }).paddingHorizontal(6).paddingVertical(2);
}

sidebar(() =>
  VStack({ spacing: 4 }, [
    header(),
    when(() => ((data.workspaces() ?? []).length === 0 ? "none" : ""), "empty", () =>
      Text("NO WORKSPACES")
        .font(10).weight("bold").monospaced().color("tertiary")
        .paddingHorizontal(10).paddingVertical(4)
    ),
    Reorderable(
      {
        items: () => data.workspaces() ?? [],
        key: (w) => w.id,
        spacing: 2,
        onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index: index }),
      },
      (item) => {
        const id = item().id;
        const w = () => findWorkspace(id) ?? item();
        return VStack({ spacing: 0 }, [
          when(() => closing() === id, "close", () => closeConfirm(w)),
          when(() => closing() !== id && !expanded(w()), "compact", () => compactCard(w)),
          when(() => closing() !== id && expanded(w()), "full", () => card(w)),
        ]);
      }
    ),
    Spacer(),
  ]).padding(6),
  { surface: "glass" }
)
