#!/usr/bin/env bash
#
# pre-merge-gate.test.sh — deterministic, offline test for the merge-gate hooks.
#
# Proves every branch of pre-merge-gate.sh (and the post-merge-redcheck backstop)
# WITHOUT touching GitHub or creating a real red PR. It puts a stubbed `gh` on
# PATH whose rollup output is driven by env vars, feeds the hook mock PreToolUse
# JSON on stdin, and asserts the emitted decision.
#
# Run:  bash .claude/hooks/pre-merge-gate.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).

# Many test commands are single-quoted ON PURPOSE — `$(...)`, `$n` and backticks
# must reach the parser as LITERAL text (that is exactly what we're testing).
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/pre-merge-gate.sh"
BACKSTOP="$HERE/post-merge-redcheck.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- stub `gh` ------------------------------------------------------------------
# Two shapes the hook issues:
#   - `gh pr view <n> --json ...` : rollup + mergeability. Mode is GH_STUB,
#     overridable PER PR via GH_STUB_<n> (e.g. GH_STUB_43=failure) so
#     chained-merge tests can make different PRs green/red independently. The
#     PR's changed-file list is GH_FILES_JSON, overridable PER PR the same way
#     via GH_FILES_JSON_<n>. If GH_MARK names a path, every view call touches
#     it (lets a test prove the merge branch was never consulted).
#   - `gh api repos/.../compare/<base>...<headOid> --jq .behind_by` : the
#     protection-independent base-freshness check. Answer driven by GH_COMPARE:
#     unset/`0` -> print `0` (head up-to-date); an integer like `2` -> print it
#     (that many commits behind); `error` -> exit 1 (gh api unreachable).
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash

# --- base-freshness compare shape ('gh api …/compare/… --jq .behind_by') -----
# Detected by the `api` subcommand word; the compare answer is ground truth for
# stale-green detection, so it is independent of mergeStateStatus/protection.
for a in "$@"; do
  if [ "$a" = "api" ]; then
    case "${GH_COMPARE:-0}" in
      error)  exit 1 ;;                                 # gh api failed / unreachable
      ''|0)   echo 0; exit 0 ;;                         # default: head up-to-date
      *)      printf '%s\n' "${GH_COMPARE}"; exit 0 ;;  # e.g. 2 commits behind
    esac
  fi
done

# --- pr view shape ('gh pr view <n> --json …') -------------------------------
num=""
seen_view=0
for a in "$@"; do
  if [ "$seen_view" = "1" ] && [ -z "$num" ]; then
    case "$a" in -*) : ;; *[!0-9]*) : ;; *) num="$a" ;; esac
  fi
  [ "$a" = "view" ] && seen_view=1
done
ovr="GH_STUB_${num}"
mode="${!ovr:-${GH_STUB:-green}}"
fovr="GH_FILES_JSON_${num}"
files="${!fovr:-${GH_FILES_JSON:-[]}}"
[ -n "${GH_MARK:-}" ] && : >"$GH_MARK"
case "$mode" in
  error)   exit 1 ;;                                   # gh failed / unreachable
  slow)    sleep "${GH_STUB_SLEEP:-5}"; exit 0 ;;      # exceed the internal timeout
  empty)   echo '{"statusCheckRollup":[]}'; exit 0 ;;  # CI not registered yet
  green)
    printf '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"},"files":%s}\n' "$files" ;;
  skipped)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"optional","status":"COMPLETED","conclusion":"SKIPPED"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
  e2eskipped)  # roadmap-only lane shape: e2e SKIPPED by the workflow's lane job; files from GH_FILES_JSON
    printf '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SKIPPED"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"audit-gate","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"},"files":%s}\n' "$files" ;;
  greenfull)  # green including the ci-status aggregator (presence-check shape)
    printf '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"ci-status","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"},"files":%s}\n' "$files" ;;
  gateskipped)  # a gate check that may NEVER skip reports SKIPPED (misconfigured workflow)
    printf '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"audit-gate","status":"COMPLETED","conclusion":"SKIPPED"}
    ],"mergeStateStatus":"CLEAN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"},"files":%s}\n' "$files" ;;
  failure)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeCommit":{"oid":"deadbeef"}}' ;;
  pending)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null}
    ],"mergeCommit":{"oid":"deadbeef"}}' ;;
  behind)   # green checks; mergeStateStatus reports BEHIND (only under strict protection)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"BEHIND","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
  nostate)  # green checks, mergeStateStatus ABSENT (old gh / API oddity); base/head present
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
  unknownstate)  # green checks, GitHub still computing mergeStateStatus
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"UNKNOWN","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
  blockedstate)  # green rollup, mergeStateStatus BLOCKED — freshness still decided by compare
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"BLOCKED","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
  unstablestate)  # all-green rollup, mergeStateStatus UNSTABLE — compare decides freshness
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeStateStatus":"UNSTABLE","baseRefName":"main","headRefOid":"deadbeef","mergeCommit":{"oid":"deadbeef"}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/gh"

# Generous default gh timeout so normal-path cases never flake under load; the
# explicit timeout test overrides MGT=1 with a stub that sleeps longer than that.
run_gate() {  # $1=GH_STUB, $2=command, [$3=cwd override] ; feeds mock PreToolUse JSON
  local stub="$1" cmd="$2" cwd="${3:-$WORK}"
  local json
  json="$(jq -cn --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
  PATH="$STUB_BIN:$PATH" GH_STUB="$stub" GH_COMPARE="${GH_COMPARE:-0}" \
    MERGE_GATE_GH_TIMEOUT="${MGT:-5}" GH_FILES_JSON="${GH_FILES_JSON:-[]}" \
    bash "$GATE" <<<"$json"
}

run_backstop() {  # $1=GH_STUB, $2=command ; returns hook exit code, prints stderr
  local stub="$1" cmd="$2"
  local json
  json="$(jq -cn --arg c "$cmd" --arg d "$WORK" \
    '{tool_name:"Bash",hook_event_name:"PostToolUse",cwd:$d,tool_input:{command:$c}}')"
  PATH="$STUB_BIN:$PATH" GH_STUB="$stub" MERGE_GATE_GH_TIMEOUT="${MGT:-5}" \
    bash "$BACKSTOP" <<<"$json"
}

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

is_deny()   { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }
reason()    { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

echo "== pre-merge-gate.sh branches =="

# (a) all green -> ALLOW (no deny, empty/no decision)
out="$(run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "a) green -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "a) green -> allow (silent no-op)"
else bad "a) green -> allow" "unexpected stdout: $out"; fi

# (a2) skipped check is non-blocking -> ALLOW (must not wedge)
out="$(run_gate skipped 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "a2) skipped -> allow" "got deny: $(reason "$out")"
else ok "a2) skipped check treated as non-blocking -> allow"; fi

