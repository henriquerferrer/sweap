# sweap-board — read-only live viewer (design)

**Date:** 2026-07-19
**Status:** approved (brainstorm) → next: implementation plan
**Author:** Henrique + Claude
**Relates to:** 2026-07-18-parallel-roadmap-runs-design.md (board + coordinator),
2026-07-19-roadmap-substrate-design.md (item-file backlog it reads)

## Context

The pipeline runs parallel coordinator-mode roadmap runs; durable/ephemeral
state is spread across item files (`roadmap/<ID>.md`), the gitignored board
(`.claude/sweap-board.md`), git worktrees, and open PRs. Today the human's
at-a-glance surface is the raw board markdown plus push notifications. When 2–4
items are in flight, a rendered view is materially more glanceable — and the
research on parallel agent fleets found the human's real bottleneck is
review/unblock bandwidth, so a surface that foregrounds "items waiting on you"
serves the job that stays human.

This is a **read-only viewer**, deliberately not a control plane. The board is
both the human's status surface and the coordinator's externalized memory
specifically so the two cannot drift (parallel-runs spec, locked decision 6); a
second *writer* would break that invariant. The viewer only ever reads.

## Goals

- One glanceable local screen: live run status on top, full backlog +
  dependency graph below.
- Smooth live updates while a run is in flight, without hammering the GitHub API.
- Ship in the plugin so every sweap project gets it; read that project's config.
- Robust to the common real states: no active run, `gh`/network unavailable,
  a malformed item file.

## Non-goals (YAGNI)

- No writes/actions of any kind (no answering blocked items, no triggering runs,
  no editing the board or item files).
- No auth, no persistence/DB, no history/timeline, no websockets, no
  multi-project aggregation. A future "act from the UI" feature is a separate
  spec — it crosses the read-only line by design and must be decided
  deliberately.

## Locked decisions

1. **Single dependency-free Node script**, `plugin/tools/sweap-board.js`. Node is
   guaranteed in the Claude Code environment and matches the existing
   `plugin/workflows/milestone-audit.js`. No npm dependencies — Node stdlib only
   (`http`, `child_process`, `fs`, `path`).
2. **Tiny local read-only HTTP server**, `serve` subcommand (default). Binds
   `127.0.0.1` only. Routes: `GET /` → the self-contained HTML page; `GET
   /state.json` → the computed state. Every route is GET; the process writes no
   file and mutates nothing. A `--port` flag (default e.g. 7878); if the port is
   taken, try the next few and report the chosen one; `--open` opens the browser.
3. **State derived from ground truth, board used only for annotation.** The
   status/dependency truth is the item files + git + PRs; `.claude/sweap-board.md`
   contributes only supplementary annotations (queue order, current-step label,
   blocked question) and is never trusted for status. This keeps the viewer
   correct even if the coordinator's board narration lags.
4. **Refresh cadence split by cost.** The browser polls `/state.json` every ~3s.
   Server-side, cheap local reads (item files + `git worktree list`) run per
   request; the network `gh` call is cached ~15s so fast polling never hammers
   the API. Response carries a `generatedAt` stamp the page shows as "updated Ns
   ago".
5. **Graceful degradation is a first-class requirement.** No board file → "no run
   in flight" state, backlog still fully rendered. `gh` missing / offline /
   erroring → render items + worktrees with a visible "PR/CI unavailable" note,
   never crash. A malformed item file → surface it flagged, never abort the whole
   view.
6. **State-builder is the tested unit.** A pure function
   `buildState(projectDir, { git, gh })` where `git`/`gh` are injectable command
   runners, returning the state object. Unit-tested with on-disk fixtures +
   stubbed git/gh output (same offline, deterministic style as
   `pre-merge-gate.test.sh` / `roadmap-lint.test.sh`). The HTTP/HTML layer stays
   thin and gets one smoke test.
7. **Optional `/board` launcher command** (`plugin/commands/board.md`) that just
   runs the script in the current project — convenience, not required to use the
   tool.

## Data model — `/state.json`

Built by `buildState(projectDir, deps)`. Inputs, in order:

