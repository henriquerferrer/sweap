# Parallel Roadmap Runs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in parallel execution of independent roadmap items — frontier scheduling, worktree-isolated workers, and a FIFO always-verify merge queue — to the sweap plugin, per `docs/superpowers/specs/2026-07-18-parallel-roadmap-runs-design.md`.

**Architecture:** Thin coordinator, fat gates. Workers are the existing per-feature loop, unchanged. All new behavior is (a) one mechanical hook check (`BEHIND` merge denial), (b) config/scaffold surface (`parallel:` key, board-file gitignore), (c) doctrine text (playbook coordinator-mode section, `/milestone` awareness). No new runtime processes; the coordinator is prompt-level behavior reading externalized state.

**Tech Stack:** Bash hooks (jq-based, stub-`gh` test harness), Markdown command/playbook/template files. No new dependencies.

## Global Constraints

- The pre-merge hook only ever DENIES or stays silent — it never emits an allow and never weakens the gate (invariant documented in `pre-merge-gate.sh` header).
- All hook uncertainty paths deny *recoverably* (fail-closed, never a permanent wedge); hooks always `exit 0` and speak via stdout JSON.
- `parallel:` default is `1` (existing projects see zero behavior change); enable at `2`–`3`; hard cap `4`.
- The board file is `.claude/sweap-board.md`, always gitignored, never committed.
- No verification-skip fast-path anywhere: diff-disjointness may inform queue ORDER only. Never write language suggesting the combined-state CI run can be skipped.
- Repo norm: commit directly to `main` (this plugin repo has no PR flow).
- Run the full hook suite (`bash plugin/hooks/pre-merge-gate.test.sh`) before every commit that touches `plugin/hooks/`.

---

### Task 1: `BEHIND` denial in pre-merge-gate

**Files:**
- Modify: `plugin/hooks/pre-merge-gate.sh` (gh query at ~line 182, new check after the offenders block at ~line 217, header comment)
- Test: `plugin/hooks/pre-merge-gate.test.sh` (stub modes at ~lines 44–70, new cases after d3 at ~line 143)

**Interfaces:**
- Consumes: existing `verify_pr()` / `emit_deny()` structure and the `GH_STUB` test harness.
- Produces: deny reasons containing the literal strings `BEHIND` (stale-base case) and `freshness` (missing/UNKNOWN case) — the test greps and the playbook text (Task 3) reference this behavior as "the pre-merge gate denies a BEHIND PR".

- [ ] **Step 1: Extend the gh stub and add three failing test cases**

In `plugin/hooks/pre-merge-gate.test.sh`, update the stub's `green` and `skipped` modes to carry a healthy `mergeStateStatus` (real gh output includes it once we request it), and add three new modes. Replace the `green` and `skipped` case bodies and add `behind`/`nostate`/`unknownstate`:

```bash
  green)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"CLEAN","mergeCommit":{"oid":"deadbeef"}}' ;;
  skipped)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"optional","status":"COMPLETED","conclusion":"SKIPPED"}
    ],"mergeStateStatus":"CLEAN","mergeCommit":{"oid":"deadbeef"}}' ;;
  behind)   # green checks, but the branch is BEHIND the base — stale green
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"BEHIND","mergeCommit":{"oid":"deadbeef"}}' ;;
  nostate)  # green checks, mergeStateStatus absent (old gh / API oddity)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeCommit":{"oid":"deadbeef"}}' ;;
  unknownstate)  # green checks, GitHub still computing mergeability
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"UNKNOWN","mergeCommit":{"oid":"deadbeef"}}' ;;
```

Then insert the three cases immediately after case `(d3)` (the empty-rollup test, ~line 143):

