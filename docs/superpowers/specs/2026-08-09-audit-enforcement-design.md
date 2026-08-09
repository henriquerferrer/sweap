# Milestone-audit enforcement: committed audit records + deterministic audit gate

**Design spec — 2026-08-09.** Approved via brainstorm on top of the research memo
`docs/research/2026-08-08-milestone-audit-enforcement.md` (cited survey of CI
required-check mechanics, SLSA/in-toto provenance, tamper-evident logs, and the
LLM verifier-gaming literature).

## Problem

The milestone audit is part of the definition of done, but "run the audit
honestly" is doctrine, not mechanism. Two observed failure modes: the audit
silently doesn't run (session stops early, milestone declared done unaudited),
and the audit is faked or mis-targeted (session reports "audit clean" in prose
without running it, or audits the wrong milestone). Already shipped: the
workflow throws when the resolved milestone ≠ the requested one; doctrine
requires quoted evidence. Missing: mechanical enforcement.

The audit currently leaves **no committed artifact** — results live only in
session output. That is the root enabler of prose-faking, and fixing it is the
heart of this design.

## Principle (from the research memo)

Separate "enforce that valid evidence of the audit exists" (cheap,
deterministic, runs at every gate) from "run the audit" (expensive,
session-run). The evidence is a committed record bound to exact commit SHAs;
the verifier is a dumb script the session doesn't author at enforcement time.
Skip and mistarget become structurally impossible; fabrication becomes a
deliberate, tamper-evident act rather than lazy drift. Audit *quality* remains
out of mechanical reach (the documented limit of every attestation system
surveyed).

## Decisions made during brainstorm

- **Scope**: all three memo layers — R1 record + R2 gate (load-bearing), R3
  provenance-lite stamping, R4 consumer-hardening docs.
- **Grandfathering**: explicit exempt list `audit.baseline: [F1, F2, ...]` in
  the `## sweap config` block of CLAUDE.md. A list, not a cutoff marker — no
  milestone-ordering semantics needed, works across prefixes (`F*`, `DS*`).
- **Strictness**: roadmap-scoped denial. While audit debt exists, merges that
  advance the backlog (touch roadmap item files beyond the debt's own
  discharge) are denied; code-only PRs (hotfixes, chores) pass.
- **Gate home**: new `plugin/hooks/audit-gate.sh` (bash sibling of
  `roadmap-lint.sh`), not a roadmap-lint extension (per-file linter vs
  repo-global gate) and not a node tool (keeps the merge-critical path on the
  existing bash/git/gh/jq surface).

## Architecture

1. **`roadmap/audits/<milestone>.md`** — committed audit record, one file per
   milestone, written by the session running `/milestone-audit` from the
   Workflow's return value. Lives under `backlog.dir` in an `audits/` subdir
   (same pattern as `ideas/`). Tamper-evident once pushed (git Merkle DAG).
   Re-running an audit overwrites the file; git history keeps prior runs.
2. **`plugin/hooks/audit-gate.sh`** — deterministic validator. Pure bash +
   git; jq/gh only on the merge path (which already has them). Modes:
   - `--check`: repo-state mode — compute the debt set, validate records,
     exit non-zero with reasons when debt exists or a record is invalid.
   - merge mode: given a PR's changed files, apply the roadmap-scoped denial.
3. **`pre-merge-gate.sh`** — one new deny condition: on `gh pr merge`, fetch
   the PR's changed files and consult audit-gate; non-pass ⇒ recoverable deny.
4. **Consumer CI** — documented always-run job running `--check` + diff
   classification (playbook guidance, not a shipped workflow; consumers own CI).
5. **Pre-flights** — `/milestone` and `/roadmap` run `audit-gate.sh --check`
   before opening/dispatching anything, alongside their existing lint calls.

Core invariant: *a milestone whose items are all done and which is not in
`audit.baseline` must have a valid, correctly bound audit record before any
backlog-advancing merge is allowed.*