- **Config:** read `backlog.file` / `backlog.dir` from the `## sweap config`
  block in `CLAUDE.md` (defaults `ROADMAP.md` / `roadmap/`).
- **Items:** parse each `<backlog.dir>/*.md` frontmatter (flat single-line keys,
  inline `depends_on` — the format contract `roadmap-lint.sh` enforces): `id`,
  `title`, `status`, `depends_on`, `review-dimensions`, `lane`, `followup_of`,
  `blocked`. A file that fails to parse becomes an item with `malformed: true`.
- **Worktrees:** `git worktree list --porcelain` → branch/path per in-flight
  checkout.
- **PRs:** `gh pr list --json number,title,headRefName,state,statusCheckRollup,mergeStateStatus`
  (cached ~15s; on failure, `prsAvailable: false`).
- **Board annotations:** if `.claude/sweap-board.md` exists, best-effort parse
  for queue order + per-item current-step + blocked question. Missing → absent,
  not an error.

Derived, returned to the page:

- `run`: `{ active: bool, generatedAt, prsAvailable }`.
- `frontier`: unblocked `status: todo` items (every `depends_on` satisfied —
  item-level dep file `done`; bare-milestone dep milestone complete), in frontier
  order (debt → index milestone order → numeric item order).
- `inFlight`: items matched to a worktree/branch/PR, each with step (board
  annotation), `worktree@branch`, PR number, CI rollup state.
- `mergeQueue`: open PRs in board queue-order (fallback: PR number order).
- `blocked`: `status: blocked` items with their question.
- `backlog`: all items grouped by milestone with status badges; plus `edges`
  (dep → dependent) for the graph.

## View

One self-contained HTML page (all CSS/JS inline; theme-aware via
`prefers-color-scheme`; no external assets). Two regions:

- **Top — live run board.** Columns: Frontier (ready) · In-flight (item · step ·
  `wt@branch` · PR# · CI badge) · Merge queue (ordered) · ⛔ Blocked (item +
  question, visually foregrounded as "needs you"). When `run.active` is false, a
  quiet "nothing in flight" placeholder.
- **Bottom — backlog.** Milestone-grouped item list with status badges, and a
  lightweight layered dependency graph (SVG; nodes = items, arrows dep →
  dependent; layer by dependency depth). Malformed items shown flagged.
- **Header:** project name, active-run indicator, counts, "updated Ns ago".

The page's only logic: poll `/state.json` every 3s and patch the DOM; no
frameworks.

## Read-only / safety invariant

The server issues only read commands (`git worktree list`, `gh pr list/view`),
writes no file, never edits the board or item files, never invokes the pipeline,
and binds to loopback only. This is the property that makes it safe to run
against a live autonomous run. Any future action capability is out of scope here
and would require its own design.

## Error handling

- Port in use → try the next few, report the chosen port; still failing → clear
  error and exit.
- No `CLAUDE.md` / no `## sweap config` → fall back to defaults; if `backlog.dir`
  is absent, render an empty backlog with a note.
- `gh` absent/offline/error → `prsAvailable: false`; merge-queue/CI panels show
  "unavailable", everything else renders.
- Malformed item file → `malformed: true`, shown flagged, never fatal.
- `git` failure (not a repo) → in-flight panel shows "no worktrees", backlog
  still renders from files.

## Testing

- `sweap-board.test.js` (or `.sh` harness driving node) — offline, deterministic,
  fixture-based. `buildState` cases: (a) active run (fixtures: two todo item
  files, one with a worktree+PR, one blocked) → correct frontier/in-flight/
  blocked; (b) no board file → `run.active=false`, backlog present; (c) `gh`
  stub failing → `prsAvailable=false`, no crash; (d) dangling/malformed item →
  flagged; (e) dependency edges correct. Git/gh are injected as stub runners.
- One HTTP smoke test: start `serve` on an ephemeral port, `GET /state.json`
  returns valid JSON, `GET /` returns HTML; then shut down.

## Open items

- Exact default port and whether `--open` is default-on (decide in the plan).
- Dependency-graph layout polish (simple layered columns first; iterate only if
  it's unreadable at real backlog sizes).
