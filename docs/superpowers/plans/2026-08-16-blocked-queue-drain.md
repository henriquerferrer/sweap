# Blocked-Queue Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `[blocked]` the drain that `[attended]` already has — a `/unblock` command that walks one question and closes it through a gated PR, a `/roadmap` pre-flight step that works the queue at the milestone boundary before the brainstorm, and a `carried:` counter that makes an unanswered question age visibly and time out.

**Architecture:** No new status — an answered blocked item flips `blocked → todo` (or `done` when the answer produces no work) and rejoins the ordinary frontier. One new frontmatter key (`carried:`), one new command file, one new pre-flight step, non-failing `AGING:` output on `audit-gate.sh --check` (which `/roadmap` already runs at exactly that moment), and a carry badge on the board's existing blocked column. **No new enforcement mechanism** — nothing here is a shortcut that pays, so the mechanism budget stays spent where it does.

**Tech Stack:** bash + git (offline, deterministic); house test harness style (mktemp fixture dirs, `check <desc> <wanted-exit> <file>`); command/playbook markdown; the board's plain-ESM lib + page.

**Spec:** `docs/superpowers/specs/2026-08-16-blocked-queue-drain-design.md` — read it before starting any task. **Research:** `docs/research/2026-08-16-blocked-question-queue.md` — §3, §4 and §5 of the spec are decided by it, not by taste; do not "improve" the agent-prepares-never-resolves rule without reading §4 of the memo first.

## Global Constraints

- **Flat frontmatter contract**: single-line keys, inline `[a, b]` lists; parse with awk/sed exactly like `roadmap-lint.sh`; never grow a YAML parser.
- **Bash 3.2 compatible** (macOS default): no associative arrays; use awk for aggregation.
- **`audit-gate.sh` exit codes are unchanged**: `AGING:` is informational like `DEFERRED:`/`STALE:` and must never contribute to `$fails`. `post-merge-auditcheck.sh` greps `^DEFERRED:` specifically, so the new prefix is inert there — verify that stays true.
- **Backward compatibility**: `carried:` is optional and absent from every existing item file. Nothing may fail for want of it, and an item without it reads as `carried: 0`.
- **Uncommitted files are skipped, not failed** — the existing `--check` idiom; `/roadmap` writes item files in the working tree before they are committed.
- All new files get the house-style header comment explaining WHY, not just what.
- Command prose is doctrine: it must state the never-rules in the imperative, because the model reading it is the enforcement for everything §6 of the spec deliberately did not mechanise.

---

### Task 1: `carried:` in the spec gate (`plugin/hooks/roadmap-lint.sh`)

- [x] After the `blocked:`/`handoff:` status-conditional block (~line 60–70), validate `carried:` **when present**: must match `^[0-9]+$`. Fail with `carried: must be a non-negative integer (the count of milestone boundaries this question has survived unanswered)`.
- [x] Do **not** require it on blocked items and do **not** reject it on other statuses — it is retained after unblocking as provenance, exactly like `blocked:` is retained on `consumer-a`' `FL.1`.
- [x] Add cases to `plugin/hooks/roadmap-lint.test.sh`: blocked item with no `carried:` passes; `carried: 0` and `carried: 3` pass; `carried: two` and `carried: -1` fail; `carried: 2` on a `status: todo` item passes (post-unblock provenance).

### Task 2: `AGING:` surfacing (`plugin/hooks/audit-gate.sh`)