```bash
# (d4) green checks but branch BEHIND base -> DENY (stale green; combined state unverified)
out="$(run_gate behind 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'BEHIND'; then
  ok "d4) behind base -> deny (rebase first)"
else bad "d4) behind -> deny" "out: $out"; fi

# (d5) mergeStateStatus missing -> DENY (recoverable, fail-closed on uncertainty)
out="$(run_gate nostate 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'freshness'; then
  ok "d5) mergeStateStatus missing -> deny-recoverable"
else bad "d5) missing state -> deny-recoverable" "out: $out"; fi

# (d6) mergeStateStatus UNKNOWN -> DENY (recoverable; GitHub still computing)
out="$(run_gate unknownstate 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'freshness'; then
  ok "d6) mergeStateStatus UNKNOWN -> deny-recoverable"
else bad "d6) UNKNOWN state -> deny-recoverable" "out: $out"; fi
```

- [ ] **Step 2: Run the suite to verify the new cases FAIL and all existing cases still PASS**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: `d4`, `d5`, `d6` FAIL (hook currently allows silently — no deny emitted); every pre-existing case PASSES (the extra stub field is ignored by the current hook). RESULT line shows exactly 3 failed.

- [ ] **Step 3: Implement the check in `pre-merge-gate.sh`**

3a. Change the gh query inside `verify_pr()` (~line 182) from:

```bash
  gh pr view "$pr" --json statusCheckRollup >"$tmp" 2>/dev/null &
```

to:

```bash
  gh pr view "$pr" --json statusCheckRollup,mergeStateStatus >"$tmp" 2>/dev/null &
```

3b. Insert after the offenders deny block (the `if [ -n "$offenders" ]; then … fi`, ~line 217–220) and before `return 0`:

```bash
  # Base-freshness gate: green checks that ran against an OLD base are not
  # evidence about the COMBINED state that would actually land (a "real
  # conflict" is invisible per-branch). BEHIND ⇒ deny with the rebase recipe.
  # Missing/UNKNOWN ⇒ deny recoverably (uncertainty is never an allow).
  local mstate
  mstate="$(printf '%s' "$json" | jq -r '(.mergeStateStatus // "") | ascii_upcase' 2>/dev/null)"
  if [ "$mstate" = "BEHIND" ]; then
    emit_deny "merge-gate: PR #$pr is BEHIND the base branch — its green checks ran against an old base, so the combined state is unverified. Rebase (git fetch origin && git rebase origin/main && git push --force-with-lease), wait for CI to go green on the rebased head, then re-run the merge."
    return 1
  fi
  if [ -z "$mstate" ] || [ "$mstate" = "UNKNOWN" ]; then
    emit_deny "merge-gate: could not determine PR #$pr's freshness against the base branch (mergeStateStatus: ${mstate:-missing}). The gate fails CLOSED — re-run the merge once GitHub reports mergeability."
    return 1
  fi
```

3c. In the file's header comment, after the line `# human-reads-the-output link from the chain.` (~line 15), add:

```bash
#
# It ALSO denies a PR whose branch is BEHIND its base (mergeStateStatus) —
# green checks against an old base say nothing about the combined state that
# would land, which is the hazard of parallel runs (see the parallel-runs
# spec, 2026-07-18). Missing/UNKNOWN mergeability denies recoverably.
```

- [ ] **Step 4: Run the suite to verify ALL cases pass**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: `RESULT: <N> passed, 0 failed` (N = previous total + 3).

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/pre-merge-gate.sh plugin/hooks/pre-merge-gate.test.sh
git commit -m "feat(hooks): pre-merge gate denies BEHIND PRs (base-freshness, fail-closed)"
```

---

### Task 2: `parallel:` config key + board-file gitignore in scaffold

**Files:**
- Modify: `plugin/templates/CLAUDE.md` (sweap config block, after `turns.default`)
- Modify: `plugin/hooks/scaffold.sh` (gitignore section, ~lines 100–110 and the summary message ~line 122–124)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: config key literal `parallel:` (read by Task 3's playbook + `/milestone` text — exact spelling matters) and gitignore entry literal `.claude/sweap-board.md`.

- [ ] **Step 1: Add the config key to the template**

In `plugin/templates/CLAUDE.md`, inside the fenced `## sweap config` block, directly below the `turns.default:    160` line, add:

