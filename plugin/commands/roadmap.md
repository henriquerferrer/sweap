---
description: "Brainstorm the next milestone into item files under roadmap/ (decide → cross-check → reconcile, then merge + clean up autonomously)."
argument-hint: "[milestone] — defaults to the next unspecced milestone"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
the backlog first — `backlog.file` (the index) plus the item files under
`backlog.dir` (see the playbook's "Backlog format (file-per-item)" section).
**Legacy pre-flight:** if `backlog.file` still contains item headers
(`### … [todo]`-style), run the one-time migration defined there (one PR
through the gate) before anything below.

Resolve the milestone:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) as a comma-separated LIST of one or more milestone-tag prefixes (e.g. `F`
  or `F, DS`) — the milestone arg (below) names which one this milestone uses;
  when authoring a brand-new milestone with no arg, default to the first
  listed prefix.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the repo
  root. `FAIL:` lines mean audit debt — do NOT draft the next milestone's
  items on top of an unaudited one; surface the debt and stop at that
  boundary (the merge gate would refuse the milestone PR anyway).
- The first argument if given (e.g. `F3` or `DS4`, naming its prefix
  explicitly); otherwise the next milestone from the index's "Later milestones"
  sketch that has **no item files yet** under `backlog.dir` (the next one to
  author), using the default prefix above.

Run the **milestone brainstorm** exactly as the playbook's "Milestone brainstorm"
section defines it. The three decision phases (decide, cross-check, reconcile)
are interactive, direction-loop work; the human's direction call ends at
reconcile, and the items are then written and merged through the gate by a
mandatory, fully autonomous 4th step (merge + clean up) — no further human
review is asked for:

1. **Decide** — use `superpowers:brainstorming` with the human. Socratic, ONE
   question at a time; ground it in the real repo (the backlog — index + item
   files, the project's core domain modules, prior `docs/superpowers/specs/`).
   Lock the core decisions and draft items in the item-file format (frontmatter
   + Spec/Acceptance body — the playbook's "Backlog format (file-per-item)"
   section). Before drafting, surface any outstanding audit follow-ups
   (unblocked `status: todo` item files with `followup_of:` set, for any
   configured prefix) as read-only context, so the
   new milestone isn't authored blind to pending fixes on the same surface.
   (A frontmatter scan — no header matching needed.) Do NOT drain or reschedule
   them here — `/roadmap` stays a pure direction-loop command; execution
   scheduling is `/milestone`'s job.
   Likewise surface the **idea inbox** (`<backlog.dir>ideas/*.md`, if any) as
   read-only context — ideas captured from the board awaiting triage. Fold the
   relevant ones into the brainstorm; do not copy them into items verbatim.
2. **Cross-check** — dispatch a fresh-context critic via the
   `milestone-cross-check` skill. Report ONLY the net-new forks the brainstorm
   missed, each with a recommended default. Flag; never rewrite or expand scope.
3. **Reconcile** — after the human answers the forks, write one item file per
   drafted item under `backlog.dir`,
   move every triaged idea file from `<backlog.dir>ideas/` to
   `<backlog.dir>ideas/archive/` (provenance preserved, inbox drained — untriaged
   ideas stay put),
   update the index's milestone list (move the
   milestone out of "Later milestones"), and run
   `bash ${CLAUDE_PLUGIN_ROOT}/hooks/roadmap-lint.sh <file>` on every new item
   file — fix failures before the PR opens (authoring and dispatch share one
   spec gate). All of it lands as one PR through the gate.
4. **Merge + clean up** — the direction call is fully spent at reconciliation, so
   take the milestone PR to the end autonomously: watch the gate and **merge on
   green** (CI + the `review` verdict both green; never override `needs-work` —
   fix and re-push). Do NOT ask the human to review the write-up. Then run
   **end-of-run hygiene, always** (mandatory, never skipped — see the playbook):
   `gh pr merge <n> --squash` (do NOT trust `--delete-branch` — in a worktree flow
   the branch is always checked out, so gh's local delete aborts and never removes
   the remote). The `post-merge-cleanup` hook then removes the worktree, the local
   branch, and the origin branch automatically; confirm none linger
   (`git worktree list`, `git branch`, `git branch -r`) and if any do, finish by
   hand: `git worktree remove` → `git branch -D` → `git push origin --delete`.

Stop after the milestone PR is **merged and cleaned up**. Do not start
implementing — that's a separate `/milestone` run.