Sequencing: the PR flipping a milestone's **last** item to done is NOT blocked
(the milestone isn't complete until it merges). Debt begins when it lands and
blocks the next roadmap-advancing merge — matching "audit runs after the last
item merges."

## Record format

Flat frontmatter per the existing format contract (single-line keys, inline
lists, greppable):

```yaml
---
milestone: F3
range_base: <sha>            # audit scoped from
range_head: <sha>            # audit ran against
lens_mode: default-plus      # default | default-plus | explicit
lenses: [correctness, authz, data-integrity, concurrency, test-integrity, api-contract]
raw: 14
refuted: 9
confirmed: 5
workflow_run: wf_abc123      # R3 stamping
journal_sha256: <digest>     # R3 stamping: sha256 of the run's journal.jsonl
---
```

Body: one `### <n>. <title>` block per confirmed finding with flat fields
`severity:`, `lens:`, and exactly one `disposition:` —
`fix_pr #NN` | `followup F3.9` | `blocked F3.10`.
`confirmed: 0` ⇒ no finding blocks.

## Gate rules

**Rule 1 — skip (debt computation).** A milestone is *complete* when it has
item files and every item under its id prefix is `status: done`. Debt set =
complete milestones ∉ `audit.baseline` without a valid record. If debt is
non-empty, deny merges whose changed files include roadmap item files EXCEPT
files discharging the debt: the record file for a debt milestone and its
triage items (`followup_of: <debt milestone>`, or `status: blocked` items
referenced by the record's dispositions). PRs touching nothing under
`roadmap/` always pass. Fix-PRs are code-only ⇒ pass naturally.

**Rule 2 — mistarget (record binding).** A record for milestone M is valid iff
(plain git, deterministic):

- `milestone:` names a real milestone (item files exist under the prefix) and
  all its items are done;
- `range_base` is an ancestor of `range_head`; `range_head` is an ancestor of
  current HEAD (`git merge-base --is-ancestor`);
- for every done item of M, the commit introducing its `status: done` line
  (oldest `git log -S'status: done' -- <item file>` hit) is reachable from
  `range_head` — the audited range actually contains the milestone's merges.

An invalid record does not crash the gate: the milestone stays in the debt set
and the deny reason names the failed binding check. (An audit of F2 can never
discharge F3; a stale range fails structurally.)

**Rule 3 — triage closure.** Every finding block has exactly one
`disposition:`; each `followup`/`blocked` reference resolves to an existing
item file that passes `roadmap-lint.sh` and carries `followup_of: M` (and
`status: blocked` where claimed); `fix_pr` is format-checked (`#\d+`) only —
no network anywhere except the merge path. `confirmed:` must equal the number
of finding blocks; `raw == refuted + confirmed` (every raw finding is either
refuted or confirmed by the workflow's majority vote).

**Fail-closed semantics** (inherited from pre-merge-gate's invariants): on the
merge path any uncertainty (unreadable file, malformed frontmatter, git error)
denies recoverably with a reason; the gate never emits an allow — it can only
add denials. In `--check` mode the same conditions are a red exit with reasons
on stdout.

## Wiring

- **`plugin/commands/milestone-audit.md`**: after the Workflow returns and
  triage completes, the session writes `roadmap/audits/<milestone>.md` —
  transcribing the Workflow return (counts, findings, lenses), resolved range
  SHAs, `workflow_run` id, and `journal_sha256` (hash of the run's
  journal.jsonl). Record + follow-up/blocked items + index update land in ONE
  PR through the normal gate (audit-gate permits it as debt discharge). The
  command then runs `audit-gate.sh --check` and quotes the passing output in
  its summary — quoted evidence with a machine-verifiable object.
- **`plugin/hooks/pre-merge-gate.sh`**: after greenness + freshness checks,
  the PR's changed files (rides the existing `gh pr view --json` query by
  adding `files` to its field list — no extra call) → audit-gate merge mode →
  non-pass becomes a recoverable deny with audit-gate's reason attached.
  Deny-only/fail-closed contract unchanged.
- **`plugin/workflows/milestone-audit.js`**: unchanged — its existing
  milestone-mismatch throw stays; the gate is the backstop, not a replacement.
- **`plugin/commands/milestone.md` + `roadmap.md`**: pre-flight step — run
  `audit-gate.sh --check`; non-empty debt ⇒ the only permitted work is
  discharging it.
- **Playbook** (`plugin/playbook/agentic-loop-playbook.md`): update the
  "Milestone audit" section (record is now part of the audit's definition of
  done) and add "Enforcing the audit gate in CI": always-run job (no `paths:`
  filter, no job-level `if:` — skipped jobs SATISFY required checks),
  `fetch-depth: 0` (ancestry checks need full history), diff classification
  via `git diff --name-only origin/$GITHUB_BASE_REF...HEAD`; required check
  pinned to the GitHub Actions app, never "any source" (commit statuses are
  forgeable by any push-access token; check runs are App-only); protect
  `.github/workflows/**` (CODEOWNERS/ruleset); default `GITHUB_TOKEN`
  read-only.

## Testing

`plugin/hooks/audit-gate.test.sh` in the house style (temp `git init` fixture
repos, crafted item files/records, assert allow/deny + reason strings):

- no debt → pass; debt + roadmap-advancing PR → deny; debt + code-only PR →
  pass; debt + discharge PR (record + followups) → pass; valid record clears
  debt;
- mistarget: `range_head` not ancestor of HEAD; done-flip commit outside
  range; wrong milestone id → record invalid (milestone stays in debt);
- triage closure: missing disposition; dangling followup ref; count mismatch;
- `audit.baseline` exemption; malformed frontmatter → fail-closed deny.

Plus one integration case in `pre-merge-gate.test.sh` for the new deny path
using its existing mocked-`gh` harness.

## Verified against the code (was blocked during brainstorm; resolved before commit)

1. **No lint/board exclusions needed for `roadmap/audits/`.** `roadmap-lint.sh`
   is strictly per-file (callers pass paths; it never globs), and
   `sweap-board.lib.mjs#loadItems` reads only top-level `roadmap/*.md`
   (`readdirSync(dir).filter(endsWith('.md'))`), so the `audits/` subdir is
   invisible to both. audit-gate enumerates top-level `roadmap/*.md` itself.
2. **Merge-hook insertion point**: inside `pre-merge-gate.sh#verify_pr`, after
   the base-freshness compare passes. Add `files` to the EXISTING
   `gh pr view --json statusCheckRollup,mergeStateStatus,baseRefName,headRefOid`
   field list — no extra gh call, no new budget pressure. Non-pass ⇒
   `emit_deny` with audit-gate's reason. `bounded_run`/budget/`CLEAN_ALLOW`
   conventions unchanged; new test cases ride the existing mocked-`gh` harness
   in `pre-merge-gate.test.sh`.
3. **Milestone-semantics parity** with `sweap-board.lib.mjs`: milestone of an
   item = id minus its last dot segment (`milestoneOf`); a milestone is
   complete when every item with that milestone prefix is `status: done`
   (matches `isUnblocked`'s milestone-dependency rule); ordering uses numeric
   segment compare (`numKey`) — the bash gate mirrors these rules, it does not
   call the lib.
4. **Done-flip commit** via oldest `git log -S'status: done' -- <item file>`
   hit is correct even for items created directly at `status: done` (the
   creating commit is the hit).

## Residual limits (unchanged from the memo)

The gate makes skip and mistarget structurally impossible and forces
fabrication into a deliberate, committed, tamper-evident forgery — it cannot
detect a real-but-shallow audit, and a local agent with shell access can still
hand-forge a well-formed record (unforgeability would require the audit to run
under a CI identity — the memo's R5 upgrade path, incompatible with
session-run audits today). The gate scripts themselves are repo files; the
consumer-side ruleset + app-pinned check is the outermost trust anchor.
