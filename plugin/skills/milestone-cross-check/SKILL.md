---
name: milestone-cross-check
description: Completeness critic for a milestone's drafted item files. Use AFTER an interactive superpowers:brainstorming pass has produced draft items and BEFORE writing them under backlog.dir (roadmap/). Reviews the draft against a fixed lens and surfaces ONLY the net-new forks/gaps the brainstorm missed — it does NOT rewrite items or expand scope; it flags gaps for the human to resolve. Distilled from the product-management write-spec lens (non-goals, persona coverage, success signals, open questions).
---

# Milestone cross-check

The second half of a milestone brainstorm. Phase 1 (interactive
`superpowers:brainstorming`) *decides* — it locks the core with the human
answering one question at a time. This skill is the *completeness critic* that
catches what a decisive pass skips: it reads the drafted items with a fresh,
breadth-oriented lens and reports the forks the brainstorm never raised.

It exists because a single decisive pass is fast but leaves blind spots — the
same reason the milestone audit pairs finders with refuters. For example: a
brainstorm can lock a time-triggered feature's core well yet never raise how it
behaves across timezones and daylight-saving boundaries; an independent breadth
pass surfaces exactly that fork.

## How to run it

Run this as a **fresh-context pass** — ideally dispatch it as a subagent so the
critique is independent of the brainstorm's own reasoning (a critic that shares
the author's context inherits the author's blind spots).

Give the critic: the drafted milestone items, plus the real repo context it must
check against —
- the backlog (the `ROADMAP.md` index + prior milestones' item files under
  `roadmap/`; the item schema lives in the playbook's "Backlog format" section),
- the project's role/permission definitions (the actual role/permission matrix),
- the shipped data model and prior specs (the entities the new milestone
  interacts with).

## The lens — check every item against each

1. **Non-goals / explicit deferrals.** What is deliberately OUT of this
   milestone, and is it *written down* with a one-line rationale? Unstated
   scope cuts become bucket-3 audit findings later. (PM `write-spec` lens.)
2. **Role / persona coverage.** For every role the project defines (e.g. owner,
   admin, and lower-privileged member roles), is its access to each new
   capability decided — including the *negative* (who is denied / 403'd)? A
   brainstorm that omits a role silently under- or over-permissions it.
3. **Locale / timezone / clock.** Anything time- or locale-dependent: is
   storage vs. display timezone decided? Is time-triggered behaviour testable
   with an injectable clock rather than wall-clock waiting?
4. **Data lifecycle & cross-feature interaction.** How do the new entities
   interact with *already-shipped* milestones under archive / delete / cascade /
   concurrency? Cross-feature interactions are what per-PR review structurally
   can't see and what the milestone audit later pays to find — cheaper to catch
   here. (Concurrency races frequently hide exactly here.)
5. **Edge-case policies.** Overlap, empty/null states, duplicates,
   simultaneous mutation, idempotency of any retry/scan. Is each decided or
   silently assumed?
6. **Acceptance-criteria testability.** Is every AC an observable, deterministic
   e2e assertion (concrete role + action + outcome, incl. the negative /
   unauthorized case), or is any of them vague / wall-clock-dependent /
   unassertable?
7. **Scope tiering.** Is anything marked core (P0 / `[todo]`) that is really
   cuttable (should be split to a later item), or vice versa? Over-scoped first
   items break the 10–25-turn budget.
8. **Success signal (light).** One line per milestone: how would we know this
   shipped *well* — the behavioural signal, not a vanity metric. Not a full
   metrics suite; just a sanity check that the milestone has a point.

## Output

A compact list of **net-new** findings only — do not restate what the brainstorm
already decided. For each:

> **[lens category] — affects `Fx.y`** — the specific missed fork, stated as a
> question, with a **recommended default** so the human can resolve it fast.

Then a one-line verdict: `Ready to write` (no blocking gaps) or
`Resolve N forks first` (list the item IDs).

## Hard rules

- **Flag, don't fix.** Surface gaps; never rewrite items, never pick a scope
  decision yourself, never expand the milestone. Every fork goes back to the
  human — this is direction-loop work, interactive-only, same as brainstorming.
- **Net-new only.** If the brainstorm already resolved something, don't relitigate it.
- **Recommend a default** for each fork so resolving is one word, not an essay.
