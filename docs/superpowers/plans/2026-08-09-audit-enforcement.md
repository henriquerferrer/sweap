# Milestone-Audit Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it structurally impossible for a milestone to be declared done without a valid, correctly targeted audit record — committed audit records under `roadmap/audits/` plus a deterministic `audit-gate.sh` enforced at merge time, in CI, and in command pre-flights.

**Architecture:** A new bash validator `plugin/hooks/audit-gate.sh` (sibling of `roadmap-lint.sh`) computes the *audit debt set* (complete milestones without a valid record, minus the `audit.baseline` grandfather list) and validates records against three rules: skip (debt blocks backlog-advancing merges), mistarget (record SHAs recomputed against git ancestry), and triage closure (every confirmed finding's disposition resolves). `pre-merge-gate.sh` consults it on every `gh pr merge`; command docs and the playbook wire it into `/milestone-audit`, `/milestone`, `/roadmap`, and consumer CI.

**Tech Stack:** bash + git (offline, deterministic); jq/gh only on the merge path (already there); house test harness style (mktemp fixture dirs, stubbed `gh`).

**Spec:** `docs/superpowers/specs/2026-08-09-audit-enforcement-design.md` — read it before starting any task.

## Global Constraints

- **Flat frontmatter contract**: single-line keys, inline `[a, b]` lists; parse with awk/sed exactly like `roadmap-lint.sh`; never grow a YAML parser.
- **Hook invariants** (from `pre-merge-gate.sh` header): the merge hook only ever DENIES or stays silent; fail-closed recoverably on ANY uncertainty; always exit 0 and communicate via stdout JSON; bounded runtimes.
- **audit-gate exit codes**: 0 = pass, 1 = fail (one `FAIL: reason` per line on stdout, matching `roadmap-lint.sh`), 2 = usage.
- **Bash 3.2 compatible** (macOS default): no associative arrays in bash — use awk for aggregation.
- **Milestone semantics parity with `sweap-board.lib.mjs`**: milestone of an item = id minus last dot segment (`${id%.*}`); a milestone is *complete* when it has ≥1 item file and every item under its prefix is `status: done`; ids without a dot are not items (skip).
- **Only top-level `<backlog.dir>*.md` are item files** — `audits/`, `ideas/`, `archive/` subdirs are never item files.
- All new files get the house-style header comment explaining WHY, not just what.

---

### Task 1: `audit-gate.sh` — debt computation + `--check` mode

**Files:**
- Create: `plugin/hooks/audit-gate.sh`
- Create: `plugin/hooks/audit-gate.test.sh`

**Interfaces:**
- Produces: `audit-gate.sh --check` (run from repo root as cwd): exit 0 = no debt; exit 1 with `FAIL: ...` lines. Internal functions later tasks extend: `frontmatter <file>`, `fm_get <file> <key>`, `cfg_get <key>`, `validate_record <milestone> <file>` (returns 0/1, appends to `FAILS` via `fail <msg>`), and the computed vars `BACKLOG_DIR` (with trailing slash), `BASELINE` (space-separated milestone list), `COMPLETE` (newline list of complete milestones), `DEBT` (newline list of milestones in debt).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test file with the harness and Task-1 cases**

Create `plugin/hooks/audit-gate.test.sh`:

```bash
#!/usr/bin/env bash
#
# audit-gate.test.sh — deterministic, offline tests for audit-gate.sh
# (mechanical enforcement of the milestone-audit invariant).
#
# Run:  bash plugin/hooks/audit-gate.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/audit-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
# run_gate <repo> <args...>; captures OUT/RC for asserts
OUT=""; RC=0
run_gate() { local r="$1"; shift; OUT="$( (cd "$r" && bash "$GATE" "$@") 2>&1)"; RC=$?; }
check() { # check <desc> <wanted-rc>
  local desc="$1" want="$2"
  if [ "$RC" = "$want" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s (exit %s, wanted %s)\n%s\n' "$desc" "$RC" "$want" "$OUT"; fi
}
check_out() { # check_out <desc> <grep-pattern> (asserts on last run's OUT)
  local desc="$1" pat="$2"
  if printf '%s\n' "$OUT" | grep -q "$pat"; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s (no match: %s)\n%s\n' "$desc" "$pat" "$OUT"; fi
}

# --- fixture builders -----------------------------------------------------------
# new_repo <name>: fresh git repo with roadmap/ + an initial commit; echoes path.
new_repo() {
  local r="$WORK/$1"
  mkdir -p "$r/roadmap/audits"
  git -C "$r" init -q
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$r"
}
# mk_item <repo> <id> <status> [extra-frontmatter-line]
# done/blocked items are records (frontmatter only) — matches roadmap-lint.
mk_item() {
  local r="$1" id="$2" status="$3" extra="${4:-}"
  { printf -- '---\nid: %s\ntitle: %s\nstatus: %s\ndepends_on: []\nreview-dimensions: []\n' "$id" "$id" "$status"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf -- '---\n\n# %s\n' "$id"
  } > "$r/roadmap/$id.md"
}
commit_all() { git -C "$1" add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -qm "${2:-c}"; }
head_sha() { git -C "$1" rev-parse HEAD; }
# mk_record <repo> <milestone> <base> <head> <raw> <refuted> <confirmed> [body]
mk_record() {
  local r="$1" m="$2" base="$3" head="$4" raw="$5" ref="$6" conf="$7" body="${8:-}"
  { printf -- '---\nmilestone: %s\nrange_base: %s\nrange_head: %s\nlens_mode: default\n' "$m" "$base" "$head"
    printf 'lenses: [correctness, authz]\nraw: %s\nrefuted: %s\nconfirmed: %s\n' "$raw" "$ref" "$conf"
    printf -- 'workflow_run: wf_test\njournal_sha256: 0123abcd\n---\n\n# %s audit\n%s\n' "$m" "$body"
  } > "$r/roadmap/audits/$m.md"
}

echo "audit-gate.test.sh:"

# T1: empty repo (no items) -> pass
R="$(new_repo t1)"
run_gate "$R" --check
check "no items => no debt" 0

# T2: milestone in progress (one item todo... uses a done+todo pair) -> pass
R="$(new_repo t2)"
mk_item "$R" F1.1 done
mk_item "$R" F1.2 todo
commit_all "$R"
run_gate "$R" --check
check "incomplete milestone => no debt" 0

# T3: complete milestone, no record -> FAIL naming the milestone
R="$(new_repo t3)"
mk_item "$R" F1.1 done
mk_item "$R" F1.2 done
commit_all "$R"
run_gate "$R" --check
check "complete milestone without record => debt" 1
check_out "debt names milestone" "FAIL: milestone F1 .*no audit record"

# T4: audit.baseline exempts it
R="$(new_repo t4)"
mk_item "$R" F1.1 done
commit_all "$R"
printf '## sweap config\naudit.baseline: [F1, F7]\n' > "$R/CLAUDE.md"
run_gate "$R" --check
check "baseline-listed milestone exempt" 0

# T5: multi-segment milestone id (DS.2 with items DS.2.1) in debt
R="$(new_repo t5)"
mk_item "$R" DS.2.1 done
commit_all "$R"
run_gate "$R" --check
check "multi-segment milestone => debt" 1
check_out "multi-segment milestone named" "FAIL: milestone DS\.2 "

# T6: record file present and valid => debt cleared
R="$(new_repo t6)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
mk_item "$R" F1.2 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 0 0 0
commit_all "$R" record
run_gate "$R" --check
check "valid record clears debt" 0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: FAIL on every case (audit-gate.sh does not exist; `bash` exits 127 → rc mismatch).

- [ ] **Step 3: Implement `audit-gate.sh` (debt computation; record validation minimal for now)**

Create `plugin/hooks/audit-gate.sh`:

```bash
#!/usr/bin/env bash
#
# audit-gate.sh — mechanical enforcement of the milestone-audit invariant.
#
# Invariant: a milestone whose items are all `status: done` and which is not
# listed in `audit.baseline` must have a VALID audit record at
# <backlog.dir>audits/<milestone>.md before any backlog-advancing merge lands.
# This converts the playbook's "the audit is part of the milestone's definition
# of done" from doctrine into mechanism (see the 2026-08-09 design spec and the
# 2026-08-08 research memo: enforcement of "a valid audit EXISTS" is cheap and
# deterministic even though the audit itself is expensive and session-run).
#
# Modes:
#   audit-gate.sh --check
#       Repo-state mode (CI, /milestone & /roadmap pre-flights, and
#       /milestone-audit's own self-check). Exit 0 = no audit debt and every
#       record under audits/ is valid. Exit 1 = "FAIL: ..." lines on stdout.
#   audit-gate.sh --files <path>...
#       Merge mode (pre-merge-gate, CI diff classification). Given a PR's
#       changed paths: exit 0 if the merge is allowed under the roadmap-scoped
#       denial, exit 1 with "FAIL: ..." lines if it must be denied.
#
# Both modes run from the repo root (cwd). Deterministic and OFFLINE: bash +
# git only — network trust lives in the callers (pre-merge-gate / CI).
#
# Format contract (playbook "Backlog format"): flat single-line frontmatter
# keys; inline [a, b] lists. That contract is what keeps this script trivial —
# do not grow a YAML parser here (same rule as roadmap-lint.sh).
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
  --check|--files) : ;;
  *) echo "usage: audit-gate.sh --check | --files <path>..."; exit 2 ;;
