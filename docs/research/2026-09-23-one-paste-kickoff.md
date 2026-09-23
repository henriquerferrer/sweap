# One paste: the goal launches the run (2026-09-23)

**Question.** The `/milestone` kickoff printed two things to paste — a `/goal`
condition and a `/sweap:run {"ids": [...]}` launch — and the human asked
"should I run the goal or the other one?". Is the best way to run sweap one
command, and what is gained or lost by each shape?

**Method.** Claims below, then three fresh-context refuters in parallel (harness
semantics from the official `/goal` and Workflow docs plus the Claude Code
2.1.281 binary; the run script and consumer A's live data; process, docs and the
Consumer A transcripts of 2026-09-18..23). Everything they could not verify is
listed at the end as a decider, not as a claim.

## Claims

- **C1.** One paste suffices: `/goal` "starts a turn immediately, with the
  condition itself as the directive" (goal.md), so a driver sentence inside the
  condition makes the session launch the workflow; the second paste is
  redundant.
- **C2.** A bare `/sweap:run` is not milestone-scoped: the frontier is
  backlog-wide, so an F13 run drains F14 and F15 items; and it discards the
  kickoff's drain order. Fix: `{ids, milestone}` args, enforced in the script.
- **C3.** "Or after N turns" stays as a backstop against a relaunch loop; 160
  is loose but harmless.
- **C4.** Under `/goal`, a long background workflow costs idle check-ins (30
  min, 1 h, 2 h, then paused) and its completion still starts a turn; nothing
  to build.
- **C5.** 24/7 needs `autoContinueAtUsageLimit` in USER settings, never seeded
  by the plugin.

## What the refuters found