```
parallel:         1                        # concurrent roadmap items: 1 = serial; 2-3 enables coordinator mode (cap 4) — see playbook "Parallel runs"
```

- [ ] **Step 2: Generalize the scaffold gitignore section**

In `plugin/hooks/scaffold.sh`, replace the single-line gitignore block:

```bash
# .gitignore: ensure the red-main flag file is excluded, never duplicated.
gitignore_line='.claude/main-red-*.flag'
gitignore_action="unchanged"
gi="$proj/.gitignore"
if [ -f "$gi" ]; then
  if ! grep -qF "$gitignore_line" "$gi" 2>/dev/null; then
    printf '%s\n' "$gitignore_line" >> "$gi" 2>/dev/null && gitignore_action="appended"
  fi
else
  printf '%s\n' "$gitignore_line" > "$gi" 2>/dev/null && gitignore_action="created"
fi
```

with a loop over sweap's runtime files:

```bash
# .gitignore: ensure sweap's runtime files are excluded, never duplicated.
gitignore_action="unchanged"
gi="$proj/.gitignore"
for gitignore_line in '.claude/main-red-*.flag' '.claude/sweap-board.md'; do
  if [ -f "$gi" ]; then
    if ! grep -qF "$gitignore_line" "$gi" 2>/dev/null; then
      printf '%s\n' "$gitignore_line" >> "$gi" 2>/dev/null && gitignore_action="appended"
    fi
  else
    printf '%s\n' "$gitignore_line" > "$gi" 2>/dev/null && gitignore_action="created"
  fi
done
```

and update the summary message branch that references it:

```bash
if [ "$gitignore_action" != "unchanged" ]; then
  msg="$msg .gitignore: $gitignore_action sweap runtime ignore rules (.claude/main-red-*.flag, .claude/sweap-board.md)."
fi
```

- [ ] **Step 3: Verify scaffold behavior in a throwaway repo (create + idempotent re-run)**

```bash
T="$(mktemp -d)" && git -C "$T" init -q && \
CLAUDE_PROJECT_DIR="$T" CLAUDE_PLUGIN_ROOT="$PWD/plugin" bash plugin/hooks/scaffold.sh >/dev/null && \
grep -c 'sweap-board' "$T/.gitignore" && grep -c 'main-red' "$T/.gitignore" && \
CLAUDE_PROJECT_DIR="$T" CLAUDE_PLUGIN_ROOT="$PWD/plugin" bash plugin/hooks/scaffold.sh >/dev/null ; \
grep -c 'sweap-board' "$T/.gitignore" ; grep 'parallel:' "$T/CLAUDE.md" ; rm -rf "$T"
```

Expected: each `grep -c` prints `1` (both lines present, no duplicates after the second run — the fast-guard makes run 2 a no-op), and the last grep prints the `parallel:         1` line from the scaffolded CLAUDE.md.

- [ ] **Step 4: Run the hook suite (guard against accidental breakage)**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugin/templates/CLAUDE.md plugin/hooks/scaffold.sh
git commit -m "feat: parallel config key + sweap-board gitignore in scaffold"
```

---

### Task 3: Coordinator-mode doctrine (playbook + `/milestone`)

**Files:**
- Modify: `plugin/playbook/agentic-loop-playbook.md` (config-key list in "How this project is configured"; replace the "Rationale: the throughput lever…" paragraph at the end of the Milestone-audit section; new `## Parallel runs (coordinator mode)` section directly after that paragraph)
- Modify: `plugin/commands/milestone.md` (new "Parallel width" paragraph before the goal-printing section)

**Interfaces:**
- Consumes: config key `parallel:` (Task 2), the hook's BEHIND denial (Task 1 — referenced as behavior, not by string).
- Produces: section title literal `## Parallel runs (coordinator mode)` — `milestone.md` references it by that exact name.

