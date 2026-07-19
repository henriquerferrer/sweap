# sweap — backlog substrate: file-per-item roadmap + dispatch gates (design)

**Date:** 2026-07-19
**Status:** approved (research + Henrique's go) → next: implementation plan
**Author:** Henrique + Claude
**Extends:** 2026-07-18-parallel-roadmap-runs-design.md (frontier + merge queue)

## Context

Two further deep-research passes (2026-07-19, ~105 adversarially-verified
agents each) asked (a) how labs/practitioners manage roadmaps for parallel
coding-agent pipelines and (b) what substrate the backlog should live in.
Verified conclusions that drive this design:

1. **No verified system runs parallel agents off a single mutable markdown
   file, and none uses a SaaS tracker as source of truth.** Anthropic's
   parallel-Claude C compiler coordinated entirely via one-file-per-task locks
   in a `current_tasks/` dir with git push/pull as the only concurrency
   mechanism; Claude Code agent teams use a local file store with file-locked
   claims; GitHub's spec-kit keeps in-repo markdown as authoring truth and
   treats GitHub Issues as a derived export (`/speckit.taskstoissues`).
2. **Markdown is not the problem; shared-file mutation is.** A 9,649-run
   format study found markdown vs JSON/YAML makes no significant difference to
   agent reading accuracy (p=0.484). Every surveyed system avoids concurrent
   mutation of one file via per-task granularity or locking — never by
   switching serialization format.
3. **Agent-self-reported status is unreliable** (Anthropic's own agent-teams
   docs: teammates "sometimes fail to mark tasks as completed"). Status must
   be verified/gated, not trusted.
4. **Spec-first delegation is the parallel-dispatch prerequisite.** Vague
   delegation is the dominant failure; the effective spec is self-contained —
   names files/surface, interfaces, out-of-scope, and an e2e verification
   step. Decompose along feature/interface boundaries (vertical slices), never
   role phases; pre-declare the contract when two concurrent items share one.
5. **Event-driven dependency release beats waves and stubs**: dispatch an item
   when its upstream items have actually merged, so it plans against real
   interfaces (Co-Coder: 45–52% latency cut with higher pass rate; direction
   trustworthy, magnitudes greenfield-benchmark-derived).
6. **Review bandwidth, not agent capacity, is the practitioner-converged
   concurrency cap** (Willison: "I can only focus on reviewing and landing one
   significant change at a time"; Ronacher: "it's only so much my mind can
   review!").
7. Tightly coupled chains gain nothing from parallelism (Co-Coder's own
   limitation) — route them to an explicit serial lane.

## Goals

- Remove the backlog file as a concurrent-write hotspot (parallel item PRs
  currently all edit `ROADMAP.md` status lines).
- Make the pre-dispatch spec gate mechanical (lintable), not judgment-only.
- Encode coupled-chain serialization (`lane:`) and keep frontier release
  event-driven.
- Simplify the fragile header-matching rules (`### …` + "never match the
  legend line" caveats) into trivial frontmatter scans.

## Non-goals

- No GitHub-Issues/Linear integration (may later become a derived *view*;
  never source of truth).
- No YAML/JSON conversion of item bodies — markdown stays (evidence: format
  doesn't matter; granularity does).
- No new locking machinery: git merge semantics + the existing merge queue
  remain the only concurrency control (per the C-compiler precedent). The
  gitignored board stays the only ephemeral store.

## Locked decisions

1. **Two-layer substrate.**
   - *Durable, in-repo:* `ROADMAP.md` (`backlog.file`) becomes a thin
     **index** — milestone list in priority order + later-milestones sketch,
     never per-item status. Items live **one file each** under `roadmap/`
     (new config key `backlog.dir`, default `roadmap/`): `roadmap/<ID>.md`.
     Dropped items move to `roadmap/archive/` (`status: dropped` +
     `dropped_reason:`) — reversible soft-delete, replacing the index's
     "Archived / dropped" section.
   - *Ephemeral, out-of-repo:* `.claude/sweap-board.md` unchanged (claims,
     queue order) — already gitignored by the scaffold.
2. **Item file schema.** Flat single-line YAML frontmatter (greppable;
   `depends_on` inline `[a, b]`): `id` (must equal filename), `title`,
   `status` (`todo|blocked|deferred|done`, `dropped` in archive only),
   `depends_on` (item IDs and/or bare milestone tags), `review-dimensions`,
   optional `lane`, optional `followup_of` (milestone tag → audit-debt item),
   `premise` (required when deferred), `blocked` (required when blocked;
   the question). Body: `# <ID> — <title>`, `## Spec` (bullets **Surface**,
   **Interfaces**, **Out of scope**), `## Acceptance (e2e)`, optional
   `## Notes` (ANSWER threads, UNBLOCKED annotations).
3. **Mechanical spec gate: `roadmap-lint.sh`.** Shipped in `plugin/hooks/`,
   run (a) by `/roadmap` on every new/changed item file before the milestone
   PR opens and (b) by the dispatching session (serial or coordinator) before
   any item is dispatched. Checks: frontmatter present/valid, `id`==filename,
   status enum, deferred→`premise:` present, blocked→`blocked:` present,
   item-level `depends_on` entries resolve to existing files, `## Spec` +
   `## Acceptance` present with the three Spec bullets, and (todo items) no
   unfilled `<…>` placeholders. Fail = item not runnable: fix mechanically or
   escalate. Authoring and dispatch share this one gate.
4. **Status flips ride the item's own PR** (unchanged rule, now conflict-free
   by construction: disjoint files). Verified, not trusted: after a merge
   lands, the coordinator/serial loop confirms the merged file on `main`
   reads `status: done`; a missed flip is a worker error fixed through the
   next gated PR — never a direct commit to `main`.
5. **Frontier order** (replaces "top-of-file order"): debt first
   (`followup_of:` set), then milestone order as listed in the index, then
   numeric item order within a milestone (numeric segment compare, F1.9 <
   F1.10). Unblocked: item-level dep → dep file `status: done`; bare
   milestone dep → that milestone complete (all its item files done).
   Dispatch stays **event-driven**: recompute on every merge/block and fill
   the freed slot immediately — never wait out a "wave".
6. **`lane:` serialization.** Items sharing a `lane:` value never co-dispatch
   (declared coupled chain ⇒ serial by construction). Complements the
   existing judgment rule and the two-`migration`s-never rule.
7. **Review-bandwidth cap made explicit.** A worker slot is held until the
   item's PR *merges* (not until code-complete), so open unmerged PRs consume
   width — this is the doctrine rationale for K staying small (≤4) and the
   practitioner-converged constraint named in the playbook.
8. **Legacy migration is agentic and one-time.** `/roadmap` and `/milestone`
   pre-flight: if `backlog.file` still contains item headers (`### … [tag]`),
   run a single migration PR through the gate — split items into
   `backlog.dir` files (parsed fields → frontmatter; audit-follow-up sections
   → `followup_of:`; `Premise:` → `premise:`), rewrite the index, delete the
   legacy sections. No shell parser; the session performs the split and lints
   every produced file.

## Changes by component

| Component | Change |
|---|---|
| `plugin/hooks/roadmap-lint.sh` (+ `.test.sh`) | NEW — the mechanical spec gate |
| `plugin/templates/ROADMAP.md` | Rewrite as thin index |
| `plugin/templates/roadmap/.gitkeep` | NEW — scaffold creates the items dir |
| `plugin/templates/CLAUDE.md` | Backlog pointer, `backlog.dir` key, standing-prefs wording |
| `plugin/hooks/scaffold.sh` | TODO message mentions item-file format |
| `plugin/playbook/agentic-loop-playbook.md` | New "Backlog format" section; config keys; deferred/audit/coordinator/hygiene/pick-up-cold sections reworded to frontmatter scans; spec-gate, lane, event-driven, review-bandwidth doctrine |
| `plugin/commands/roadmap.md` | Item-file authoring, lint-before-PR, legacy pre-flight, frontmatter debt surfacing |
| `plugin/commands/milestone.md` | Frontmatter deferred/debt scans, lint-before-dispatch, legacy pre-flight |
| `plugin/commands/milestone-audit.md` | Buckets 2/3 write item files (`followup_of:` / `blocked:`) |
| `plugin/commands/loop-schedule.md` | Goal wording → backlog = index + item files |
| `plugin/skills/milestone-cross-check/SKILL.md` | Draft = item files; format pointer to playbook |
| `plugin/workflows/milestone-audit.js` | `whenToUse`/scope wording → item files' `status: done` |

Untouched: worker loop, review dimensions, merge queue mechanics, pre/post
merge hooks, board format, notifications.

## Testing

- `roadmap-lint.test.sh`: valid item passes; each validation rule has a
  failing case; bare-milestone dep allowed; done item with placeholders passes
  (placeholder rule gates todo only).
- Existing `pre-merge-gate.test.sh` stays green (no hook changes).
- First real use: next `/roadmap` run on a live project performs the legacy
  migration under supervision.

## Evidence

Research session 2026-07-19 (two deep-research workflow runs, 3-vote
adversarial verification; key sources: Anthropic building-c-compiler +
agent-teams docs + building-multi-agent-systems post, Cognition
dont-build-multi-agents / multi-agents-working, GitHub spec-kit, Co-Coder
arXiv 2606.00953, SPOQ arXiv 2606.03115, format study arXiv 2602.05447,
practitioner posts: Willison, J. Vincent, Cherny, Steinberger, Ronacher).
Full verified-claim record in the session's memory file
(`research_parallel_roadmap.md`).
