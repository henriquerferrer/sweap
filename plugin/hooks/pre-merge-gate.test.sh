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
# Behavior driven by GH_STUB (green|failure|pending|skipped|error|empty).
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh pr view <n> --json ...` stub. Mode is GH_STUB, overridable
# PER PR via GH_STUB_<n> (e.g. GH_STUB_43=failure) so chained-merge tests can
# make different PRs green/red independently.
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
case "$mode" in
  error)   exit 1 ;;                                   # gh failed / unreachable
  slow)    sleep "${GH_STUB_SLEEP:-5}"; exit 0 ;;      # exceed the internal timeout
  empty)   echo '{"statusCheckRollup":[]}'; exit 0 ;;  # CI not registered yet
  green)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}
    ],"mergeCommit":{"oid":"deadbeef"}}' ;;
  skipped)
    echo '{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","name":"optional","status":"COMPLETED","conclusion":"SKIPPED"}
    ],"mergeCommit":{"oid":"deadbeef"}}' ;;
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
esac
exit 0
STUB
chmod +x "$STUB_BIN/gh"

# Generous default gh timeout so normal-path cases never flake under load; the
# explicit timeout test overrides MGT=1 with a stub that sleeps longer than that.
run_gate() {  # $1=GH_STUB, $2=command ; feeds mock PreToolUse JSON, prints stdout
  local stub="$1" cmd="$2"
  local json
  json="$(jq -cn --arg c "$cmd" --arg d "$WORK" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",cwd:$d,tool_input:{command:$c}}')"
  PATH="$STUB_BIN:$PATH" GH_STUB="$stub" MERGE_GATE_GH_TIMEOUT="${MGT:-5}" \
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

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