| Claim | Verdict | Evidence |
|---|---|---|
| C1 as stated | REFUTED, then rebuilt | No consumer A transcript shows the session launching a workflow from a goal sentence — the field ran the other way: on 2026-09-23 the human typed a bare `/sweap:run` at 19:29:58 (the printed `{"ids": [...]}` never reached the run: the journal's first Scope prompt reads "Return the frontier as printed"; the run started on FP.2, not the CI flake DV.48 the kickoff put first), then pasted the goal at 19:30:17, wrapped in `<pasted_content>` — a multi-line paste is text, not a command — and the session said "not starting a second copy". The Workflow tool launches only on the user's explicit ask; the `/sweap:run` command's expansion is that ask, a goal sentence is not unless written as one. |
| C1, workflow name | SURVIVES | `Workflow({name: "sweap:milestone-audit"})` launched 2026-09-02; `{name: "milestone-audit"}` was "not found" the same minute. `plugin/commands/milestone-audit.md` still named the bare form. |
| C1, string args | NEW DEFECT | A model has passed workflow args as a JSON STRING (2026-09-02, milestone-audit, which throws on it). `run.js` split any string on commas: `'{"ids": [...]}'` became garbage ids and the run would end "batch exhausted" with nothing done. |
| C1, evaluator and procedural text | UNVERIFIED | The docs say the evaluator judges "what Claude has surfaced"; nothing says a "how" sentence harms the verdict. No consumer A goal has ever visibly been evaluated (below), so there is no field data either way. |
| Was `/goal` ever active on consumer A? | UNKNOWN, probably not | Across 70+ session files: zero evaluator verdicts, zero check-ins, zero `/goal` command entries. The 09-18 goal arrived as raw typed text; the 09-23 one as a paste. The 09-18 run went 70 hours on 82 turns started by task notifications and peer messages, none by an evaluator. Decider: `/goal` with no argument in the live session. |
| C2, the rule | SURVIVES-WITH-CHANGE | On the live frontier (29 items) the rule classifies every item as the goal text does. Two wrong inclusions with `startsWith(M + ".")`: a follow-up OF the milestone (`F13.28, followup_of: F13`) and a deeper id (`DS.2.1` in a `DS` run). Built: `followupOf ? followupOf !== M : milestoneOf(id) === M`. |
| C2, "lint the first item you return" | REFUTED | The Scope agent never knew which item the script would pick (`attempted` is script state: an item that failed without a PR stays first in the frontier). The implementer's step 1 already runs the lint. Built: lint leaves Scope; the classification sentence moves to step 1. |
| C2, `skipped` | PRE-EXISTING DEFECT | A batch id not runnable at scope #1 (a dependency unmet) was appended to `skipped` and never removed, so an item that merged later was returned both merged and skipped. Built: `skipped` = batch ids never attempted; the frontier's own `malformed` list gets its own key. |
| C2, relaunch "replays from the journal" | REFUTED | A journal resume replays the FIRST launch's Resume result, so the next implementer gets stale worktree/PR state; the live run's Resume found the FP.2 worktree only because it ran fresh. Built: every "relaunch" now says fresh, same args. |
| C3 | SURVIVES-WITH-CHANGE | A turn is a launch, a return, a check-in or chatter, not a batch; the 09-18 run used 82 turns in 70 hours, so 160 is a week-scale backstop. The clause binds only if the model reports against it (goal.md). Default kept; the semantics are now written where `turns.default` is defined. |
| C4 | SURVIVES-WITH-CHANGE | Check-in cadence and completion delivery are as claimed (delivery does not depend on the goal: 55 notification-started turns on 09-18..20). Three strand cases the claim missed, one witnessed: a per-model credit wall on the SESSION model ("You've reached your Fable limit", 2026-09-03, eight hours idle); a weekly reset more than 24 h out; the third usage wait of one run (the agent resolves null, the run stops). |
| C5 | SURVIVES, corrected | `autoContinueAtUsageLimit` is ON by default (user scope, 2.1.234+); the human must not have turned it off, and "a project or local settings file that sets it turns the feature off rather than being ignored" — the plugin must never write it. |

## A hostile review of the fix found seven more, all built

1. The template sent the session to `/milestone-audit` on any "drained"
   return, including one with items left open (a human hold, a blocked flip):
   the audit is now conditional on every milestone item being `done`.
2. "Record awaiting-human, naming the item it stopped on" contradicted the
   board: `verifyEnd` rejects an `awaiting-human` that names nothing, and a
   usage wall or an API death in the Resume stage names nothing. The stop
   clause now says "a cause you cannot clear (say which)", and the record
   section says such a run is not over: no `ended:`, say what stopped it.
3. `verifyEnd` counted the backlog-wide frontier, so a milestone-scoped run
   ending with F14 items runnable would render `goal-met` and
   `frontier-empty` as contradicted by design. It now counts the run's scope
   (the same rule as the workflow's `allowedFor`) when the run file names a
   milestone.
4. `parseArgs` passed a bare array through as an object — `ids` undefined,
   a silent whole-frontier run, the exact failure the change exists to stop —
   and `{ids: "DV.48, FP.2"}` likewise. Both are batches now.
5. A missing `sweap-frontier` returned an empty frontier that read as
   "drained" and, with finding 1, would have audited on nothing. The Scope
   agent reports `command_missing` and the run stops with the cause.
6. The comment claimed a follow-up of the run's milestone is "never picked";
   the batch applies no filter. The batch is trusted as the kickoff computed
   it; the comment says so.
7. `skipped` claimed "not runnable at any scope"; after an early stop it also
   holds ids never reached. Its description says so.

## What was built (0.33.0)

- `run.js`: `{milestone}` arg; `pickOrder`/`allowedFor` in the script (batch
  first in batch order, then the milestone's items and other milestones'
  follow-ups; never this milestone's follow-ups; `milestoneOf` is the id minus
  its last dot-segment, as the board lib does it); the Scope agent returns the
  frontier as printed and lints nothing; `skipped` derived from what was never
  attempted; a `malformed` key; JSON-string args parsed, unparseable ones stop
  the run with the text; every "relaunch" is fresh. Tests: allowedFor,
  pickOrder, parseArgs, the wiring.
- `/milestone`: the driver block is gone; each goal template carries the driver
  sentence, written as the human's explicit ask, naming `sweap:run` exactly,
  args as an object with `ids` and `milestone`, "end your turn and wait",
  drained → audit, stopped → clear and relaunch fresh; a stop clause for a
  cause only a human clears; the goal prints as ONE line; the ritual says how
  to confirm the goal took and names the two strand cases.
- `/milestone-audit`: the workflow's plugin-scoped name.
- `sweap-board.lib.mjs`: `verifyEnd` counts the run's scope (tested).
- Playbook: "Who holds the loop", `turns.default`, the `/milestone` bullet,
  the Workflow and `sweap:run` mechanism rows.

## Not built

- A change to `turns.default`: the number has never been approached.
- Anything for the check-in cadence (`CLAUDE_CODE_GOAL_CHECKIN_MINUTES` is the
  user's knob).
- A cure for the three strand cases: a run session on a subscription-covered
  model is a ritual choice, documented, not a control.

## Deciders (unverified; each is one look on the next consumer A kickoff)

1. `/goal` with no argument in the live session: "No goal set" confirms the
   ritual has been running on prose.
2. Whether a real, single-line `/goal` whose text carries the driver sentence
   makes the session call `Workflow({name: "sweap:run", args: {...}})` with an
   object — read the journal's first Scope prompt and the ids it picked first.
3. Whether a running workflow defers goal evaluation (otherwise the "no tool
   use for several turns" guard pauses the goal while the workflow runs — the
   run continues, the re-driver does not).
4. Whether `<command-args>` JSON on a user-typed `/sweap:run {...}` reaches the
   Workflow call as an object — never exercised in any transcript.

## Consumer follow-ups (consumer A)

- The live run (`wf_12dc3384-263`, launched bare 2026-09-23 19:30) has the
  whole frontier in scope: F14.1 and five F15 items follow the F13 items. Stop
  it after its current item merges, update the plugin, and relaunch from a
  fresh `/milestone` paste — or let it run and stop it before it reaches F14.1.
- `.claude/sweap-run.md` records a scope the run never received; the next
  kickoff overwrites it.