- [ ] **Step 1: Add the config key to the playbook's key list**

In `agentic-loop-playbook.md`, in the `## How this project is configured` bullet list, after the `turns.default` bullet, add:

```markdown
- **`parallel`** — max concurrent roadmap items. Default **`1`** (the serial
  loop). `2`–`3` enables coordinator mode (see **Parallel runs (coordinator
  mode)**); hard cap **4** — clamp anything higher to 4 and say so.
```

- [ ] **Step 2: Replace the rationale paragraph**

Replace this paragraph (end of the "Milestone audit" section):

```markdown
Rationale: the throughput lever is loop tightness with machine verification, not
parallelism. Core features are often serially dependent; parallelize only
genuinely independent tracks (marketing site, CI, polish on merged features) via
worktree-isolated agents.
```

with:

```markdown
Rationale: loop tightness with machine verification remains the PRIMARY
throughput lever. Frontier parallelism (next section) is a secondary lever
that mostly recovers CI dead time on genuinely independent items — expect
~1.5–2x on an independent frontier, not K-x; a serially-dependent milestone
gains nothing and simply runs the serial loop.
```

- [ ] **Step 3: Add the coordinator-mode section**

Insert directly after the replaced paragraph (before `## The three loops`):

```markdown
## Parallel runs (coordinator mode)

Active when the `## sweap config` block declares `parallel: 2` or more
(default `1` = the serial loop; hard cap 4). Evidence base and locked
decisions: the parallel-roadmap-runs spec (2026-07-18) in the sweap plugin
repo. The shape is **thin coordinator, fat gates** — the gates do the
verifying; the coordinator only schedules.

**Workers (unchanged).** Each in-flight item runs the standard per-feature
loop in its own worktree — TDD, fresh-context review, review dimensions,
PR — one item to a clean mergeable state. A worker reports back only a
compressed summary (~1–2k tokens): item, worktree@branch, PR number, gate
state, blocked question if any. Workers never merge; the coordinator owns
the queue.

**Coordinator (holds no implementation state — everything durable lives on
disk: ROADMAP.md, the board, per-item progress files, git, PRs).**

1. **Frontier:** every unblocked `[todo]` item, debt-first, top-of-file
   order — the `/milestone` picker taking the top K instead of the top 1.
   Recompute after every merge or block (a merge may unblock items).
2. **Dispatch** up to `parallel:` workers as background agents in isolated
   worktrees. Co-dispatch judgment rule: never two items plausibly touching
   the same surface at once; two `migration`-tagged items NEVER run
   together.
3. **Merge queue (FIFO, always-verify):** when a worker's PR is ready —
   rebase the branch onto current `main`, `git push --force-with-lease`,
   wait for CI green on the rebased head, then `gh pr merge <n> --squash`
   (the pre-merge gate hook independently re-verifies greenness AND denies
   a BEHIND PR, so stale-green merges are mechanically impossible).
   **Speculative rebase:** the moment a merge lands, immediately rebase the
   next queued PR so its combined-state CI runs during otherwise-idle time.
   Diff-disjointness may pick queue ORDER (least-entangled first); it NEVER
   skips the combined-state CI run — there is no "looks independent"
   fast-path, by locked decision (industry skips are hermetic-build-graph
   proofs or statistically-measured skips with post-land safety nets; this
   pipeline has neither).
4. **Board:** maintain `.claude/sweap-board.md` (gitignored, never
   committed) — one line per in-flight item:
   `<item> | <status/current step> | <worktree>@<branch> | PR #<n> |
   <blocked question or ->`, plus the current merge-queue order. The board
   is BOTH the human's at-a-glance status surface and the coordinator's
   externalized memory: on restart (`claude --continue` or a fresh
   session), rebuild all state from board + ROADMAP.md +
   `git worktree list` + open PRs. Losing the coordinator loses nothing.

