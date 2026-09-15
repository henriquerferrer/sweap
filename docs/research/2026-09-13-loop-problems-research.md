# Six loop problems, researched and refuted (2026-09-13)

Trigger: the consumer A run of 2026-09-08..13 (54 PRs, F12 shipped, goal met) left six
things behind that looked like pipeline problems. Henrique asked for a fan-out
research workflow over papers, lab engineering posts and practitioners, one
refuter per finding, and the survivors built. This memo is the record.

Workflow run: `wf_5695428f-95f` (56 agents: 18 research sweeps, 6 merges, 32
refuters; 5.7M output tokens, 34 min). Journal:
`~/.claude/projects/-Users-me-Documents-sweap/d96e36ac-…/subagents/workflows/wf_5695428f-95f/journal.jsonl`.

## Headline

**Zero of 32 proposals survived as proposed.** Seven were `already_built`, four
`killed_before` (in substance the 2026-08-25 kill table), four `not_applicable`,
thirteen `needs_human_decision`, and four `new` but refuted on mechanism. The
refuters were told to default to refuted when uncertain and to read the repo and
the kill table first, and every one did; the useful output is not a survivor
list but (a) a set of factual corrections to the run assessment, (b) four small
kernels the refuters themselves sketched, all four built in this PR series, and
(c) a short list of decisions only Henrique can make.

Coverage caveat: the session's WebSearch budget (200 calls) ran out part-way
through the Research phase, so 8 of 18 sweeps ran fetch-only from URLs the
agent could name. X posts mostly return HTTP 402 and were reached through
mirrors when at all. Sources cited across all findings: 85 arXiv, 44
code.claude.com, 22 anthropic.com, 12 github.com; x.com 4. Treat the
practitioner modality as thin.

## Corrections to the run assessment (the refuters' evidence)

These change what the problems ARE. Each was checked against the consumer A repo,
its transcripts or its driver ledger by the refuter, and I re-checked the ones
that mattered.