# (a3) roadmap-only lane: e2e SKIPPED + every changed file is backlog/docs -> ALLOW
out="$(GH_FILES_JSON='[{"path":"roadmap/discovered/x-0a1b2c.md"},{"path":"roadmap/F1.2.md"},{"path":"docs/research/m.md"}]' run_gate e2eskipped 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "a3) e2e skipped + roadmap-only files -> allow" "got deny: $(reason "$out")"
else ok "a3) e2e skipped on a roadmap-only PR -> allow (the fast lane)"; fi

# (a4) e2e SKIPPED but the PR touches code -> DENY (a skip is not a pass)
out="$(GH_FILES_JSON='[{"path":"roadmap/F1.2.md"},{"path":"src/a.ts"}]' run_gate e2eskipped 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q "not roadmap-only"; then ok "a4) e2e skipped + code file -> deny (skip != pass)"
else bad "a4) e2e skipped + code -> deny" "got: $out"; fi

# (a5) e2e SKIPPED and a workflow edit -> DENY (self-modifying CI fires before the lane check)
out="$(GH_FILES_JSON='[{"path":".github/workflows/ci.yml"}]' run_gate e2eskipped 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q "CI controls"; then ok "a5) e2e skipped + workflow edit -> deny (self-modifying CI, fires before lane check)"
else bad "a5) e2e skipped + workflow edit -> deny" "got: $out"; fi

# (a6) e2e SKIPPED with no file list -> DENY (cannot confirm the lane)
out="$(GH_FILES_JSON='[]' run_gate e2eskipped 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q "no changed files"; then ok "a6) e2e skipped + no files -> deny (fail closed)"
else bad "a6) e2e skipped + no files -> deny" "got: $out"; fi

# (a7-a9) ci-status PRESENCE: required iff the repo's own workflows declare the job.
# A ci.yml that never triggers reports nothing; audit-gate+review alone would read
# all-green. The gate must notice the aggregator is MISSING, not merely non-red.
DECL="$WORK/decl"; mkdir -p "$DECL/.github/workflows"
printf 'jobs:\n  lint:\n    runs-on: x\n  ci-status:\n    needs: [lint]\n' > "$DECL/.github/workflows/ci.yml"
out="$(run_gate green 'gh pr merge 42 --squash' "$DECL")"
if is_deny "$out" && reason "$out" | grep -q "no 'ci-status' check"; then ok "a7) repo declares ci-status, rollup lacks it -> deny (absence != pass)"
else bad "a7) declared ci-status absent -> deny" "got: $out"; fi
out="$(run_gate greenfull 'gh pr merge 42 --squash' "$DECL")"
if is_deny "$out"; then bad "a8) declared + present green -> allow" "got deny: $(reason "$out")"
else ok "a8) repo declares ci-status, rollup has it green -> allow"; fi
out="$(run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "a9) repo without a ci-status job stays unaffected" "got deny: $(reason "$out")"
else ok "a9) no ci-status declared -> presence not required (no regression)"; fi

# (a7) a gate check that may never skip (audit-gate) reports SKIPPED -> DENY
out="$(run_gate gateskipped 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q "SKIPPED: audit-gate"; then ok "a7) audit-gate skipped -> deny (misconfigured workflow)"
else bad "a7) audit-gate skipped -> deny" "got: $out"; fi

echo "== self-modifying CI: a PR touching .github/workflows or .github/scripts is never session-mergeable =="

# (w1) green PR editing a workflow -> DENY naming the PR and the human exit
out="$(GH_FILES_JSON='[{"path":".github/workflows/ci.yml"}]' run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'PR #42' && reason "$out" | grep -q 'HUMAN'; then ok "w1) green + .github/workflows/ci.yml -> deny (human merges)"
else bad "w1) workflow edit -> deny" "got: $out"; fi

# (w2) mixed PR (code + workflow) -> DENY naming the workflow file
out="$(GH_FILES_JSON='[{"path":"src/a.ts"},{"path":".github/workflows/claude-review.yml"}]' run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'claude-review.yml'; then ok "w2) mixed code + workflow -> deny naming claude-review.yml"
else bad "w2) mixed PR -> deny" "got: $out"; fi

# (w3) vendored gate script -> DENY
out="$(GH_FILES_JSON='[{"path":".github/scripts/audit-gate.sh"}]' run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'CI controls'; then ok "w3) .github/scripts/audit-gate.sh -> deny"
else bad "w3) vendored script -> deny" "got: $out"; fi

# (w4) consumer-owned script in the vendored dir -> DENY (whole directory protected)
out="$(GH_FILES_JSON='[{"path":".github/scripts/ci-status.sh"}]' run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'CI controls'; then ok "w4) .github/scripts/ci-status.sh -> deny (whole dir)"
else bad "w4) consumer script -> deny" "got: $out"; fi

# (w5) nested path -> DENY
out="$(GH_FILES_JSON='[{"path":".github/workflows/nested/x.yml"}]' run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'CI controls'; then ok "w5) nested .github/workflows/nested/x.yml -> deny"
else bad "w5) nested path -> deny" "got: $out"; fi

# (w6) other .github files are NOT CI controls -> ALLOW
out="$(GH_FILES_JSON='[{"path":".github/ISSUE_TEMPLATE/bug.md"},{"path":".github/CODEOWNERS"},{"path":".github/dependabot.yml"}]' run_gate green 'gh pr merge 42 --squash')"
if [ -z "$out" ]; then ok "w6) .github/ non-workflow files -> allow"
else bad "w6) other .github files -> allow" "unexpected: $out"; fi

# (w7) root-anchored: look-alike paths elsewhere -> ALLOW
out="$(GH_FILES_JSON='[{"path":"docs/.github/workflows/x.yml"},{"path":"github/workflows/y.yml"}]' run_gate green 'gh pr merge 42 --squash')"
if [ -z "$out" ]; then ok "w7) docs/.github/workflows + github/workflows -> allow (root-anchored)"
else bad "w7) look-alike paths -> allow" "unexpected: $out"; fi

# (w8) batch: only the SECOND PR edits a workflow -> deny naming #42, not #41
export GH_FILES_JSON_42='[{"path":".github/workflows/ci.yml"}]'
out="$(GH_FILES_JSON='[{"path":"src/a.ts"}]' run_gate green 'gh pr merge 41 --squash && gh pr merge 42 --squash')"
unset GH_FILES_JSON_42
if is_deny "$out" && reason "$out" | grep -q 'PR #42' && ! reason "$out" | grep -q 'PR #41'; then ok "w8) batch 41(code) && 42(workflow) -> deny naming #42 only"
else bad "w8) batch workflow deny" "got: $out"; fi

