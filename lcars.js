// lcars: workspace cards with name, folder and branch, the live agent's
// status and last message, and a minimap row with one tile per terminal.
// Click a card to select the workspace, a tile to focus that terminal, and
// drag cards to reorder. Right-click a card for pin, mark read, new tab, move and close.
//
// https://github.com/blaisethompson/lcars
//
// Open as a pane:      cmux sidebar open lcars
// Use as left sidebar: cmux sidebar select lcars

// LCARS panel colours. Red is kept for alerts: needs input, unread, close.
const LCARS = {
  amber: "#FF9900",
  peach: "#FFCC99",
  lavender: "#CC99CC",
  periwinkle: "#9999FF",
  salmon: "#FF9966",
  ice: "#99CCFF",
  gold: "#FFCC66",
  mauve: "#CC6699",
  slate: "#9999CC",
  tan: "#CC9966",
  red: "#FF5555",
};

const PALETTE = [
  LCARS.amber, LCARS.peach, LCARS.lavender, LCARS.periwinkle, LCARS.salmon,
  LCARS.ice, LCARS.gold, LCARS.mauve, LCARS.slate, LCARS.tan,
];

const STATUS = {
  needs_input: { label: "Needs input", color: LCARS.red, rank: 3 },
  working: { label: "Working", color: LCARS.amber, rank: 2 },
  idle: { label: "Idle", color: LCARS.periwinkle, rank: 1 },
};

// Each agent keeps its own mark and colour; its state shows as strength
// (faded when idle) and a red tile border when it needs input.
// `step` is the glyph's symmetry angle: a working mark turns one step per
// clock tick, so it always comes to rest looking upright.
const AGENTS = {
  claude: { glyph: "✱", color: LCARS.amber, step: 60 },
  opencode: { glyph: "▣", color: LCARS.ice, step: 90 },
};
const OTHER_AGENT = { glyph: "◆", color: LCARS.peach, step: 90 };
const agentMark = (a) => AGENTS[a?.kind] ?? OTHER_AGENT;

// Claude Code doesn't report an interrupted turn, so an agent can stay
// "working" until the next prompt. Hooks fire on every tool call, so a
// working agent that has been silent this long is shown as quiet: its mark
// stops turning, but it is never called idle, since a long build or a long
// reply is silent too.
const QUIET_AFTER = 120;

