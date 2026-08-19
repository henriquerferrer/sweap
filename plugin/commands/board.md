---
description: Launch the read-only sweap-board viewer for this project (live run + backlog + deps).
argument-hint: "[--port N] [--no-open] — defaults: 7878, opens the browser"
---

Start the **read-only** board viewer for the current project:

```bash
node "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.mjs" --project "$PWD" $ARGUMENTS
```

It binds to `127.0.0.1` only, serves a live page (frontier / in-flight / merge
queue / hand-offs / blocked, plus the backlog, dependency graph, and the idea
inbox), and
refreshes itself by polling. It is **read-only against all pipeline state** —
item files, `git worktree list`, `gh pr list`, and `.claude/sweap-board.md`
(annotation only). Its ONLY write is create-only idea capture: the Ideas form
writes *new* files under `<backlog.dir>ideas/` (triaged later by `/roadmap`).
Those files land UNTRACKED — the form is an HTTP POST with no Claude session
behind it, so nothing can open a PR for them at capture time. They are picked up
by the sweep rule (playbook, End-of-run hygiene): the next gated PR any session
opens carries them. If you capture from the board and then stop working, run
`/idea` (or any command that opens a PR) to get them onto `origin`.
It never edits or deletes anything and never touches items, the board, or the
pipeline, so it is safe to leave running during an autonomous coordinator run.
Stop it with Ctrl-C.
