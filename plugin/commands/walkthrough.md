---
description: "Walk one shipped milestone with the human — the acceptance pass a green suite cannot give. Not the test suite; that is verify.e2e."
argument-hint: "[milestone] — defaults to the last complete milestone with no session sheet"
---

Read `CLAUDE.md`, the playbook's **Backlog format (file-per-item)** and
**Discovered work — the three-lane rule** sections, and the item files under
`backlog.dir` first.

This command exists because **every gate can be green and the answer can still
be no**. sweap automates the correctness loop and the prompting loop and keeps
the direction loop human — but all three human inputs happen *before* or
*during* the work (`/sweap:roadmap` takes direction, `/sweap:unblock` takes an answer,
`/sweap:handoff` takes a task). Nothing happens *after* something ships.

The evidence is local, not theoretical. On 2026-08-18 one unscripted walkthrough
of a consumer repo — green on 269 Playwright specs, a six-lens adversarial code audit and
a five-lens UI critic — found ten defects plus a screenful of server-console
errors, and became the DS.5 milestone plus a spun-off one
(`roadmap/ideas/archive/revisit-and-standardize-the-screens.md`). It has happened
exactly once in sixteen milestones, by accident. `DS.5.13` is the hand-authored
attempt to schedule it and it stalled: it asks for the whole app on two
viewports and has never started. **This command is the mechanism that doctrine
was missing, and it is deliberately small enough to actually run.**

Automated acceptance asserts what the spec said, so it cannot fail for a reason
nobody wrote down — "the spec was wrong", "this is ugly", "this flow is
awkward". Those have exactly one collection mechanism, and it is a person.

**Resolve the milestone.** The first argument if given. Otherwise ask the lib —
never infer, and never print the answer without its source:

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

A milestone is **complete** when every non-`followup_of` item under it is
`status: done` — the rule `audit-gate.sh` already uses, so an open hand-off or a
blocked question keeps it incomplete, and outstanding audit follow-ups do not.
Order is the **index's**, not the id's. Print the milestone, its item count and
the `source` string verbatim, then `not that one? /sweap:walkthrough <M>`. If the resolver
returns null, say nothing is complete yet and stop.

`milestone-audit.js` still falls back to the literal phrase "the most recently
completed milestone" inside a prompt, and the playbook records that this once
audited the WRONG milestone. That is why this resolves mechanically.

**Pre-flight.**

1. **Audit debt does not block a session.** Run the gate for information only —
   `bash "$([ -f .github/scripts/audit-gate.sh ] && echo .github/scripts/audit-gate.sh || echo "${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh")" --check` —
   report any `FAIL:` in one line and **continue**. This command's only writes
   land under `<backlog.dir>sessions/`, `discovered/` and `ideas/`, which
   `audit-gate.sh` classifies as non-item, so the capture PR is not
   backlog-advancing and lands during debt.
2. **The app must be running.** Same ladder as `/sweap:milestone`'s environment
   pre-flight: `services.up` if declared, `docker info`, `open -a Docker` plus a
   ~90s poll on macOS. **There is no CI-gated fallback here** — a session
   without a running app is not a session. If it will not come up, say so and
   stop. Prefer the project's recorded launch recipe (Claude Code's `/run`
   skill) over inventing one.
3. **Read what already found things** — the milestone's item files and
   `<backlog.dir>audits/<M>.md` if it exists. Say how many findings the audit
   already booked. That is the honest prior on what is left, and it stops the
   session re-reporting known work.
4. **Prefer a fresh session, and say so once.** If this session implemented any
   of the milestone's items, recommend running `/sweap:walkthrough` in a new one: *"a fresh
   context improves code review since Claude won't be biased toward code it just
   wrote"*, and the same bias operates on a facilitator. A recommendation, not a
   block — a wall gets routed around.

**The session** — a chartered session in the Session-Based Test Management
sense: one stated mission, one time-box, and a sheet at the end a third party
could read.

