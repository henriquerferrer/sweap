---
description: "Work one blocked item with the human — prepare the fork, take their answer, and close it through a gated PR."
argument-hint: "[item-id] — defaults to the highest-ranked open blocked item"
---

Read `CLAUDE.md`, the playbook's **Blocked items (a question awaiting an
answer)** section, and the item files under `backlog.dir` first.

This command exists because a question that is merely *listed* is never
answered. `[blocked]` is surfaced in three places — the end-of-run summary, the
board, the loop's stop condition — and all three are read-only, so questions
pile up across milestones while the work they gate goes unbuilt. The agent's job
here is to make answering one take a minute instead of an evening, and then to
close the loop in the backlog so the pipeline moves.

**Resolve the item.** The first argument if given; otherwise the highest-ranked
`status: blocked` item: most transitively-gated not-yet-done items first, then
highest `carried:`, then oldest. If the resolved item is not `status: blocked`,
stop and say so — this command touches no other status. An `[attended]` item is
a *task* the human performs, not a question; that one is `/handoff`.

**Then, in order:**

1. **Brief the human.** The question from `blocked:` verbatim, what raised it
   (`followup_of:`, and the audit or item it came out of), what it gates (the
   not-yet-done items that transitively depend on it), and its carry history
   (`carried:` plus any `> **CARRIED:**` notes). Say the carry count plainly and
   once — a question that has outlived two milestones is a different ask from
   one raised this morning.

2. **Prepare the fork — and do not answer it.** Give them, in this order:
   - the options, stated as the fork actually is, not as a yes/no if it isn't;
   - a **recommended default** with its rationale, including any house idiom,
     archetype convention, or locked spec decision that bears on it;
   - the **double-turn simulation**: write out what the resulting item file
     looks like under *each* answer — the `## Spec` surface, interfaces, and
     acceptance each one implies.

   Then classify, out loud, into exactly one of three:
   - **The premise is invalidated** — shipped code has made the question moot.
     Say so and **attach the evidence** (the PR, commit, or diff). Propose
     closing it; do not close it yourself.
   - **Both branches produce the same item file** — the fork changes nothing
     downstream, so it was never a direction call. Show the two simulations that
     came out identical and propose closing it with the default.
   - **A direction call** — taste, scope, policy, cross-milestone information
     architecture. **You may not resolve this one.** Recommending a default is
     the most you may do; the answer is theirs.

   **Never talk yourself out of asking.** Having the repo in context makes it
   easy to decide a direction call is "obvious from the code" — that is the
   documented failure mode (`docs/research/2026-08-16-blocked-question-queue.md`
   §4: retrieved context makes models less likely to ask and more likely to
   assume), and it is why this step ends in a classification rather than an
   answer. When the classification is not obvious, it is a direction call.

3. **Take the answer.** One question, one answer, in this session. If they elect
   the recommended default, that is a real answer — record it as one, marked
   `(default taken)`. If they want to think about it, stop here and leave the
   item exactly as it is; do not increment `carried:` (only `/roadmap`'s
   boundary pre-flight does that).

4. **Close it — only on their explicit answer.** In a worktree (never on
   `main`), append `> **ANSWER (YYYY-MM-DD):** <their answer, verbatim>` under
   `## Notes`, keep `blocked:` and `carried:` as the record of what was asked and
   how long it waited, and then take one of two paths:

   - **The answer produces work** → `status: todo`, and **author the `## Spec`
     and `## Acceptance` the answer implies**. This is the real work of the
     command: a blocked item is a record without a full spec, and
     `roadmap-lint.sh` requires both for `todo`, so the flip is not a one-line
     edit. Write them to the same standard `/roadmap` writes items — surface,
     interfaces, out-of-scope, acceptance criteria that name their layer — then
     run `sweap-roadmap-lint <file>` and fix failures
     before the PR opens (authoring and dispatch share one spec gate).
   - **The answer produces no work** ("keep it as-is", "that's already right")
     → `status: done`, with the answer as the record and a
     `> **DONE (YYYY-MM-DD):** answered; no code change warranted` note. The
     decision *is* the outcome. Keep the file where it is rather than archiving
     it — it stays findable as the reason the behaviour is what it is, and
     `done` keeps `audit-gate.sh`'s milestone-completeness arithmetic correct.

   **Either path, if the item came out of a milestone audit** (it carries
   `followup_of: <M>` and `<backlog.dir>audits/<M>.md` has
   `disposition: blocked <id>` lines): in the same commit, rewrite every one of
   those lines to `disposition: followup <id>`, and add a dated note above the
   record's findings saying which blocks moved, that the human answered through
   `/unblock <id>`, and the answer in one line. `audit-gate.sh` fails a record
   whose `blocked` disposition names an item that is no longer `status: blocked`,
   so without this the PR goes red (a consumer: three unblocks in a row).

   Open a PR and merge it on green through the normal gate (the
   `pre-merge-gate` hook enforces greenness), then run end-of-run hygiene as
   always.

5. **Report what it released.** After the merge, name the items that just became
   unblocked and are now on the frontier. If a run is in flight it
   recomputes the frontier after every merge and will pick them up; if not,
   offer to run `/milestone`.

**What this command never does:** resolve a direction call without the human
answering in this session; run as part of an unattended run; touch an item that
is not `status: blocked`; increment `carried:`; or convert a blocked item into
`attended` — a hand-off is authored, never transitioned into, and
`audit-gate.sh --check` enforces that mechanically.
