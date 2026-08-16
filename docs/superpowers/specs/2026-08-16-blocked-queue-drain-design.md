# Draining the blocked queue: `/unblock`, carry notes, and a boundary that closes

**Design spec — 2026-08-16.** Sits on the research memo
`docs/research/2026-08-16-blocked-question-queue.md` (mixed-initiative HCI, the
2025–2026 clarifying-question literature, the closed-loop-communication evidence
from patient safety, and the alert-fatigue counterweight). Read it before
changing any of this — the two most counter-intuitive decisions here (§3 and §5)
are decided by that evidence, not by taste.

## Problem

`[blocked]` is the only state in the pipeline that is **surfaced everywhere and
drained nowhere**. It appears in the end-of-run summary, in the board's
`⛔ Blocked` column, and in the loop's stop condition — all read-only displays —
while the one place a direction call is actually taken, `/roadmap`'s brainstorm,
scans only for `status: todo` items with `followup_of:` (pending *fixes*).
Blocked items are excluded by construction.

`/handoff` states the gap out loud: *"A `[blocked]` item is a question awaiting a
`> ANSWER:` line, not a hand-off; answer it in the item file instead."*
`[attended]` got a command that walks it and closes the loop through a gated PR.
`[blocked]` got a sentence telling the human to hand-edit YAML.

Observed in `consumer-a` on 2026-08-16: six open blocked items, **five of which
survived at least one full milestone authoring-and-draining cycle** without being
asked (`FJ.6` survived two). Every one is a well-framed binary with stated
options — the questions are good; nothing drains them. The leak is not
occasional, it is once per milestone.

## Principle

The intervention is a **closing event at the boundary**, not more visibility.
sweap already surfaces blocked items in three places and it changed nothing; the
patient-safety literature on results pending at discharge is unambiguous that
what works is documented pending-state plus a notification tied to the transition,
with an owner — not a standing list.

Three constraints shape the mechanism:

1. **The milestone boundary is the right moment** (Horvitz CHI '99, factor 3 —
   consider the cost of deferring action to a time when it is less distracting).
   It is a low-cost interruption point *and* the one moment a direction call is
   already being made and new work already scoped.
2. **The agent prepares; it never resolves a direction call.** Su & Cardie
   (arXiv:2605.25284) found that retrieved context makes models *less* likely to
   ask and more likely to assume. "Go check whether the repo answers these" is
   exactly that condition applied to questions already escalated for a human.
3. **An unanswered question must time out.** LookOut waits, then evaporates;
   sweap waits forever. A decision with a visible default beats an open question
   forever — but the human still authors it (see §5, which is why the deadline
   *asks* rather than auto-answers).

## Architecture

**No new status.** An answered blocked item flips `blocked → todo` with the
`> ANSWER:` line and becomes an ordinary frontier candidate — exactly how audit
follow-ups already work. "Picked up in the next milestone" falls out for free;
the queue only has to be drained before the frontier is computed.

**One new frontmatter key** (`carried:`), **one new command** (`/unblock`), **one
new pre-flight step** in `/roadmap`, and **informational output** on the gate
that already runs at that boundary. No new enforcement mechanism — see §6.

---

## 1. `carried:` — the age of a question, in boundaries

A new optional integer key on item frontmatter, parallel to `blocked:`:

```yaml
status: blocked
blocked: "…the question…"
carried: 2
```

`carried: N` = this question has survived N milestone boundaries unanswered.
Absent or `0` means fresh. `/roadmap`'s pre-flight is the only writer; it
increments on every boundary the item is not resolved at, and writes a matching
human-readable note under `## Notes`:

```
> **CARRIED (2026-08-16):** unanswered through F10.
```

The note is the provenance (legible in the diff); the key is what the board, the
gate and the pre-flight read, so nothing has to grep a body. Both are retained
after the item is unblocked, like `blocked:` itself is retained on `FL.1` today.

**Why a counter and not derivation from git.** The carry count is a count of
*boundaries*, not of commits or days, and no git query answers "how many
milestones were authored while this sat" without reconstructing milestone history.
A single integer written at the one moment the boundary is crossed is both cheaper
and more truthful.

## 2. The escalation ladder

| `carried` | what `/roadmap` does |
|---|---|
| 0 | lists it, offers it |
| 1 | lists it with its carry note, and writes a `> **RECOMMENDATION (date):** <default> — <rationale>` note if none exists |
| ≥2 | **asks it** — the brainstorm does not start until it is resolved |

"Resolved" at ≥2 means one of: answered; the human says *take the recommended
default* (recorded as an answer, with `(default taken)` in the note); or dropped
with a `dropped_reason:`. The recommendation has by then been sitting in the item
for a full boundary, so the deadline never springs a fresh proposal on anyone.

This is the bounded deferral: deferrable while cheap, mandatory before it rots.
Everything below `carried: 2` stays a **soft** gate — surface, offer, record the
skip with its cost. The adjacent audit-debt check is a hard stop because audit
debt is never legitimately deferrable; a direction call is.

## 3. What the agent may do to a question — and what it may not

Three buckets, split mechanically rather than by judgement:

**(a) Premise invalidated.** The world moved and the question is moot, evidenced
by a merged PR, a diff, or a shipped item — the `FL.1` shape, which is the one
blocked item in `consumer-a` that ever closed, and it closed because the world moved
rather than because anyone answered. The agent may **propose** closing it *with
the evidence attached*; the human confirms.

