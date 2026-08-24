# Discovered work — a note, not an item; a lane, not a rule — design

**Date:** 2026-08-22
**Status:** approved (decisions 1 and 2 below taken by Henrique, 2026-08-22)
**Evidence:** `docs/research/2026-08-22-mid-run-discovered-items.md`

## Problem

An agent working item X notices work Y. On consumer A (#181) three such Ys became
item files plus an index retitle, committed onto an unrelated in-flight code
branch, because a PR per file would have cost a full CI cycle each (two e2e
runs on consumer A — the PR and the `push` to main). Three defects, none of which
sweap could see: the code PR became backlog-advancing for `audit-gate.sh
--files` (a gate coupling), the ids were minted against a branch (a collision
waiting for a second session), and the files would die with the branch if the
PR were abandoned (orphaning). The ideas path shipped in #20 covers
`roadmap/ideas/` only.

## Design (three layers, in build order)

### 1. The discovered inbox — `<backlog.dir>discovered/`

A **note**, written at discovery time through `writeDiscovered()` in
`tools/sweap-board.lib.mjs` (create-only, hash-suffixed filename, `kind:` and a
*why* required). No id, no status, no spec. Two kinds, on the line the audit
triage already draws: `gap` (failed-the-spec: agent work) and `direction`
(not-in-the-spec: a human's call). Gate-exempt by path through the existing
"other subdirs" arm of `audit-gate.sh` — no gate change, one new test.

**The three-lane rule** (playbook, per-feature loop): a new item → a note; a
status flip → the item's own PR (unchanged); an index/direction edit →
`/roadmap`, never mid-run. Framed as protocol, not prohibition, and backed by
a hard rule for unattended runs.

**Promotion.** `/milestone` pre-flight promotes every `gap` note with a
resolvable milestone (`milestone_hint:`, else the milestone of
`discovered_from:`): mint the id against main with `nextItemId()` (counts
`archive/`, never reuses), author a real spec, lint, `archiveDiscovered()` with
`promoted_to:`, one `chore(backlog): promote …` PR. Promoted items carry
`followup_of: <milestone>` so they drain debt-first through the existing
bucket-2 pipeline without touching milestone completeness or a landed audit
record (`audit-gate --check` only validates `followup_of:` on items a record
references — verified). `direction` notes and unplaceable gaps are listed at
kickoff and triaged by `/roadmap`, which archives them with `promoted_to:` or
`declined:`.

**Decision 1 (taken):** promotion is automatic for `gap`, attended for
`direction`. "If no direction is needed, B is completely OK."

**Sweep + flush.** The End-of-run sweep rule and `/idea`'s idle flush cover
both inboxes. The board shows unpromoted notes (`loadDiscovered()`), so a
parallel session sees them as soon as they are on main.

### 2. The stranded-backlog detector — `hooks/stranded-roadmap.sh`

One script, three readers. For every not-merged branch (remote, plus local
ones with no remote twin): `git diff --name-only main...branch --
<backlog.dir>`; non-empty → a line `branch\tstate\tage\tpaths`, where state is
the PR's (`open` = rider, `closed`/`none` = stranded, MERGED = skipped because
squash merges are invisible to git). Readers: `post-merge-cleanup.sh` step 4
(reports stranded branches to the session as `additionalContext`, with the
rescue recipe — report-only, a hook must not open PRs), the board (a section
plus a note), and the stop path (End-of-run hygiene: run it before abandoning
a branch; rescue inbox files with a docs-only PR; list item files/index edits
for the human). Fetches nothing, writes nothing.

### 3. The roadmap-only CI lane — `hooks/ci-lane.sh`

An allowlist classifier (`<backlog.dir>**`, `docs/**`, `*.md`; `.github/**`
and an empty diff are `code`), vendored to `.github/scripts/ci-lane.sh` by the
scaffold's managed-file sync. The CI template gains a `changes` job and `e2e`
skips when the lane is `roadmap-only` (`!cancelled()` so a failed `changes`
still runs e2e). `pre-merge-gate.sh` stops trusting a skip: `e2e` SKIPPED is
green only when the plugin's copy of the same script, run on the PR's file
list, says `roadmap-only`; any other contract check (lint, typecheck, test,
review, audit-gate, ci-status) SKIPPED is denied as a misconfiguration;
unknown check names stay non-blocking as before.

**Decision 2 (taken):** yes, job-skip e2e on the roadmap-only lane, in exactly
this bounded form. It is the only layer that makes the sanctioned path cheaper
than the shortcut, which the evidence says is the condition under which the
rule will hold. The model review is deliberately NOT skipped.

## Rejected

- A sidecar `backlog` branch, git-notes, or a refs-only store: beads shipped a
  sync branch and deleted it (~11k lines, v0.53.0); notes are invisible on
  GitHub and rebase-fragile; every sweap reader reads files on main.
- An external tracker as the capture channel: split brain with the frontier.
- Hardening the gate to deny any feature PR touching `roadmap/`: punishes the
  symptom and invites a less visible variant.
- Auto-relaying stranded files from the hook: a side effect nobody asked for;
  the hook detects, the session rescues.

## Touchpoints

`tools/sweap-board.lib.mjs` (+ `.page.mjs`, `.mjs`, tests), `hooks/ci-lane.sh`
(+ test), `hooks/stranded-roadmap.sh` (+ test), `hooks/pre-merge-gate.sh` (+
tests), `hooks/post-merge-cleanup.sh`, `hooks/audit-gate.sh` (comments + test),
`hooks/scaffold.sh`, `templates/.github/workflows/ci.yml`, the playbook
(layout, per-feature loop, new CI-lane section, End-of-run hygiene, hard
rules), `/milestone`, `/roadmap`, `/idea`, `/board`.