# (w9) red PR + workflow edit -> the red-check deny fires first (ordering unchanged)
out="$(GH_FILES_JSON='[{"path":".github/workflows/ci.yml"}]' run_gate failure 'gh pr merge 42 --squash')"
if is_deny "$out" && reason "$out" | grep -q 'e2e=FAILURE'; then ok "w9) red + workflow edit -> red deny first"
else bad "w9) red + workflow -> red deny first" "got: $out"; fi

# (b) a FAILURE -> DENY naming the check
out="$(run_gate failure 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'e2e=FAILURE'; then
  ok "b) failure -> deny naming e2e"
else bad "b) failure -> deny naming check" "out: $out"; fi

# (c) a PENDING/IN_PROGRESS -> DENY
out="$(run_gate pending 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'e2e=IN_PROGRESS'; then
  ok "c) pending -> deny naming e2e"
else bad "c) pending -> deny" "out: $out"; fi

# (d) gh error -> DENY (recoverable)
out="$(run_gate error 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'fails CLOSED'; then
  ok "d) gh error -> deny-recoverable"
else bad "d) gh error -> deny-recoverable" "out: $out"; fi

# (d2) gh timeout (real internal-timeout path): MGT=1 with a stub that sleeps 3.
out="$(MGT=1 GH_STUB_SLEEP=3 run_gate slow 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'fails CLOSED'; then
  ok "d2) gh timeout -> deny-recoverable"
else bad "d2) gh timeout -> deny-recoverable" "out: $out"; fi

# (d3) empty rollup (CI not registered) -> DENY (recoverable)
out="$(run_gate empty 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'no checks'; then
  ok "d3) empty rollup -> deny-recoverable"
else bad "d3) empty rollup -> deny-recoverable" "out: $out"; fi

# (d4) green checks but branch BEHIND base -> DENY (stale green; combined state unverified)
out="$(run_gate behind 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'BEHIND'; then
  ok "d4) behind base -> deny (rebase first)"
else bad "d4) behind -> deny" "out: $out"; fi

# (d5) mergeStateStatus MISSING but the compare API says the head is up-to-date
# (behind_by=0) -> ALLOW. The compare check is now ground truth, so a missing
# mergeStateStatus is no longer fatal when freshness is provable independently.
out="$(run_gate nostate 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "d5) missing state + compare-fresh -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "d5) mergeStateStatus missing + compare fresh -> allow"
else bad "d5) missing state + compare-fresh -> allow" "unexpected stdout: $out"; fi

# (d6) mergeStateStatus UNKNOWN but the compare API says fresh (behind_by=0) ->
# ALLOW. Same principle: compare is ground truth, UNKNOWN is not fatal when the
# head is provably not behind its base.
out="$(run_gate unknownstate 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "d6) UNKNOWN state + compare-fresh -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "d6) mergeStateStatus UNKNOWN + compare fresh -> allow"
else bad "d6) UNKNOWN state + compare-fresh -> allow" "unexpected stdout: $out"; fi

# (d7) green + mergeStateStatus CLEAN but the compare API reports behind_by=2 ->
# DENY. This is the real-world stale-green case the probe confirmed: a free-plan
# repo reports CLEAN while the head is actually behind base. The deny names
# BEHIND and gives the rebase recipe against the ACTUAL base branch (main).
out="$(GH_COMPARE=2 run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" \
   && printf '%s' "$(reason "$out")" | grep -q 'BEHIND' \
   && printf '%s' "$(reason "$out")" | grep -q 'origin/main'; then
  ok "d7) CLEAN but compare behind_by=2 -> deny (BEHIND, rebase origin/main)"
else bad "d7) stale-green via compare -> deny" "out: $out"; fi

# (d8) green + CLEAN but the compare call ERRORS -> DENY (recoverable). Freshness
# uncertainty is never an allow.
out="$(GH_COMPARE=error run_gate green 'gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'freshness'; then
  ok "d8) compare API errors -> deny-recoverable (freshness)"
else bad "d8) compare error -> deny-recoverable" "out: $out"; fi

# (d9) scope-pin: green rollup + mergeStateStatus BLOCKED + compare fresh -> ALLOW.
# BLOCKED is not BEHIND; with the head provably up-to-date the freshness gate
# must not deny (only BEHIND/behind_by>0/uncertainty deny).
out="$(run_gate blockedstate 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "d9) BLOCKED + compare-fresh -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "d9) BLOCKED mstate + compare fresh -> allow"
else bad "d9) BLOCKED + compare-fresh -> allow" "unexpected stdout: $out"; fi

# (d10) scope-pin: all-green rollup + mergeStateStatus UNSTABLE + compare fresh ->
# ALLOW. Greenness is judged on the FULL rollup (all green here); UNSTABLE alone
# (a non-required context) with a fresh head is not a merge blocker.
out="$(run_gate unstablestate 'gh pr merge 42 --squash')"
if is_deny "$out"; then bad "d10) UNSTABLE + compare-fresh -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "d10) UNSTABLE mstate + compare fresh -> allow"
else bad "d10) UNSTABLE + compare-fresh -> allow" "unexpected stdout: $out"; fi

# (e1) --admin -> DENY (never queries gh; use green stub to prove it's the flag)
out="$(run_gate green 'gh pr merge 42 --admin --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'admin'; then
  ok "e1) --admin -> deny"
else bad "e1) --admin -> deny" "out: $out"; fi

# (e2) --repo -> DENY
out="$(run_gate green 'gh pr merge 42 --repo other/repo --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "e2) --repo -> deny"
else bad "e2) --repo -> deny" "out: $out"; fi

# (e3) -R (short alias) -> DENY
out="$(run_gate green 'gh pr merge -R other/repo 42')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "e3) -R -> deny"
else bad "e3) -R -> deny" "out: $out"; fi

# (e4) unparseable (no PR number) -> DENY
out="$(run_gate green 'gh pr merge --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "e4) no PR number -> deny"
else bad "e4) no PR number -> deny" "out: $out"; fi

# (e5) jq missing + merge command -> FAIL CLOSED (deny), not silent no-op.
# Build a PATH that has the tools the hook needs EXCEPT jq. Pre-build the input
# JSON with the real jq, then run the hook under the jq-less PATH.
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
for b in bash grep sed head cat mktemp sleep rm date; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$b"
done
ln -sf "$STUB_BIN/gh" "$NOJQ/gh"
merge_json="$(jq -cn --arg c 'gh pr merge 42 --squash' --arg d "$WORK" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
out="$(PATH="$NOJQ" bash "$GATE" <<<"$merge_json")"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'jq is unavailable'; then
  ok "e5) jq missing + merge -> deny (fail-closed)"
else bad "e5) jq missing -> fail-closed" "out: $out"; fi
# jq missing + NON-merge -> still a no-op
nonmerge_json="$(jq -cn --arg c 'ls -la' --arg d "$WORK" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
out="$(PATH="$NOJQ" bash "$GATE" <<<"$nonmerge_json")"
if [ -z "$out" ]; then ok "e6) jq missing + non-merge -> no-op"
else bad "e6) jq missing + non-merge -> no-op" "out: $out"; fi