esac
shift

fails=0
fail() { echo "FAIL: $1"; fails=1; }

# --- frontmatter helpers (same idiom as roadmap-lint.sh) ------------------------
frontmatter() { awk '{ sub(/\r$/,"") } NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$1"; }
fm_get() { frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }

# --- config from CLAUDE.md's `## sweap config` block ----------------------------
# Keys are unique single-line `key: value` entries; match anywhere in the file
# (same relaxation sweap-board.lib.mjs#readConfig uses).
cfg_get() { [ -f CLAUDE.md ] && sed -n "s/^$1:[[:space:]]*//p" CLAUDE.md | head -1 | sed 's/[[:space:]]*$//' || true; }

BACKLOG_DIR="$(cfg_get 'backlog\.dir')"
BACKLOG_DIR="${BACKLOG_DIR:-roadmap/}"
case "$BACKLOG_DIR" in */) : ;; *) BACKLOG_DIR="$BACKLOG_DIR/" ;; esac

BASELINE="$(cfg_get 'audit\.baseline' | tr -d '[]' | tr ',' ' ')"
in_baseline() { local m; for m in $BASELINE; do [ "$m" = "$1" ] && return 0; done; return 1; }

# --- enumerate item files (TOP-LEVEL only — audits/, ideas/, archive/ are not
# item files) and compute complete milestones: milestone = id minus last dot
# segment (parity with sweap-board.lib.mjs#milestoneOf); complete = every item
# under the prefix is done. awk aggregation keeps this bash-3.2 safe.
item_rows() { # "<milestone> <status>" per item file
  local f id status
  for f in "${BACKLOG_DIR}"*.md; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .md)"
    case "$id" in *.*) : ;; *) continue ;; esac   # no dot => not an item file
    status="$(fm_get "$f" status)"
    printf '%s %s\n' "${id%.*}" "${status:-unknown}"
  done
}
COMPLETE="$(item_rows | awk '{tot[$1]++; if($2=="done") d[$1]++} END{for(m in tot) if(d[m]==tot[m]) print m}' | sort)"

# --- record validation ----------------------------------------------------------
# Task 2 (binding) and Task 3 (triage closure) extend this function. A record
# failing here does NOT crash the gate: the milestone stays in debt and the
# reason is reported.
validate_record() { # validate_record <milestone> <file> ; 0 = valid
  local m="$1" rec="$2"
  local ok=1
  [ "$(fm_get "$rec" milestone)" = "$m" ] || { fail "record $rec: milestone key != $m"; ok=0; }
  [ "$ok" = 1 ]
}