1. **Build the charter, cap it, show it before starting.** Union two sources:
   every item's `## Spec` **Surface** and `## Acceptance` bullets, and the
   diff of the merges that landed `M` (surfaces that shipped but were never
   specced appear only in the second). **Six to eight stops, 30–45 minutes.**
   Cut ruthlessly: keep only the routes where a *person's reaction* is the only
   available signal, and drop anything machine-observable and already e2e-covered
   — a scan pipeline or a delivery webhook has nothing a human can judge. Offer
   to trim further. This cap is the whole lesson of `DS.5.13`.

2. **State the route and the task. Never the expected result.** "Settings →
   Message templates. Edit the SMS reminder template and save it" — not "you
   should see it save and a toast appear." Saying what should happen before they
   look anchors them, and the unprimed reaction is the only thing this session
   produces that nothing else can. **This is a hard rule.**

3. **They drive; you have hands.** On explicit request: navigate
   (claude-in-chrome, already sanctioned by the `ui-design` skill §4), run
   `test.seed`, build a fixture, open a route, read the network tab. One action
   at a time, narrated before you take it. Diverting from the charter is allowed
   and gets recorded — SBTM calls it *on-opportunity* testing and encourages it.

4. **Watch the console and the server log throughout, unprompted.** Machine
   observation carries no facilitator bias, and it is exactly what produced
   "multiple errors in the server console" on 2026-08-18 — which shipped as
   `DS.5.2`.

5. **Capture continuously, in their words.** Keep the human's phrasing verbatim,
   the way `/sweap:idea` already requires. **Never argue an observation into
   correctness.** You may have written this code; you do not get to defend it
   here. A disagreement is recorded as a disagreement.

6. **Record what passed, too.** A sheet listing only defects is unfalsifiable and
   cannot be re-run. Every charter line gets walked or skipped, and a verdict.

7. **Debrief, then classify — at the end, in one batch.** Never mid-walk: it
   interrupts the walk and primes the next stop. Read the harvest back in their
   own words and let them correct it. Two questions are mandatory: *"Does this
   session report faithfully represent the testing that was done?"* and, when
   the harvest is empty, *"If there are no issues, does that mean there was no
   confusion, no remaining questions, and no obstacles in the path of testing?"*
   A clean session is a claim, and it gets tested like any other.

**The four outlets.** This is SBTM's bugs / issues / notes split mapped onto
queues sweap already drains. **`/sweap:walkthrough` mints no item files itself:**

| the observation | outlet | who drains it |
|---|---|---|
| contradicts a stated `## Acceptance` bullet | `writeDiscovered` — `kind: gap`, `from: <item id>`, `milestone: <M>` | `/sweap:milestone` triages it: with a harm class it becomes a `followup_of: <M>` item whose `## Acceptance` becomes a permanent test; without one it waits for you at `/sweap:roadmap` — an agent never parks what you filed |
| a UI/aesthetic shortfall | same, with the *why* naming the contract clause it should become | the clause plus its check land with the item |
| works as specced and is still wrong | `writeDiscovered` — `kind: direction` | `/sweap:roadmap` decides: an item, a spec line, or a `declined:` |
| a genuinely new want | `writeIdea` | `/sweap:roadmap` triage |
| a question you can answer | answered live | recorded in the sheet under `answered:` |

Use the lib snippets exactly as the playbook's "Discovered work" section and
`/sweap:idea` step 4 give them — `writeDiscovered` and `writeIdea` are create-only and
own the format. **When unsure, `direction`**: a human un-deciding a gap costs a
minute, an agent deciding direction costs a milestone.

**Why not an idea file by default.** The `ui-design` skill §9 is explicit:
*"Findings left as prose in an idea file teach the pipeline nothing and will be
rediscovered by hand next milestone."* A defect routed to `discovered/ kind: gap`
ends as an item with a real acceptance criterion — a check, which is what that
section demands. `ideas/` is for wants that are nobody's defect.