# (e7) greedy scan tools missing (no awk/tr) + merge -> FAIL CLOSED, not no-op.
# jq/dirname present (input parse + lib source) but awk & tr absent, so the greedy
# counter can't run; a merge-ish command must still DENY.
NOAWK="$WORK/noawk"
mkdir -p "$NOAWK"
for b in bash grep sed head cat mktemp sleep rm date jq xargs printf dirname; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOAWK/$b"
done
ln -sf "$STUB_BIN/gh" "$NOAWK/gh"
out="$(PATH="$NOAWK" GH_STUB=green MERGE_GATE_GH_TIMEOUT=5 bash "$GATE" <<<"$merge_json")"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "e7) greedy scan (awk/tr) missing + merge -> deny (fail-closed)"
else bad "e7) awk/tr missing -> fail-closed" "out: $out"; fi
# same PATH, a non-merge command still no-ops
out="$(PATH="$NOAWK" bash "$GATE" <<<"$nonmerge_json")"
if [ -z "$out" ]; then ok "e8) awk/tr missing + non-merge -> no-op"
else bad "e8) awk/tr missing + non-merge -> no-op" "out: $out"; fi

# (e9) the shared parser lib fails to LOAD (here: `dirname` missing breaks the
# source line) -> merge must FAIL CLOSED via the parser-unavailable guard.
NOLIB="$WORK/nolib"
mkdir -p "$NOLIB"
for b in bash grep sed head cat mktemp sleep rm date jq xargs printf awk tr; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOLIB/$b"
done   # deliberately NO dirname -> `. "$(dirname …)/lib…"` fails -> lib not loaded
ln -sf "$STUB_BIN/gh" "$NOLIB/gh"
out="$(PATH="$NOLIB" GH_STUB=green MERGE_GATE_GH_TIMEOUT=5 bash "$GATE" <<<"$merge_json" 2>/dev/null)"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'parser could not load'; then
  ok "e9) parser lib fails to load + merge -> deny (fail-closed)"
else bad "e9) lib load failure -> fail-closed" "out: $out"; fi
out="$(PATH="$NOLIB" bash "$GATE" <<<"$nonmerge_json" 2>/dev/null)"
if [ -z "$out" ]; then ok "e10) parser lib fails to load + non-merge -> no-op"
else bad "e10) lib load failure + non-merge -> no-op" "out: $out"; fi

# (f) non-merge command -> ALLOW / no-op (silent)
out="$(run_gate green 'gh pr view 42 --json state')"
if [ -z "$out" ]; then ok "f) non-merge (gh pr view) -> silent no-op"
else bad "f) non-merge -> no-op" "unexpected stdout: $out"; fi

out="$(run_gate green 'ls -la && echo hi')"
if [ -z "$out" ]; then ok "f2) unrelated command -> silent no-op"
else bad "f2) unrelated -> no-op" "unexpected stdout: $out"; fi

# (f3) look-alike command name must NOT match (mygh pr merge)
out="$(run_gate failure 'mygh pr merge 42')"
if [ -z "$out" ]; then ok "f3) 'mygh pr merge' (look-alike) -> no-op, not gated"
else bad "f3) look-alike -> no-op" "unexpected stdout: $out"; fi

# (g) compound command hiding a real merge MUST still be gated (no --if bypass)
out="$(run_gate failure 'true && gh pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'e2e=FAILURE'; then
  ok "g) compound 'x && gh pr merge' -> gated (deny)"
else bad "g) compound merge -> gated" "out: $out"; fi

# (h) PR URL form parses
out="$(run_gate failure 'gh pr merge https://github.com/o/r/pull/42')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'e2e=FAILURE'; then
  ok "h) PR URL form -> parsed & gated"
else bad "h) PR URL -> parsed" "out: $out"; fi

# (h2) a number in a TRAILING command must NOT be grabbed as the PR (wrong-PR guard).
# `gh pr merge` (no number) && echo 42  -> must DENY "could not parse", NOT verify PR 42.
out="$(run_gate green 'gh pr merge && echo 42')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "h2) trailing number not grabbed as PR -> deny(parse)"
else bad "h2) wrong-PR guard" "out: $out"; fi

# (h3) legitimate trailing command after a numbered merge still parses the real PR.
out="$(run_gate failure 'gh pr merge 42 --squash && echo done')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q 'e2e=FAILURE'; then
  ok "h3) 'merge 42 && echo done' -> gates PR 42"
else bad "h3) trailing cmd after numbered merge" "out: $out"; fi

echo "== adversarial: detector evasion / wrong-PR / repo-flag / false-positives =="

# (B1a) backslash line-continuation between `pr` and `merge` must still be gated.
out="$(run_gate failure "$(printf 'gh pr \\\nmerge 42 --squash')")"
if is_deny "$out"; then ok "B1a) backslash-newline continuation -> gated"
else bad "B1a) backslash-newline -> gated" "out: $out"; fi

# (B1b) alias-escape token `\gh` (xargs normalises) must still be gated.
out="$(run_gate failure '\gh pr merge 42')"
if is_deny "$out"; then ok "B1b) '\\gh pr merge' -> gated"
else bad "B1b) \\gh -> gated" "out: $out"; fi

# (B1c) quoted command words `'gh' pr 'merge'` must still be gated.
out="$(run_gate failure "'gh' pr 'merge' 42")"
if is_deny "$out"; then ok "B1c) quoted 'gh'/'merge' tokens -> gated"
else bad "B1c) quoted tokens -> gated" "out: $out"; fi

# (B1d) no-space pipe hiding a real merge must still be gated (operator-padding).
out="$(run_gate failure 'echo x|gh pr merge 42')"
if is_deny "$out"; then ok "B1d) 'echo x|gh pr merge' (no-space pipe) -> gated"
else bad "B1d) no-space pipe -> gated" "out: $out"; fi

# (B2) a pull/<n> URL inside --body must NOT hijack the PR (verify the positional).
# merge is #42 (FAILURE); body mentions pull/99 (green) -> must DENY naming #42's e2e.
out="$(run_gate failure 'gh pr merge 42 --squash --body "supersedes pull/99"')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q '#42'; then
  ok "B2) --body pull/99 does not hijack -> verifies #42"
else bad "B2) wrong-PR via --body" "out: $out"; fi

# (M1) attached-form `-Rvalue` must be rejected as a repo violation.
out="$(run_gate green 'gh pr merge -Rother/repo 42')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "M1) '-Rother/repo' (attached) -> deny(repo)"
else bad "M1) -Rvalue attached -> deny" "out: $out"; fi