**(b) Not actually a question.** Decided by the **double-turn test**, transferred
from Zhang, Knox & Choi (ICLR 2025), who label clarifying questions by *simulating
their expected outcomes in future turns*: simulate both answers and write out the
item file each would produce. If they are the same, the fork changes nothing
downstream and does not belong on a human's queue — propose closing it with the
default, showing the simulation. **This test decides whether to ask, never what
the answer is.**

**(c) A direction call** — taste, scope, policy, cross-milestone information
architecture. The agent may restate the fork, list the options, recommend a
default with rationale, and say what changes downstream either way. **It may
never resolve one.** This is the rule constraint 2 exists to protect, and the
one an implementation will drift on if it is written loosely.

**Explicitly not supported:** open-ended "let's brainstorm what the answer might
be" as a matter of course. Preparation with a recommended default is supported;
inviting the model to reason its way to an answer invites it to talk itself out
of asking, which is the documented failure mode. If the human asks to brainstorm
a specific one, that is different — that is the human thinking out loud, and the
answer is still theirs.

## 4. `/roadmap` step 0 — the boundary that closes

A new pre-flight step, **before** the brainstorm and after the existing
audit-debt check, not folded into phase 1. Answering accumulated questions inside
the new milestone's narrative anchors them to it; the two are different modes and
get separate steps.

1. Read every `status: blocked` item file (any configured prefix).
2. Triage into the three buckets of §3. Propose the (a) and (b) closures as a
   single batch — they are evidence, not decisions, and cost one confirmation.
3. Rank the remainder by what the answer unblocks (transitive not-yet-done
   dependents, the board's existing `reverseDeps`/`gatedItems` rule), then by
   `carried`, then by age.
4. **Ask at most three** — plus every `carried: ≥2` item, which is mandatory —
   one at a time, in the Socratic style the brainstorm already uses. Each ask
   runs `/unblock`'s brief.
5. Everything not resolved: increment `carried:`, append the `> **CARRIED:**`
   note, and add the `> **RECOMMENDATION:**` note if missing.
6. State the skip and its cost in one line, then start the brainstorm.

**Why "at most three".** Alert-fatigue evidence: clinical-decision-support
override rates run 49–96%, and 88.2% of *very severe* drug-interaction alerts were
overridden in one study. A six-item dump converts a forgetting problem into a
rubber-stamping problem, which is worse — it leaves a record saying the question
was answered. Three is a default with a rationale, not a magic number; the human
can ask for more.

All of step 0's writes land in the milestone PR that the brainstorm produces —
one PR through the gate, as today.

## 5. `/unblock [item-id]` — the sibling `/handoff` already implies

Walks one blocked item and closes the loop through a gated PR. Structurally
parallel to `/handoff` (brief → work it → close only on explicit confirmation →
report what it released), and it removes the embarrassment in `/handoff`'s own
text.

**Brief.** The question verbatim, which item or audit raised it (`followup_of:`),
what it gates, and its carry history. Then the agent's preparation: the options,
a recommended default with rationale, and the double-turn simulation — what the
resulting item file looks like under each answer. Never an assertion of the
answer.

**Close, only on the human's explicit answer in-session.** Two outcomes:

- **The answer produces work** → `status: todo`, `> **ANSWER (date):** <verbatim>`
  under `## Notes`, and the agent **authors the `## Spec` / `## Acceptance` the
  answer implies** — a blocked item is a record without a full spec, and
  `roadmap-lint.sh` requires both for `todo`, so the flip is not a one-line edit.
  Run `roadmap-lint.sh` on the file before the PR opens.
- **The answer produces no work** ("keep it as-is") → `status: done` with the
  answer recorded, matching the `FL.1` precedent. The decision *is* the outcome,
  and `done` keeps the milestone-completeness arithmetic in `audit-gate.sh`
  correct while leaving the record findable at the top level (archiving would
  move it out of sight).

`blocked:` and `carried:` are retained in both cases, as the record of what was
asked and how long it waited.

**Never**: resolve a direction call without the human answering in this session;
run inside an unattended run; touch any item that is not `status: blocked`;
convert a blocked item into `attended` (that path is already mechanically denied —
a hand-off is authored, never transitioned into).

## 6. Why no new mechanism

`attended` got a git-provenance check in `audit-gate.sh --check` because
relabelling stuck work as human work is a *shortcut that buys the agent a
legitimate run-stop*. Nothing here is that. Skipping the carry increment buys an
agent nothing it wants; taking a default without asking is denied by the same
`--check` only in the sense that it would be a visible, diffable lie. The
mechanism budget stays spent where shortcuts pay.

What is added instead is **non-failing surfacing on the machinery that already
runs at the boundary**: `audit-gate.sh --check` gains an informational
`AGING: blocked <id> …` line per open blocked item, alongside the existing
non-failing `DEFERRED:` and `STALE:` prefixes. `/roadmap` already runs `--check`
as its pre-flight and already classifies that output, so the reminder rides on
plumbing that exists and is already read at exactly the right moment. It never
fails a build, and it makes "what is pending at this transition" a documented
artifact of the transition — which is the intervention the evidence supports.

## 7. Board

`⛔ Blocked — needs you` gains the carry count per item (`carried: 2` renders as a
warn-toned age badge). `loadItems` reads `carried:`; `deriveBacklog`'s blocked
mapping passes it through. No new column — blocked already has one, and the point
is that the *queue* was never worked, not that it was never shown.

## Out of scope

- Draining the blocked queue during a run. Bounded deferral says the boundary is
  the low-cost moment; mid-run asks are the thing the escalate-don't-guess rule
  deliberately avoids. `/unblock <id>` is available any time the human wants it.
- Any hard gate below `carried: 2`.
- Auto-answering. See §3(c).
