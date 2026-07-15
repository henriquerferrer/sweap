#!/usr/bin/env bash
#
# pre-merge-gate.sh — mechanical enforcement of the merge-greenness gate.
#
# Wired as a PreToolUse(Bash) hook (see .claude/settings.json). It fires on EVERY
# Bash tool call and self-filters: it is a silent no-op for anything that is not a
# `gh pr merge` invocation. For a `gh pr merge`, it independently verifies the
# PR's check rollup is all-green and DENIES the merge otherwise — converting the
# playbook's instruction-level gate ("never merge until `gh pr checks` is green,
# including `review`") into a mechanical control.
#
# WHY THIS EXISTS: the gate silently failed once — a `gh pr checks <n> --watch |
# tail` pipe masked the real exit code (a pipe returns tail's 0), so a PR whose
# e2e had FAILED got merged and briefly broke `main`. This hook removes the
# human-reads-the-output link from the chain.
#
# DESIGN INVARIANTS (this hook STRENGTHENS the gate; it must never weaken it):
#   - It only ever emits a DENY or stays silent. It NEVER emits an allow/approve,
#     so it can only ADD denials on top of the normal permission flow — it can
#     never make a command more permissive than baseline.
#   - Fail-closed for merges: on ANY error/uncertainty (gh errors, times out,
#     unparseable output) it DENIES *recoverably* — the operator re-runs once gh
#     recovers and a genuinely-green PR then passes. It never fails open (that
#     would reopen the hole) and never permanently wedges (a later retry passes).
#   - The harness may treat a non-zero hook exit as a NON-blocking (fail-open)
#     error, so this script ALWAYS exits 0 and communicates purely via stdout
#     JSON. An EXIT trap guarantees a deny is emitted even on an unexpected crash
#     while handling a merge command.
#   - Bounded: the gh query has its own internal timeout so the hook always
#     finishes well inside the harness hook timeout and never relies on it.
#   - Current repo only: gh runs in the caller's cwd (no --repo), and --repo/-R
#     /--admin on the merge command are rejected outright.
#
# Exit: always 0. Decision is the stdout JSON (deny) or empty stdout (no-op/defer).

set -uo pipefail

# Shared shell-aware `gh pr merge` detector/parser (see lib-merge-parse.sh).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-merge-parse.sh"

# --- guaranteed decision channel ------------------------------------------------
DECISION_EMITTED=0   # set when we print a deny
IS_MERGE=0           # set once we know the command is a `gh pr merge`
CLEAN_ALLOW=0        # set right before a deliberate all-green (silent) allow

emit_deny() {
  # $1 = human-readable reason. Emits the PreToolUse deny JSON and marks done.
  local reason="$1"
  DECISION_EMITTED=1
  # jq builds valid JSON regardless of characters in the reason.
  jq -cn --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

# Fail-closed backstop: if we are handling a merge command and somehow reach exit
# WITHOUT having emitted a decision (unexpected crash / unbound var / etc.), deny
# recoverably. Always force exit 0 so the harness parses our stdout JSON rather
# than treating a non-zero exit as a fail-open non-blocking error.
# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT`
handle_exit() {
  if [ "$DECISION_EMITTED" != "1" ] && [ "$IS_MERGE" = "1" ] && [ "$CLEAN_ALLOW" != "1" ]; then
    emit_deny "merge-gate hook could not complete its greenness check (internal error). Denying to stay fail-closed — re-run the merge once resolved."
  fi
  exit 0
}
trap handle_exit EXIT

# --- read hook input ------------------------------------------------------------
input="$(cat)"

# jq parses the tool call. If it is somehow missing we cannot parse the JSON, so
# fall back to a RAW grep of the whole input: if it looks like a `gh pr merge`,
# FAIL CLOSED (deny-recoverable) rather than silently letting an unverifiable
# merge through; otherwise no-op. (jq is a hard repo dependency and is always
# present — this is pure defence-in-depth so the jq-missing path is never a hole.)
if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
    IS_MERGE=1
    DECISION_EMITTED=1
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"merge-gate: jq is unavailable so checks cannot be verified. Denying (recoverable) — install jq and re-run the merge."}}'
  fi
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"