# (M2) greedy-detect + fail-closed: commands that MENTION the words in order (even
# in a quoted message) are the accepted DENY edge — over-blocking only forces a
# plain re-issue; under-detecting would be a silent hole.
out="$(run_gate failure 'echo "remember to gh pr merge 7 after review"')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "M2a) echo mentioning phrase -> deny (accepted over-block)"
else bad "M2a) echo mention -> deny" "out: $out"; fi
out="$(run_gate failure 'git commit -m "document gh pr merge workflow"')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "M2b) git commit mentioning phrase -> deny (accepted over-block)"
else bad "M2b) commit mention -> deny" "out: $out"; fi

echo "== chained multi-PR merges in one Bash call (every merge must be verified) =="
CHAIN='gh pr merge 42 --squash && gh pr merge 43 --squash'

# (C1) green && green -> ALLOW
out="$(run_gate green "$CHAIN")"
if is_deny "$out"; then bad "C1) green && green -> allow" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "C1) green && green -> allow"
else bad "C1) green && green -> allow" "unexpected: $out"; fi

# (C2) green(42) && red(43) -> DENY naming #43 (the un-checked second merge)
export GH_STUB_43=failure
out="$(run_gate green "$CHAIN")"
unset GH_STUB_43
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q '#43'; then
  ok "C2) green && red -> deny naming #43"
else bad "C2) green && red -> deny #43" "out: $out"; fi

# (C3) green(42) && pending(43) -> DENY naming #43
export GH_STUB_43=pending
out="$(run_gate green "$CHAIN")"
unset GH_STUB_43
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -q '#43'; then
  ok "C3) green && pending -> deny naming #43"
else bad "C3) green && pending -> deny #43" "out: $out"; fi

# (C4) chain whose SECOND merge uses --admin -> DENY (flag guard across whole cmd)
out="$(run_gate green 'gh pr merge 42 --squash && gh pr merge 43 --admin')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'admin'; then
  ok "C4) second merge --admin -> deny"
else bad "C4) second merge --admin -> deny" "out: $out"; fi

# (C5) chain whose SECOND merge lacks a PR number -> DENY (can't verify it)
out="$(run_gate green 'gh pr merge 42 --squash && gh pr merge --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "C5) second merge missing PR -> deny(parse)"
else bad "C5) second merge missing PR -> deny" "out: $out"; fi

# (C6) global time budget across a multi-PR batch: if the batch can't be verified
# within the total budget (set to 0 here to force it deterministically), the gate
# must DENY-recoverable — it must NOT run long enough to be killed by the harness
# hook timeout and fail open.
export MERGE_GATE_TOTAL_BUDGET=0
out="$(run_gate green "$CHAIN")"
unset MERGE_GATE_TOTAL_BUDGET
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'time budget'; then
  ok "C6) exhausted batch time budget -> deny(fail-closed)"
else bad "C6) time-budget exhaustion -> deny" "out: $out"; fi

echo "== inherited flags BETWEEN subcommand words (gh pr [-R x] merge ...) =="

# (P1) `gh pr -R other/repo merge 42` -> DENY (repo); flag lands between pr & merge.
out="$(run_gate green 'gh pr -R other/repo merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "P1) 'gh pr -R x merge 42' -> deny(repo)"
else bad "P1) flag between pr/merge (-R) -> deny(repo)" "out: $out"; fi

# (P2) `gh pr --repo x merge 42` -> DENY (repo).
out="$(run_gate green 'gh pr --repo other/repo merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "P2) 'gh pr --repo x merge 42' -> deny(repo)"
else bad "P2) --repo between pr/merge -> deny(repo)" "out: $out"; fi

# (P3) `gh -R x pr merge 42` -> DENY (repo); global-position flag before pr.
out="$(run_gate green 'gh -R other/repo pr merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "P3) 'gh -R x pr merge 42' -> deny(repo)"
else bad "P3) -R before pr -> deny(repo)" "out: $out"; fi

# (P4) `gh pr --admin merge 42` -> DENY (admin) with the flag between words.
out="$(run_gate green 'gh pr --admin merge 42 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'admin'; then
  ok "P4) '--admin' between pr/merge -> deny(admin)"
else bad "P4) --admin between words -> deny" "out: $out"; fi

# (P5) a real merge that is merge-ish but has an EXTRA/ambiguous positional ->
# fail-closed DENY (durable rule), not a silent no-op.
out="$(run_gate green 'gh pr merge 42 43 --squash')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "P5) extra positional -> deny(fail-closed)"
else bad "P5) ambiguous positional -> fail-closed deny" "out: $out"; fi

# (P6) the clean common form with an interposed innocuous flag still ALLOWS green.
out="$(run_gate green 'gh pr merge 42 --squash --delete-branch')"
if is_deny "$out"; then bad "P6) clean form still allows" "got deny: $(reason "$out")"
elif [ -z "$out" ]; then ok "P6) 'merge 42 --squash --delete-branch' green -> allow"
else bad "P6) clean form allow" "unexpected: $out"; fi

# (P7) a green merge with -R still DENIES on the flag (never silently verifies-then-allows).
out="$(run_gate green 'gh pr -R other/repo merge 42')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'repo'; then
  ok "P7) green + -R between words -> deny(repo), not allow"
else bad "P7) green + -R -> deny" "out: $out"; fi

echo "== greedy-detect + fail-closed on compound constructs (keywords/grouping) =="

# (G1) merge wrapped in an `if` (honest retry/fallback shape) -> DENY, not no-op.
out="$(run_gate green 'if gh pr merge 56 --squash; then echo ok; fi')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G1) 'if gh pr merge 56; then …; fi' -> deny(fail-closed)"
else bad "G1) if-wrapped merge -> deny" "out: $out"; fi

# (G2) merge in a `while` loop -> DENY.
out="$(run_gate green 'while gh pr merge 56; do :; done')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G2) 'while gh pr merge 56; do :; done' -> deny(fail-closed)"
else bad "G2) while-wrapped merge -> deny" "out: $out"; fi

# (G3) merge in a subshell group -> DENY.
out="$(run_gate green '( gh pr merge 56 --squash )')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G3) '( gh pr merge 56 )' subshell -> deny(fail-closed)"
else bad "G3) subshell-wrapped merge -> deny" "out: $out"; fi

# (G4) merge in a command substitution -> DENY.
out="$(run_gate green 'x=$(gh pr merge 56)')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G4) 'x=\$(gh pr merge 56)' command-sub -> deny(fail-closed)"
else bad "G4) command-sub merge -> deny" "out: $out"; fi

# (G5) merge in a `for` loop body -> DENY.
out="$(run_gate green 'for n in 56; do gh pr merge $n --squash; done')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G5) 'for … do gh pr merge \$n; done' -> deny(fail-closed)"
else bad "G5) for-wrapped merge -> deny" "out: $out"; fi