# --- debt set -------------------------------------------------------------------
DEBT=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  in_baseline "$m" && continue
  rec="${BACKLOG_DIR}audits/$m.md"
  if [ ! -f "$rec" ]; then
    DEBT="$DEBT$m"$'\n'
    [ "$MODE" = "--check" ] && fail "milestone $m is complete but has no audit record ($rec) — run /milestone-audit for it"
  elif ! validate_record "$m" "$rec"; then
    DEBT="$DEBT$m"$'\n'
  fi
done <<COMPLETE_EOF
$COMPLETE
COMPLETE_EOF

if [ "$MODE" = "--check" ]; then
  exit "$fails"
fi

# --- merge mode (--files): roadmap-scoped denial --------------------------------
# Deny iff debt exists AND the PR touches top-level item files AND it does not
# discharge the debt (contain the audit record for a debt milestone). Follow-up
# and blocked items ride the same PR as the record, so path-level detection of
# the record is sufficient (record validity is re-checked at the next --check).
[ -n "$(printf '%s' "$DEBT")" ] || exit 0
touches_items=0; discharges=0
for f in "$@"; do
  case "$f" in
    "${BACKLOG_DIR}audits/"*.md)
      m="$(basename "$f" .md)"
      while IFS= read -r d; do [ "$m" = "$d" ] && discharges=1; done <<DEBT_EOF
