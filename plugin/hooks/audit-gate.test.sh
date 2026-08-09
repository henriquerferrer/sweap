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
