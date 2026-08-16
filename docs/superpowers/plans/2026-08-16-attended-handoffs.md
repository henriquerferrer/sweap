# Attended items (planned human hand-offs) — design record

**Goal:** Give sweap a way to represent work that was always the human's to do —
a step needing credentials, an account, hardware, a legal identity, a
third-party approval, or a taste decision — so that it becomes a tracked item
instead of a deletion, and so the "needs me now" queue stops conflating *an
agent failed* with *this was always mine*.

**Research:** `docs/research/2026-08-16-planned-human-handoffs.md` (BPMN user-task
prior art; LangGraph/Agno HITL primitives; fan-out theory; the reward-hacking
findings that decided doctrine-vs-mechanism). Read it before changing any of
this — two decisions here are counter-intuitive and the memo is why.

**Architecture:** One new **status value**, not a flag. `todo` means
*agent-dispatchable* and everything downstream keys off that exact string, so a
fifth status is correct for free: the frontier (`status === "todo"`), dependency
resolution (satisfied only by `done`), the board's blocked queue
(`status === "blocked"`) and `audit-gate.sh`'s milestone-completeness computation
(anything not `done` keeps a milestone incomplete) all behave correctly with no
special cases. Every change below is therefore **additive surfacing** plus one
new mechanical control.

## What shipped

**Schema + spec gate** (`hooks/roadmap-lint.sh`)
- `attended` joins the valid status list; `handoff:` is required when the status
  is `attended`, exactly parallel to `blocked:`/`premise:`.
- An attended item must carry a `## Hand-off` body section (placeholder-checked
  like Spec/Acceptance). It is a record for the *spec* gate — no
  `## Spec`/`## Acceptance` — but it is picked up by a human, so it needs its own
  self-contained instructions. The body/section/placeholder helpers were lifted
  out of the `todo` branch so both kinds share one implementation.
- **Backward compatibility:** no pre-existing item file can carry
  `status: attended`, so no new requirement can retroactively fail anything
  already merged. That is the whole reason the new requirements attach to the
  new status rather than to items in general.

**Anti-escape-hatch control** (`hooks/audit-gate.sh --check`)
- For every item currently `attended`, the commit that introduced
  `status: attended` must BE the commit that added the file. A hand-off is
  **authored, never transitioned into**. Provenance comes from git, so it cannot
  be forged by editing the item — the same idiom `record_is_legacy` already uses.
- Why a mechanism and not a rule: `attended` is a legitimate run-stop condition
  (`stop when only [blocked] or [attended] remain`) and carries no failure
  stigma, so relabelling stuck work is a real shortcut, and the literature says
  instructions against shortcuts are advisory at best and can backfire. Every
  other tempting shortcut here (`--admin`, merging red, skipping the audit) is
  denied by a mechanism.
- **Two invariants now share `--check`**, distinguished by line prefix:
  `FAIL: milestone …` / `FAIL: record …` is audit debt; `FAIL: hand-off …` is a
  backlog-integrity violation that no audit discharges. `/milestone` and
  `/roadmap` pre-flights were updated to classify them. They share one script
  (rather than a new mode or a new file) because both are deterministic
  git-provenance questions about the backlog run by the same CI job — and
  because a new mode would need every consumer repo's `audit-gate.yml` to change
  before the control could reach it, while `--check` is already wired.
- Uncommitted files are skipped, not failed: `/roadmap` lints items in the
  working tree before they are ever committed.

**Board** (`tools/sweap-board.lib.mjs`, `.page.mjs`)
- `loadItems` reads `handoff:`; `deriveBacklog` returns an `attended` list with
  `task`, `ready` (unblocked) and `gates`.
- `gates` = every not-yet-done item transitively depending on the hand-off, via
  new `reverseDeps`/`gatedItems`. A bare-milestone dep expands to that
  milestone's items, matching `isUnblocked`'s classify-by-membership rule. This
  number is what makes `/milestone`'s kickoff fork a decision rather than a nag.