$DEBT
DEBT_EOF
      ;;
    "${BACKLOG_DIR}"*/*) : ;;              # other subdirs (ideas/, archive/) — not item files
    "${BACKLOG_DIR}"*.md) touches_items=1 ;;
  esac
done
if [ "$touches_items" = 1 ] && [ "$discharges" = 0 ]; then
  debt_list="$(printf '%s' "$DEBT" | tr '\n' ' ')"
  fail "audit debt exists for milestone(s): ${debt_list}— this PR advances the backlog without discharging it. Run /milestone-audit and land its record (+ follow-ups) first; code-only PRs are unaffected."
fi
exit "$fails"
```

Then: `chmod +x plugin/hooks/audit-gate.sh`

- [ ] **Step 4: Run the tests, verify all Task-1 cases pass**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: 8 PASS (T1–T6 incl. the two `check_out`s), 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/audit-gate.sh plugin/hooks/audit-gate.test.sh
git commit -m "feat(hooks): audit-gate.sh — audit-debt computation + --check mode"
```

---

### Task 2: Record binding validation (mistarget rule)

**Files:**
- Modify: `plugin/hooks/audit-gate.sh` (extend `validate_record`)
- Modify: `plugin/hooks/audit-gate.test.sh` (append cases)

**Interfaces:**
- Consumes: Task 1's `validate_record <milestone> <file>`, `fail`, `fm_get`, `BACKLOG_DIR`.
- Produces: `validate_record` now enforces: required keys present, SHAs are real commits, `range_base` ancestor of `range_head`, `range_head` ancestor of HEAD, every done item's done-flip commit reachable from `range_head`.

- [ ] **Step 1: Append failing tests**

Append to `plugin/hooks/audit-gate.test.sh` (before the final `printf`/exit lines):

```bash
# T7: record head not an ancestor of HEAD (bogus sha) -> debt stays
R="$(new_repo t7)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "0000000000000000000000000000000000000000" 0 0 0
commit_all "$R" record
run_gate "$R" --check
check "unresolvable range_head => invalid record" 1
check_out "binding failure named" "FAIL: record .*range_head"

# T8: done-flip commit outside the audited range -> invalid
# (item flips to done AFTER range_head: audit predates the milestone's last merge)
R="$(new_repo t8)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
early="$(head_sha "$R")"
mk_item "$R" F1.2 todo
commit_all "$R"
mk_item "$R" F1.2 done
commit_all "$R" "flip F1.2 after the audited range"
mk_record "$R" F1 "$base" "$early" 0 0 0
commit_all "$R" record
run_gate "$R" --check
check "done-flip outside range => invalid record" 1
check_out "names the unreached item" "FAIL: record .*F1\.2"

# T9: record for the WRONG milestone id in the filename slot -> invalid
R="$(new_repo t9)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F2 "$base" "$(head_sha "$R")" 0 0 0   # file is audits/F2.md, F1 unaudited
commit_all "$R" record
run_gate "$R" --check
check "record for other milestone leaves F1 in debt" 1
check_out "F1 still in debt" "FAIL: milestone F1 "

# T10: uncommitted done flip (working tree only) -> fail closed
R="$(new_repo t10)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done          # never committed
mk_record "$R" F1 "$base" "$base" 0 0 0
run_gate "$R" --check
check "uncommitted done flip => fail closed" 1
```

- [ ] **Step 2: Run tests, verify the new cases fail**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: T1–T6 PASS; T7–T10 FAIL (validate_record accepts everything with a matching milestone key).

- [ ] **Step 3: Extend `validate_record` with the binding checks**

Replace the whole `validate_record` function in `plugin/hooks/audit-gate.sh` with:

```bash
validate_record() { # validate_record <milestone> <file> ; 0 = valid
  local m="$1" rec="$2"
  local ok=1 k v base head f id flip
  # Required keys — a record missing provenance/scope fields is not a record.
  for k in milestone range_base range_head lens_mode lenses raw refuted confirmed workflow_run journal_sha256; do
    v="$(fm_get "$rec" "$k")"
    [ -n "$v" ] || { fail "record $rec: missing $k:"; ok=0; }
  done
  [ "$(fm_get "$rec" milestone)" = "$m" ] || { fail "record $rec: milestone key != $m"; ok=0; }
  base="$(fm_get "$rec" range_base)"; head="$(fm_get "$rec" range_head)"
  # Binding (the mistarget rule): recompute, never trust. Any git uncertainty
  # is a validation failure — fail closed, the milestone stays in debt.
  if [ -n "$base" ] && [ -n "$head" ]; then
    git cat-file -e "$base^{commit}" 2>/dev/null || { fail "record $rec: range_base is not a commit here"; ok=0; }
    git cat-file -e "$head^{commit}" 2>/dev/null || { fail "record $rec: range_head is not a commit here"; ok=0; }
    if [ "$ok" = 1 ]; then
      git merge-base --is-ancestor "$base" "$head" 2>/dev/null || { fail "record $rec: range_base is not an ancestor of range_head"; ok=0; }
      git merge-base --is-ancestor "$head" HEAD 2>/dev/null || { fail "record $rec: range_head is not an ancestor of HEAD"; ok=0; }
    fi
    if [ "$ok" = 1 ]; then
      # Every done item of M must have completed WITHIN the audited range:
      # the commit that introduced its `status: done` (oldest -S hit) must be
      # reachable from range_head. This is what makes "audited F1's real
      # merges" checkable — an audit of a stale range fails structurally.
      for f in "${BACKLOG_DIR}"*.md; do
        [ -f "$f" ] || continue
        id="$(basename "$f" .md)"
        case "$id" in *.*) [ "${id%.*}" = "$m" ] || continue ;; *) continue ;; esac
        [ "$(fm_get "$f" status)" = "done" ] || continue
        flip="$(git log --format=%H -S'status: done' -- "$f" 2>/dev/null | tail -1)"
        if [ -z "$flip" ]; then
          fail "record $rec: cannot locate the commit that completed $id (uncommitted flip?) — fail closed"; ok=0
        elif ! git merge-base --is-ancestor "$flip" "$head" 2>/dev/null; then
          fail "record $rec: $id completed outside the audited range (flip $flip not reachable from range_head)"; ok=0
        fi
      done
    fi
  fi
  [ "$ok" = 1 ]
}
```

- [ ] **Step 4: Run tests, verify all pass**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: all T1–T10 PASS (T6's record was built from real fixture SHAs, so it stays valid).

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/audit-gate.sh plugin/hooks/audit-gate.test.sh
git commit -m "feat(hooks): audit-gate binding checks — record SHAs recomputed against git ancestry"
```

---

### Task 3: Triage-closure validation

**Files:**
- Modify: `plugin/hooks/audit-gate.sh` (extend `validate_record`)
- Modify: `plugin/hooks/audit-gate.test.sh` (append cases)

**Interfaces:**
- Consumes: Task 2's `validate_record`; `roadmap-lint.sh` (invoked per referenced item file).
- Produces: `validate_record` additionally enforces: `raw == refuted + confirmed`; `### ` finding-block count == `confirmed`; every block has exactly one `disposition:` of `fix_pr #N` | `followup <id>` | `blocked <id>`; referenced items exist, pass roadmap-lint, carry `followup_of: <m>`, and `blocked` ones are `status: blocked`.

- [ ] **Step 1: Append failing tests**

Append to `plugin/hooks/audit-gate.test.sh` (before the final `printf`/exit lines). Note the follow-up item is `status: todo`, so it needs a full lint-passing spec body:

```bash
# mk_todo_followup <repo> <id> <milestone>: lint-clean todo follow-up item
mk_todo_followup() {
  local r="$1" id="$2" m="$3"
  cat > "$r/roadmap/$id.md" <<EOF_ITEM
---
id: $id
title: follow-up
status: todo
depends_on: []
review-dimensions: []
followup_of: $m
---

# $id — follow-up

## Spec
- **Surface:** src/fix.ts
- **Interfaces:** none
- **Out of scope:** everything else

## Acceptance (e2e)
- the finding is fixed
EOF_ITEM
}

# T11: counts inconsistent (raw != refuted + confirmed) -> invalid
R="$(new_repo t11)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 5 2 1
commit_all "$R" record
run_gate "$R" --check
check "raw != refuted+confirmed => invalid" 1

# T12: confirmed=1 but no finding block -> invalid
R="$(new_repo t12)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1
commit_all "$R" record
run_gate "$R" --check
check "confirmed without finding block => invalid" 1

# T13: finding block missing disposition -> invalid
R="$(new_repo t13)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. stale read
severity: high
lens: correctness
'
commit_all "$R" record
run_gate "$R" --check
check "finding without disposition => invalid" 1

# T14: dangling followup reference -> invalid
R="$(new_repo t14)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. stale read
severity: high
lens: correctness
disposition: followup F1.9
'
commit_all "$R" record
run_gate "$R" --check
check "dangling followup ref => invalid" 1
check_out "names the dangling ref" "FAIL: record .*F1\.9"

# T15: fully closed record (fix_pr + followup + blocked) -> valid
R="$(new_repo t15)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_todo_followup "$R" F1.9 F1
mk_item "$R" F1.10 blocked 'followup_of: F1
blocked: should exports include archived rows?'
mk_record "$R" F1 "$base" "$(head_sha "$R")" 5 2 3 '### 1. stale read
severity: high
lens: correctness
disposition: fix_pr #42

### 2. missing index
severity: medium
lens: data-integrity
disposition: followup F1.9

### 3. export scope unclear
severity: low
lens: api-contract
disposition: blocked F1.10
'
commit_all "$R" record
run_gate "$R" --check
check "fully closed record => valid" 0
```

- [ ] **Step 2: Run tests, verify T11–T15 fail**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: T1–T10 PASS; T11–T14 FAIL (records accepted), T15 may PASS trivially — confirm T11–T14 fail before proceeding.

**Important fixture-ordering note for T15:** `mk_todo_followup`/`mk_item F1.10` create items in milestone F1 that are NOT done — that makes F1 *incomplete*, dropping it from the debt/validation path entirely and vacuously passing. To keep F1 complete while follow-ups exist, follow-up items must NOT count toward their `followup_of` milestone's completeness when they carry `followup_of:`. **This is a real semantic the implementation must handle** (the playbook folds follow-ups into the NEXT `/milestone` run — they are debt of the audited milestone, not members of it): in `item_rows`, skip items whose `followup_of:` is set when computing completeness... BUT they still belong to the milestone prefix for other purposes. Implement: `item_rows` emits nothing for items with a non-empty `followup_of:` frontmatter key. Add this to Step 3.

- [ ] **Step 3: Extend `validate_record` with triage closure + exclude follow-ups from completeness**

In `item_rows` (Task 1 code), after `status="$(fm_get "$f" status)"`, add:

```bash
    # Follow-up/blocked items created by an audit's triage are DEBT OF the
    # milestone, not members of it — they must not flip it back to incomplete
    # (they drain in the next /milestone run per the playbook).
    [ -n "$(fm_get "$f" followup_of)" ] && continue
```

Then append inside `validate_record`, after the done-flip loop's closing `fi` (still inside the function, before `[ "$ok" = 1 ]`):

```bash
  # --- triage closure: counts add up and every confirmed finding lands somewhere
  local raw refuted confirmed body blocks dispo ref reftype reffile
  raw="$(fm_get "$rec" raw)"; refuted="$(fm_get "$rec" refuted)"; confirmed="$(fm_get "$rec" confirmed)"
  case "$raw$refuted$confirmed" in *[!0-9]*) fail "record $rec: raw/refuted/confirmed must be numeric"; ok=0 ;; esac
  if [ "$ok" = 1 ] && [ "$raw" -ne $((refuted + confirmed)) ]; then
    fail "record $rec: raw ($raw) != refuted ($refuted) + confirmed ($confirmed)"; ok=0
  fi
  body="$(awk '{ sub(/\r$/,"") } NR==1 && $0=="---" { infm=1; next } infm && /^---$/ { infm=0; next } !infm { print }' "$rec")"
  blocks="$(printf '%s\n' "$body" | grep -c '^### ' || true)"
  if [ "$ok" = 1 ] && [ "$blocks" -ne "$confirmed" ]; then
    fail "record $rec: $blocks finding block(s) but confirmed: $confirmed"; ok=0
  fi
  # One disposition per block, each resolvable. Blocks are separated by ^###
  # headers; a disposition line is `disposition: fix_pr #N | followup <id> |
  # blocked <id>`. Count and validate per block via awk block-splitting.
  if [ "$blocks" -gt 0 ]; then
    local n=0
    while [ "$n" -lt "$blocks" ]; do
      n=$((n + 1))
      dispo="$(printf '%s\n' "$body" | awk -v want="$n" '/^### /{b++} b==want && /^disposition:[[:space:]]/{ sub(/^disposition:[[:space:]]*/,""); print }')"
      if [ "$(printf '%s\n' "$dispo" | grep -c '[^[:space:]]')" -ne 1 ]; then
        fail "record $rec: finding block $n needs exactly one disposition: line"; ok=0; continue
      fi
      case "$dispo" in
        "fix_pr #"[0-9]*) : ;;
        "followup "*|"blocked "*)
          reftype="${dispo%% *}"; ref="${dispo#* }"
          reffile="${BACKLOG_DIR}${ref}.md"
          if [ ! -f "$reffile" ]; then
            fail "record $rec: disposition references $ref but ${reffile} does not exist"; ok=0
          else
            [ "$(fm_get "$reffile" followup_of)" = "$m" ] || { fail "record $rec: $ref must carry followup_of: $m"; ok=0; }
            if [ "$reftype" = "blocked" ]; then
              [ "$(fm_get "$reffile" status)" = "blocked" ] || { fail "record $rec: $ref disposition says blocked but its status is not"; ok=0; }
            fi
            bash "$(dirname "${BASH_SOURCE[0]}")/roadmap-lint.sh" "$reffile" >/dev/null 2>&1 \
              || { fail "record $rec: $ref fails roadmap-lint"; ok=0; }
          fi
          ;;
        *) fail "record $rec: finding block $n has malformed disposition '$dispo'"; ok=0 ;;
      esac
    done
  fi