**Failure handling (all existing doctrine, mapped):** worker blocked →
escalate-don't-guess, mark `[blocked]`, notify, fill the slot with the next
frontier item. Worker dies mid-feature → re-dispatch onto the same
worktree; it resumes from the progress file + git history (pick-up-cold).
CI red after rebase — a semantic conflict, exactly what the queue exists to
catch → the owning worker gets the standard ~3 distinct fix attempts, then
`[blocked]` with the PR left open.

**Instrumentation (mandatory in the end-of-run summary):** max/mean
concurrency achieved, rebases performed, conflicts hit (textual vs
CI-caught semantic), queue-caused CI reruns, and rough wall-clock vs
estimated serial. Widen K (≤4) only when this data says parallelism pays;
retreat to `parallel: 1` when it doesn't.

**CI determinism is a standing constraint:** a merge queue amplifies a
flaky suite (every flake blocks the queue head). Fix or quarantine-with-
flag per existing doctrine; never retry-until-green.
```

- [ ] **Step 4: Add the parallel-width paragraph to `/milestone`**

In `plugin/commands/milestone.md`, insert before the paragraph that begins `Then **print** the exact goal line`:

```markdown
Parallel width (coordinator mode). Read `parallel:` from the `## sweap
config` block (default 1; clamp values above 4 to 4 and say so). If it is 2
or more, say the run will operate in **coordinator mode** per the playbook's
"Parallel runs (coordinator mode)" section — frontier scheduling,
worktree-isolated workers, the FIFO always-verify merge queue, and the
`.claude/sweap-board.md` board file. The printed goal line is IDENTICAL to
the serial form — the mode changes how the run executes, not its definition
of done.
```

- [ ] **Step 5: Coherence check**

Run: `grep -n 'Parallel runs (coordinator mode)' plugin/playbook/agentic-loop-playbook.md plugin/commands/milestone.md && grep -n 'parallel' plugin/templates/CLAUDE.md plugin/playbook/agentic-loop-playbook.md | head -20`
Expected: the section title appears in the playbook (as `##` heading) and in milestone.md (as reference); the `parallel` key appears in both the template and the playbook key list. Read the diff once for contradictions with the untouched sections (e.g., end-of-run hygiene still applies per merge).

- [ ] **Step 6: Commit**

```bash
git add plugin/playbook/agentic-loop-playbook.md plugin/commands/milestone.md
git commit -m "feat(doctrine): parallel runs coordinator mode (playbook section + /milestone awareness)"
```

---

### Task 4: Repo integrity verification

**Files:**
- No new files; verification only (fix-forward if anything is red).

**Interfaces:**
- Consumes: all prior tasks' outputs.
- Produces: a clean verification record in the commit history (empty task if all green — then no commit).

- [ ] **Step 1: Full hook suite**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: `0 failed`.

- [ ] **Step 2: Manifest and syntax integrity**

```bash
jq -e . plugin/plugin.json .claude-plugin/marketplace.json >/dev/null && echo manifests-ok
bash -n plugin/hooks/pre-merge-gate.sh plugin/hooks/scaffold.sh plugin/hooks/post-merge-cleanup.sh plugin/hooks/post-merge-redcheck.sh plugin/hooks/lib-merge-parse.sh && echo syntax-ok
```

Expected: `manifests-ok` and `syntax-ok`.

- [ ] **Step 3: Scaffold end-to-end re-check (fresh throwaway repo)**

Re-run the Task 2 Step 3 verification one-liner.
Expected: same results (`1`s, `parallel:` line present).

- [ ] **Step 4: Spec cross-check**

Open `docs/superpowers/specs/2026-07-18-parallel-roadmap-runs-design.md` "Changes by component" table; confirm each row now has a corresponding committed change (template key, playbook section + rationale, milestone paragraph, hook + test, scaffold entry). Fix any gap before declaring done.

- [ ] **Step 5: Commit any fixes (skip if none)**

```bash
git add -A && git commit -m "fix: integrity follow-ups from parallel-runs verification" || echo "nothing to fix"
```
