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
  { printf -- '---\nsweap_format: 1\nmilestone: %s\nrange_base: %s\nrange_head: %s\nlens_mode: default\n' "$m" "$base" "$head"
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

# T22-T24: invalid record (unresolvable range_head, T7 fixture shape) must join
# the debt set SILENTLY in merge mode, not deny outright. Regression: every
# internal fail() inside validate_record set the shared `fails` global, and
# only the record-MISSING branch was --check-gated, so an INVALID record used
# to deny even code-only PRs in --files mode.
R="$(new_repo t22)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "0000000000000000000000000000000000000000" 0 0 0
commit_all "$R" record

# T22: invalid record + code-only PR -> pass
run_gate "$R" --files src/a.ts docs/x.md
check "invalid record + code-only PR => pass" 0

# T23: invalid record + item-file PR -> deny (invalid record still counts as debt)
run_gate "$R" --files roadmap/F2.1.md
check "invalid record + item-file PR => deny" 1
check_out "deny names the debt for invalid record" "FAIL: audit debt .*F1"

# T24: invalid record + discharge PR (record path present) -> pass
run_gate "$R" --files roadmap/audits/F1.md roadmap/F2.1.md
check "discharge PR may fix an invalid record" 0

# --check on the same repo still fails AND still prints the range_head
# diagnostic (guards the re-emit path — no loss of --check diagnostics)
run_gate "$R" --check
check "--check still denies invalid record" 1
check_out "--check still prints the range_head diagnostic" "FAIL: record .*range_head"

# T25: CLAUDE.md using the SHIPPED TEMPLATE's exact commented `backlog.dir:`
# style (copied verbatim from plugin/templates/CLAUDE.md) with a complete
# milestone and no record. Regression: cfg_get used to capture the whole rest
# of the line, so BACKLOG_DIR became "roadmap/  ... Backlog format"/ (a
# nonexistent dir) -> item_rows found zero items -> gate passed unconditionally
# on every template-scaffolded repo. Must now deny, naming the milestone.
R="$(new_repo t25)"
mk_item "$R" F1.1 done
commit_all "$R"
{
  printf '## sweap config\n'
  printf 'backlog.dir:      roadmap/                  # one file per item — see playbook "Backlog format"\n'
  printf 'audit.baseline:   []\n'
} > "$R/CLAUDE.md"
commit_all "$R" "template-style CLAUDE.md"
run_gate "$R" --check
check "template-commented backlog.dir still finds the debt" 1
check_out "debt names milestone despite the inline comment" "FAIL: milestone F1 .*no audit record"

# T26: inline list + trailing comment (`audit.baseline: [F1] # grandfathered`)
# must strip the comment while keeping the list intact, so F1 stays exempt.
R="$(new_repo t26)"
mk_item "$R" F1.1 done
commit_all "$R"
printf '## sweap config\naudit.baseline: [F1] # grandfathered\n' > "$R/CLAUDE.md"
commit_all "$R" "baseline with inline comment"
run_gate "$R" --check
check "inline-comment baseline still exempts F1" 0

# --- record format versioning + legacy (pre-format) records ---------------------
# Regression suite for the 2026-08-11 consumer A miss: F9's record landed as pure
# prose (written by a sweap that had no record format yet) and a later plugin
# refresh retroactively turned it into merge-blocking debt. A tightening must
# report inherited records, never wedge the loop on them — and must still refuse
# to let NEW pre-format records in.
anchor_main() { git -C "$1" update-ref refs/remotes/origin/main HEAD; }
# mk_prose_record <repo> <milestone>: a pre-format record — pure prose, no frontmatter.
mk_prose_record() { printf '# %s milestone audit\n\nWe audited it. Trust me.\n' "$2" > "$1/roadmap/audits/$2.md"; }

# T27: a record that DECLARES a format this gate does not speak is hard debt —
# it carries sweap_format, so it is not inherited, it is wrong.
R="$(new_repo t27)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 0 0 0
sed -i.bak 's/^sweap_format: 1$/sweap_format: 2/' "$R/roadmap/audits/F1.md" && rm -f "$R/roadmap/audits/F1.md.bak"
commit_all "$R" rec
anchor_main "$R"
run_gate "$R" --check
check "unknown sweap_format => hard debt" 1
check_out "names the format mismatch" "sweap_format: 2 but this gate speaks format 1"

# T28: an ALREADY-MERGED pre-format record is reported as STALE, not FAIL —
# --check passes so the repo's loop is not wedged by a format introduction.
R="$(new_repo t28)"
mk_item "$R" F1.1 done
mk_prose_record "$R" F1
commit_all "$R"
anchor_main "$R"
run_gate "$R" --check
check "merged pre-format record => STALE, not debt" 0
check_out "STALE line names the record and the migration path" "STALE: record roadmap/audits/F1.md predates"

# T29: and it does not block a backlog-advancing merge (the F10-on-top case).
run_gate "$R" --files roadmap/F2.1.md
check "stale-only debt does not block an item-file PR" 0

# T30: THE DOOR CLOSES. A pre-format record introduced by the work under review
# (its adding commit is not reachable from origin/main) is judged strictly — so
# "legacy" can be inherited but never authored.
R="$(new_repo t30)"
mk_item "$R" F1.1 done
commit_all "$R"
anchor_main "$R"
mk_prose_record "$R" F1
commit_all "$R" "sneak in a prose record"
run_gate "$R" --check
check "newly-added pre-format record => hard debt" 1
check_out "judged strictly, not grandfathered" "FAIL: record roadmap/audits/F1.md: missing sweap_format:"
run_gate "$R" --files roadmap/F2.1.md
check "newly-added pre-format record still blocks merges" 1

# T31: no mainline anchor (no remote) => nothing can be proven inherited, so the
# gate judges strictly. Uncertainty is never a free pass.
R="$(new_repo t31)"
mk_item "$R" F1.1 done
mk_prose_record "$R" F1
commit_all "$R"
run_gate "$R" --check
check "no origin/main => pre-format record judged strictly" 1

# --- defects: collapsing converged findings -------------------------------------
# A multi-lens ensemble converging on ONE defect is the normal case, not an edge
# case (consumer A F9: six lenses hit the same claim-lease bug). Blocks are
# dispositions, not findings.

# T32a: without `defects:`, blocks must still equal confirmed (unchanged contract).
R="$(new_repo t32a)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 6 0 6 '### 1. a
disposition: fix_pr #1
### 2. b
disposition: fix_pr #2'
commit_all "$R" rec
run_gate "$R" --check
check "no defects: key => blocks must equal confirmed" 1

# T32b: `defects: 2` lets 6 converged findings collapse to 2 disposition blocks.
sed -i.bak 's/^confirmed: 6$/confirmed: 6\ndefects: 2/' "$R/roadmap/audits/F1.md" && rm -f "$R/roadmap/audits/F1.md.bak"
commit_all "$R" collapse
run_gate "$R" --check
check "defects: collapses converged findings" 0

# T32c: a collapse may merge, never invent — defects > confirmed is rejected.
sed -i.bak 's/^defects: 2$/defects: 9/' "$R/roadmap/audits/F1.md" && rm -f "$R/roadmap/audits/F1.md.bak"
commit_all "$R" overclaim
run_gate "$R" --check
check "defects > confirmed => invalid" 1
check_out "names the collapse rule" "defects (9) must be >0 and <= total confirmed across all axes (6)"

# T32d: nor may it drop everything — confirmed findings must land somewhere.
sed -i.bak 's/^defects: 9$/defects: 0/' "$R/roadmap/audits/F1.md" && rm -f "$R/roadmap/audits/F1.md.bak"
commit_all "$R" dropall
run_gate "$R" --check
check "defects: 0 with confirmed findings => invalid" 1

# T33: the anchor is overridable (CI on a PR points it at origin/<base_ref>).
R="$(new_repo t32)"
mk_item "$R" F1.1 done
mk_prose_record "$R" F1
commit_all "$R"
git -C "$R" update-ref refs/remotes/origin/release HEAD
OUT="$( (cd "$R" && SWEAP_MAIN_REF=origin/release bash "$GATE" --check) 2>&1)"; RC=$?
check "SWEAP_MAIN_REF selects the anchor" 0

# --- multi-axis audits (code + Tier-2 UI) ---------------------------------------
# A UI-heavy milestone is audited on two axes, each a separate run with its own
# lens set, stats and journal. Consumer A F9: 54/34/20 on code, 11/9/2 on UI, and the
# two UI survivors (FK.4, FK.5) needed disposition blocks that no single
# `confirmed` count could account for.
add_axis() { # add_axis <repo> <milestone> <axis> <raw> <refuted> <confirmed>
  local r="$1" m="$2" ax="$3"
  python3 - "$r/roadmap/audits/$m.md" "$ax" "$4" "$5" "$6" <<'PYEOF'
import sys
p,ax,raw,ref,conf=sys.argv[1:6]
s=open(p).read().split('---')
fm=s[1].rstrip('\n')
fm+=f"\naxes: [{ax}]\n{ax}.raw: {raw}\n{ax}.refuted: {ref}\n{ax}.confirmed: {conf}\n"
fm+=f"{ax}.lens_mode: explicit\n{ax}.lenses: [hierarchy, a11y]\n{ax}.workflow_run: wf_ui\n{ax}.journal_sha256: beef\n"
open(p,'w').write('---'+fm+'\n---'+'---'.join(s[2:]))
PYEOF
}

# T34: a UI-axis survivor may carry its own disposition block. Primary confirmed
# is 1, UI confirmed is 2 => 3 blocks are legitimate.
R="$(new_repo t34)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. code defect
disposition: fix_pr #1
### 2. ui a11y defect
disposition: fix_pr #2
### 3. ui focus defect
disposition: fix_pr #3'
add_axis "$R" F1 ui 11 9 2
commit_all "$R" rec
run_gate "$R" --check
check "UI-axis survivors get their own disposition blocks" 0

# T35: a declared axis must carry its full key set.
R="$(new_repo t35)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. x
disposition: fix_pr #1'
sed -i.bak 's/^confirmed: 1$/confirmed: 1\naxes: [ui]/' "$R/roadmap/audits/F1.md" && rm -f "$R/roadmap/audits/F1.md.bak"
commit_all "$R" rec
run_gate "$R" --check
check "declared axis missing its keys => invalid" 1
check_out "names the missing axis key" "axis 'ui' is declared but ui.raw: is missing"

# T36: axis stats must themselves add up.
R="$(new_repo t36)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. x
disposition: fix_pr #1'
add_axis "$R" F1 ui 11 9 5
commit_all "$R" rec
run_gate "$R" --check
check "axis raw != refuted + confirmed => invalid" 1

# T37: blocks are still bounded — an axis does not license unlimited blocks.
R="$(new_repo t37)"
base="$(head_sha "$R")"
mk_item "$R" F1.1 done
commit_all "$R"
mk_record "$R" F1 "$base" "$(head_sha "$R")" 1 0 1 '### 1. a
disposition: fix_pr #1
### 2. b
disposition: fix_pr #2
### 3. c
disposition: fix_pr #3
### 4. d
disposition: fix_pr #4'
add_axis "$R" F1 ui 11 9 2
commit_all "$R" rec
run_gate "$R" --check
check "blocks beyond total confirmed across axes => invalid" 1

# --- T38-T43: the milestone boundary -------------------------------------------
# The final PR of a milestone is the one merge the gate cannot ask for a record
# on: the audit only runs against the merged mainline (playbook, "Audit
# evidence"), and validate_record enforces that (range_head ancestor of HEAD).
# Before this, that PR was denied in BOTH modes on its own checkout, so no
# milestone could ever be completed. Consumer A hit it on F10.4, 2026-08-15.
#
# with_anchor <ref> <repo> <args...>: run the gate with SWEAP_MAIN_REF set.
# Exported/unset around the call rather than prefixed onto run_gate — a
# `VAR=x func` prefix on a FUNCTION can persist past the call in bash.
with_anchor() { local a="$1"; shift; export SWEAP_MAIN_REF="$a"; run_gate "$@"; unset SWEAP_MAIN_REF; }

# boundary_repo <name>: echoes "<repo> <base_sha>". At base_sha F1.1 is done and
# F1.2 is todo (F1 incomplete); the tip flips F1.2 to done, exactly as the PR
# that completes the milestone does.
boundary_repo() {
  local r; r="$(new_repo "$1")"
  mk_item "$r" F1.1 done
  mk_item "$r" F1.2 todo
  commit_all "$r" base
  local b; b="$(head_sha "$r")"
  mk_item "$r" F1.2 done
  commit_all "$r" "complete F1"
  printf '%s %s\n' "$r" "$b"
}

# T38: --check on the completing diff -> pass, and say why
read -r R BASE <<<"$(boundary_repo t38)"
with_anchor "$BASE" "$R" --check
check "milestone completed by this diff => --check passes" 0
check_out "--check explains the deferral" "^DEFERRED: milestone F1 becomes complete"

# T39: --files on the completing diff -> NOT denied. This is the case that
# actually unblocks the merge: the CI job runs --files on the PR's own checkout,
# and the PR touches the very item file that completed the milestone, so a
# --check-only exemption would leave the deadlock intact.
with_anchor "$BASE" "$R" --files roadmap/F1.2.md ROADMAP.md
check "completing PR is not denied in merge mode" 0

# T40: one PR later the exemption is GONE. The anchor now contains the
# completion, so F1 is real debt and the next backlog-advancing PR is denied.
with_anchor "$(head_sha "$R")" "$R" --files roadmap/F2.1.md
check "after the completion lands, debt blocks the next item PR" 1
check_out "post-landing denial names F1" "FAIL: audit debt .*F1"
with_anchor "$(head_sha "$R")" "$R" --check
check "after the completion lands, --check reports the debt" 1
check_out "post-landing --check names F1" "FAIL: milestone F1 is complete but has no audit record"

# T41: the exemption is per-milestone, not a blanket pass. Debt inherited from
# the anchor still fails on the very same diff that completes another milestone.
R="$(new_repo t41)"
mk_item "$R" F0.1 done
mk_item "$R" F1.1 done
mk_item "$R" F1.2 todo
commit_all "$R" base
BASE="$(head_sha "$R")"
mk_item "$R" F1.2 done
commit_all "$R" "complete F1"
with_anchor "$BASE" "$R" --check
check "inherited debt still fails on a completing diff" 1
check_out "inherited debt names F0" "FAIL: milestone F0 is complete but has no audit record"
check_out "and F1 is still deferred" "^DEFERRED: milestone F1"
with_anchor "$BASE" "$R" --files roadmap/F1.2.md
check "inherited debt still denies the completing PR in merge mode" 1

# T42: FAILS CLOSED on an unresolvable anchor — an unknown base exempts nothing,
# so the pre-existing behaviour (and T3) is what a bogus ref gets.
read -r R BASE <<<"$(boundary_repo t42)"
with_anchor "refs/heads/no-such-branch-here" "$R" --check
check "unresolvable anchor => nothing is exempt (fails closed)" 1
check_out "fail-closed names the milestone" "FAIL: milestone F1 is complete but has no audit record"

# T43: SCOPE — the exemption covers a MISSING record only. A record PRESENT on
# the completing diff is validated strictly, because CI is the only surface that
# catches a malformed record before it merges.
read -r R BASE <<<"$(boundary_repo t43)"
mk_record "$R" F1 "$BASE" "$(head_sha "$R")" 5 1 1 '### 1. x
disposition: fix_pr #1'
commit_all "$R" rec
with_anchor "$BASE" "$R" --check
check "a record present on the completing diff is still validated" 1
check_out "malformed record on the completing diff is named" "FAIL: record .*raw (5)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
