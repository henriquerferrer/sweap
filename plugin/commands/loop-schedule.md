---
description: Create a scheduled cloud agent whose kickoff prompt is the goal condition — the no-paste hands-off pipeline driver.
argument-hint: "[milestone] [cadence] — e.g. F2 nightly (cadence: 'nightly' or an explicit cron expression)"
---

Read `CLAUDE.md` (incl. the `## sweap config` block),
`${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and the backlog
(`backlog.file` index + item files under `backlog.dir`) first.

Resolve the run exactly as `/milestone` does:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) — the milestone-tag prefix used below.
- **Milestone `M`** = the first argument if given (e.g. `F2` using the
  configured prefix); otherwise the next runnable milestone in the index's
  order that has `status: todo` item files whose dependencies are all
  satisfied (the next runnable milestone).
- **Turns** = `turns.default` from the `## sweap config` block (default `160`).
  `/loop-schedule` takes no turn-bound argument — its second argument is the
  cadence — so the turn bound always comes from config.

**Cadence** = the second argument:
- `nightly` → a daily cron (pick a fixed off-hours UTC time, e.g. `0 3 * * *`,
  and say so).
- anything else is taken as an explicit cron expression and used verbatim.

Then create a **scheduled cloud agent** using the `/schedule` mechanism (the
"Cron jobs / scheduled cloud agents" row of the playbook's mechanisms table —
Claude can create these; they run unattended even if the local machine is
off). The agent's **kickoff prompt IS the goal condition** for this run — this
is what makes the run hands-off: no human has to paste anything, because the
schedule supplies the goal via its own kickoff prompt instead. Do **not**
invoke `/goal` yourself — `/goal` is user-only (only a human can invoke it);
`/loop-schedule` is the additive hands-off path that works around that by
handing the goal condition to the schedule's prompt instead.

Kickoff prompt template (fill in `<MILESTONE>` and `<TURNS>` from the resolved
values above):

> Drain the backlog's unblocked items in frontier order (index + item files
> under `backlog.dir`) per the sweap playbook.
> For each item: work in an isolated worktree, TDD (include RED+GREEN
> evidence), dispatch a fresh-context review, open a PR, and merge only when
> the gate is green (the pre-merge-gate hook enforces this). Escalate any
> blocker to a `status: blocked` item file plus a notification instead of
> guessing. When the last <MILESTONE> item merges, run `/milestone-audit` for
> that range and triage the confirmed findings. Stop when only `[blocked]`
> items remain, or after <TURNS> turns. Notify with a merged-PRs and
> blocked-items summary.

This kickoff prompt inherits every autonomy rule from the playbook (TDD, the
review dimensions, end-of-run hygiene, escalate-don't-guess, the merge gate) —
it states only the end condition, exactly as a pasted `/goal` line would; it
invents no new rules.

Once the schedule is created, confirm it back to the user: the cadence (cron
expression, human-readable), the resolved milestone `<MILESTONE>`, and the
turn bound `<TURNS>`. Note that they can cancel or disable it at any time via
the schedule manager (the routines list at https://claude.ai/code/routines, or
by asking Claude to disable/update the routine by name).
