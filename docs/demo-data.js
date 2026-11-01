// Sample workspaces for the README screenshots (docs/screenshots.sh).
// The script prepends this to a copy of lcars.js and points that copy's
// data.workspaces() reads at demoWorkspaces(), so everything on screen is
// drawn by the real sidebar code. Times are relative to the live clock.

const DEMO_SELECTED = "__SELECTED__";

function demoWorkspaces() {
  const now = data.clock()?.epoch ?? 0;
  const ago = (s) => now - s;
  const tab = (id, title, extra) => ({ id, title, surfaceId: id, focused: false, pinned: false, hasUnread: false, ...extra });
  const agent = (id, kind, name, status, panelId, since, extra) => ({
    id, kind, name, status, panelId, surfaceId: panelId,
    sinceEpoch: ago(since), lastActivityAt: ago(status === "idle" ? since : 4), ...extra,
  });
  const list = [
    {
      id: "checkout", title: "Apple Pay checkout", directory: "~/src/checkout-api",
      branch: "feature/apple-pay", color: "#99CCFF", unread: 0,
      latestMessage: "Wiring the payment sheet into the checkout flow",
      tabs: [tab("checkout-1", "claude", { focused: true }), tab("checkout-2", "dev server")],
      agents: [agent("c1", "claude", "Claude", "working", "checkout-1", 72)],
    },
    {
      id: "onboarding", title: "Onboarding crash fix", directory: "~/src/mobile-app",
      branch: "fix/onboarding-crash", dirty: true, color: "#66CCCC", unread: 1,
      latestMessage: "Should I keep the old migration path for users on 3.x?",
      tabs: [tab("onboarding-1", "claude", { focused: true, hasUnread: true })],
      agents: [agent("c2", "claude", "Claude", "needs_input", "onboarding-1", 64)],
    },
    {
      id: "search", title: "Search typo tolerance", directory: "~/src/search-service",
      branch: "feat/typo-tolerance", color: "#99CC99", unread: 0,
      latestMessage: "Benchmarks are in: p95 went from 41ms to 44ms",
      description: 'lcars-tabs {"ses_fuzzy":"Fuzzy matching","ses_bench":"Benchmark harness"}',
      tabs: [tab("search-1", "OC | Fuzzy matching", { focused: true })],
      agents: [
        agent("ses_fuzzy", "opencode", "OpenCode", "working", "search-1", 32),
        agent("ses_bench", "opencode", "OpenCode", "idle", "search-1", 95),
      ],
    },
    {
      id: "docs", title: "Docs refresh", directory: "~/src/docs-site",
      branch: "main", color: "#CC99CC", unread: 0,
      tabs: [tab("docs-1", "codex", { focused: true })],
      agents: [agent("c3", "codex", "Codex", "idle", "docs-1", 300)],
    },
    {
      id: "postgres", title: "Postgres 17 upgrade", directory: "~/src/infra",
      branch: "upgrade/postgres-17", color: "#99CCFF", unread: 0,
      tabs: [tab("pg-1", "psql", { focused: true }), tab("pg-2", "terraform"), tab("pg-3", "logs")],
    },
    {
      id: "dotfiles", title: "~/dotfiles", directory: "~/dotfiles",
      branch: "main", color: "#CC6699", unread: 0,
      tabs: [tab("dot-1", "~/dotfiles", { focused: true })],
    },
  ];
  return list.map((w, index) => ({
    pinned: false, ports: [], portCount: 0, status: "todo", tabCount: w.tabs.length,
    ...w, index, selected: w.id === DEMO_SELECTED,
  }));
}

