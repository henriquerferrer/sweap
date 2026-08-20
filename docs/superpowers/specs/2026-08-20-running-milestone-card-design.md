# Running-milestone card — design

**Date:** 2026-08-20
**Touches:** `plugin/tools/sweap-board.{lib,page,}.mjs`, `plugin/commands/{board,milestone,agentic-loop-init}.md`,
`plugin/hooks/scaffold.sh`, `plugin/playbook/agentic-loop-playbook.md`

## The gap

The board could always answer *which items are moving*. It could never answer
*which milestone is moving, and what stands between it and done*.

Concretely, before this change the page carried no milestone concept in its live
section at all. `Frontier (ready)` listed every unblocked `todo` item across all
milestones with nothing saying which milestone they belonged to; `In-flight`
listed items with a worktree or PR, item-level and unlabelled; `Backlog` grouped
by milestone but rendered every group identically, with no progress and no
marker for the one being run. The only run-level signal on the whole page was
the boolean `run.active`, rendered as the string `no run in flight` beside the
timestamp.

The root cause is upstream of the board. `/milestone` resolves a milestone and a
run *shape* at kickoff, prints a goal line, and forgets both. Nothing on disk
recorded which milestone a run was executing, whether it was debt-first or
debt-only, whether a hand-off had been deferred, or when it started. The board
could not display state that was never written.

## What ships

A card at the top of the page, above the live-run columns:

- **Identity** — milestone id, its goal sentence, and a `running` / `next up`
  chip.
- **Scope** — the run shape, the debt-first prefix (`2 audit follow-ups → F4`),
  the turn budget, and how long ago the run started.
- **Progress** — a bar plus a tally (`5/9 done · 2 todo · 1 blocked · 1 yours`).
- **Right now** — in-flight items, each tagged by where it sits in the run's
  scope: `milestone`, `debt`, or `other milestone`.
- **Next ready** — the frontier, narrowed to this milestone and minus what is
  already in flight.
- **Blocking completion** — the milestone's open hand-offs (with what each
  gates) and its blocked questions (with their `carried:` count).
- **Audit** — the gate's verdict for this milestone.

The matching group in `Backlog` gets an accent rail and the same chip, so the
card and the list below it are visibly the same milestone.

## Two new reads

**The milestone index (`backlog.file`).** The board had never read it. It
carries the two things item files structurally cannot: a milestone's *goal
sentence* and the human's *priority order*. `parseMilestoneIndex` takes bullets
only under a heading naming milestones, which keeps the index's prose — which
also uses dashes — out of the parse, and tags the "Later milestones (sketch)"
section so an unspecced milestone is never mistaken for runnable work.

**The run file (`.claude/sweap-run.md`).** Gitignored and ephemeral, exactly like
`.claude/sweap-board.md`. `/milestone` writes it on the paths that actually print
a goal; End-of-run hygiene deletes it. It records `milestone`, `shape`, `scope`,
`turns`, `started`, `deferred_handoffs`.

**Nothing in the loop reads it to decide anything.** Status truth remains the
item files. It feeds a display, so a stale or missing one degrades the card and
never a control — which is why `/milestone` is told a failed write is worth one
line of apology and nothing more, never a blocked kickoff.

## Resolving "which milestone is running"

In order of authority:

1. **The run file** — exact, and the only source that knows the run *shape*.
   Ignored once its milestone has no unfinished items: that run is over and the
   file is litter.
2. **The earliest in-flight item that is not an audit follow-up** — a follow-up
   belongs to the milestone that was *audited*, not the one being *run*, so
   leading with it would name the wrong milestone. A run draining only debt
   still reads as `running`; the card names the milestone that debt runs ahead
   of.
3. **The next runnable milestone** — the same rule `/milestone` resolves by:
   first in index order holding a `todo` item whose dependencies are all
   satisfied, follow-ups excluded for the reason above. This is a claim about
   the future, so the card's chip says `next up`, not `running`.

Every card states its `source` on its face. An inference must never be readable
as a fact — that asymmetry is the entire reason the run file exists rather than
the card simply guessing well.