1. **The audit findings do not map to the big refactor PRs.** F12.md's 29 code
   findings attribute to F12.8 (#318, 889 lines: 5), F12.1 (5), F12.2 (5),
   F12.9 (4, already a 1/2+2/2 series), F12.14 (4), F12.5 (3), F12.10 (2). Zero
   map to #309/#310/#312 (+8.8k/+10.9k/+9.0k). Defect density was highest in the
   smallest product PR. The headline "notes stay on screen after anonymisation"
   is a spec-level omission: the 4-prefix invalidation set is written into
   F12.2's Interfaces bullet, so a faithful 300-line PR would also have been
   approved; its org-messages variant is a cross-PR seam (F12.2 fixed the set,
   F12.4 introduced a disjoint key family, patients.ts is not in #310's diff)
   that no per-PR review at any size can see and the milestone audit exists for.
   "Thin reviews on big PRs" is therefore not supported by this run's data.
2. **The 10-hour stall was the orchestrator's own death, not the lane runner's.**
   Transcript rows 1648/1650: the lane's failure notification arrived at
   23:31:50Z and the orchestrator's very next turn ended in
   `API Error: 500` at 23:31:52Z. A main session whose turn ends in an API error
   is not re-driven by anything until a human types. The 9-hour usage-limit
   pause WAS auto-resumed by Claude Code ("Your claude.ai usage limit has
   reset. Continue…"). Recovery of the dead lane, when prompted, took 68 s and
   lost nothing; across 54 PRs there was no duplicate work and no split-brain.
   The real gap is supervisor liveness on `StopFailure`, not checkpointing.
3. **The debt fan-out is not enumeration.** Classifying all 170 consumer A
   discovered notes: 73 attribute themselves to a critic, walkthrough, Tier-2
   critique, audit or review pass; 8 mention a lint/check/inventory, and those
   eight mostly ask for MORE checks. Top spawner: DS.5.13 "does it feel high
   end?" (12 notes), then UI items via Tier-2 critiques. The memory note that
   blamed enumerating checks is wrong about the mechanism; the generator is
   inventory-scoped critics and audits.
4. **The reds were real.** Of 35 `failed` episodes in the driver ledger, 19 went
   `failed → superseded` (a push; 18 of 19 were genuine fix pushes) and 14 went
   `failed → pending` (same-head hand rerun, which the driver already observes
   via `run_attempt`). One empty re-push. There is no measured "re-push as
   retry" problem; the flake tax is real but small, and the manual-rerun
   doctrine is already practised.
5. **Cost is implementer context, not the audit.** Attribution over all 330
   transcripts: in-session implementers 6.93M output tokens (53%) and 2.99B of
   4.49B cached input (67%); the whole audit Workflow 1.87M (14%) / 0.38B (8%);
   refuters 7% / 2%. At list price cached input outweighs output about 7:1.
   Moving refuters/finders/first-pass review to Sonnet saves ~6-8% and reverses
   a written policy without the labeled set it requires. The lever is context
   growth in implementers (see the 2026-08-22 context-budget memo), not tier.
6. **The verification bug's cause is isolated.** Claude Code's workflow runtime
   `structuredClone`s every value that crosses a `parallel()`/`pipeline()`
   boundary (probe `wf_77f58e4b-395`: `wrapper.finding !== f`; one refuter read
   the same in the 2.1.270 binary). `milestone-audit.js` mutated the clone.
   Nothing was dropped: the harness journaled and returned all 26 verdicts.

## Per problem: proposals, verdicts, kernels

Fits are the refuters'. "Kernel" is what the refuter said would survive.

### 1. Empirical verification (5 proposals, 0 survive)

| proposal | fit | why it died |
|---|---|---|
| Reading may only kill; `confirmed` only as an on-disk execution artifact with controls, status derived by a rule step | new | no fs in Workflow scripts (killed 3-0 on 08-25 for span validation); provers cannot commit; a 3-week rebuild for a 10-line binding bug |
| PoC-as-test through a deterministic filter chain and fresh-sandbox re-runner | already_built | same fs problem; deletes the only execution-backed kill (`refuted`); evidence bar already schema-enforced |
| Durable per-ticket verdict ledger + reconciler that aborts the record | killed_before | journal.jsonl already IS that ledger; the in-run abort is the circuit breaker killed and test-guarded; its count invariant (26 == 26) would have PASSED on F12 |
| Redesign the refuter panel against agreeableness (claim-only context, minority veto, calibration) | killed_before | minority veto explicitly deferred in TUNING; one prompt change already moved the kill rate 63% → 2.7%; no measurement |
| Planted canaries, TPR/TNR per run | new | a canary costs a prover + worktree to test plumbing a node test proves free; a sandbox that cannot run `just` discards a whole batch |

Kernels, **built** (PR #51 + this PR): bind proofs by index, never by
reference; `proven: lost` distinct from `unverifiable`; `proofs_dispatched` /
`proof_confirmed` / `proof_refuted` / `proof_unverifiable` / `proofs_lost:`
frontmatter (additive, emitted only when Validate ran); per-block
`refuted_votes: x/y` and `proven:` lines, which accumulate the labeled set the
TUNING comment says a recalibration needs; `audit-gate.sh` refuses
`proofs_lost > 0` without `proofs_lost_accepted:`, mirroring `unscored:`.

### 2. Debt fan-out (6 proposals, 0 survive, 5 need a decision)

| proposal | fit | why it died |
|---|---|---|
| Diff-scoped checks with committed baselines; never file pre-existing violations | not_applicable | 8/170 notes come from checks; consumer A already built and drained exactly this (lint-data-layer allowlist, Rule D) and it converged by tracking burn-down items, which the proposal bans |
| Admit an item only on reproduction or spec failure; discard is a success verdict | needs decision | reverses "gap notes promote automatically" (08-22) and "an agent never discards work" |
| Budgeted gardening lane against golden principles | needs decision | a gardening scan IS an enumerating critic; same 1.7N, relabelled |
| Fix-forward at discovery; file only what a cheap subagent could not finish | needs decision | the reviewer cannot fork a fixer (no nesting, reviewer never fixes); becomes a prompt rule with no budget |
| Expire untouched notes, cap the queue, per-milestone debt budget | needs decision | finders audit one commit range, not the repo, so "anything real is re-observed" is false; TTL deletes refuter-confirmed findings unseen |
| Filing is a privilege; suspend sources by not-useful rate | needs decision | keys on the uncalibrated 3-refuter kill as if it were Google's human "Not useful" click |

Kernel: none buildable without a decision. The decision is one question, below.

### 3. Flaky tests at the gate (5 proposals, 0 survive)

| proposal | fit | why it died |
|---|---|---|
| Driver-owned retry ladder (rerun → rerun-without-patch → block), k sized by a ledger | already_built | rung 1 by hand is doctrine + observed via `run_attempt`; rungs 2-3 need `workflow_dispatch` (a CI edit); k-by-test-identity is the predictor Haben et al. show misses 76% of faults; Google's FACF applies a floor of 8 reruns to everything, the opposite of "no history → block" |
| Classify before rerunning (timeline + symptom clustering) | needs decision | depends on auto-rerun (D5, out of scope) and on a JUnit/JSON reporter uploaded every run (a CI edit, plus storage on an account that hit 100%) |
| Flake ledger FSM with expiring human-owned quarantine | new | no per-test signal reaches the driver (rollup level by design); sized for Uber |
| Impact-scored filing with three-way retry | new | "retry on a different host" needs a second e2e host; consumer A has one label-fenced runner |
| Deflake acceptance contract (reproduce, N consecutive passes, before/after rates) | needs decision | template-only change; helps only if "file a flake note when a rerun turns green" is also a rule; CPU budget is Henrique's |

Kernel, **built** (separate PR, `feat/sweap-merge-rerun`): the manual
`sweap-merge rerun <pr> --reason` verb the 08-25 memo already specced (one per
head SHA, refused when the same workflow is red on the base tip, recorded in
the state file), and a discovered note filed automatically when a rerun turns
green, keyed by workflow path so re-occurrences append rather than duplicate.
The driver still never reruns on its own.

### 4. Review depth vs diff size (6 proposals, 0 survive)

| proposal | fit | why it died |
|---|---|---|
| Diff-size budget at planning, size-capped PR series, zero-finding-on-oversize = re-run | new | correction 1: density was zero in the largest PRs; label is agent self-certified; re-run same model/prompt/diff is the forbidden re-roll; "split when >30 turns" already doctrine |
| Tidy-first structural stack with mechanical equivalence | not_applicable | premise (29 defects in the refactor PRs) is false; no mechanical-equivalence tool for TSX |
| CI-job-layer fan-out (shards aggregated deterministically) | new | Rewind's own post refuses >10k diffs rather than sharding; Cursor abandoned multi-pass majority vote; and it is a `.github/` edit |
| Risk-weighted second pass from a structural risk map | already_built | cited papers predict review EFFORT, not defects; `review.focus` already routes attention |
| Elicitation/decision split with calibrated probabilities | not_applicable | the reviewer elicited nothing on #309/#310/#312 to swallow |
| Scoped cited rules fed back from the audit | already_built | `review.focus` + repo CLAUDE.md; evidence bar already in the managed prompt |

Kernel, **built** (this PR): a `::notice::review-size: +A -D across F files;
verdict: …` line in the managed workflow's verdict step. A diagnostic only, so
the next audit can correlate size with findings on real data before anyone
proposes a cap again.

### 5. Failure recovery (5 proposals, 0 survive)

| proposal | fit | why it died |
|---|---|---|
| Progress heartbeat + supervisor wake-up | needs decision | the supervisor died on the same 500; nothing re-drives a main session after StopFailure |
| One live owner per worktree, fenced lease | not_applicable | zero owners for 10 h, not two; parallel-runs spec excludes multi-coordinator |
| Worktree + stage ledger checkpoint, commit-on-stop | already_built | pick-up-cold + retained task-id transcript recovered in 68 s; Stop does not fire on API errors, StopFailure does |
| Class-targeted recovery with persisted budgets | needs decision | no process can run the classifier at the moment it is needed; mis-targets the forbidden `attended` transition |
| Turn on usage-limit auto-continue | already_built | it was on and it fired (21:01Z) |

Kernel, **built** (this PR): `hooks/stop-failure-notify.sh` on `StopFailure`
(every error class). While a run is active it appends a `stalled: <ts> <type>`
line to `.claude/sweap-run.md` and fires a desktop notification; the playbook's
pick-up-cold step 5 reads the line. The docs are explicit that this event
cannot re-enter the turn (output discarded except side effects).

**Superseded upstream, found by the decision refuters (2026-09-14):** Claude
Code 2.1.269 (2026-09-11) "Fixed `/goal` runs silently stalling after API
errors, network drops, or token limits: the goal now retries with backoff, or
pauses and says why". The consumer A run was on 2.1.263; this machine is on
2.1.270. The hook now reads the installed version and says which case applies
(retrying by itself, check in ~25 min; or nothing retries, send a message
now). What remains open is only the outage that outlasts the harness's retries.

### 6. Cost (5 proposals, 0 survive)

| proposal | fit | why it died |
|---|---|---|
| Per-stage cost ledger, cache-shaped fan-outs | already_built | audit fan-out is already cache-shaped; no per-agent usage surface to a script |
| Bound the review loop (round cap, no-progress detector) | needs decision | the 7-round item was in-session pre-PR; what happens after round 3 is Henrique's |
| Confidence-gated early termination | killed_before | 2-then-1 refuter exit already the shipped arithmetic; the rest collides with locked rules |
| Deterministic checks before LLM checks, retry-once | killed_before | retry-once is the deferred auto-rerun; ordering already built |
| Tier model/effort per stage | needs decision | correction 5: targets 25% of output and 10% of cache; reverses Model policy before the labeled set exists |

Kernel: none without a decision. What does hold: per-stage `effort` is a real
runtime lever and refuters run at `high` on bounded read tasks.

## Decisions, refuted (2026-09-14, `wf_1e89f63e-749`)

Henrique asked for the six decisions to be explained and refuted like the
proposals. Each option got one refuter (17 agents, 1.7M output tokens) reading
the repo, the memos and consumer A data. Result per decision, survivors in bold:

| decision | options | verdict |
|---|---|---|
| 1 promotion | keep / cap / gate / critics | **none survive.** keep: 78 debt items (22 FP + 56 promotable notes) would run before 19 F13 items in a 54-PR run, and 44 of 60 live gap notes were filed from DU/DV branches, i.e. debt begets debt. cap: no severity field exists to sort by; four readers re-derive "debt" from files (the 08-25 3-0 kill of filtering one reader); the run's stop rule refuses to stop on runnable items. gate: "user-visible" lets the UI-critic bulk through and parks the tenancy/GDPR/authz notes; it is agent self-classification. critics: neither critic writes to the inbox (all 104 notes are implementer-filed); the audit gate rejects dispositions that are not `followup_of:`; DS.5 WAS that consistency milestone and was the biggest spawner. What works today without a mechanism: at `/roadmap`, put `depends_on: [F13]` on the follow-ups that should wait; the frontier skips them and releases them when F13 completes. |
| 2 fix-forward | **keep** / narrow | keep is the shipped doctrine and the last run obeyed it (30 notes, 0 scope-creep flags); every follow-up landed as a 400-2300 line change with a test, so none was a one-liner. narrow: 57 of 60 gap notes are about a missing test/lint/sweep, which it forbids; nothing can check the disclosure heading (the gate ignores PR prose by design). |
| 3 stalled run | **notify** (with change) / cron / upstream | 2.1.269 already retries; the hook wording was false and is fixed. cron: session-scoped, cannot tell a hiccup from a filled context, restarts itself without a grant; the human-granted form is `/loop 1h continue …` typed by the human. upstream: closed bug. |
| 4 auto-rerun | **manual** (with change) / auto1 | Last run: 14 hand reruns within ~1.5 min (10 green), 18 of 28 reds real and fixed by a push; main green throughout, so "base green" screens nothing. auto1 would fire ~33 reruns on one fenced runner, most on commits about to be replaced. Changes asked for and made on #52: cap per (head, workflow) not per head; a PreToolUse redirect from bare `gh run rerun` to the verb. |
| 5 review rounds | openpr / blocked / fresh | **none survive, and the premise was wrong.** The 7-round item (DV.9, PR #273) was ONE reviewer re-messaged five times, each round approving the last fix and finding a new class of remark, ending on comment wording; the CI reviewer approved on its first pass and it merged in 26 min. No item ever reached a third fresh needs-work. openpr: the CI reviewer posted 92 approve / 0 needs-work across #255-#320, so it hands a confirmed objection to a gate that has never said no. blocked: reviewer findings are not a human question, and the self-close default reverses "the agent prepares; the agent does not answer". fresh: pays a second implementation to chase reviewer drift. Built instead: a re-review is a NEW dispatch, never a message to a live reviewer; `### Advisory` remarks never flip the verdict. |
| 6 model tier | **keep** (with change) / sonnet / effort | Refuters are ~2-3% of spend; the labeled set does not exist and one wording change already moved the kill rate 63% → 2.7%. Change made: effort is a named TUNING value stamped into the record (`find_effort:` etc.) so rows stay comparable. |

Corrections to this memo from that pass: the 2.1.269 changelog (above); the
CI reviewer's 92/0 verdict ratio, which means "CI reviewer as the fallback
gate" is not a gate; the DV.9 round count was reviewer drift, not implementer
failure.

## Decisions for Henrique (the thirteen, folded to six)

1. **Promotion.** Keep automatic `gap` promotion and debt-first (08-22), or add
   `debt.cap: N` to `## sweap config` so at most N follow-ups run ahead of the
   product milestone (ordered by audit severity then age, remainder waits), or
   promote only gaps whose `why` names a user-visible failure and send the rest
   to `/roadmap` with the direction notes. Given correction 3, also: should
   Tier-2 UI critics file into the inbox at all, or into a scoped consistency
   milestone you sequence yourself?
2. **Fix-forward exception.** Allow an implementer (never the reviewer) to fix a
   `gap` whose fix stays inside files the item's diff already touches, adds no
   test/lint/ratchet/inventory, and is disclosed in the PR body?
3. **Re-driving a stalled run.** The notify-only hook is built; a hook cannot
   re-enter the turn. Re-driving needs something outside the session: a
   recurring cron nudge created at `/milestone` kickoff and deleted at run end
   ("if the run file has a `stalled:` line and no `ended:`, continue"), which
   costs a paid orchestrator turn per interval and is autonomy you did not
   grant. Or file upstream as a `/goal` defect ("an errored turn does not
   re-enter the goal loop") and live with the notification.
4. **Auto-rerun.** Reverse D5 and let the driver rerun a red run ONCE
   automatically when the same workflow is green on the base tip? The evidence
   (correction 4) says the manual verb is enough; recommendation: no.
5. **Review rounds.** After a third in-session `needs-work`: open the PR and let
   CI + the managed reviewer gate, or go `blocked` with the findings as the
   question, or one fresh-worktree attempt then either?
6. **Model tier.** Not now: correction 5 says the money is elsewhere and the
   labeled set for judging a refuter change is what this PR starts collecting.

## What was built from this memo

- PR #51 — prover verdicts applied by index; `proven: lost`.
- This PR — the reading/running join in the record and stats; `proofs_lost:`
  gate rule; reviewer `review-size` notice; the `StopFailure` notify hook and
  its version-aware `stalled:` run-file line; effort as a stamped TUNING
  value; the re-review-is-a-new-dispatch rule and the reviewer's `Advisory`
  section; this memo.
- `feat/sweap-merge-rerun` — manual rerun verb + flake note (separate PR).
- Consumer A follow-up (not done here, needs your go): regenerate
  `roadmap/audits/F12.md` from the journal's 26 verdicts and re-triage; 25
  findings gain sandboxed-run evidence and become bucket-1 candidates, one FP
  item rests on a refuted claim.