function quiet(a) {
  if (a?.status !== "working") return false;
  const last = Math.max(a.lastActivityAt ?? 0, a.sinceEpoch ?? 0);
  return last > 0 && epoch() - last > QUIET_AFTER;
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

const MAX_TILES = 3;

const epoch = () => data.clock()?.epoch ?? 0;
const findWorkspace = (id) => (data.workspaces() ?? []).find((x) => x.id === id);

// Renders `view(value)` only while `value()` is truthy.
function when(value, key, view) {
  return ForEach(
    { items: () => (value() ? [value()] : []), key: () => key },
    (v) => view(v)
  );
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

// cmux never hears that OpenCode quit, so its sessions stay "idle" after
// the terminal is back at a shell. OpenCode titles its terminal "OC | …"
// while it runs; hide its sessions in a terminal that no longer says so.
const OPENCODE_TITLE = /^OC \||opencode/i;

function liveAgents(w) {
  return (w?.agents ?? []).filter((a) => {
    if (!STATUS[a.status]) return false;
    if (a.kind !== "opencode") return true;
    const tab = (w?.tabs ?? []).find((t) => t.id === a.panelId);
    return !tab || OPENCODE_TITLE.test(tab.title ?? "");
  });
}

function topAgent(w) {
  let best = null;
  for (const a of liveAgents(w)) {
    if (!best || STATUS[a.status].rank > STATUS[best.status].rank) best = a;
  }
  return best;
}

function agentForTab(w, tab) {
  const live = liveAgents(w).filter((a) => a.panelId === tab?.id);
  live.sort((a, b) => STATUS[b.status].rank - STATUS[a.status].rank);
  return live[0] ?? null;
}

// lcars's OpenCode plugin patch keeps each open tab's name in the workspace
// description as "lcars-tabs {sessionID: title}". lcars never shows the
// description, so the map stays out of sight.
const TAB_NAMES_MARK = "lcars-tabs ";

function tabNames(w) {
  const d = w?.description ?? "";
  if (!d.startsWith(TAB_NAMES_MARK)) return {};
  try { return JSON.parse(d.slice(TAB_NAMES_MARK.length)) ?? {}; } catch (e) { return {}; }
}

function agentName(w, a) {
  return a.title || tabNames(w)[a.id] || "";
}

function statusLine(w) {
  const a = topAgent(w);
  if (!a) return null;
  const meta = STATUS[a.status];
  const since = a.status === "idle" ? null : a.sinceEpoch;
  return {
    color: meta.color,
    text: meta.label + (quiet(a) ? " · " + sessionAge(a) : since ? " · " + elapsed(since) : ""),
    who: agentName(w, a) || a.name || a.kind || "",
  };
}

// One entry per live agent session, labelled with its name when one is known
// and otherwise by the terminal it runs in. Unnamed OpenCode tabs sharing a
// terminal are numbered in a stable order.
function sessions(w) {
  const live = liveAgents(w).slice().sort((a, b) => (a.id < b.id ? -1 : 1));
  const tabs = w?.tabs ?? [];
  const perPanel = new Map();
  for (const a of live) perPanel.set(a.panelId, (perPanel.get(a.panelId) ?? 0) + 1);
  const seen = new Map();
  return live.map((a) => {
    const tab = tabs.find((t) => t.id === a.panelId);
    const n = (seen.get(a.panelId) ?? 0) + 1;
    seen.set(a.panelId, n);
    const where = tab ? tabLabel(w, tab) : (a.name || a.kind || "agent");
    const terminals = new Set(live.map((x) => x.panelId)).size;
    let label = where;
    const name = agentName(w, a);
    if (name) label = terminals > 1 ? name + " · " + where : name;
    else if (perPanel.get(a.panelId) > 1) label = terminals > 1 ? "Tab " + n + " · " + where : "Tab " + n;
    return { key: a.id, agent: a, label };
  });
}

function sessionAge(a) {
  if (quiet(a)) return "quiet " + elapsed(Math.max(a.lastActivityAt ?? 0, a.sinceEpoch ?? 0));
  if (a.status !== "idle" && a.sinceEpoch) return elapsed(a.sinceEpoch);
  return a.lastActivityAt ? elapsed(a.lastActivityAt) : "";
}

function sessionRow(w, s) {
  const meta = () => STATUS[s().agent.status];
  return HStack({ spacing: 6 }, [
    Circle({ size: 6 }).fill(() => meta().color),
    Text(() => s().label)
      .font(11).color("secondary")
      .lineLimit(1).truncation("tail"),
    Spacer({ minLength: 4 }),
    Text(() => meta().label).font(10).color(() => meta().color).fixedSize(),
    Text(() => sessionAge(s().agent))
      .font(10).monospaced().color("tertiary").fixedSize(),
  ])
    .paddingHorizontal(4)
    .paddingVertical(2)
    .cornerRadius(4)
    .hoverBackground("#FFFFFF0F")
    .cursor("pointer")
    .onTap(() => {
      const sid = s().agent.surfaceId;
      if (sid) cmux("surface.focus", { surface_id: sid, workspace_id: w().id });
      else cmux("workspace.select", { workspace_id: w().id });
    });
}

function cleanMessage(text) {
  if (!text) return "";
  const t = String(text).trim();
  if (!t || t.startsWith("<")) return "";
  return t.replace(/\s+/g, " ");
}

// A workspace still named after its path reads as "folder/".
function workspaceTitle(w) {
  const title = (w?.title ?? "").trim();
  if (!title) return basename(w?.directory) + "/";
  if (title.startsWith("~/") || title.startsWith("/")) return basename(title) + "/";
  return title;
}

function tabLabel(w, t) {
  const title = (t?.title ?? "").trim();
  if (!title) return "terminal";
  if (title.startsWith("~/") || title.startsWith("/")) return basename(title);
  return title;
}

// A tall tile per terminal: the workspace tint, the agent's ✱ in its status
// colour in the middle, and the terminal's name across the top.
function tile(w, t) {
  const agent = () => agentForTab(w(), t());
  const focused = () => !!t()?.focused;
  const live = () => focused() && !!w()?.selected;
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 3 }, [
      Text(() => tabLabel(w(), t()))
        .font(10)
        .lineLimit(1)
        .truncation("tail")
        .color(() => (live() ? "primary" : "secondary")),
      Spacer({ minLength: 0 }),
      Circle({ size: 6 }).fill(() => (t()?.hasUnread ? LCARS.red : "clear")),
    ]),
    Spacer({ minLength: 0 }),
    HStack({ spacing: 0 }, [
      Spacer({ minLength: 0 }),
      Text(() => (agent() ? agentMark(agent()).glyph : ""))
        .font(20).weight("bold")
        .color(() => (agent() ? agentMark(agent()).color : "clear"))
        .opacity(() => (agent()?.status === "idle" ? 0.4 : 1))
        .rotation(spin(agent)),
      Spacer({ minLength: 0 }),
    ]),
    Spacer({ minLength: 0 }),
  ])
    .padding(5)
    .frame({ maxWidth: "infinity", height: 56 })
    .background(() => accent(w()) + (live() ? "59" : focused() ? "38" : "21"))
    .borderColor(() =>
      agent()?.status === "needs_input" ? LCARS.red : accent(w()) + (live() ? "D9" : "40"))
    .borderWidth(() => (live() || agent()?.status === "needs_input" ? 2 : 1))
    .cornerRadius(6)
    .hoverBackground(() => accent(w()) + "4D")
    .cursor("pointer")
    .onTap(() => {
      const sid = t()?.surfaceId;
      if (sid) cmux("surface.focus", { surface_id: sid, workspace_id: w().id });
      else cmux("workspace.select", { workspace_id: w().id });
    });
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
function shortcutHint(w, size) {
  const i = () => w()?.index ?? 9;
  return Text(() => (i() < 9 ? "⌘" + (i() + 1) : ""))
    .font(size).monospaced().color("tertiary")
    .lineLimit(1).fixedSize().layoutPriority(2);
}