# (G6) merge in backticks -> DENY.
out="$(run_gate green 'echo `gh pr merge 56`')"
if is_deny "$out" && printf '%s' "$(reason "$out")" | grep -qi 'pristine'; then
  ok "G6) backtick-wrapped merge -> deny(fail-closed)"
else bad "G6) backtick merge -> deny" "out: $out"; fi

echo "== post-merge-redcheck.sh backstop =="

# (i) merge that landed RED -> exit 2 + marker file written
rm -f "$WORK/.claude/main-red-"*.flag 2>/dev/null
mkdir -p "$WORK/.claude"
# Point the backstop's primary-derivation at $WORK by running inside a git repo there.
( cd "$WORK" && git init -q 2>/dev/null )
err="$(run_backstop failure 'gh pr merge 42 --squash' 2>&1 1>/dev/null)"; rc=$?
if [ "$rc" = "2" ] && printf '%s' "$err" | grep -q 'RED MAIN'; then
  ok "i) red merge -> exit 2 loud banner"
else bad "i) red merge -> exit 2" "rc=$rc err=$err"; fi
if ls "$WORK"/.claude/main-red-*.flag >/dev/null 2>&1; then
  ok "i2) red merge -> gitignored marker written"
else bad "i2) marker written" "no marker in $WORK/.claude"; fi

# (j) green merge -> backstop quiet (exit 0, no marker)
rm -f "$WORK"/.claude/main-red-*.flag 2>/dev/null
run_backstop green 'gh pr merge 42 --squash' >/dev/null 2>&1; rc=$?
if [ "$rc" = "0" ] && ! ls "$WORK"/.claude/main-red-*.flag >/dev/null 2>&1; then
  ok "j) green merge -> backstop silent, no marker"
else bad "j) green merge -> silent" "rc=$rc, marker present?"; fi

# (k) non-merge command -> backstop no-op
run_backstop failure 'ls -la' >/dev/null 2>&1; rc=$?
if [ "$rc" = "0" ]; then ok "k) non-merge -> backstop no-op"
else bad "k) non-merge -> no-op" "rc=$rc"; fi

# (l) chained merge where the SECOND landed red -> backstop alarms + marks it.
rm -f "$WORK"/.claude/main-red-*.flag 2>/dev/null
export GH_STUB_43=failure
err="$(run_backstop green 'gh pr merge 42 --squash && gh pr merge 43 --squash' 2>&1 1>/dev/null)"; rc=$?
unset GH_STUB_43
if [ "$rc" = "2" ] && printf '%s' "$err" | grep -q '#43' && ls "$WORK"/.claude/main-red-*.flag >/dev/null 2>&1; then
  ok "l) chained green&&red -> backstop alarms + marks #43"
else bad "l) chained backstop" "rc=$rc err=$err"; fi

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

echo "== push gate: a git push whose destination resolves to the base branch =="

# Offline git fixture: bare remote, clone on feat/x tracking origin/feat/x,
# origin/HEAD -> main, a worktree on feat/y, plus a develop-default clone.
PF="$WORK/push"
mkdir -p "$PF"
git init -q --bare "$PF/remote.git"
git clone -q "$PF/remote.git" "$PF/repo" 2>/dev/null
PG="git -C $PF/repo -c user.email=t@t -c user.name=t"
$PG commit -q --allow-empty -m init
$PG branch -M main
$PG push -q -u origin main
$PG remote set-head origin -a >/dev/null 2>&1
$PG branch feat/y && $PG push -q -u origin feat/y && $PG worktree add -q "$PF/wt" feat/y
$PG checkout -q -b feat/x && $PG push -q -u origin feat/x
PREPO="$PF/repo"

run_push() {  # $1=command [$2=cwd] ; extra env via caller. Green stub on PATH, GH_MARK records any view.
  local cmd="$1" cwd="${2:-$PREPO}"
  local json
  json="$(jq -cn --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
  PATH="$STUB_BIN:$PATH" GH_STUB=green GH_COMPARE=0 MERGE_GATE_GH_TIMEOUT=5 GH_FILES_JSON='[]' \
    GH_MARK="$PF/viewed" bash "$GATE" <<<"$json"
}
expect_allow() {  # $1=label $2=cmd [$3=cwd]
  local out; out="$(run_push "$2" "${3:-$PREPO}")"
  if [ -z "$out" ]; then ok "$1"; else bad "$1" "unexpected: $out"; fi
}
expect_deny() {  # $1=label $2=cmd $3=reason-substring [$4=cwd]
  local out; out="$(run_push "$2" "${4:-$PREPO}")"
  if is_deny "$out" && reason "$out" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "got: $out"; fi
}

# MUST NOT DENY (hot path)
expect_allow "p1) --force-with-lease origin feat/x -> allow"            'git push --force-with-lease origin feat/x'
expect_allow "p2) --force-with-lease=feat/x:abc origin feat/x -> allow"  'git push --force-with-lease=feat/x:abc origin feat/x'
expect_allow "p3) -u origin feat/x -> allow"                             'git push -u origin feat/x'
expect_allow "p4) origin HEAD on feat/x -> allow"                        'git push origin HEAD'
expect_allow "p5) bare git push on feat/x (upstream feat/x) -> allow"    'git push'
expect_allow "p6) bare --force-with-lease from the worktree -> allow"    'git push --force-with-lease' "$PF/wt"
expect_allow "p7) verbatim rebase recipe -> allow"                       'git fetch origin && git rebase origin/main && git push --force-with-lease'
expect_allow "p8) origin --delete feat/x -> allow"                       'git push origin --delete feat/x'
expect_allow "p9) origin :feat/x -> allow"                               'git push origin :feat/x'
expect_allow "p10) origin main:feat/x -> allow"                          'git push origin main:feat/x'
expect_allow "p11) tag v1.2.3 -> allow"                                  'git push origin v1.2.3'
expect_allow "p12) HEAD:refs/sweap/probe -> allow (not a branch)"        'git push origin HEAD:refs/sweap/probe'
expect_allow "p13) -u origin feat/x 2>&1 | tail -3 -> allow"             'git push -u origin feat/x 2>&1 | tail -3'
expect_allow "p13b) git -C <wt> push origin feat/x -> allow (explicit refspec)" "git -C $PF/wt push origin feat/x"
expect_allow "p14) git pull origin main -> no-op"                        'git pull origin main'
expect_allow "p15) git stash push -m wip -> no-op"                       'git stash push -m wip'
expect_allow "p16) commit message mentioning push -> no-op"              'git commit -m "feat: push notifications"'
expect_allow "p17) git log --grep push -> no-op"                         'git log --grep push'
expect_allow "p18) git log main -> no-op"                                'git log main'
expect_allow "p19) echo push -> no-op"                                   'echo push'
expect_allow "p20) gh pr merge 42 green -> merge branch unchanged"       'gh pr merge 42 --squash'
out="$(SWEAP_PUSH_GATE=off run_push 'git push origin main')"
if [ -z "$out" ]; then ok "p21) SWEAP_PUSH_GATE=off in hook env (no project file) -> allow"
else bad "p21) override from hook env -> allow" "unexpected: $out"; fi