```

**Gotcha:** `roadmap-lint.sh` is invoked from the FIXTURE repo's cwd but lives beside audit-gate.sh — `$(dirname "${BASH_SOURCE[0]}")` resolves the hook dir correctly regardless of cwd. Its second arg defaults to the item file's own dir, which is the fixture's `roadmap/` — correct for dep resolution.

- [ ] **Step 4: Run tests, verify all T1–T15 pass**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: all PASS (T6's zero-findings record stays valid: 0 == 0 + 0, no blocks).

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/audit-gate.sh plugin/hooks/audit-gate.test.sh
git commit -m "feat(hooks): audit-gate triage closure — dispositions must resolve; follow-ups excluded from completeness"
```

---

### Task 4: Merge mode (`--files`) tests

**Files:**
- Modify: `plugin/hooks/audit-gate.test.sh` (append cases; the `--files` implementation shipped in Task 1 — this task proves it against real debt states and fixes anything the tests flush out)

**Interfaces:**
- Consumes: `audit-gate.sh --files <path>...` from Task 1; debt semantics from Tasks 2–3.
- Produces: verified merge-mode contract for Task 5.

- [ ] **Step 1: Append the merge-mode cases**

Append to `plugin/hooks/audit-gate.test.sh` (before the final `printf`/exit lines):

