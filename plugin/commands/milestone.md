---
description: Prepare and kick off an autonomous milestone run (pre-flight + ready-to-paste goal).
argument-hint: "[milestone] [turns] — defaults: next unstarted milestone, turns.default"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
the backlog first — `backlog.file` (the index) plus the item files under
`backlog.dir` (playbook: "Backlog format (file-per-item)").
**Legacy pre-flight:** if `backlog.file` still contains item headers
(`### … [todo]`-style), run the one-time migration defined there (one PR
through the gate) before anything below.

Resolve the run:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) as a comma-separated LIST of one or more milestone-tag prefixes (e.g. `F`
  or `F, DS`) — these are the prefixes used below.
- Run `bash "$([ -f .github/scripts/audit-gate.sh ] && echo .github/scripts/audit-gate.sh || echo "${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh")" --check`
  from the repo root — the repo's VENDORED gate when present, falling back to
  the plugin's (same reason as `/roadmap`: the vendored copy is what CI runs;
  the plugin path can be a stale cache build).
 A `DEFERRED:` line is NOT debt: it means the state you are standing in is what
  completed that milestone, so its audit could not have run yet (an audit reads
  the merged default branch). Land that merge, then run `/milestone-audit` for
  the named milestone before resolving anything new — the gate will deny the
  next backlog-advancing PR until its record is in.
 A `FAIL: hand-off <id> ...` line is NOT debt either: it is a backlog-integrity
  violation — an item was transitioned into `status: attended` instead of being
  authored as one, which is the move the playbook's "Never an escape hatch"
  forbids. No audit discharges it. Fix the item (archive-and-re-author, per the
  failure message) before running anything.
 `AGING:` lines are informational and never fail: an open blocked question and
  how many milestone boundaries it has survived. This run does not drain them —
  the boundary does, in `/roadmap`'s step 0 — but list them with the run's open
  hand-offs so the human sees both needs-me-now queues at kickoff, and offer
  `/unblock <id>` for any that gate work in this run's scope.
 Any OTHER `FAIL:` output (`FAIL: milestone ...` / `FAIL: record ...`) means
  **audit debt**: a completed milestone lacks a
  valid audit record. The ONLY permitted work while debt exists is discharging
  it (run `/milestone-audit` for the named milestone; land its record PR) —
  do not resolve a new milestone past unaudited work. This **record-debt** is
  distinct from the outstanding `followup_of:` items ("Audit debt `D`"
  below): draining `D` never clears the gate — only landing the audit record
  PR does — and while record-debt exists that record PR is the only
  backlog-advancing merge the gate allows, so resolve it before picking any
  run shape.
- **Milestone `M`** = the first argument if given (e.g. `F2` or `DS3`, using
  any configured prefix); otherwise the next runnable milestone —
  across ALL configured prefixes, in the index's milestone order — that has
  `status: todo` item files whose dependencies are all satisfied (the next
  runnable milestone). A milestone is a milestone regardless of prefix: a
  `DS3` run gets the same audit-inclusive goal as an `F2` run.
- **Audit debt `D`** = the outstanding audit follow-ups from the audit-debt scan
  below.
- **Hand-offs `H`** = the outstanding human hand-offs from the hand-off scan
  below.
- **Turns** = the second argument if given; otherwise `turns.default` from the
  `## sweap config` block (default `160`).

Then pick the run shape:
- **`M` exists** → scope = `D` then `M` (debt-first): drain every item in `D`,
  then run `M`'s items. If any hand-off in `H` is still open after the fork
  below, this becomes the **hand-offs-outstanding** shape — same scope minus
  what those hand-offs gate, and no audit this run.
- **No runnable `M` but `D` is non-empty** → **debt-only run**: scope = `D`. Do
  NOT run a milestone-audit for a debt-only run — you don't audit a debt-drain.
- **Nothing runnable but `H` is non-empty** → there is no goal to print: the
  milestone cannot start until a hand-off is closed. Print the `/handoff`
  command and stop.
- **Neither** → nothing to run; say so and stop.