function card(w) {
  const selected = () => !!w()?.selected;
  const folder = () => basename(w()?.directory);
  const branch = () => (w()?.branch ? w().branch : "");
  const message = () => cleanMessage(w()?.latestMessage);
  const extra = () => Math.max(0, (w()?.tabs?.length ?? 0) - MAX_TILES);

  const body = VStack({ spacing: 5 }, [
    // Title row: name, then pin / unread badge.
    HStack({ spacing: 6 }, [
      Text(() => workspaceTitle(w()))
        .font(16).weight("bold")
        .lineLimit(1).truncation("tail").marquee()
        .color(() => (selected() ? "primary" : "#FFFFFFD9")),
      Spacer({ minLength: 0 }),
      Image("pin.fill")
        .font(9).color("tertiary")
        .opacity(() => (w()?.pinned ? 1 : 0)),
      unreadBlock(w, 10),
      shortcutHint(w, 10),
    ]),

    // Folder and branch.
    HStack({ spacing: 4 }, [
      Image("folder").font(9).color("tertiary"),
      Text(folder).font(11).color("secondary").lineLimit(1).truncation("tail"),
      Image("arrow.triangle.branch").font(9).color("tertiary")
        .opacity(() => (branch() ? 1 : 0)),
      Text(branch).font(11).monospaced().color(LCARS.periwinkle)
        .lineLimit(1).truncation("middle"),
      Circle({ size: 5 }).fill(() => (branch() && w()?.dirty ? LCARS.gold : "clear")),
      Spacer({ minLength: 0 }),
    ]),

    // Several live sessions: one line each.
    VStack({ spacing: 1 }, [
      ForEach(
        { items: () => { const s = sessions(w()); return s.length > 1 ? s : []; }, key: (s) => s.key },
        (s) => sessionRow(w, s)
      ),
    ]),

    // A single live session: one status line.
    when(() => (sessions(w()).length === 1 ? statusLine(w()) : null), "status", (s) =>
      HStack({ spacing: 5 }, [
        Circle({ size: 6 }).fill(() => s().color),
        Text(() => s().text).font(11).weight("medium").color(() => s().color)
          .lineLimit(1).fixedSize().layoutPriority(2),
        Text(() => s().who).font(11).color("tertiary").lineLimit(1).truncation("tail"),
        Spacer({ minLength: 0 }),
      ])
    ),

    // Last agent message.
    when(message, "message", (m) =>
      HStack({ spacing: 0 }, [
        Text(() => m()).font(11).color("secondary").lineLimit(2).truncation("tail"),
        Spacer({ minLength: 0 }),
      ])
    ),

    // Minimap: one tile per terminal.
    HStack({ spacing: 4 }, [
      ForEach(
        { items: () => (w()?.tabs ?? []).slice(0, MAX_TILES), key: (t) => t.id },
        (t) => tile(w, t)
      ),
      when(() => (extra() > 0 ? "+" + extra() : ""), "extra", (n) =>
        Text(() => n()).font(10).monospaced().color("tertiary").fixedSize()
      ),
    ]),
  ])
    .paddingVertical(8)
    .paddingLeading(8)
    .paddingTrailing(6)
    .frame({ maxWidth: "infinity" });

  return HStack({ spacing: 0 }, [
    RoundedRectangle({ cornerRadius: 2 })
      .fill(() => accent(w()))
      .frame({ width: 6 })
      .paddingVertical(8),
    body,
  ])
    .paddingLeading(6)
    .cornerRadius(8)
    .background(() => (selected() ? "#FFFFFF14" : null))
    .hoverBackground(() => (selected() ? "#FFFFFF14" : "#FFFFFF0A"))
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

// Sidebars can't show a dialog, and cmux refuses to close a workspace with a
// running process unless the call is forced. "Close…" asks here instead, and
// the confirmed close is forced like the built-in sidebar's.
const [closing, setClosing] = signal(null);

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
      .font(12).weight("semibold")
      .lineLimit(1).truncation("tail"),
    Spacer({ minLength: 4 }),
    button("arrow.uturn.backward", "secondary", "#FFFFFF1F", "#FFFFFF33", () => setClosing(null)),
    button("xmark", "white", LCARS.red + "D9", LCARS.red, () => {
      setClosing(null);
      cmux("workspace.close", { workspace_id: w().id, force: true });
    }),
  ])
    .paddingVertical(5)
    .paddingHorizontal(6)
    .cornerRadius(7)
    .background(LCARS.red + "1F")
    .frame({ maxWidth: "infinity" });
}

