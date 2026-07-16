---
description: "Brainstorm the next milestone into ROADMAP items (decide → cross-check → reconcile, then merge + clean up autonomously)."
argument-hint: "[milestone] — defaults to the next unspecced milestone"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
`ROADMAP.md` (`backlog.file`) first.

Resolve the milestone:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) as a comma-separated LIST of one or more milestone-tag prefixes (e.g. `F`
  or `F, DS`) — the milestone arg (below) names which one this milestone uses;
  when authoring a brand-new milestone with no arg, default to the first
  listed prefix.
- The first argument if given (e.g. `F3` or `DS.4`, naming its prefix
  explicitly); otherwise the next milestone from the "Later milestones" sketch
  that has **no active ROADMAP items yet** (the next one to author), using the
  default prefix above.

Run the **milestone brainstorm** exactly as the playbook's "Milestone brainstorm"
section defines it. The three decision phases (decide, cross-check, reconcile)
are interactive, direction-loop work; the human's direction call ends at
reconcile, and the items are then written and merged through the gate by a
mandatory, fully autonomous 4th step (merge + clean up) — no further human
review is asked for:

1. **Decide** — use `superpowers:brainstorming` with the human. Socratic, ONE
   question at a time; ground it in the real repo (`ROADMAP.md`, the project's
   core domain modules, prior `docs/superpowers/specs/`). Lock the core decisions
   and draft items in the ROADMAP house format (status tag, `Depends on:`,
   `review-dimensions:`, e2e acceptance criteria). Before drafting, surface any
   outstanding audit follow-ups (unblocked `[todo]` items under a
   `## <prefix># audit follow-ups` section, for any configured prefix) as
   read-only context, so the
   new milestone isn't authored blind to pending fixes on the same surface. When
   scanning for these, match only ROADMAP item headers (`### …` lines carrying a
   status tag), never the status-tag legend/explainer line or a prose mention of
   a tag. Do NOT drain or reschedule them here — `/roadmap` stays a pure
   direction-loop command; execution scheduling is `/milestone`'s job.
2. **Cross-check** — dispatch a fresh-context critic via the
   `milestone-cross-check` skill. Report ONLY the net-new forks the brainstorm
   missed, each with a recommended default. Flag; never rewrite or expand scope.
3. **Reconcile** — after the human answers the forks, write the milestone into
   ROADMAP.md's active section as a PR through the gate (move it out of the
   "Later milestones" sketch).
4. **Merge + clean up** — the direction call is fully spent at reconciliation, so
   take the ROADMAP PR to the end autonomously: watch the gate and **merge on
   green** (CI + the `review` verdict both green; never override `needs-work` —
   fix and re-push). Do NOT ask the human to review the write-up. Then run
   **end-of-run hygiene, always** (mandatory, never skipped — see the playbook):
   `gh pr merge <n> --squash` (do NOT trust `--delete-branch` — in a worktree flow
   the branch is always checked out, so gh's local delete aborts and never removes
   the remote). The `post-merge-cleanup` hook then removes the worktree, the local
   branch, and the origin branch automatically; confirm none linger
   (`git worktree list`, `git branch`, `git branch -r`) and if any do, finish by
   hand: `git worktree remove` → `git branch -D` → `git push origin --delete`.

Stop after the ROADMAP PR is **merged and cleaned up**. Do not start
implementing — that's a separate `/milestone` run.