```bash
# T16: no debt -> any file list passes
R="$(new_repo t16)"
mk_item "$R" F1.1 todo
commit_all "$R"
run_gate "$R" --files roadmap/F1.2.md src/a.ts
check "no debt => merge mode passes" 0

# T17: debt + code-only PR -> pass
R="$(new_repo t17)"
mk_item "$R" F1.1 done
commit_all "$R"
run_gate "$R" --files src/a.ts docs/x.md
check "debt + code-only PR => pass" 0

# T18: debt + roadmap-advancing PR -> deny
run_gate "$R" --files roadmap/F2.1.md src/a.ts
check "debt + item-file PR => deny" 1
check_out "deny names the debt" "FAIL: audit debt .*F1"

# T19: debt + discharge PR (record + follow-up in same PR) -> pass
run_gate "$R" --files roadmap/audits/F1.md roadmap/F1.9.md ROADMAP.md
check "discharge PR passes" 0

# T20: debt + record for a NON-debt milestone does not discharge -> deny
run_gate "$R" --files roadmap/audits/F9.md roadmap/F2.1.md
check "wrong-milestone record does not discharge" 1

# T21: subdir files (ideas/) are not item files -> pass
run_gate "$R" --files roadmap/ideas/some-idea.md
check "ideas/ files do not trigger the gate" 0
```

- [ ] **Step 2: Run tests**

Run: `bash plugin/hooks/audit-gate.test.sh`
Expected: all PASS. If T16–T21 surface ordering/pattern bugs in the Task-1 `--files` block (e.g. the `case` patterns matching in the wrong order), fix `audit-gate.sh` minimally until green — the `case` arm order matters: `audits/` first, then `*/*` (other subdirs), then top-level `*.md`.

- [ ] **Step 3: Commit**

```bash
git add plugin/hooks/audit-gate.test.sh plugin/hooks/audit-gate.sh
git commit -m "test(hooks): audit-gate merge-mode (--files) coverage — roadmap-scoped denial + discharge"
```

---

### Task 5: `pre-merge-gate.sh` integration

**Files:**
- Modify: `plugin/hooks/pre-merge-gate.sh` (in `verify_pr`, after the base-freshness compare passes, before `return 0`; and add `files` to the `gh pr view --json` field list at line ~225)
- Modify: `plugin/hooks/pre-merge-gate.test.sh` (stub `gh` gains a `files` field; new cases)

**Interfaces:**
- Consumes: `audit-gate.sh --files` (Task 4 contract); `emit_deny`, `bounded_run`, `verify_pr` internals from the existing hook.
- Produces: every `gh pr merge` is additionally gated on audit debt.

- [ ] **Step 1: Add failing test cases**

In `plugin/hooks/pre-merge-gate.test.sh`, first extend the stub `gh`'s `green` mode (only `green` needs it — audit cases run against green PRs) so its JSON includes a `files` field driven by `GH_FILES_JSON`:

Replace the `green)` block's echo with:

```bash
  green)
    printf '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"},"files":%s}\n' "${GH_FILES_JSON:-[]}" ;;
```

Then extend the existing `run_gate` helper (it hardcodes `cwd:$WORK` via `--arg d "$WORK"`) with an optional third parameter so audit cases can point cwd at a fixture repo, defaulting to the current value so every existing case is untouched:

```bash
run_gate() {  # $1=GH_STUB, $2=command, [$3=cwd override] ; feeds mock PreToolUse JSON
  local stub="$1" cmd="$2" cwd="${3:-$WORK}"
  local json
  json="$(jq -cn --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
  PATH="$STUB_BIN:$PATH" GH_STUB="$stub" GH_COMPARE="${GH_COMPARE:-0}" \
    MERGE_GATE_GH_TIMEOUT="${MGT:-5}" GH_FILES_JSON="${GH_FILES_JSON:-[]}" \
    bash "$GATE" <<<"$json"
}
```

Append cases at the end of the pre-merge-gate section (before the backstop/summary), in the harness's inline `ok`/`bad` style:

```bash
echo "== audit-gate integration =="

# Fixture repo with audit debt (complete milestone F1, no record).
AUD="$WORK/audrepo"
mkdir -p "$AUD/roadmap/audits"
git -C "$AUD" init -q
git -C "$AUD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf -- '---\nid: F1.1\ntitle: t\nstatus: done\ndepends_on: []\nreview-dimensions: []\n---\n' > "$AUD/roadmap/F1.1.md"
git -C "$AUD" add -A && git -C "$AUD" -c user.email=t@t -c user.name=t commit -qm items

# (g1) green PR whose files advance the backlog while debt exists -> DENY
out="$(GH_FILES_JSON='[{"path":"roadmap/F2.1.md"}]' run_gate green 'gh pr merge 7 --squash' "$AUD")"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'audit'; then
  ok "g1) audit debt + item-file PR -> deny"
else bad "g1) audit debt + item-file PR -> deny" "out: $out"; fi

# (g2) green PR, code-only files, same debt -> ALLOW (silent)
out="$(GH_FILES_JSON='[{"path":"src/a.ts"}]' run_gate green 'gh pr merge 7 --squash' "$AUD")"
if [ -z "$out" ]; then ok "g2) audit debt + code-only PR -> allow"
else bad "g2) audit debt + code-only PR -> allow" "unexpected stdout: $out"; fi

# (g3) green PR discharging the debt -> ALLOW
out="$(GH_FILES_JSON='[{"path":"roadmap/audits/F1.md"},{"path":"roadmap/F1.9.md"}]' run_gate green 'gh pr merge 7 --squash' "$AUD")"
if [ -z "$out" ]; then ok "g3) discharge PR -> allow"
else bad "g3) discharge PR -> allow" "unexpected stdout: $out"; fi

# (g4) file list at the truncation threshold -> DENY (fail closed)
BIGLIST='['; i=0; while [ $i -lt 100 ]; do BIGLIST="$BIGLIST{\"path\":\"src/f$i.ts\"},"; i=$((i+1)); done
BIGLIST="${BIGLIST%,}]"
out="$(GH_FILES_JSON="$BIGLIST" run_gate green 'gh pr merge 7 --squash' "$AUD")"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'truncat'; then
  ok "g4) 100-file PR fails closed"
else bad "g4) 100-file PR fails closed" "out: $out"; fi
```

- [ ] **Step 2: Run, verify the new cases fail**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: existing cases PASS (the hook ignores the new `files` field so far); the deny/discharge/truncation cases FAIL.