// Compact minimap: a terminal running an agent shows that agent's mark on
// the row itself (faded when idle, on red when it needs input); any other
// terminal is a small square in the workspace tint.
function miniTile(w, t) {
  const agent = () => agentForTab(w(), t());
  const live = () => !!t()?.focused && !!w()?.selected;
  const needsInput = () => agent()?.status === "needs_input";
  const side = () => (agent() ? 20 : 10);
  // The shape gives the tile its size; an empty Text alone collapses to
  // nothing, which hid plain terminals' squares.
  return ZStack([
    RoundedRectangle({ cornerRadius: 3 })
      .fill(() =>
        needsInput() ? LCARS.red
          : agent() ? "clear"
          : accent(w()) + (live() ? "B3" : "59"))
      .frame(() => ({ width: side(), height: side() })),
    Text(() => (agent() ? agentMark(agent()).glyph : ""))
      .font(14).weight("bold")
      .color(() => (needsInput() ? "black" : agent() ? agentMark(agent()).color : "clear"))
      .opacity(() => (agent()?.status === "idle" ? 0.4 : 1))
      .rotation(spin(agent)),
  ])
    .borderColor(() =>
      t()?.hasUnread ? LCARS.red : live() && !agent() ? "#FFFFFFCC" : "clear")
    .borderWidth(1)
    .cornerRadius(3)
    .cursor("pointer")
    .onTap(() => {
      const sid = t()?.surfaceId;
      if (sid) cmux("surface.focus", { surface_id: sid, workspace_id: w().id });
      else cmux("workspace.select", { workspace_id: w().id });
    });
}