# MUST DENY
B="destination resolves to base branch 'main'"
expect_deny "q1) origin main -> deny"                    'git push origin main' "$B"
expect_deny "q2) origin HEAD:main -> deny"               'git push origin HEAD:main' "$B"
expect_deny "q3) origin main:main -> deny"               'git push origin main:main' "$B"
expect_deny "q4) origin refs/heads/main -> deny"         'git push origin refs/heads/main' "$B"
expect_deny "q5) origin +main -> deny"                   'git push origin +main' "$B"
expect_deny "q6) -f origin main -> deny"                 'git push -f origin main' "$B"
expect_deny "q7) --force-with-lease origin main -> deny (flag must not eat origin)" 'git push --force-with-lease origin main' "$B"
expect_deny "q8) origin feat/x:main -> deny"             'git push origin feat/x:main' "$B"
expect_deny "q9) origin :main -> deny"                   'git push origin :main' "$B"
expect_deny "q10) origin --delete main -> deny"          'git push origin --delete main' "$B"
expect_deny "q11) origin master -> deny"                 'git push origin master' "base branch 'master'"
expect_deny "q12) --all origin -> deny"                  'git push --all origin' 'every branch'
expect_deny "q13) --mirror origin -> deny"               'git push --mirror origin' 'every branch'
expect_deny "q14) git -C <repo> push origin main -> deny (explicit refspec; -C irrelevant)" "git -C $PREPO push origin main" "$B"
expect_deny "q15) FOO=bar git push origin main -> deny"  'FOO=bar git push origin main' "$B"
expect_deny "q16) origin main && echo ok -> deny"        'git push origin main && echo ok' "$B"
expect_deny "q17) echo x | git push origin main -> deny" 'echo x | git push origin main' "$B"
expect_deny "q18) upstream main -> deny"                 'git push upstream main' "$B"
expect_deny "q19) origin main 2>&1 -> deny"              'git push origin main 2>&1' "$B"
expect_deny "q20) cd sub && git push -> deny (recoverable)" 'cd sub && git push' 'cd/-C'
expect_deny "q21) if-wrapped push -> deny (greedy 1 != precise 0)" 'if true; then git push origin feat/x; fi' 'push-related but is not a plain'
expect_deny "q22) echo \"git push origin feat/x\" -> deny (accepted over-block)" 'echo "git push origin feat/x"' 'push-related but is not a plain'
expect_deny "q23) bash -c \"git push origin main\" -> deny" 'bash -c "git push origin main"' 'push-related but is not a plain'
expect_deny "q24) -C \"/dir with space\" -> deny (precise 1, greedy 0)" 'git -C "/dir with space" push origin main' 'push-related but is not a plain'
expect_deny "q25) unbalanced quote -> deny"              'git push origin "main' 'push-related but is not a plain'
expect_deny "q26) SWEAP_PUSH_GATE=off inline prefix -> still deny" 'SWEAP_PUSH_GATE=off git push origin main' "$B"
out="$(SWEAP_BASE_BRANCH=develop run_push 'git push origin develop')"
if is_deny "$out" && reason "$out" | grep -q "base branch 'develop'"; then ok "q27) SWEAP_BASE_BRANCH=develop + push develop -> deny"
else bad "q27) SWEAP_BASE_BRANCH -> deny" "got: $out"; fi

# q28: origin/HEAD -> trunk fixture
git clone -q "$PF/remote.git" "$PF/trunkrepo" 2>/dev/null
TG="git -C $PF/trunkrepo -c user.email=t@t -c user.name=t"
$TG checkout -q -b trunk && $TG push -q -u origin trunk
$TG symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
$TG checkout -q -b feat/z
expect_deny "q28) origin/HEAD -> trunk + push origin trunk -> deny" 'git push origin trunk' "base branch 'trunk'" "$PF/trunkrepo"
expect_allow "q28b) same repo, push origin feat/z -> allow"        'git push origin feat/z' "$PF/trunkrepo"

# q29: bare push while on main
$PG checkout -q main
expect_deny "q29) bare git push with HEAD on main -> deny"   'git push' "$B"
expect_deny "q30) origin HEAD on main -> deny"               'git push origin HEAD' "$B"
$PG checkout -q feat/x

# q31: push.default=upstream with upstream origin/main
$PG branch -q -u origin/main && $PG config push.default upstream
expect_deny "q31) bare push, upstream origin/main, push.default=upstream -> deny" 'git push' "$B"
$PG config push.default matching
expect_deny "q32) bare push, push.default=matching -> deny"  'git push' 'matching'
$PG config --unset push.default && $PG branch -q -u origin/feat/x

# q33: detached HEAD
$PG checkout -q --detach
expect_deny "q33) detached HEAD + origin HEAD -> deny (recoverable)" 'git push origin HEAD' 'detached'
$PG checkout -q feat/x

# q34: awk missing -> sentinel deny even for an item branch
out="$(PATH="$NOAWK" GH_STUB=green bash "$GATE" <<<"$(jq -cn --arg c 'git push origin feat/x' --arg d "$PREPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')")"
if is_deny "$out" && reason "$out" | grep -q 'push-related but is not a plain'; then ok "q34) awk/tr missing + push feat/x -> sentinel deny"
else bad "q34) awk missing -> deny" "got: $out"; fi

# q35: parser lib unreadable (hook copied without the lib) -> deny
NOLIBDIR="$WORK/nolibdir"; mkdir -p "$NOLIBDIR"; cp "$GATE" "$NOLIBDIR/pre-merge-gate.sh"
out="$(bash "$NOLIBDIR/pre-merge-gate.sh" <<<"$(jq -cn --arg c 'git push origin main' --arg d "$PREPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')" 2>/dev/null)"
if is_deny "$out" && reason "$out" | grep -q 'parser could not load'; then ok "q35) parser lib missing + push -> deny (fail-closed)"
else bad "q35) lib missing -> deny" "got: $out"; fi
out="$(bash "$NOLIBDIR/pre-merge-gate.sh" <<<"$(jq -cn --arg c 'ls -la' --arg d "$PREPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')" 2>/dev/null)"
if [ -z "$out" ]; then ok "q35b) parser lib missing + unrelated -> no-op"
else bad "q35b) lib missing + unrelated -> no-op" "got: $out"; fi