# Only Bash tool calls carry a shell command.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# If the shared parser failed to load (lib missing/deleted, a syntax error, or a
# missing tool like `dirname` broke the `.` source line), do NOT proceed to an
# undefined `parse_merge_command` — that would abort under `set -u` before we mark
# IS_MERGE and fail OPEN. Fail CLOSED on anything merge-ish instead.
if ! declare -F parse_merge_command >/dev/null 2>&1; then
  if printf '%s' "$cmd" | grep -Eq 'gh.*pr.*merge'; then
    IS_MERGE=1
    emit_deny "merge-gate: the gate's parser could not load, so this merge cannot be verified. Denying (recoverable) — retry once the environment is healthy."
  fi
  exit 0
fi

# --- greedy-detect + fail-closed ------------------------------------------------
# parse_merge_command sets MC_MERGE_RELATED (a structure-agnostic greedy trip-wire:
# do the words gh->pr->merge appear in order anywhere?) plus a PRECISE parse of the
# pristine simple form. Not merge-related → silent no-op. Merge-related but NOT a
# pristine simple merge (wrapped in if/while/for/subshell/$()/backticks, extra or
# missing args, a bad flag, untokenisable, or the precise parse didn't account for
# every greedy occurrence) → fail CLOSED. Only a pristine, all-green merge ALLOWs.
parse_merge_command "$cmd"
if [ "$MC_MERGE_RELATED" != "1" ]; then
  exit 0   # not merge-related — silent no-op
fi
IS_MERGE=1

# Specific, actionable denials first (bad flags anywhere in a recognised merge).
if [ "$MC_BAD_FLAG" = "admin" ]; then
  emit_deny "Refusing 'gh pr merge --admin': force-merging past required checks is never self-authorized (standing policy). Merge only via a green gate."
  exit 0
fi
if [ "$MC_BAD_FLAG" = "repo" ]; then
  emit_deny "Refusing 'gh pr merge --repo/-R': the agent merges only the CURRENT repo's PRs (standing policy). Drop the --repo/-R flag."
  exit 0
fi

# Fail CLOSED unless this is a PRISTINE simple merge the parser fully accounts for:
#   - tokenised cleanly (no unbalanced quotes),
#   - precise parser recognised a command-position `gh pr merge`,
#   - it recognised EXACTLY as many merges as the greedy scan saw (nothing hidden
#     in an `if`/subshell/`$()` alongside),
#   - every merge yielded one clean numeric/URL PR (nothing unparsed),
#   - at least one PR to check.
if [ "${MC_PARSE_ERR:-0}" = "1" ] \
   || [ "$MC_IS_MERGE" != "1" ] \
   || [ "${MC_UNPARSED:-0}" -gt 0 ] \
   || [ "${MC_MERGE_COUNT:-0}" != "${MC_RELATED_COUNT:-0}" ] \
   || [ -z "$MC_PRS" ]; then
  emit_deny "merge-gate: this command is merge-related but is NOT a pristine 'gh pr merge <n>' the gate can verify — it is wrapped (if/while/for/subshell/\$()/backticks), has extra/missing/ambiguous arguments, or could not be cleanly tokenised. Failing CLOSED. Re-issue each merge plainly on its own line: 'gh pr merge <n> --squash'."
  exit 0
fi

# --- run in the caller's cwd so gh resolves the CURRENT repo --------------------
if [ -n "$cwd" ]; then
  cd "$cwd" 2>/dev/null || {
    emit_deny "merge-gate: could not enter the working directory to verify checks. Denying (recoverable) — re-run the merge."
    exit 0
  }
fi