function compactCard(w) {
  const selected = () => !!w()?.selected;
  const extra = () => Math.max(0, (w()?.tabs?.length ?? 0) - MAX_TILES);
  const subtitle = () => {
    const folder = basename(w()?.directory);
    return w()?.branch ? folder + " · " + w().branch : folder;
  };

  return HStack({ spacing: 8 }, [
    RoundedRectangle({ cornerRadius: 2 })
      .fill(() => accent(w()))
      .frame({ width: 6, height: 26 }),
    VStack({ spacing: 2 }, [
      HStack({ spacing: 5 }, [
        Text(() => workspaceTitle(w()))
          .font(14).weight("bold")
          .lineLimit(1).truncation("tail").marquee()
          .color(() => (selected() ? "primary" : "#FFFFFFD9")),
        Spacer({ minLength: 0 }),
        Image("pin.fill")
          .font(8).color("tertiary")
          .opacity(() => (w()?.pinned ? 1 : 0)),
        unreadBlock(w, 9),
      ]),
      HStack({ spacing: 4 }, [
        Text(subtitle)
          .font(10).color("secondary")
          .lineLimit(1).truncation("middle"),
        Spacer({ minLength: 0 }),
      ]),
    ]),
    // Minimap, centred on the row's height.
    HStack({ spacing: 3 }, [
      ForEach(
        { items: () => (w()?.tabs ?? []).slice(0, MAX_TILES), key: (t) => t.id },
        (t) => miniTile(w, t)
      ),
      when(() => (extra() > 0 ? "+" + extra() : ""), "extra", (n) =>
        Text(() => n()).font(9).monospaced().color("tertiary").fixedSize()
      ),
    ]).fixedSize().layoutPriority(2),
    // At the right edge, level with the name, so it lines up from row to row.
    VStack({ spacing: 0 }, [shortcutHint(w, 9), Spacer({ minLength: 0 })])
      .frame({ height: 26 }),
  ])
    .paddingVertical(5)
    .paddingHorizontal(6)
    .cornerRadius(7)
    .background(() => (selected() ? "#FFFFFF14" : null))
    .hoverBackground(() => (selected() ? "#FFFFFF14" : "#FFFFFF0A"))
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu(cardMenu(w));
}

// "auto" expands the selected workspace and any that want attention.
const MODES = [
  { id: "auto", label: "Auto", icon: "sparkles" },
  { id: "compact", label: "Compact", icon: "list.bullet" },
  { id: "full", label: "Full", icon: "rectangle.grid.1x2" },
];
const [modeIndex, setModeIndex] = signal(0);
const mode = () => MODES[modeIndex()];

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

function header() {
  return HStack({ spacing: 6 }, [
    Text("WORKSPACES").font(11).weight("bold").color(LCARS.amber).lineLimit(1).fixedSize(),
    Text(() => String((data.workspaces() ?? []).length))
      .font(10).monospaced().color(LCARS.peach),
    Spacer(),
    HStack({ spacing: 4 }, [
      Image(() => mode().icon).font(10).color("secondary"),
      Text(() => mode().label).font(10).color("secondary").lineLimit(1).fixedSize(),
    ])
      .paddingHorizontal(6)
      .paddingVertical(3)
      .cornerRadius(5)
      .hoverBackground("#FFFFFF14")
      .cursor("pointer")
      .onTap(() => setModeIndex((modeIndex() + 1) % MODES.length)),
  ]).paddingHorizontal(6).paddingVertical(2);
}

sidebar(() =>
  VStack({ spacing: 4 }, [
    header(),
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
