---
description: Launch the read-only sweap-board viewer for this project (live run + backlog + deps).
argument-hint: "[--port N] [--no-open] — defaults: 7878, opens the browser"
---

Start the **read-only** board viewer for the current project:

```bash
node "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.mjs" --project "$PWD" $ARGUMENTS
```

It binds to `127.0.0.1` only, serves a live page and refreshes itself by
polling. The page leads with the **running-milestone card** — which milestone
this run is executing, its goal line from the index, progress, what is in flight
right now, what is ready next, and the hand-offs and blocked questions standing
between it and done, with the audit's verdict at the foot. Below it: frontier /
in-flight / merge queue / hand-offs / blocked, then the backlog (the running
milestone marked), the idea inbox, the **discovered inbox** (notes captured
mid-run — `gap` is triaged at the next `/milestone`, `direction` waits for
`/roadmap`), **roadmap changes sitting on branches** (from
`hooks/stranded-roadmap.sh`: a rider on an open PR is shown plainly; a branch
whose PR is closed or that never had one is flagged as stranded, with a note
at the top — nothing is scheduled to land those files), and the dependency
graph.

The card prefers `.claude/sweap-run.md` — what `/milestone` actually resolved,
including the run *shape* nothing else records. Absent (a run started before
that file existed, or hand-driven work), it **derives** the milestone from what
is in flight, or names the next runnable one, and says on its face which of the
three it did. An inference must never be readable as a fact.

It is **read-only against all pipeline state** — item files, the roadmap index,
`.claude/sweap-run.md`, `git worktree list`, `gh pr list`, `.claude/sweap-board.md`
(annotation only), `audit-gate.sh --check` for the card's audit line (the
repo's vendored copy when present, else the plugin's; `--check` reports, and its
only write is a temp dir it removes), and `stranded-roadmap.sh` (diffs local
refs, fetches nothing, writes nothing).

Its ONLY write is create-only idea capture: the Ideas form writes *new* files under `<backlog.dir>ideas/` (triaged later by `/roadmap`).
Those files land UNTRACKED — the form is an HTTP POST with no Claude session
behind it, so nothing can open a PR for them at capture time. They are picked up
by the sweep rule (playbook, End-of-run hygiene): the next gated PR any session
opens carries them. If you capture from the board and then stop working, run
`/idea` (or any command that opens a PR) to get them onto `origin`.
It never edits or deletes anything and never touches items, the board, or the
pipeline, so it is safe to leave running during an autonomous run.
Stop it with Ctrl-C.