- [x] In the `--check` block, after the hand-off provenance loop and **before** `exit "$fails"`, add a loop over `"${BACKLOG_DIR}"*.md` selecting `status: blocked` items (same id/dot-segment filter the hand-off loop uses).
- [x] For each, `printf` one line: `AGING: blocked <id> — carried <N> milestone boundary(ies); <first 100 chars of blocked:>… Answer it with /unblock <id>, or it is asked mandatorily at carried 2.` Use `fm_get "$f" carried` defaulting to `0`.
- [x] Header comment must say **why this is informational and not a failure**: an unanswered direction call is legitimately deferrable (unlike audit debt), the memo's evidence says the intervention is a documented pending-state at the transition rather than a block, and `/roadmap` already reads this output at exactly the boundary where it matters.
- [x] Must not touch `$fails`. Add a test to `plugin/hooks/audit-gate.test.sh`: a fixture repo with one blocked item and no audit debt exits **0** and prints an `AGING:` line; a fixture with blocked items and real audit debt still exits 1 with the `FAIL:` line present and the `AGING:` line alongside it.
- [x] Confirm `post-merge-auditcheck.sh`'s `grep '^DEFERRED:'` is unaffected (read it; do not change it).

### Task 3: `/unblock` command (`plugin/commands/unblock.md`)

- [x] New command file, structurally parallel to `plugin/commands/handoff.md` — same frontmatter shape (`description`, `argument-hint: "[item-id] — defaults to the highest-ranked open blocked item"`), same "read CLAUDE.md + the playbook section + the item files first" opener, same numbered-step body.
- [x] **Resolve**: the argument if given; otherwise the highest-ranked `status: blocked` item by the spec's §4 ranking (transitive not-yet-done dependents, then `carried:`, then age). If the resolved item is not `status: blocked`, stop and say so.
- [x] **Step 1 — Brief**: the question verbatim, what raised it (`followup_of:`), what it gates, and the carry history.
- [x] **Step 2 — Prepare, never resolve**: state the options, a recommended default with rationale, and the **double-turn simulation** — write out what the resulting item file looks like under each answer. If the two are identical, say so and propose closing it as not-a-question. If shipped code has invalidated the premise, propose closing it *with the evidence* (PR/commit/diff). In all other cases it is a direction call and the agent may not answer it.
- [x] **Step 3 — Close, only on the human's explicit answer in-session.** Two outcomes, both in a worktree, both through the normal gate:
  - answer produces work → `status: todo`, `> **ANSWER (YYYY-MM-DD):** <verbatim>` under `## Notes`, **and author the `## Spec` / `## Acceptance` the answer implies** (lint requires both for `todo` — this flip is not a one-line edit), then run `roadmap-lint.sh` on the file before opening the PR;
  - answer produces no work → `status: done` with the answer recorded (the `FL.1` precedent), keeping the item findable at top level rather than archiving it.
  - Retain `blocked:` and `carried:` in both cases.
- [x] **Step 4 — Report what it released**: newly-unblocked frontier items; offer `/milestone` if no run is in flight.
- [x] **Never section**: resolve a direction call without an in-session human answer; run in an unattended run; touch a non-`blocked` item; convert a blocked item into `attended` (already mechanically denied — a hand-off is authored, never transitioned into).
- [x] Fix the now-stale sentence in `plugin/commands/handoff.md:18-19` — it should point at `/unblock` instead of telling the human to edit the item file by hand.

### Task 4: `/roadmap` step 0 (`plugin/commands/roadmap.md`)