## The audit line

`audit-gate.sh --check` is the single answer to "is a record missing" — a git
provenance question a second reading here would only drift from. The board
shells out to the repo's **vendored** copy when present, falling back to the
plugin's, for the same reason `/milestone` and `/roadmap` pre-flights do: the
vendored copy is what CI runs, and the plugin path can be a stale cache build.

`--check` is read-only against the repo (its one write is a `mktemp -d` it
removes), so this stays inside the board's read-only mandate. It is cached for
15s alongside the `gh` call — the page polls every 3s and the gate walks git
history — and killed at 10s, so a wedged subprocess degrades the card to `?`
instead of stalling every poll behind it.

Verdict precedence, most specific first:

| state | meaning |
|---|---|
| `unknown` | the gate did not run — outranks everything below, since a silence about record debt is not a clean bill of health |
| `debt` | this milestone is complete with no valid record |
| `deferred` | this milestone completes in the state under review, so its audit cannot have run yet |
| `blocked-by-debt` | *another* milestone's debt — loud anyway: while it stands, no backlog-advancing PR merges at all |
| `not-due` | an open hand-off keeps this milestone incomplete, so its audit is not owed this run |
| `clean` | no debt, nothing outstanding |

`FAIL: hand-off <id>` is not an audit state at all — it is a backlog-integrity
violation no audit discharges — so it surfaces as a page-level note rather than
in the card's audit line.

## What running it against consumer A changed

The first live run, against consumer A mid-milestone (DS.5, debt-first, two workers
in flight), rendered **no card at all**. Three defects, only one of them the
card's:

1. **`parseBoard` read nothing from a real board file.** It accepted only the
   documented one-line form (`F1.1 | review | wt-a@feat-F1.1 | PR #31 | -`);
   Consumer A's coordinator writes a pipe-edged markdown table, so `parts[0]` was the
   empty cell before the first pipe and every row was dropped. Worse, the id
   guard `/^[A-Za-z]+\d/` rejects `FN.3` and `DS.5.1` outright — it only ever
   matched `<letters><digit>`. The In-flight column had been blind for the whole
   run. Now: outer empty cells are trimmed, the rule row is skipped, the id must
   be the *whole* cell (`/^[A-Za-z]+[0-9.]*[0-9]$/`, anchored at both ends so a
   lane row like `FN.1 → FN.2` cannot pass), and a dash-only cell reads as blank
   rather than as a blocked question.

2. **Branch names drop the dots.** consumer A ships `fn3-status-guards` for `FN.3`
   and `fn10-message-tables` for `FN.10`; `refMatchesId` needs the literal id, so
   the worktree and PR fallbacks matched nothing either. `refMatchesLoosely`
   adds the dotless form, but only for an id that **owns** that key outright —
   `F1.3` and `F13` collapse to `f13`, and a wrong link is worse than no link.
   PR *titles* are also matched, strictly, since convention puts the id there.

3. **An audit-follow-up family is not a milestone, and a gated milestone still
   runs.** `milestoneOf("FN.3")` is `"FN"` — but FN is a family keyed by
   `followup_of: F11`, and consumer A's backlog holds 13 such families against 15
   real milestones. A group with no non-follow-up item in it has never been a
   milestone, so the card refuses to name one. Separately, `nextRunnable`
   required a *ready* item; DS.5's nine todos all wait on `DS.5.3`, an attended
   hand-off, which is precisely the hand-offs-outstanding shape `/milestone`
   models. Requiring readiness there is what turned "the milestone that is
   running" into "no milestone to run". A fourth source, `gated`, names it and
   says why.

With those fixed the card reads consumer A correctly: `DS.5 · running · gated`,
2/13 done, FN.3 (#170, passing) and FN.10 (#171, pending) shown as `debt` in
flight, `DS.5.3` gating 10 items, audit `not-due`.

## Read-only, still

The board's one write remains create-only idea capture. This change adds two
file reads and one read-only subprocess, and `/milestone` gains one write to a
gitignored path outside the backlog. No pipeline state is mutated.
