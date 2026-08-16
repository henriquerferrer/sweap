#!/usr/bin/env bash
#
# audit-agent-guard.test.sh — tests for the audit sub-agent PreToolUse guard.
#
# Run:  bash plugin/hooks/audit-agent-guard.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/audit-agent-guard.sh"

pass=0; fail=0
OUT=""
run() { # run <json>
  OUT="$(printf '%s' "$1" | bash "$GUARD" 2>&1)"
}
denied() { printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
check() { # check <desc> <deny|silent>
  local desc="$1" want="$2" got="silent"
  denied && got="deny"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s (got %s, wanted %s)\n    %s\n' "$desc" "$got" "$want" "$OUT"; fi
}
ev() { # ev <agent_type> <tool> [file_path] [cwd]
  jq -cn --arg a "$1" --arg t "$2" --arg p "${3:-}" --arg c "${4:-}" \
    '{agent_type:$a, tool_name:$t, cwd:$c, tool_input:(if $p == "" then {} else {file_path:$p} end)}'
}

echo "audit-agent-guard.test.sh:"

# --- audit-reader: no mutation, no execution ---------------------------------
for t in Write Edit NotebookEdit Bash; do
  run "$(ev audit-reader "$t" /tmp/x.txt /repo)"
  check "reader is denied $t" deny
done
run "$(ev audit-reader Read /repo/a.ts /repo)"
check "reader may Read" silent
run "$(ev audit-reader Grep "" /repo)"
check "reader may Grep" silent

# Plugin-scoped identifiers must match too — guessing the scoping wrong would
# silently disable the whole guard.
run "$(ev sweap:audit-reader Write /tmp/x.txt /repo)"
check "plugin-scoped agent_type is still matched" deny

# --- audit-prover: may write, but only inside its worktree --------------------
run "$(ev audit-prover Write /repo/wt/probe.test.ts /repo/wt)"
check "prover may write inside its worktree (absolute, inside cwd)" silent
run "$(ev audit-prover Write probe.test.ts /repo/wt)"
check "prover may write a relative path" silent
run "$(ev audit-prover Bash "" /repo/wt)"
check "prover may run commands" silent
run "$(ev audit-prover Write /Users/h/consumer-a/apps/x.test.tsx /repo/wt)"
check "prover is denied an absolute write outside its worktree" deny
run "$(ev audit-prover Write /repo/wt-other/x.ts /repo/wt)"
check "a sibling path sharing a prefix is not inside the worktree" deny
run "$(ev audit-prover Write /tmp/x.ts "")"
check "absolute write with no cwd to compare fails closed" deny

# --- everyone else is none of this hook's business ---------------------------
run "$(ev general-purpose Write /repo/x.ts /repo)"
check "an unrelated agent type is untouched" silent
run "$(printf '{"tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"/repo/x.ts"}}')"
check "a main-session call (no agent_type) is untouched" silent
run "$(printf '{}')"
check "empty payload is a silent no-op" silent
run "$(printf 'not json at all')"
check "unparseable payload is a silent no-op" silent

# --- the hook never approves, only denies or stays silent --------------------
run "$(ev audit-reader Read /repo/a.ts /repo)"
if printf '%s' "$OUT" | grep -q 'allow'; then
  fail=$((fail+1)); printf '  FAIL  hook must never emit an allow decision\n'
else
  pass=$((pass+1)); printf '  PASS  hook never emits an allow decision\n'
fi

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
