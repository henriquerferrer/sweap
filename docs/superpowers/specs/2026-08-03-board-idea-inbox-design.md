# sweap-board idea inbox — design

**Date:** 2026-08-03
**Status:** approved

## Goal

Let a human capture ideas from the sweap-board page while a run is live, without
breaking the board's safety contract. Ideas land in an inbox that the next
`/roadmap` brainstorm is required to surface, so nothing rots.

## Decision summary

- **Write scope:** idea inbox only. The board never edits existing items or any
  pipeline state; its only write is *creating new files* under `roadmap/ideas/`.
- **Idea flow:** ideas are fodder for `/roadmap`'s decide phase (same precedent
  as audit follow-ups), not draft items. No new `status:` value anywhere —
  lint, dep resolution, and the frontier never see ideas.
- **Capture form:** title (required) + free-form body (optional). No premature
  structure (milestone, size, tags) — that is what the brainstorm decides.

Rejected alternatives: draft items with `status: idea` (three mechanisms —
roadmap-lint, milestone-dep resolution, board lib — would each need to learn a
new status, and capture-time ids/deps front-run the brainstorm); a single
`IDEAS.md` (append races, merge conflicts, nothing consumes it).

## Capture endpoint

`sweap-board.mjs` keeps its global "reject non-GET" guard with exactly one
exception: `POST /ideas`, loopback-only like the rest of the server.

- Body: JSON `{title, body}`. `title` required, non-empty after trimming;
  `body` optional free text.
- Writes `roadmap/ideas/<slug>.md`. Slug = title lowercased, reduced to
  `[a-z0-9-]` (collapsing runs, trimming edge dashes) — this also makes path
  traversal impossible. On collision append `-2`, `-3`, …
- File format: flat frontmatter `title:` + `created:` (ISO timestamp), then the
  body verbatim.
- Create-only: the server never modifies or deletes anything, before or after
  this change.
- Errors: missing/empty title → 400; fs failure → 500; every other non-GET
  request → 405 as today.

## Board UI + state

- `sweap-board.lib.mjs` gains `loadIdeas(projectDir, backlogDir)`: reads
  `<backlogDir>/ideas/*.md` (non-recursive, so `ideas/archive/` is ignored),
  returns `{title, file, created}` per idea. `buildState()` adds an `ideas`
  array to `state.json`.
- `sweap-board.page.mjs` gains an **Ideas** panel: capture form (title input,
  textarea, submit posting to `/ideas`) plus the list of pending ideas rendered
  from `state.json`. Existing polling picks up new captures — no extra wiring.

## Pipeline integration (doc edits only)

- `/roadmap` (`plugin/commands/roadmap.md`): the decide phase surfaces
  `roadmap/ideas/` as read-only context, in the same step where it already
  surfaces audit follow-ups. At reconcile, triaged ideas move to
  `roadmap/ideas/archive/` as part of the milestone PR (provenance preserved,
  inbox drained).
- Playbook (`plugin/playbook/agentic-loop-playbook.md`): the backlog-format
  section documents the `ideas/` subdir alongside `archive/`.
- `/board` (`plugin/commands/board.md`): the "never writes anything" claim is
  updated to the true contract — *read-only against all pipeline state; its
  only write is creating new idea files in `roadmap/ideas/`* — still safe
  during autonomous runs.

## Why this stays safe during autonomous runs

Create-only writes of new uniquely-named files, in a subdirectory nothing in
the pipeline reads mechanically (`loadItems` reads `roadmap/*.md`
non-recursively; roadmap-lint runs per-file and resolves deps as
`roadmap/<dep>.md` — the same reason `roadmap/archive/` is invisible to
both), cannot race the coordinator, dirty an
in-flight PR, or corrupt state.

## Testing

Matching the existing TDD-style test files:

- **lib:** `loadIdeas` happy path; missing `ideas/` dir → `[]`; slug collision
  handling.
- **server:** `POST /ideas` happy path (file created, correct frontmatter);
  400 on missing/empty title; non-GET still 405 on every other route; slug is
  traversal-safe.
- **page:** the Ideas form renders.

## Out of scope

Editing, deleting, or archiving ideas from the board (triage belongs to
`/roadmap`), and any other write capability.