- [ ] **Step 3: Implement the hook change**

In `plugin/hooks/pre-merge-gate.sh`:

(a) Line ~225, extend the field list:

```bash
  if ! bounded_run "$budget" gh pr view "$pr" --json statusCheckRollup,mergeStateStatus,baseRefName,headRefOid,files; then
```

(b) In `verify_pr`, after the `behind` check's closing `fi` and before the final `return 0`, insert:

```bash
  # --- audit gate (roadmap-scoped denial; logic lives in audit-gate.sh) ---------
  # Deterministic and local: uses the SAME view payload (files ride the query),
  # so this adds no gh calls and no budget pressure.
  local fcount fpaths_nl ag_out ag_rc
  fcount="$(printf '%s' "$json" | jq -r '(.files // []) | length' 2>/dev/null)"
  if ! printf '%s' "$fcount" | grep -qE '^[0-9]+$'; then
    emit_deny "merge-gate: could not read PR #$pr's changed-file list for the audit gate. Denying (recoverable) — re-run the merge."
    return 1
  fi
  if [ "$fcount" -ge 100 ]; then
    emit_deny "merge-gate: PR #$pr reports $fcount changed files — gh may truncate the list at 100, so the audit gate cannot classify this PR. Failing CLOSED. Split the PR (or land the audit record first)."
    return 1
  fi
  if [ "$fcount" -gt 0 ]; then
    fpaths_nl="$(printf '%s' "$json" | jq -r '(.files // []) | .[].path' 2>/dev/null)"
    local -a fpaths=()
    while IFS= read -r fp; do [ -n "$fp" ] && fpaths+=("$fp"); done <<AUDIT_FILES_EOF
$fpaths_nl
AUDIT_FILES_EOF
    ag_out="$(bash "$(dirname "${BASH_SOURCE[0]}")/audit-gate.sh" --files "${fpaths[@]}" 2>&1)"
    ag_rc=$?
    if [ "$ag_rc" != "0" ]; then
      emit_deny "merge-gate: audit gate refused PR #$pr: ${ag_out} (see plugin/hooks/audit-gate.sh; run 'audit-gate.sh --check' for the full debt state)"
      return 1
    fi
  fi
```

**Design notes the implementer must keep:** the call is unconditioned on exit-code kind — usage errors, missing script, anything non-zero denies (fail closed); the audit-gate runs in the caller's cwd (the hook already `cd`'d there); `local -a` is fine (the file already targets bash arrays via `MC_PRS` handling in its lib).

- [ ] **Step 4: Run both hook test suites, verify green**

