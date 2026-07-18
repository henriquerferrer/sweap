# sweap — parallel roadmap runs: frontier scheduling + merge queue (design)

**Date:** 2026-07-18
**Status:** approved (brainstorm) → next: implementation plan
**Author:** Henrique + Claude

## Context

Today the loop is deliberately serial: one session drains a milestone top-down,
always picking the top unblocked `[todo]` item. Henrique authors large backlogs
ahead of time and wants runs to **move faster where the dependency graph
allows** — parallel where `Depends on:` permits, serial where it doesn't — while
keeping management down to a glanceable status surface.

Two deep-research passes (adversarially verified, cited in Evidence below)
ground this design. They validated merge serialization as the converged
industry pattern, validated the skepticism about a fat orchestrator, killed the
"skip re-verification when changes look independent" fast-path, and set the
default concurrency width.

## Goals

- Run mutually-independent roadmap items concurrently, degrading gracefully to
  today's serial loop when the frontier is width-1.
- Keep `main` always-green under concurrent merges (combined-state gating).
- Management surface = one glanceable board file + existing notifications; the
  human's time stays on direction (roadmap authoring, blocked answers), never
  on scheduling mechanics.
- Preserve every existing safety rail unchanged: per-feature worker loop, TDD,
  fresh-context review, review dimensions, hook-enforced merge gate, audits.

## Non-goals

- **No skip-on-judged-independence.** Neither file-disjointness nor LLM
  judgment ever skips the combined-state CI run (see Locked decision 4).
- **No speculation trees / batching / parallel merge machinery** (SubmitQueue-
  style). Unnecessary below hundreds of changes/day.
