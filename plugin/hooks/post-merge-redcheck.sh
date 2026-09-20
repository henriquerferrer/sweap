#!/usr/bin/env bash
#
# post-merge-redcheck.sh — belt-and-suspenders backstop to pre-merge-gate.sh.
#
# Wired as a PostToolUse(Bash) hook (hooks/hooks.json). Fires on EVERY Bash tool
# call and self-filters to `gh pr merge`. After a merge it re-checks the
# just-merged PR's rollup; if a merge somehow landed while a check was
# definitively RED (FAILURE/ERROR/CANCELLED/TIMED_OUT/ACTION_REQUIRED) it emits a
# loud stderr banner, fed back to the session via exit 2. Nothing else: it writes
# no file and never touches `main`.
#
# It covers ONE path: a session-issued `gh pr merge` whose PreToolUse gate was
# killed by the harness before it could answer. `sweap-merge` does not run it —
# the driver runs the gate in its own loop, fail-closed, seconds before a merge
# pinned to the head it judged, so this would re-read the identical rollup. A red
# push-run on main is session-main-redcheck.sh's job.
#
# Scope note: this alarms only on DEFINITIVELY-failed checks (a broken main), not
# on PENDING — the pre-merge gate is the comprehensive greenness control; this is
# the narrow "did we break main?" smoke alarm.
#
# Never fails the run on its own bookkeeping: all detection/notification steps
# swallow their own errors. Exit 2 (loud) ONLY when a red main is confirmed.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# Shared shell-aware `gh pr merge` detector/parser (see lib-merge-parse.sh).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-merge-parse.sh"

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# Only act after a merge-related command (same greedy detector as the gate). We
# red-check whatever clean PR numbers the precise parser could extract (MC_PRS);
# a wrapped/unparseable merge should never have reached here (the pre-gate denies
# it), and if it somehow did there are no clean PRs to key off — nothing to check.
parse_merge_command "$cmd"
[ "$MC_MERGE_RELATED" = "1" ] || exit 0

# Best-effort: run gh in the caller's cwd so it resolves the current repo. If the
# cd fails we deliberately continue in the current dir rather than abort.
if [ -n "$cwd" ]; then cd "$cwd" 2>/dev/null || true; fi

command -v gh >/dev/null 2>&1 || exit 0

# A compound command can batch several merges — check EVERY merged PR, not just
# the first (mirrors the pre-merge gate).
[ -n "$MC_PRS" ] || exit 0

GH_TIMEOUT="${MERGE_GATE_GH_TIMEOUT:-10}"

any_red=0
banner=""

check_one() {   # $1 = pr ; on a definitively-red rollup: adds to the banner
  local pr="$1" tmp ghpid watcher json red
  printf '%s' "$pr" | grep -qE '^[0-9]+$' || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  gh pr view "$pr" --json statusCheckRollup,mergeCommit >"$tmp" 2>/dev/null &
  ghpid=$!
  ( sleep "$GH_TIMEOUT"; kill -TERM "$ghpid" 2>/dev/null ) &
  watcher=$!
  wait "$ghpid" 2>/dev/null
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  json="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"

  # Can't determine → stay quiet (the pre-merge gate is the real control).
  [ -n "$json" ] && printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 0

  # Definitively-red checks only (a broken main), not PENDING.
  red="$(printf '%s' "$json" | jq -r '
    def norm:
      if (.__typename // "") == "CheckRun"
      then (if (.status // "") != "COMPLETED" then "PENDING" else (.conclusion // "PENDING") end)
      else (.state // "PENDING") end;
    (.statusCheckRollup // [])
    | map({name: (.name // .context // "unknown"), s: (norm | ascii_upcase)})
    | map(select(.s as $s | ($s == "FAILURE" or $s == "ERROR" or $s == "CANCELLED" or $s == "TIMED_OUT" or $s == "ACTION_REQUIRED")))
    | map("\(.name)=\(.s)")
    | join(", ")
  ' 2>/dev/null)"
  [ -n "$red" ] || return 0   # this PR is not red

  any_red=1
  banner="${banner}## RED MAIN: PR #${pr} merged while NOT green — ${red}
"
}

# shellcheck disable=SC2086  # MC_PRS is a space-separated list of bare integers
for pr in $MC_PRS; do check_one "$pr"; done

[ "$any_red" = "1" ] || exit 0   # no red main — nothing to do

# Loud banner to stderr; exit 2 feeds it back to the session as automated context.
{
  printf '\n################################################################\n'
  printf '%s' "$banner"
  printf '## OPEN A REMEDIATION PR (through the gate). Do NOT commit to main.\n'
  printf '################################################################\n'
} >&2
exit 2