Run: `bash plugin/hooks/pre-merge-gate.test.sh && bash plugin/hooks/audit-gate.test.sh`
Expected: all PASS, including every pre-existing pre-merge-gate case (no-debt repos: the existing cases' cwd has no roadmap dir → `item_rows` finds nothing → no debt → pass-through).

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/pre-merge-gate.sh plugin/hooks/pre-merge-gate.test.sh
git commit -m "feat(hooks): pre-merge-gate consults audit-gate — audit debt denies backlog-advancing merges"
```

---

### Task 6: Command docs — `/milestone-audit` writes the record; pre-flights consult the gate

**Files:**
- Modify: `plugin/commands/milestone-audit.md`
- Modify: `plugin/commands/milestone.md` (pre-flight, near the `backlog.prefix` step at line ~14)
- Modify: `plugin/commands/roadmap.md` (pre-flight, same region)

**Interfaces:**
- Consumes: `audit-gate.sh --check`; the record format from the spec.
- Produces: the doctrine layer that tells sessions to produce what the gate demands.

- [ ] **Step 1: Extend `plugin/commands/milestone-audit.md`**

Append after the triage-buckets section (after the "The dividing line…" paragraph) and REPLACE the final "Post a summary…" paragraph with:

```markdown
**Write the audit record (mechanical part of the audit's definition of done).**
After triage, write `<backlog.dir>audits/<milestone>.md`:

    ---
    milestone: F3
    range_base: <base sha of the audited range>
    range_head: <head sha of the audited range>
    lens_mode: default            # default | default-plus | explicit
    lenses: [correctness, authz, data-integrity, concurrency, test-integrity, api-contract]
    raw: 14                       # from the Workflow's stats
    refuted: 9
    confirmed: 5
    workflow_run: wf_...          # the Workflow invocation's runId
    journal_sha256: <sha256 of the run's journal.jsonl>
    ---

One `### <n>. <title>` block per confirmed finding with flat `severity:`,
`lens:`, and exactly one `disposition:` line — `fix_pr #NN` | `followup <id>` |
`blocked <id>`. Transcribe the Workflow's RETURN VALUE — do not restate
findings from memory. Compute `journal_sha256` with
`shasum -a 256 <transcriptDir>/journal.jsonl` from the run's transcript
directory. Land the record, its `followup_of:`-tagged follow-up/blocked item
files, and the index update in ONE PR through the normal gate (the audit gate
recognizes that PR as debt discharge).

Then run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the
repo root and QUOTE its passing output in your summary. A `FAIL:` line means
the record is malformed or mis-bound — fix the record, never the gate.

Post a summary of the run: range audited, lenses used, raw/refuted/confirmed
counts, where each confirmed finding landed (fix-PR link, follow-up item file,
or `status: blocked` item), and the quoted `audit-gate.sh --check` pass.
```

- [ ] **Step 2: Add the pre-flight line to `plugin/commands/milestone.md`**

In the pre-flight list (immediately after the `backlog.prefix` bullet at line ~14), insert:

```markdown
- Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the repo
  root. Any `FAIL:` output means **audit debt**: a completed milestone lacks a
  valid audit record. The ONLY permitted work while debt exists is discharging
  it (run `/milestone-audit` for the named milestone; land its record PR) —
  do not resolve a new milestone past unaudited work. (Debt-only runs draining
  `followup_of:` items are, as ever, fine — they are the discharge.)
```

- [ ] **Step 3: Add the same pre-flight to `plugin/commands/roadmap.md`**

After its `backlog.prefix` bullet (line ~14), insert:

```markdown
- Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the repo
  root. `FAIL:` lines mean audit debt — do NOT draft the next milestone's
  items on top of an unaudited one; surface the debt and stop at that
  boundary (the merge gate would refuse the milestone PR anyway).
```

- [ ] **Step 4: Verify doc consistency**

Run: `grep -n "audit-gate" plugin/commands/*.md`
Expected: hits in all three files, each using `${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check`.

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/milestone-audit.md plugin/commands/milestone.md plugin/commands/roadmap.md
git commit -m "docs(commands): audit record writing + audit-gate pre-flights"
```

---

### Task 7: Playbook + template + version bump

**Files:**
- Modify: `plugin/playbook/agentic-loop-playbook.md` ("Milestone audit" section, config listing at line ~40, new CI subsection)
- Modify: `plugin/templates/CLAUDE.md` (config block, line ~18)
- Modify: `plugin/plugin.json` (version 0.1.0 → 0.2.0)

**Interfaces:**
- Consumes: everything above (documents it).
- Produces: consumer-facing doctrine incl. the CI required-check recipe.

- [ ] **Step 1: Config listing — add `audit.baseline` to the playbook**

In `plugin/playbook/agentic-loop-playbook.md`, after the `audit.lenses` bullet (ends around line 50), add:

```markdown
- **`audit.baseline`** — inline list of milestones grandfathered before audit
  enforcement shipped (e.g. `[F1, F2]`). Milestones listed here are exempt
  from the audit-gate's debt computation. Set once at adoption; never grow it
  to dodge an audit — that is the bypass the gate exists to make visible.
```

- [ ] **Step 2: Extend the "Milestone audit" section**

In the same file, at the end of the "Milestone audit (after a milestone completes)" section (after the UI-audit paragraph, before the token-spend paragraph at line ~552), add:

```markdown
**The audit record + gate (mechanical enforcement).** The audit's definition
of done includes a committed record at `<backlog.dir>audits/<milestone>.md`
(range SHAs, lens set, raw/refuted/confirmed counts, one block per confirmed
finding with its disposition — see `/milestone-audit`). The record is what
makes "the audit ran, on the right range, and its findings went somewhere"
machine-checkable: `hooks/audit-gate.sh` recomputes the binding from git
ancestry (a record for the wrong milestone or a stale range fails
structurally) and verifies every disposition resolves. A completed milestone
without a valid record is **audit debt**: the merge gate denies any
backlog-advancing merge (roadmap item files) until the record PR lands;
code-only PRs (hotfixes, chores) pass. What this cannot do — by design and
per the attestation literature — is judge audit QUALITY: a real-but-shallow
audit passes the gate. The adversarial refuter design and the human on the
direction loop remain the answer for that.
```

- [ ] **Step 3: Add the CI subsection**

Immediately after the text added in Step 2, add:

```markdown
**Enforcing the audit gate in CI (consumer repos).** Add an always-run job to
the repo's CI workflow and make it a required check:

    audit-gate:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
          with: { fetch-depth: 0 }   # the gate's ancestry checks need history
        - name: audit gate
          run: |
            bash <plugin-path>/hooks/audit-gate.sh --check
            if [ -n "${{ github.base_ref }}" ]; then
              git fetch -q origin "${{ github.base_ref }}"
              CHANGED=$(git diff --name-only "origin/${{ github.base_ref }}...HEAD")
              [ -z "$CHANGED" ] || bash <plugin-path>/hooks/audit-gate.sh --files $CHANGED
            fi

Hard-won rules for the required check (research memo, 2026-08-08):
- **Never** put the job behind a `paths:` filter or a job-level `if:` — a
  job skipped by an `if:` reports SUCCESS and *satisfies* the required check
  (GitHub-documented). Always run; the gate is cheap.
- Pin the required check to the **GitHub Actions app** in the ruleset, never
  "any source": commit statuses can be posted green by any push-access token,
  while check runs are App-only.
- Protect `.github/workflows/**` (CODEOWNERS or a push ruleset) and keep the
  default `GITHUB_TOKEN` read-only — otherwise the actor can edit the
  validator out of its own way.
```

- [ ] **Step 4: Template config block**

In `plugin/templates/CLAUDE.md`, after the `audit.lenses:     default` line (line 18), add:

```markdown
audit.baseline:   []
```

- [ ] **Step 5: Version bump + full test sweep**

In `plugin/plugin.json`: `"version": "0.1.0"` → `"version": "0.2.0"`.

Run: `bash plugin/hooks/audit-gate.test.sh && bash plugin/hooks/pre-merge-gate.test.sh && bash plugin/hooks/roadmap-lint.test.sh`
Expected: all three suites fully PASS.

- [ ] **Step 6: Commit**

```bash
git add plugin/playbook/agentic-loop-playbook.md plugin/templates/CLAUDE.md plugin/plugin.json
git commit -m "docs(playbook): audit record + gate doctrine, CI required-check recipe, audit.baseline config"
```

---

## Self-Review Checklist (run after all tasks)

1. **Spec coverage:** record format ✔ (T6/T15 fixtures + command doc), skip rule ✔ (T3/T17–T19), mistarget ✔ (T7–T10), triage closure ✔ (T11–T15), baseline ✔ (T4), roadmap-scoped denial ✔ (T16–T21), pre-merge-gate wiring ✔ (Task 5), pre-flights ✔ (Task 6), CI guidance + hardening ✔ (Task 7), stamping ✔ (record keys + command doc).
2. **Fail-closed:** every uncertain path in audit-gate and the hook insertion denies/fails with a reason; verified by T7/T10 and the truncation case.
3. **No weakened invariants:** pre-merge-gate still never emits an allow; audit-gate `--check` is offline.
