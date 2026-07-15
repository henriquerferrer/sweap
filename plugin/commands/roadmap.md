---
description: Brainstorm the next milestone into ROADMAP items (3-phase: decide → cross-check → reconcile).
argument-hint: "[milestone] — defaults to the next unspecced milestone"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
`ROADMAP.md` (`backlog.file`) first.

Resolve the milestone:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) — this is the milestone-tag prefix used below.
- The first argument if given (e.g. `F3` using the configured prefix);
  otherwise the next milestone from the "Later milestones" sketch that has **no
  active ROADMAP items yet** (the next one to author).

Run the **milestone brainstorm** exactly as the playbook's "Milestone brainstorm"
section defines it — this is interactive, direction-loop work:

1. **Decide** — use `superpowers:brainstorming` with the human. Socratic, ONE
   question at a time; ground it in the real repo (`ROADMAP.md`, the project's
   core domain modules, prior `docs/superpowers/specs/`). Lock the core decisions
   and draft items in the ROADMAP house format (status tag, `Depends on:`,
   `review-dimensions:`, e2e acceptance criteria). Before drafting, surface any
   outstanding audit follow-ups (unblocked `[todo]` items under a
   `## <backlog.prefix># audit follow-ups` section) as read-only context, so the
   new milestone isn't authored blind to pending fixes on the same surface. Do
   NOT drain or reschedule them here — `/roadmap` stays a pure direction-loop
   command; execution scheduling is `/milestone`'s job.
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
