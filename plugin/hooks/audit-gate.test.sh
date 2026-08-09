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

# T15b: follow-up completion after record should not invalidate it
# (done-flip loop must exclude items with followup_of:, just like item_rows does)
R="$(new_repo t15b)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
range_head="$(head_sha "$R")"
mk_record "$R" F1 "$base" "$range_head" 0 0 0
commit_all "$R" record
# Now (after the record is committed) create and complete a follow-up item.
# This is the normal debt-drain flow: the follow-up was referenced in the record
# but only completes later (in a post-audit commit).
mk_todo_followup "$R" F1.9 F1
commit_all "$R"
# Flip F1.9 to done while preserving its followup_of: key (portable awk+mv, not sed -i)
awk '{ sub(/^status: todo$/, "status: done"); print }' "$R/roadmap/F1.9.md" > "$R/roadmap/F1.9.md.tmp" && mv "$R/roadmap/F1.9.md.tmp" "$R/roadmap/F1.9.md"
grep -q '^status: done$' "$R/roadmap/F1.9.md" || { echo 'T15b fixture broken: flip did not apply'; exit 1; }
commit_all "$R"
run_gate "$R" --check
check "follow-up completing after record doesn't invalidate it" 0

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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