Discovered-items triage (see the playbook's "Backlog format" and "Discovered
work — the three-lane rule"). Before the audit-debt scan, read the discovered
inbox — `<backlog.dir>discovered/*.md` (the `loadDiscovered` /
`promotionTarget` helpers in `${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.lib.mjs`,
or a frontmatter scan). Read every `kind: gap` note whose target milestone
resolves (`milestone_hint:`, else the milestone of `discovered_from:` when that
is an item id) TOGETHER, then give each exactly one outcome. A note being true
is not the bar — follow-ups drain ahead of features, so the bar is the harm the
fix removes.

**The harm bar.** Name one class, or the note has none:
- `security` — authz, tenancy, or personal data reaching someone it should not.
- `data-loss` — a user's data destroyed or irreversibly corrupted.
- `wrong-data` — a user is shown something false, including a failed read
  rendered as a fact.
- `outage` — a user cannot complete a task the product promises, or the pipeline
  cannot ship: a red default branch, a broken deploy, a flake the merge driver
  recorded (a slow test someone saw locally is not one).

The harm must be reachable — steps a user can take on the default branch today;
a latent or unmeasured harm has no class. A weak check (a test that cannot fail,
a guard with a hole, lint that skips a folder) takes a class only when it
DIRECTLY asserts harm-class behaviour: the server refusing a role, the tenant
scope on a query. A check on a check, or a UI mirror of a rule the server
already enforces, does not.

- **Has a class → promote.** Mint the id against main with
  `nextItemId(projectDir, backlogDir, <milestone>)` — never by hand (it counts
  `archive/` too, so a dropped id is never reused). Author the item file:
  `status: todo`, `followup_of: <milestone>`, `harm: <class>`,
  `discovered_from: <the note's>`, `depends_on: []`, `review-dimensions:` as the
  surface warrants, a `## Harm` section (one or two sentences: who is harmed, by
  what steps), and a real `## Spec` (Surface / Interfaces / Out of scope) +
  `## Acceptance` written from the note's *why* — a note is a lead, the item is
  the spec. Run `sweap-roadmap-lint <file>` and fix before the PR opens, then
  `archiveDiscovered(projectDir, backlogDir, <file>, { promotedTo: <id> })`.
- **No class, and an agent filed it → park.** `archiveDiscovered(projectDir,
  backlogDir, <file>, { declined: "parked: <one-line reason>" })`. The note
  stays in `discovered/archive/`, greppable by `declined: parked`; moving it
  back re-opens it.
- **No class, and a human filed it** (a `/walkthrough` or `/handoff` session —
  its `discovered_by:` or its body says so) **→ leave it in the inbox** and list
  it with the `direction` notes below. The bar filters what agents noticed,
  never what the owner asked for; `/roadmap` decides it with them.

**The same pass, over follow-ups already in the backlog**: every unblocked
`status: todo` item with `followup_of:` set and no `harm:` — what an older
plugin promoted mechanically, or an audit filed before this rule. Skip an item
that carries `blocked:` (a human's answer made it work) or that another open
item names in `depends_on` (its author declared it needed). Tag the rest
(`harm:` + `## Harm`), or park it: `status: deferred` with `premise: parked
<date> — no harm class: <reason>`. **Never move a follow-up to `archive/`** —
the audit record that filed it names the file, and the gate fails a record
whose file is gone.

Notes with no resolvable target, every `kind: direction` note, and every note
the board lib reports as `kind: unknown` are NOT triaged here — list them
alongside the hand-offs and blocked questions so the human sees them at kickoff,
and leave them for `/roadmap`. Land the whole pass as ONE PR,
`chore(backlog): triage — promote <p> of <n> discovered note(s)`, its body
listing each promotion (class + harm sentence) and each park (reason), through
the gate, in a worktree like any other: it IS backlog-advancing, so during
record-debt it is correctly denied — skip it, say so, and let the record land
first. Merge on green (it rides the roadmap-only CI lane), run end-of-run
hygiene, then continue: the audit-debt scan below picks the promoted items up
as `D`. A promote rate near 100% means the bar is not being applied — say so in
the run summary. Stateless and idempotent, and it needs no human: a
non-interactive kickoff runs it exactly the same way.

Audit-debt scan (see the playbook's "Milestone audit" section). Collect the
debt set `D`: every item file with `followup_of:` set — for ANY configured
prefix — that is `status: todo` AND unblocked (all `depends_on` satisfied;
blocked and deferred items are excluded — same rule as the frontier picker).
A frontmatter scan; no header matching. These are auto-folded into this run's scope **ahead of**
the named milestone's items (debt-first). Report the list of items in `D`. This is
stateless — it just re-reads current statuses — so running it here every time is
safe and idempotent. (An item in `D` that turns
out to need a direction call on pickup escalates to `[blocked]` and is left for
the human, exactly like any other item — the stop clause in the printed goal
below still lets the run finish.)

Hand-off scan, then **the kickoff fork** (see the playbook's "Attended items"
section). Collect `H`: every `status: attended` item file in the run's scope
(`M`'s milestone, plus any `D` item's) that is **unblocked** by the same rule as
above. A frontmatter scan; stateless and idempotent like the other two.

For each one compute what it **gates**: the items that transitively depend on it
(directly, or via a bare-milestone dep on its milestone) and are not yet `done`.
That number is what makes this a decision rather than a nag.

If `H` is non-empty, **ask before printing any goal** — a human is standing here
to paste it, which is the whole reason this fork lives in `/milestone` and
nowhere else. Show, compactly:

```
<M> — <N> items · <count> hand-off(s) are yours

  <id>  <handoff: task>            gates <n> items (<ids>)
  ...

  Do them now   → frontier of <x>, <M> can finish end to end this run (audit included).
  Do them later → frontier of <y>. <the gated items> stay unreachable, the milestone
                  can't complete, so <M>'s audit isn't due and won't run this run.
                  You'd close the hand-offs afterwards and re-run /milestone.
```

Then **walk the most-gating one immediately** — do not print a goal first, and
do not offer "later" as an equal option. Run `/handoff <id>` inline, here, in
this session: brief the human, take the steps, and close it on their
confirmation exactly as that command specifies. Then re-resolve from the top
(the debt and hand-off scans are all stateless, so re-running them is
free) and print the goal that now applies.

**Why this is not a fork any more.** A hand-off is an item *of* the milestone,
so while it is open the milestone cannot complete, so its audit is not due —
which means "later" never yields the ordinary goal, only the degraded one. Consumer A
ran the whole of 2026-08-20 on a goal whose audit clause was unsatisfiable from
the minute it was printed, because `DS.5.3` was authored `attended` in the very
commit that created the milestone. The run then had no legal way to finish or to
stop, correctly worked out that the goal was unreachable, and had to invent an
exit by asking the human in chat — where no tool could see it. Handing out a
goal that cannot be met is worse than spending ten minutes closing the hand-off
that blocks it.

The gated items become runnable when the hand-off's PR lands; a run in flight
recomputes its frontier after every merge and picks them up with nothing
further needed, so the goal can be printed as soon as the answer is recorded.

Two exits from this, both narrow:
- **The human declines** (they want the run started anyway, or the hand-off
  genuinely cannot be done now — a third party has to verify, hardware is in the
  post). Then print the **hand-offs-outstanding** template, with the cost
  restated in one line. `/handoff` step 5 covers recording a started-but-unfinished
  hand-off.
- **Non-interactive** — any headless driver (`claude -p`, a scheduled agent). `/handoff`
  requires a human in the session and must never run unattended, so these skip
  it entirely and use the hand-offs-outstanding template directly, naming the
  skipped hand-offs in their notification. These drivers reference this
  command's steps by name rather than copying its templates, so this file is
  the only place the goal text lives.

Acceptance offer (see `/walkthrough`). After the hand-off fork resolves and before any
goal is printed, ask the lib whether a shipped milestone has never been walked:

```bash
node --input-type=module -e '
const lib = await import("file://" + process.argv[1]);
const { backlogFile, backlogDir } = lib.readConfig(process.cwd());
const items = lib.loadItems(process.cwd(), backlogDir);
const sessions = lib.loadSessions(process.cwd(), backlogDir);
const t = lib.resolveTestTarget({ items, index: lib.readMilestoneIndex(process.cwd(), backlogFile), sessions });
console.log(JSON.stringify({ target: t, stats: lib.sessionStats(sessions) }, null, 2));
' "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.lib.mjs"
```

If it names a milestone with `sessions: 0`, **offer once**, with the cost stated
on both arms, and take either answer without argument:

```
<Mprev> shipped <n> items and nobody has looked at it.

  Test it now  → ~35 min. Findings with a harm class drain FIRST in this run;
                 the rest wait for you at /roadmap.
  Later        → the run starts now; <Mprev>'s findings, if any, arrive a
                 milestone late and cost a second drain.
```

The timing is the whole argument: a finding caught before the run becomes that
run's debt and drains at the front of the frontier; caught after, it is a
milestone late. On "now", run `/walkthrough <Mprev>` inline here, then re-resolve from
the top (every scan above is stateless) and print the goal that then applies.

**Offer it every time and escalate never.** This is deliberately NOT the
`carried: ≥2` shape the blocked queue uses, and the difference is evidenced: a
mandate is the one variable with a large null result against it (an identical
checklist mandated across 101 hospitals and 215,711 procedures moved outcomes at
P = 0.13), and checklist *completion* decays invisibly beneath stable *usage*
(81.7% → 53.2%) — so the presence of a session sheet, the only thing an
escalation could key on, is exactly the signal that cannot detect the failure.
What is watched instead is yield: if `stats.dry` reaches 3, say so and recommend
cutting `/walkthrough` back to a UI-only spot-check rather than offering it harder.

Non-interactive kickoffs — any headless driver — skip this
entirely and name the skip in their notification, exactly as they do for
`/handoff`; `/walkthrough` requires a human in the session and must never run
unattended.

Environment pre-flight (parity — see the playbook's "Environment parity"
section). Do this **yourself** — the user should never bring up services by
hand. Check whether `services.up` is declared in the `## sweap config` block in
`CLAUDE.md`:

- **If `services.up` is declared:**
  1. Run `docker info` quietly.
  2. **If it succeeds** → run the `services.up` command and continue (local
     fast-path).
  3. **If it fails but the `docker` CLI exists and this is macOS** → the daemon
     is just not started. Run `open -a Docker`, then poll `docker info` every 3s
     for up to ~90s. Once it succeeds, run the `services.up` command. (Tell the
     user you're waiting on Docker Desktop to boot.)
  4. **If Docker has no CLI, or never comes up within the timeout** (e.g. Claude
     Code web, or Docker not installed) → skip local services and drop to
     **CI-gated mode** (below).
- **If `services.up` is not declared** → there are no local services to bring
  up; go straight to **CI-gated mode**.

**CI-gated mode:** CI runs the identical services as containers on every PR and
the merge gate requires CI e2e green, so CI is the authoritative test gate. Say
which mode you ended up in. Never block the run on Docker, or on the absence of
`services.up` — the loop is identical either way.

Before any dispatch (either mode, serial included), run the spec gate on the
item: `sweap-roadmap-lint <backlog.dir>/<ID>.md` (a bare command — the sweap
plugin's `bin/` is on the Bash tool's PATH while the plugin is enabled)
— a failing todo item is not runnable (fix mechanically or escalate), per the
playbook's "Backlog format (file-per-item)" section.

**How a dispatched item's PR lands: `sweap-merge watch <n>`** — the merge
driver, in both modes. It is a bare command (the sweap plugin's `bin/` is on
the Bash tool's PATH while the plugin is enabled). It waits on the base
branch's expected checks pinned to the head, runs the merge gate, merges and
runs the post-merge hooks, and ends the turn while it waits;
`sweap-merge status` reports what it is doing. Never hand-roll the wait, and
never reach for `gh pr merge` instead. Allowlist `Bash(sweap-merge:*)` in the
project's `.claude/settings.json`.

Record the run. Write `.claude/sweap-run.md` (gitignored; the scaffold adds the
rule) with exactly the resolution above — this is the only place the run's
*shape* is ever written down, and without it the board's running-milestone card
can do no better than infer a milestone from whatever happens to be in flight:

```
---
milestone: <M>
shape: milestone+debt | hand-offs-outstanding | debt-only
scope: [<every item id in D, in drain order>]
turns: <TURNS>
started: <ISO-8601 UTC, e.g. 2026-08-20T09:14:00Z>
deferred_handoffs: [<ids the human deferred at the fork, if any>]
---

<the goal line printed below, verbatim, for reference>
```

Flat single-line keys and inline lists, the same format contract as every other
sweap file. Write it **only on the paths that actually print a goal** — not
when the hand-off fork holds the goal ("do them now"), and not when there is
nothing to run. Overwrite any existing file: one run at a time. Nothing in the
loop reads this to decide anything (status truth stays the item files), so a
failed write is worth one line of "couldn't record the run" and nothing more —
never let it block the kickoff.

**Record the end of the run.** When the goal ends — met, stopped, or out of
turns — append to `.claude/sweap-run.md`:

```
ended: <ISO-8601 UTC>
reason: frontier-empty | awaiting-human | turns-exhausted | goal-met
needs: [<ids you are waiting on a human for, if reason is awaiting-human>]
why_not_agent: [<id>=identity|money|terms|taste|authority, ...]
```

**Record only what you legitimately know.** `needs:` is the ids; `why_not_agent:`
is the one judgment no tool can derive — *why a person is required rather than
another turn*. Do NOT write the commands the human should run: the board derives
those from each item's current status at render time, so they cannot go stale,
cannot advertise a hand-off that has since closed, and cannot be built out of a
title or a vendor error string. The only variable in a derived command is an
item id, and an id that is not a plain item id is dropped rather than pasted.

`why_not_agent:` is load-bearing rather than decorative. A step that is fully
runnable and carries no reason a human is needed is flagged on the board as
**likely a bug in the run, not a hand-off** — the SRE rule that an escalation
must name an action "the system is unable to take itself", made checkable. If
you cannot name why it is theirs, do it yourself.

`reason:` must be one of those four. Headless drivers echo `reason:` and
`needs:` verbatim in their end-of-run notification — in a cloud routine the run
file is discarded with the VM, so the notification is the only durable copy.
This is what gives a stuck run a legitimate way OUT: before it existed the only exit from an unsatisfiable goal was to ask
the human in chat, where no tool could see it, which is why consumer A looked
silent for seven hours on 2026-08-21 while it was in fact politely waiting for
an answer.

**Every field here is a claim, and the board checks it rather than repeating
it** (`verifyEnd`, the same discipline `audit-gate.sh` applies to audit
records — do not trust that it happened, check that it holds). `frontier-empty`
is re-derived from the item files; `awaiting-human` must NAME what it waits on
and those items must still be open, so a wait cannot outlive its cause or be
unfalsifiable; `turns-exhausted` stays valid with work left, because that is
what running out means. A claim that contradicts the backlog is shown as
contradicted, in red — a confident wrong answer is worse than no answer. And a
run that records nothing at all is not invisible: the board derives the same
verdict from the items — and derives the action plan too, from every open
`attended`/`blocked` item — since forgetting is precisely the failure this
exists to catch.

**Then, and only in an interactive session, print the plan.** Terraform
suppresses its "run the following command" hint under `TF_IN_AUTOMATION`, git
puts every `advice.*` hint on stderr behind `GIT_ADVICE=0`, and `gh` prints its
Next Steps block only to a TTY. All three separate the same two layers, and
sweap's failure was the exact inverse: the instructions existed ONLY in the
channel no tool could read. So the record is the source and the printed block is
a rendering of it — never the other way round. Order by what each step releases
(longest downstream chain first, then breadth), show at most three, and give
each one its command, what it unblocks, and its *Done when*. Headless drivers
write the record and print nothing.

Then **print** the exact goal line, filled in, for the user to paste — do NOT
try to set `/goal` yourself (only the user can invoke it). Pick the template by
run shape from "Resolve the run" above.

**Print the driver next to it.** The goal says when the run is done; the
`/sweap:run` workflow is how the session drives the items (playbook, "Who
holds the loop"). Print the invocation with `D` as its batch, in drain order:

```
/sweap:run {"ids": ["<D, in drain order>"]}
```

The session runs it, records the run when it returns, runs `/milestone-audit`
if that completed the milestone, and relaunches it after a usage-limit reset,
a red base branch made green, or a human answer — completed items replay from
the journal, so a relaunch costs nothing for what already merged. A bare
`/sweap:run` (no ids) drains the frontier in pick order instead; use it for a
debt-only run.

**Non-negotiable for any milestone run (regardless of prefix):** the goal line
MUST carry the "…and the `<MILESTONE>` milestone-audit has run and been
triaged" clause. A milestone is not complete until its audit has run — a run
that drains every item but stops before the audit has stopped early. This
holds whether the goal is printed here or hand-written: if a milestone `/goal`
is ever hand-written rather than printed by `/milestone` (or the user pastes
one), the audit-and-triage clause is part of the definition of done, not
optional. For a UI-heavy milestone (its `review.dimensions` tags include `ui`)
the audit clause covers **both** the `/milestone-audit` code pass **and** the
Tier-2 UI audit (see the playbook's "Milestone audit" section and the
`ui-design` skill §8) — whose scope is every route carrying surface-contract
debt, not only the screens this milestone touched. Two run shapes carry no audit clause, and both are
principled rather than a loophole: the **debt-only** run (you don't audit a
debt-drain), and the **hand-offs-outstanding** run (the milestone provably
cannot complete while a hand-off is open, so its audit is not yet owed — that
template says so explicitly instead of staying silent, and the audit clause
travels with the completing run instead).

**Milestone + debt** (an `M` was resolved; no hand-offs outstanding):

```
/goal First, every outstanding audit follow-up item in the backlog is [done];
then every unblocked <MILESTONE> item is [done] per its definition of done, and
the <MILESTONE> milestone-audit (plus the Tier-2 UI audit for a UI-heavy
milestone) has run and been triaged. Stop when the only [todo] items left are
audit follow-ups carrying followup_of: <MILESTONE> (those are the next run's
debt, not this run's work), or when NOTHING IS RUNNABLE — every remaining [todo]
has an unsatisfied dependency on a [blocked], [attended] or [deferred] item, so
the frontier is empty and no agent may pick anything up. Or after <TURNS> turns.
When you stop, record it (see "Record the end of the run" below).
```

That stop condition names the follow-ups deliberately. A correct audit ends by CREATING work: bucket-2 triage writes
`followup_of:` todo items, so a run that audits well can never literally reach
"only blocked or attended remain" — consumer A's F11 run hit exactly that and had to
escalate the ambiguity. Those items are the NEXT run's debt (the frontier drains
them debt-first), not this one's.

**Hand-offs outstanding** (an `M` was resolved, but the human deferred one or
more of its hand-offs). The audit clause is deliberately absent and replaced by
an explicit statement that it is NOT due: an open hand-off keeps the milestone
incomplete, so the ordinary template's definition of done is unreachable and a
run given it would burn turns chasing it. This is not the malformed
"milestone goal without an audit clause" the playbook warns about — the audit
clause travels with the *completing* run, the one kicked off after the hand-offs
close:

```
/goal Every outstanding audit follow-up item in the backlog is [done]; then
every unblocked <MILESTONE> item NOT gated by an outstanding hand-off is [done]
per its definition of done. Hand-offs <IDS> are the human's and remain open, so
<MILESTONE> cannot complete and its milestone-audit is NOT due this run — do not
attempt it. Stop when NOTHING IS RUNNABLE — every remaining [todo] has an
unsatisfied dependency on a [blocked], [attended] or [deferred] item, so the
frontier is empty — or after <TURNS> turns. When you stop, record it (see
"Record the end of the run" below).
```

**Debt-only** (no runnable `M`, but `D` is non-empty):

```
/goal Every outstanding audit follow-up item in the backlog is [done] per its
definition of done. Stop when NOTHING IS RUNNABLE — every remaining [todo] has
an unsatisfied dependency on a [blocked], [attended] or [deferred] item, so the
frontier is empty — or after <TURNS> turns. When you stop, record it (see
"Record the end of the run" below).
```

**Why the stop clause names the frontier and not a set of statuses.** "Gated by
an unsatisfied dependency" is not a status in sweap. An item waiting behind an
attended hand-off stays `status: todo` for as long as the hand-off is open —
`blocked` means an agent got stuck and needs an answer, `deferred` means the
premise is not yet valid, and there is no third label for "todo, deps unmet".
That is what the frontier computation is for. A stop clause phrased in statuses
therefore cannot fire in exactly the situation `attended` exists to model: consumer A
reached a state on 2026-08-21 where the frontier was provably EMPTY — nothing an
agent was permitted to pick up — while nine `DS.5.4`–`DS.5.12` items sat at
`todo` behind one hand-off, so every status-based clause read false. The run
could neither win nor stop. Note the asymmetry this fixes: the
hand-offs-outstanding template's *completion* clause already said "NOT gated by
an outstanding hand-off" and got it right; its stop clause, one sentence later,
did not.

**"Nothing is runnable" is the whole bar, and it is not "something is blocked".**
A run with one blocked item and eleven runnable ones must keep going. The out is
earned only when the frontier is empty — the same computation the run already
uses to pick its next item, now also used to decide when there is no next item.

Everything else (TDD, the review dimensions, end-of-run hygiene, escalation, and
the audit auto-launch/triage) is inherited from CLAUDE.md and the playbook's Run
core, which the run reads at start (other sections by heading, when their
situation arrives) — the goal only states the end condition.

The whole ritual for the user is just: `claude --permission-mode auto` →
`/milestone` → paste the printed goal. If `services.up` is declared, services
come up automatically above — the user never runs it themselves. When the
milestone has hand-offs, one question comes first (do them now or later), and
answering "now" replaces the paste step with a `/handoff` walk-through.