- **No multi-coordinator or cross-session locking.** Exactly one coordinator
  session runs at a time (same as today's one autonomous session).
- **No cloud fan-out.** Local worktree agents only; revisit later if desired.

## Locked decisions

1. **Architecture: thin coordinator, fat gates.** Workers are today's
   per-feature loop, unchanged, one item to a clean mergeable state in an
   isolated worktree. The coordinator only: computes the frontier, dispatches
   up to K workers, runs the merge queue, maintains the board. It holds no
   implementation detail — workers return compressed summaries (~1–2k tokens);
   all durable state lives on disk (ROADMAP.md, board, per-item progress
   files, git, PRs). Killing the coordinator loses nothing; any fresh session
   rebuilds state from disk.
2. **Frontier scheduling.** Runnable frontier = every unblocked `[todo]` item,
   debt-first, top-of-file order — `/milestone`'s existing rules taking the
   top K instead of the top 1. Claims live only on the board file. Judgment
   rule (scheduling, no machinery): avoid co-dispatching items that plausibly
   touch the same surface; two `migration`-tagged items never run together.
3. **Merge queue: FIFO, always-verify, speculative rebase.** Before merging
   PR *n*: rebase onto current `main`, `git push --force-with-lease`, wait for
   CI green on the rebased head, `gh pr merge --squash`. The moment a merge
   lands, the coordinator immediately rebases the next queued PR so its
   combined-state CI overlaps idle queue time (merge-train style, scaled to
   K=2–3). Diff-disjointness may inform queue **order** only — wrong ordering
   wastes one CI run; it never authorizes skipping the gate.
4. **No verification skip, ever.** Evidence verdict: every industrial skip is
   either a formal proof over a hermetic build graph (Uber SubmitQueue — where
   even disjoint build-target sets were proven insufficient) or a measured
   statistical skip backstopped by post-land full testing + automated
   culprit-finding + rollback culture (Meta, Google). sweap has neither
   precondition and gains ~nothing from skipping once speculative rebase hides
   the latency.
5. **Hook-enforced base-freshness.** `pre-merge-gate.sh` additionally queries
   `gh pr view <n> --json mergeStateStatus` and denies merge when `BEHIND` —
   fail-closed, recoverable deny, same semantics as the greenness check. This
   makes the rebase-first rule mechanical, not behavioral. Covered by a new
   case in `pre-merge-gate.test.sh`.
6. **Board file = status surface = coordinator memory.**
   `.claude/sweap-board.md`, gitignored (scaffold adds the entry). One line
   per in-flight item: status, current step, worker/worktree/branch, PR link,
   blocked question. Queue order recorded here. Being both the human's
   at-a-glance view and the coordinator's externalized state, the two cannot
   drift.
7. **Concurrency width.** New sweap-config key `parallel:` — default `1`
   (today's behavior, no silent change for existing projects); set `2`–`3` to
   enable; hard cap `4`. Evidence: returns are non-monotonic beyond ~4 and
   coding parallelizes worse than research; width is really a function of
   provable track independence, so widen only when the frontier genuinely
   contains independent items — and only after instrumentation (below) says
   parallelism is paying.
8. **Instrumentation.** End-of-run summary gains: max/mean concurrency
   achieved, rebases performed, conflicts hit (textual vs. CI-caught
   semantic), queue-caused CI reruns, rough wall-clock vs. estimated serial.
   After 1–2 milestones this decides widen-vs-retreat with own data.
9. **CI determinism is a standing constraint.** A merge queue amplifies a
   flaky suite (every flake blocks the queue head). Flaky tests get fixed or
   quarantined-with-flag per existing doctrine, never retried-until-green.

## Failure handling (all reuse existing doctrine)

- **Worker blocked/ambiguous** → escalate-don't-guess: item `[blocked]` with
  the question, notify, coordinator fills the slot with the next frontier item.
- **Worker dies mid-feature** → worktree/branch/progress file persist; a fresh
  worker is dispatched onto the same worktree and resumes from disk (playbook
  pick-up-cold pattern).
- **CI red after rebase** (the semantic conflict the queue exists to catch) →
  owning worker gets the standard ~3 distinct fix attempts, then `[blocked]`
  with the PR left open.
- **Coordinator dies** → board + ROADMAP + PRs + worktrees reconstruct the run;
  `claude --continue` or a fresh session resumes.
- **ROADMAP.md status conflicts between queued PRs** → absorbed by the rebase
  step, resolved by the owning worker (single-line status edits; serialization
  guarantees one resolver at a time).

## Changes by component

| Component | Change |
|---|---|
| `plugin/templates/CLAUDE.md` | `parallel: 1` key + comment in the sweap config block |
| `plugin/playbook/agentic-loop-playbook.md` | New "Parallel runs (coordinator mode)" section; soften the "throughput lever is not parallelism" rationale to the evidence-backed version (loop tightness still primary; frontier parallelism recovers CI dead time on independent items) |
| `plugin/commands/milestone.md` | Read `parallel:`; when ≥2 the printed goal is unchanged but the run operates in coordinator mode |
| `plugin/hooks/pre-merge-gate.sh` | `BEHIND` denial (fail-closed, recoverable) |
| `plugin/hooks/pre-merge-gate.test.sh` | Test case for the `BEHIND` denial |
| `plugin/hooks/scaffold.sh` | Gitignore entry for `.claude/sweap-board.md` |

Untouched by design: worker loop, review dimensions, audit workflow,
deferred/blocked lifecycle, notifications, post-merge hooks.

## Testing

- Hook unit test: `BEHIND` → deny (recoverable), green+up-to-date → allow,
  gh error → recoverable deny.
- Supervised trial: one milestone run with `parallel: 2` on a sandbox project,
  human watching (build-order step 3 analog), before unattended use.
- Instrumentation output reviewed after the first two parallel milestones;
  keep/widen/retreat decision recorded in the playbook.

## Evidence (deep-research runs, 2026-07-18)

Two adversarially-verified research passes (session transcripts; ~105 agents
each, 3-vote verification per claim):

1. **Parallel-agent orchestration.** Merge serialization with combined-state
   CI is the converged pattern (Uber SubmitQueue, GitHub Merge Queue, GitLab
   merge trains, Bors, CAID) — per-branch green CI provably misses "real
   conflicts" (~5% at 2 concurrent potentially-conflicting changes, EuroSys
   2019). Fat orchestrators fail via context rot; the production mitigation is
   externalized state + compressed worker summaries (Anthropic multi-agent /
   context-engineering / long-running-harness posts). One-feature-per-session
   to mergeable state is the critical worker granularity. Returns non-monotonic
   beyond K≈4 (CAID; its headline speedups were refuted in verification —
   expect dead-time recovery, ~1.5–2x on independent items, not K-x).
2. **Verification skipping.** No production system skips combined-state
   verification on per-change judged independence: skips are proofs over
   hermetic build graphs (Uber; even target-disjointness was insufficient —
   7.9% of changes alter the build graph) or measured-recall statistical skips
   conditioned on post-land full testing, ~98%-accurate culprit finding, and
   rollback culture (Meta ~0.1% accepted miss + stabilization stage; Google
   optimistic presubmit + TAP postsubmit — which still saw ~20k
   individually-validated culprits break main in 3 months). No surviving
   evidence on LLM reliability at judging behavioral independence.

Grounding: the Anthropic recursive-self-improvement essay's division of labor
(human time compresses toward direction-setting and oversight; the doing costs
~nothing) motivates the coordinator owning scheduling mechanics and the human
surface being roadmap + board only.

## Open items

- Measure sweap's actual conflict rate and parallel speedup at K=2 (own data;
  the Uber-scale rates don't transfer).
- Revisit K default and the co-dispatch judgment rule after two instrumented
  milestones.