- [x] Insert a **blocked-queue pre-flight** between the existing audit-debt gate and the "Run the milestone brainstorm" section, as its own numbered step — explicitly **not** folded into brainstorm phase 1 (answering accumulated questions inside the new milestone's narrative anchors them to it).
- [x] Body: read every `status: blocked` item for any configured prefix → triage into the spec's three buckets → propose the premise-invalidated and not-actually-a-question closures as **one batch confirmation** → rank the remainder → **ask at most three** (plus every `carried: ≥2` item, mandatory) one at a time in the Socratic style → for everything unresolved, increment `carried:`, append `> **CARRIED (YYYY-MM-DD):** unanswered through <milestone>.` and add `> **RECOMMENDATION (YYYY-MM-DD):** <default> — <rationale>` if absent → state the skip and its cost in one line → start the brainstorm.
- [x] State the "at most three" rationale inline in one sentence (alert-fatigue override rates; a wholesale dump leaves a record saying the question was answered). A number without its reason gets tuned away by the next editor.
- [x] State that `carried: ≥2` items are **asked, not offered** — the brainstorm does not start until each is answered, defaulted on the human's explicit say-so, or dropped with a `dropped_reason:` — and that everything below that stays a **soft** gate (surface, offer, record the skip), unlike the audit-debt check immediately above it, which is hard because audit debt is never legitimately deferrable.
- [x] All of step 0's writes land in the milestone PR the brainstorm already produces — one PR through the gate, no extra merge.
- [x] Update the existing follow-up-scan sentence so it is honest about what it does and does not cover now (it scans `todo` + `followup_of:`; blocked items are step 0's job).

### Task 5: Playbook doctrine (`plugin/playbook/agentic-loop-playbook.md`)

- [x] Extend the frontmatter schema block (~line 101–107) with `carried:` and its one-line meaning.
- [x] In the status table and the `[blocked]` prose (~line 132–140, 460–500): add the lifecycle — a blocked item is *worked* at the boundary by `/roadmap` step 0 or any time by `/unblock`; answering flips it to `todo` **with a spec authored** or to `done` when the answer produces no work; `blocked:`/`carried:` are retained as provenance.
- [x] Add the **carry convention** next to the existing `> **UNBLOCKED:**` / `> **STARTED:**` note conventions: `> **CARRIED (date):**`, `> **RECOMMENDATION (date):**`, `> **ANSWER (date):**` (with `(default taken)` when the human elects the default at the deadline).
- [x] Add the **agent prepares, never resolves** rule with its reason in one sentence (retrieved context makes models less likely to ask and more likely to assume — cite the research memo path, not the arXiv id, so the doctrine and the evidence stay linked in-repo).
- [x] Add `/unblock` to the command table (~line 1097) next to `/handoff`.
- [x] Update the end-of-run summary and loop-stop wording so "stop when only [blocked] or [attended] remain" now names the two commands that drain them.

### Task 6: Board carry badge (`plugin/tools/sweap-board.lib.mjs`, `.page.mjs`)

- [x] `loadItems`: read `carried: fm.carried ? Number(fm.carried) : 0` alongside `blocked`/`handoff`; add `carried: 0` to the malformed-item fallback object.
- [x] `deriveBacklog`: pass `carried` through the `blocked` mapping (`{ id, title, question, carried }`).
- [x] `.page.mjs`: render a warn-toned age badge in the blocked column when `carried > 0` (`carried 2 boundaries`). No new column — blocked already has one; the point is the queue was never worked, not that it was never shown.
- [x] Add a `sweap-board.test.mjs` case: a blocked fixture with `carried: 2` surfaces it in `deriveBacklog().blocked`, and one without it reads `0`.

### Task 7: Version + consumer story

- [x] `plugin/plugin.json` → `0.4.4`.
- [x] Confirm nothing here requires a consumer's `audit-gate.yml` to change — `--check` is already wired and `AGING:` is additive stdout. Note in the PR body that consumers pick it up on their next vendor bump, and that `consumer-a` has six open blocked items that step 0 will triage on its next `/roadmap`.
- [x] Run all hook test suites plus `sweap-board.test.mjs` and confirm green before opening the PR.

---

## Verification

- [x] `bash plugin/hooks/roadmap-lint.test.sh` — green, new `carried:` cases included.
- [x] `bash plugin/hooks/audit-gate.test.sh` — green; `AGING:` present and exit code unchanged in both the clean and the debt fixture.
- [x] `node plugin/tools/sweap-board.test.mjs` — green.
- [x] Manual: point the board at a fixture backlog with `carried: 2` and confirm the badge renders.
- [ ] **NOT DONE — deliberately deferred to the first real run.** Manual dry-read of `/roadmap` step 0 and `/unblock` against `consumer-a`' six real blocked items (`FJ.6`, `FJ.7`, `FJ.8`, `FK.9`, `FK.10`, `FM.6`) — the triage must classify `FJ.6` (7 days, two boundaries) as mandatory-ask, and must not classify any of the six as premise-invalidated without producing the evidence.
