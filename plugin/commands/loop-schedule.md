---
description: Create a scheduled cloud agent whose kickoff prompt is the goal condition — the no-paste hands-off pipeline driver.
argument-hint: "[milestone] [cadence] — cadence: 'nightly', an explicit cron expression, or 'once' (a milestone argument implies once)"
---

Read `CLAUDE.md` (incl. the `## sweap config` block), the sweap playbook
(`playbook/agentic-loop-playbook.md` under the plugin root), and the backlog
(`backlog.file` index + item files under `backlog.dir`) first.

This command decides only what a schedule needs: cadence, whether the run is
recurring or one-off, and the turn bound. It does **not** resolve the milestone
— the run does that itself, at its own start, by running `/milestone`.

**Cadence** = the cadence argument (the last one):
- `nightly` → a daily cron at a fixed off-hours UTC time: `0 3 * * *`, and say
  so. This is the recommended cadence.
- `once` → a one-off schedule. Routines auto-disable after a one-off fires, and
  one-off runs do not count against the daily routine cap.
- anything else is an explicit cron expression, used verbatim. Routines reject
  intervals under 1h. If the expression fires more than once per 24h, print a
  warning: overlapping runs on the same backlog are **not prevented** — a
  second run may pick up an item the first is mid-way through; stranded
  `claude/` branches are caught later by the stranded-roadmap detector, not
  avoided.

**Milestone argument.** Recurring-vs-one-shot is decided here, and the default
is **drain-the-frontier**:
- **No milestone argument → recurring drain.** The schedule is recurring and
  the milestone is resolved by the RUN at its start, never by this command —
  a routine re-clones `main` on every run, so a milestone frozen into a
  recurring prompt is stale from the second night. Each run re-resolves
  exactly as `/milestone` does and stops at frontier-empty; the audit-gate
  `--check` keeps a run from resolving past unaudited work, so a run is
  naturally bounded to one milestone boundary plus its audit.
- **Milestone `M` given → one-off.** Cadence is forced to `once`. If the user
  also passed a recurring cadence, refuse with: *"a pinned milestone is a
  one-shot; a recurring schedule drains whatever is runnable — pick one"*.
  (A pinned milestone in a recurring routine would idle with `reason:
  goal-met` while later milestones are runnable, and the board contradicts
  that claim every night.)

**Turns** = `turns.default` from the `## sweap config` block (default `160`).
`/loop-schedule` takes no turn-bound argument, so the bound always comes from
config. Inside a routine it is advisory: there is no evaluator model, the run
enforces its own stop clause.

Then create a **scheduled cloud agent** using the `/schedule` mechanism (the
"Cron jobs / scheduled cloud agents" row of the playbook's mechanisms table —
Claude can create these; they run unattended even if the local machine is
off). The agent's **kickoff prompt IS the goal condition** for this run — this
is what makes the run hands-off: no human has to paste anything, because the
schedule supplies the goal via its own kickoff prompt instead. Do **not**
invoke `/goal` yourself — `/goal` is user-only (only a human can invoke it);
`/loop-schedule` is the additive hands-off path that works around that by
handing the goal condition to the schedule's prompt instead.

## Kickoff prompt

<!-- do not embed /milestone goal templates here: the 2026-08 stop-clause drift came from copying them -->

The prompt carries **no copy of the goal text**. It names `/milestone`'s steps
and the run executes them; the goal text lives in that command and the
playbook, so there is exactly one place for it to change. Placeholders:
`<TURNS>` (from config), `<RESOLVE>` and `<CADENCE-NOTE>` (chosen by the
recurring/one-off decision above). Prompt body, in this order:

> 0. Before anything else, confirm the sweap plugin is loaded in this session
>    (`claude plugin list --enabled` shows `sweap@sweap`, and
>    `/sweap:milestone` is available). If it is not: do NO backlog work, open
>    NO PRs and merge NOTHING — the merge gate is a plugin hook and is absent
>    too. Notify: *"sweap plugin not loaded in the routine environment — add
>    `claude plugin marketplace add henriquerferrer/sweap && claude plugin install sweap@sweap`
>    to the environment's setup script"* and end.
> 1. Read `CLAUDE.md`, the sweap playbook and the backlog. Run
>    `/sweap:milestone` (`/milestone` in a bare checkout) in its
>    NON-INTERACTIVE mode: every pre-flight it defines, in its order —
>    Legacy pre-flight;
>    the audit-gate `--check` and its DEFERRED/FAIL/AGING handling;
>    Deferred-item backstop;
>    Discovered-items triage;
>    the audit-debt scan;
>    the hand-off scan taking the Non-interactive exit (never run `/handoff`;
>    take the hand-offs-outstanding shape and name the skipped hand-offs in
>    your notification);
>    Environment pre-flight;
>    Parallel width;
>    the spec gate before each dispatch;
>    Record the run (`.claude/sweap-run.md`).
>    Do not print a plan; write the record.
> 2. `<RESOLVE>`
> 3. Execute, yourself, the goal `/sweap:milestone` records for that shape —
>    the goal text lives in that command and the playbook, not here. There is
>    no evaluator model in a routine: re-check the stop clause after every
>    merge. The stop clause is the frontier clause: stop when
>    NOTHING IS RUNNABLE — every remaining `[todo]` has an unsatisfied dependency on a
>    `[blocked]`, `[attended]` or `[deferred]` item, so the frontier is empty
>    and no agent may pick anything up — or after `<TURNS>` turns (advisory;
>    the session's own limits are the hard stop).
> 4. When you stop, do `/sweap:milestone`'s "Record the end of the run":
>    append `ended:` and `reason:` (`frontier-empty | awaiting-human |
>    turns-exhausted | goal-met`), plus `needs:` and `why_not_agent:` when
>    awaiting-human. Re-run the frontier computation before writing
>    `frontier-empty`/`goal-met` — the board contradicts a claim that names an
>    empty frontier while items are runnable, and an `awaiting-human` with an
>    empty `needs:`.
> 5. Notify with: merged PRs; blocked items; open hand-offs (including the
>    ones skipped at the hand-off scan); and the run file's `reason:` line
>    verbatim (`needs:` too when present). A run that ends without a `reason:`
>    did not finish — say so. `<CADENCE-NOTE>`

`<RESOLVE>`:
- recurring: *"Resolve the run shape at THIS run's start exactly as
  `/sweap:milestone` does (audit debt first, then the next runnable milestone
  across all configured prefixes; hand-offs-outstanding when a hand-off gates
  it; debt-only when no milestone is runnable). If nothing at all is runnable,
  record `reason: frontier-empty` (or `awaiting-human` with `needs:`), notify,
  and do no work."*
- one-off with `M`: *"The milestone is `M`. If `M` is already complete and its
  audit record is landed, record `reason: goal-met` only if nothing is
  runnable; otherwise record what is true, notify, and stop — do not start
  another milestone."*

`<CADENCE-NOTE>`:
- recurring: *"This routine runs again on its schedule; the next run
  re-resolves from the backlog."*
- one-off: *"This schedule is one-shot and now disables itself."*

The prompt inherits every autonomy rule from the playbook (TDD, the review
dimensions, end-of-run hygiene, escalate-don't-guess, the merge gate) by
naming the command that applies them; it invents no new rules. Do not put the
plugin-root path variable in the prompt — it is meaningful only inside the
plugin's own command files; the run reads the playbook through the loaded
plugin.

## Hand-offs in a scheduled run

This driver is headless by definition, so it never asks the human anything:
it does NOT run `/milestone`'s kickoff fork and never runs `/handoff` (which
requires a human in the session). The run takes `/milestone`'s
**Non-interactive** exit at the hand-off scan and uses the
hand-offs-outstanding template directly. An open hand-off keeps the milestone
incomplete, so a prompt demanding its audit would send the run chasing an
unreachable condition and burn turns; the hand-offs-outstanding shape says the
audit is NOT due instead. The run's notification — which names the skipped
hand-offs — is then how the human learns their queue exists without any
session having been able to ask them.

## Cloud prerequisites

- A routine clones the repo fresh from the default branch on every run and can
  only use what is committed plus what its environment setup script installs.
  Committed `.claude/settings.json` (`enabledPlugins: {"sweap@sweap": true}` +
  `extraKnownMarketplaces.sweap`) registers the marketplace in the clone but
  does **NOT** install an externally-sourced plugin (Claude Code ≥ 2.1.195).
  The routine's cloud environment setup script must therefore run
  `claude plugin marketplace add henriquerferrer/sweap && claude plugin install sweap@sweap`
  (cached across runs). `.mcp.json` and `.claude/agents` come from the clone.
- Consequence: a routine gets CURRENT plugin `main` at install time — the
  inverse of the local plugin-cache lag.
- `.claude/sweap-run.md` is gitignored and the VM is discarded, so the run
  file exists for in-run discipline and for anyone opening/teleporting the
  session; the **notification is the durable copy of `reason:`**. A green run
  status means the session exited without infrastructure error, not that the
  goal was met.
- `/schedule` is hidden under API-key/profile/cloud-provider login, with
  `DISABLE_TELEMETRY`/`DO_NOT_TRACK`/`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`/
  `DISABLE_GROWTHBOOK` set, and inside a cloud session — surface these causes
  instead of failing silently. One-off scheduling from the CLI is rolling out;
  fall back to https://claude.ai/code/routines.
- Recommend `nightly`; warn on cadences under 24h (see Cadence).

## Confirmation

Before creating the schedule:
1. Run `git ls-files .claude/settings.json` and grep it for `sweap@sweap`. If
   missing, refuse and print the settings snippet (`enabledPlugins` +
   `extraKnownMarketplaces.sweap`) — this is the marketplace-registration half.
2. Print the setup-script line
   (`claude plugin marketplace add henriquerferrer/sweap && claude plugin install sweap@sweap`)
   and ask the user to confirm it is in the routine's environment. This
   command cannot inspect cloud environments; the prompt's step 0 is the
   runtime enforcement.

Once the schedule is created, confirm it back to the user: the cadence (cron
expression, human-readable), whether it is a recurring drain or a one-off for
`M`, the advisory turn bound `<TURNS>`, and the disable/cancel path (the
routines list at https://claude.ai/code/routines, or by asking Claude to
disable/update the routine by name).