# verify_pr <n>: query one PR's rollup (bounded by an internal timeout) and, if it
# is not green or greenness can't be determined, emit a deny and return 1. Green
# ⇒ return 0 silently.
# A CheckRun is green only when COMPLETED with conclusion SUCCESS (SKIPPED/NEUTRAL
# are non-blocking — a legitimately skipped check must not permanently wedge a
# merge, and the rollup cannot tell "should-run-but-skipped" apart). A
# StatusContext is green only when state==SUCCESS. Everything else (PENDING /
# QUEUED / IN_PROGRESS / FAILURE / ERROR / CANCELLED / TIMED_OUT / ACTION_REQUIRED)
# is not-green.
verify_pr() {
  local pr="$1"
  # Per-call timeout: caller passes a budget ($2) so a MULTI-PR batch's TOTAL
  # verification time stays bounded (see the loop) — otherwise N × per-PR-timeout
  # could exceed the harness hook timeout, which would kill the hook and (the
  # harness treating a killed hook as non-blocking) fail OPEN. Falls back to the
  # per-PR default for single-PR use.
  local timeout="${2:-${MERGE_GATE_GH_TIMEOUT:-10}}"
  local tmp ghpid watcher ghrc json count offenders
  [ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
  tmp="$(mktemp 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then
    emit_deny "merge-gate: could not allocate a temp file to verify checks. Denying (recoverable) — re-run the merge."
    return 1
  fi
  gh pr view "$pr" --json statusCheckRollup >"$tmp" 2>/dev/null &
  ghpid=$!
  ( sleep "$timeout"; kill -TERM "$ghpid" 2>/dev/null ) &
  watcher=$!
  wait "$ghpid" 2>/dev/null
  ghrc=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  json="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"

  if [ "$ghrc" != "0" ] || [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    emit_deny "merge-gate: could not verify PR #$pr's checks (gh errored or timed out). The gate fails CLOSED — it does not know the checks are green. Re-run the merge once gh recovers; a genuinely-green PR will pass."
    return 1
  fi
  count="$(printf '%s' "$json" | jq '(.statusCheckRollup // []) | length' 2>/dev/null)"
  if ! printf '%s' "$count" | grep -qE '^[0-9]+$'; then
    emit_deny "merge-gate: could not read PR #$pr's check rollup. Denying (recoverable) — re-run the merge."
    return 1
  fi
  if [ "$count" = "0" ]; then
    emit_deny "merge-gate: PR #$pr has no checks reported yet — CI has not registered. The gate fails CLOSED (can't confirm green). Re-run once the checks appear and pass."
    return 1
  fi
  offenders="$(printf '%s' "$json" | jq -r '
    def norm:
      if (.__typename // "") == "CheckRun"
      then (if (.status // "") != "COMPLETED" then (.status // "PENDING") else (.conclusion // "PENDING") end)
      else (.state // "PENDING") end;
    (.statusCheckRollup // [])
    | map({name: (.name // .context // "unknown"), s: (norm | ascii_upcase)})
    | map(select(.s as $s | ($s == "SUCCESS" or $s == "SKIPPED" or $s == "NEUTRAL") | not))
    | map("\(.name)=\(.s)")
    | join(", ")
  ' 2>/dev/null)"
  if [ -n "$offenders" ]; then
    emit_deny "merge-gate: PR #$pr is NOT green — refusing to merge. Not-green checks: $offenders. Wait for them to pass (or fix a failure) and re-run; the gate is the control, not a prompt."
    return 1
  fi
  return 0
}

# Verify EVERY batched PR; deny on the first that is not green. A GLOBAL wall-clock
# budget bounds the whole batch well under the harness hook timeout (25 s in
# settings.json) so a slow-gh batch can never run long enough to be killed and
# fail open — if the budget runs out mid-batch we deny (recoverable): merge one PR
# per call. Each PR gets min(per-PR cap, remaining budget).
GATE_TOTAL_BUDGET="${MERGE_GATE_TOTAL_BUDGET:-18}"
GATE_PER_PR_CAP="${MERGE_GATE_GH_TIMEOUT:-10}"
gate_deadline=$(( $(date +%s) + GATE_TOTAL_BUDGET ))
# shellcheck disable=SC2086  # MC_PRS is a space-separated list of bare integers
for pr in $MC_PRS; do
  remaining=$(( gate_deadline - $(date +%s) ))
  if [ "$remaining" -lt 1 ]; then
    emit_deny "merge-gate: ran out of the time budget while verifying a batch of merges (gh is slow) before checking PR #$pr. Failing CLOSED. Merge PRs one at a time so each is verified within budget."
    exit 0
  fi
  budget="$GATE_PER_PR_CAP"
  [ "$remaining" -lt "$budget" ] && budget="$remaining"
  verify_pr "$pr" "$budget" || exit 0
done

# Every PR green → stay silent (no decision). The command is on the gh allowlist
# and proceeds under the normal permission flow. The hook never auto-approves.
# CLEAN_ALLOW tells the EXIT trap this was a deliberate green pass, not a crash.
CLEAN_ALLOW=1
exit 0