# q36: override refused when the PROJECT settings define it
mkdir -p "$PREPO/.claude"; printf '{"env":{"SWEAP_PUSH_GATE":"off"}}\n' > "$PREPO/.claude/settings.json"
out="$(SWEAP_PUSH_GATE=off run_push 'git push origin main')"
if is_deny "$out" && reason "$out" | grep -q "project's .claude settings"; then ok "q36) override in hook env BUT project settings define it -> still deny"
else bad "q36) project-defined override -> deny" "got: $out"; fi
rm -rf "$PREPO/.claude"

# q37: push deny wins before the merge branch is consulted
rm -f "$PF/viewed"
expect_deny "q37) push origin main; gh pr merge 42 -> push deny" 'git push origin main; gh pr merge 42' "$B"
if [ ! -e "$PF/viewed" ]; then ok "q37b) merge never queried (no gh pr view)"
else bad "q37b) merge never queried" "stub marker present"; fi

# q38: jq missing + push -> deny, not no-op
push_json="$(jq -cn --arg c 'git push origin main' --arg d "$PREPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')"
out="$(PATH="$NOJQ" bash "$GATE" <<<"$push_json")"
if is_deny "$out" && reason "$out" | grep -q 'jq is unavailable'; then ok "q38) jq missing + push -> deny (fail-closed)"
else bad "q38) jq missing + push -> deny" "got: $out"; fi

echo "== merge-driver launch hygiene (belt B) =="
# The gate refuses a `sweap-merge.sh` launch line that carries an environment
# override. Plain launches pass untouched; the scan is a pure text match.
LAUNCH='bash "${CLAUDE_PLUGIN_ROOT}/hooks/sweap-merge.sh" watch 7'
expect_launch_ok() {  # $1=label $2=cmd
  local out; out="$(run_gate green "$2")"
  if [ -z "$out" ]; then ok "$1"; else bad "$1" "unexpected: $out"; fi
}
expect_launch_deny() {  # $1=label $2=cmd $3=var named in the reason
  local out; out="$(run_gate green "$2")"
  if is_deny "$out" && reason "$out" | grep -qF -- "refusing to launch sweap-merge.sh with an environment override ($3)"; then ok "$1"
  else bad "$1" "got: $out"; fi
}
expect_launch_ok   "m1) plain launch -> untouched"                                  "$LAUNCH"
expect_launch_ok   "m2) plain launch with --budget=300 -> untouched"                'bash "${CLAUDE_PLUGIN_ROOT}/hooks/sweap-merge.sh" tick 7 --budget=300'
expect_launch_ok   "m3) plain launch by absolute path -> untouched"                 '/Users/x/.claude/plugins/sweap/hooks/sweap-merge.sh status'
expect_launch_ok   "m4) plain launch piped to tail -> untouched"                    "$LAUNCH 2>&1 | tail -3"
expect_launch_ok   "m5) PATH= on an unrelated command -> no-op"                     'PATH=/evil:$PATH ls'
expect_launch_ok   "m6) the driver's TEST suite (sweap-merge.test.sh) -> no-op"     'PATH=/x bash plugin/hooks/sweap-merge.test.sh'
expect_launch_deny "m7) BASH_ENV= prefix -> deny"          "BASH_ENV=/tmp/be.sh $LAUNCH"                    BASH_ENV
expect_launch_deny "m8) ENV= prefix -> deny"               "ENV=/tmp/be.sh $LAUNCH"                         ENV
expect_launch_deny "m9) SHELLOPTS= prefix -> deny"         "SHELLOPTS=xtrace $LAUNCH"                       SHELLOPTS
expect_launch_deny "m10) BASHOPTS= prefix -> deny"         "BASHOPTS=x $LAUNCH"                             BASHOPTS
expect_launch_deny "m11) PATH= prefix -> deny"             "PATH=/evil:\$PATH $LAUNCH"                       PATH
expect_launch_deny "m12) CDPATH= prefix -> deny"           "CDPATH=/evil $LAUNCH"                           CDPATH
expect_launch_deny "m13) HOME= prefix -> deny"             "HOME=/evil $LAUNCH"                             HOME
expect_launch_deny "m14) GIT_DIR= prefix -> deny"          "GIT_DIR=/forged/.git $LAUNCH"                   GIT_DIR
expect_launch_deny "m15) GIT_WORK_TREE= prefix -> deny"    "GIT_WORK_TREE=/forged $LAUNCH"                  GIT_WORK_TREE
expect_launch_deny "m16) GIT_CONFIG_GLOBAL= prefix -> deny" "GIT_CONFIG_GLOBAL=/forged/gitconfig $LAUNCH"   GIT_CONFIG_GLOBAL
expect_launch_deny "m17) LD_PRELOAD= prefix -> deny"       "LD_PRELOAD=/evil.so $LAUNCH"                    LD_PRELOAD
expect_launch_deny "m18) DYLD_INSERT_LIBRARIES= prefix -> deny" "DYLD_INSERT_LIBRARIES=/evil.dylib $LAUNCH" DYLD_INSERT_LIBRARIES
expect_launch_deny "m19) SWEAP_MERGE_GH= seam prefix -> deny" "SWEAP_MERGE_GH=/evil/gh $LAUNCH"             'SWEAP_MERGE_*'
expect_launch_deny "m20) SWEAP_MERGE_NOW= seam prefix -> deny" "SWEAP_MERGE_NOW=0 $LAUNCH"                   'SWEAP_MERGE_*'
expect_launch_deny "m21) env -i wrapper -> deny"           "env -i $LAUNCH"                                 'env wrapper'
expect_launch_deny "m22) /usr/bin/env wrapper -> deny"     "/usr/bin/env BASH_ENV=/x $LAUNCH"               BASH_ENV
expect_launch_deny "m23) export PATH=…; launch -> deny"    "export PATH=/evil:\$PATH; $LAUNCH"               PATH
expect_launch_deny "m24) launch after cd with GIT_DIR= -> deny" "cd /repo && GIT_DIR=/f/.git $LAUNCH"       GIT_DIR
# Accepted over-denies (documented): the scan is textual, so a command that
# merely MENTIONS the driver next to an assignment token is refused too. The
# recovery is to rephrase (drop the mention or the `=`), never a bypass.
expect_launch_deny "m25) echo mentioning sweap-merge.sh + PATH= elsewhere -> deny (accepted over-deny)" 'echo "run sweap-merge.sh"; PATH=/x ls' PATH
expect_launch_deny "m26) grep PATH= in the driver source -> deny (accepted over-deny)" 'grep -n PATH= plugin/hooks/sweap-merge.sh' PATH
expect_launch_deny "m27) comment mentioning env + launch -> deny (accepted over-deny)" "$LAUNCH # under env -i" 'env wrapper'
expect_launch_ok   "m28) word 'environment' next to the driver is not the env wrapper -> untouched" "$LAUNCH # environment"
expect_launch_ok   "m29) grep PATH (no '=') in the driver source -> untouched"      'grep -n PATH plugin/hooks/sweap-merge.sh'

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