- New `🙋 Yours — hand-offs` column, warn-toned, deliberately separate from
  `⛔ Blocked — needs you`. Attended items are excluded from `inFlight` so the
  columns stay disjoint even when `/handoff`'s status-flip branch exists.

**Authoring catch** (`commands/roadmap.md`, `skills/milestone-cross-check/SKILL.md`)
- The decide phase must ask outright what in the milestone is not an agent's to
  do, and an `- **Out of scope:**` bullet that excludes work *because it needs a
  human* must name the attended item it moved to.
- A 9th cross-check lens, "Human dependencies & hand-offs", catches what the
  brainstorm missed — including hand-offs authored with avoidable dependencies.

**Timing** (`commands/milestone.md`, `commands/loop-schedule.md`)
- A hand-off scan joins the deferred and audit-debt scans, and `/milestone` asks
  *before* printing any goal: do them now (prints `/handoff`, holds the goal) or
  later (prints the hand-offs-outstanding goal). The ask lives only in
  `/milestone` because a human is standing there; `/loop-schedule` is headless
  and uses the outstanding form directly.
- **New run shape.** With a hand-off open the milestone provably cannot
  complete, so the ordinary template's audit clause is unreachable and a run
  given it burns turns chasing it. The hand-offs-outstanding template drops the
  clause and states explicitly that the audit is not due; the clause travels
  with the completing run. There is also a no-goal case: when every runnable
  item is gated by a hand-off, print the `/handoff` command and stop.

**Guidance** (`commands/handoff.md`, new)
- Walks one attended item, does every part an agent legitimately can, checks the
  *Done when* condition, and flips to `done` through a gated PR **only** on the
  human's explicit in-session confirmation. Records `> **STARTED (date):**` when
  a hand-off is begun but blocked on a third party, mirroring the deferred
  items' `> **UNBLOCKED:**` convention. Reports what the merge released.

**Doctrine** (`playbook`, `templates/CLAUDE.md`, `templates/ROADMAP.md`)
- New "Attended items" section; a four-state ownership table in Backlog format;
  the direction loop now names the work only the human can do; the hard-rules
  list forbids creating or transitioning into `attended`; the end-of-run
  notification includes open hand-offs.

## Decisions worth not re-litigating

- **Status, not a frontmatter flag.** A flag keeps old lints quiet but breaks
  "todo = dispatchable", so a stale plugin build would *silently dispatch* a
  hand-off to an agent. A new status makes that same skew fail loud
  (`invalid status`). Loud beats silent when the failure is an agent trying to
  open a bank account.
- **No `human-signoff` review dimension.** Putting a human click inside the
  merge gate stalls unattended runs — the one thing the design refuses. When an
  agent item genuinely needs sign-off, pair it with an attended item that
  `depends_on` it; the sign-off then shows up in the index, the board and
  milestone completeness instead of in the gate.
- **An open hand-off defers its milestone's audit.** Intended: it is what gives
  a hand-off teeth. No merges are blocked and no debt accrues — the audit is
  simply not owed yet. The escape valve is archiving the item.
- **Re-assignment is archive-and-re-author.** The provenance rule forbids
  `todo → attended`, which costs the human a legitimate move. Accepted: both
  halves stay visible in the diff, and the alternative (diffing the PR against
  the anchor to allow roadmap-only transitions) is fragile against a stale
  `origin/main`.

## Tests

- `hooks/roadmap-lint.test.sh` — valid attended record; missing `handoff:`;
  missing/placeholder `## Hand-off`; a todo item depending on a hand-off. (27)
- `hooks/audit-gate.test.sh` — authored-attended passes; `todo → attended` and
  `blocked → attended` fail; uncommitted is skipped; `attended → done` is legal;
  an open hand-off keeps its milestone incomplete so no debt accrues. (80)
- `tools/sweap-board.test.mjs` — attended is its own queue (not frontier, not
  blocked); `gates` transitively and through milestone deps; `ready` reflects
  dependencies; a hand-off with a branch is not in-flight; the page renders the
  column. (38)