**Write the sheet through the lib** — `writeSession` is create-only and owns the
format, exactly like `writeIdea`. Do NOT hand-write it: `gaps: 0` is what trips
the kill condition below, so a formatting slip in a hand-written sheet would
argue for deleting this command.

```bash
node --input-type=module -e '
const lib = await import("file://" + process.argv[3]);
const { backlogDir } = lib.readConfig(process.cwd());
const out = lib.writeSession(process.cwd(), backlogDir, { ...JSON.parse(process.argv[1]), body: process.argv[2] });
console.log(out.file);
' "$(cat <<'JSON'
{"milestone":"F11","date":"2026-08-26","viewports":["desktop","360"],
 "counts":{"duration_min":34,"charter":7,"walked":6,"skipped":1,"on_charter":5,
           "on_opportunity":2,"observations":9,"gaps":4,"directions":2,"ideas":1,
           "answered":2,"verdict":"accepted-with-followups"}}
JSON
)" "<the body>" "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.lib.mjs"
```

`verdict` is one of `accepted`, `accepted-with-followups`, `rejected`; an unknown
one falls back rather than landing, and negative counts are clamped. The body is
one block per observation: the human's verbatim words, the route, and where it
landed (`→ discovered/<file>`, `→ ideas/<file>`, or `answered`). Two sessions on
the same milestone the same day do not collide — the second gets a `-2` suffix.

**Land it.** One PR, `chore(backlog): <M> test session — <n> note(s)`, sweeping
both inboxes per End-of-run hygiene. Non-item, so it lands during audit debt;
it rides the roadmap-only CI lane, so it costs a `checks` run rather than an e2e
cycle. Merge on green through the normal gate
(`sweap-merge watch <n>`), then run
end-of-run hygiene as always. Report what the gap notes will become: the ones
with a harm class drain **debt-first**, at the front of the next run's frontier;
the rest are yours to decide at the next `/sweap:roadmap`.

**Safety rails on the half where you act.**
- Browser actions only on explicit request, one at a time, narrated first.
- **Seed only through the declared `test.seed` command** (`## sweap config`;
  undeclared = do not seed, ask the human to). Never ad-hoc SQL,
  never a destructive operation, never "just this once". An agent once generated
  ~4,000 fictional records against eleven explicit prohibitions; the lesson is
  that the rail has to be a constraint on what is invocable, not a sentence the
  model is asked to remember.
- `test.url` (`## sweap config`; undeclared = ask for the URL) must not resolve
  to production. Hard stop, no in-command override.
- Never trigger a native browser dialog — it blocks every subsequent command.
- **The session never edits code.** It observes and captures. Fixes are items.

**What this command never does:** create or transition an item into
`status: attended` (a hand-off is authored, never transitioned into, and
`audit-gate.sh --check` enforces it); author a `status: blocked` item (that is an
*agent got stuck* signal, not an observation); write an item file of any status;
edit an existing idea or discovered note; state the expected result before the
human has looked; render the verdict itself; or run unattended — this command
requires a human in the session, like `/sweap:handoff` and `/sweap:unblock`.

**It is offered, never mandated.** `/sweap:milestone` surfaces it at kickoff and takes
no for an answer, every time, without escalating. Mandating attendance is the one
variable with a large null result against it: an identical checklist mandated
across 101 hospitals and 215,711 procedures moved outcomes at P = 0.13, and
checklist *usage* has been observed holding near 90% while *completion* fell from
81.7% to 53.2% — the decay a "did it happen?" check cannot see, and the presence
of a session sheet is exactly such a check. What decides whether this command
keeps existing is its **hit rate** (`sessionStats`): notes per session, and how
many became items. Three consecutive sessions with zero `kind: gap` notes means
the automated filters have caught up — say so, and recommend cutting this back to
a UI-only spot-check rather than reminding harder.
