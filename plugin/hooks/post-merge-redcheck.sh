#!/usr/bin/env bash
#
# post-merge-redcheck.sh — belt-and-suspenders backstop to pre-merge-gate.sh.
#
# Wired as a PostToolUse(Bash) hook (see .claude/settings.json). Fires on EVERY
# Bash tool call and self-filters to `gh pr merge`. After a merge it re-checks the
# just-merged PR's rollup; if a merge somehow landed while a check was
# definitively RED (FAILURE/ERROR/CANCELLED/TIMED_OUT/ACTION_REQUIRED — i.e. the
# exact "broke main" incident this whole change targets), it:
#   (a) emits a loud stderr banner (fed back to the session via exit 2) and a
#       best-effort macOS notification, and
#   (b) drops a GITIGNORED marker file in the PRIMARY checkout's .claude/
#       (.claude/main-red-<sha>.flag) recording the PR + failing checks.
#
# It NEVER commits anything and NEVER touches `main` (that would violate the
# never-commit-to-main rule). Remediation is the agent's job: the marker + banner
# surface the red main so the next run opens a fix PR through the gate.
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

# Marker goes in the PRIMARY checkout so it survives worktree cleanup and the next
# session sees it (same primary-derivation trick the cleanup hook uses).
marker_dir=""
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
if [ -n "$gitdir" ]; then
  primary="$(cd "$(dirname "$gitdir")" 2>/dev/null && pwd)" || primary=""
  [ -n "$primary" ] && [ -d "$primary/.claude" ] && marker_dir="$primary/.claude"
fi
[ -n "$marker_dir" ] || marker_dir="$(pwd)/.claude"

any_red=0
banner=""

check_one() {   # $1 = pr ; on a definitively-red rollup: writes a marker + notifies
  local pr="$1" tmp ghpid watcher json red sha marker
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

  sha="$(printf '%s' "$json" | jq -r '.mergeCommit.oid // empty' 2>/dev/null)"
  [ -n "$sha" ] || sha="pr${pr}"
  mkdir -p "$marker_dir" 2>/dev/null || true
  marker="$marker_dir/main-red-${sha}.flag"
  {
    printf 'RED MAIN DETECTED after merge of PR #%s\n' "$pr"
    printf 'merge commit: %s\n' "$sha"
    printf 'detected at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    printf 'failing checks: %s\n' "$red"
    printf '\nRemediation: open a fix PR through the gate to make main green again.\n'
    printf 'Do NOT commit directly to main. Delete this marker once main is green.\n'
  } >"$marker" 2>/dev/null || true

  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"PR #$pr merged with RED checks: $red\" with title \"consumer A: main is RED\"" >/dev/null 2>&1 || true
  fi

  any_red=1
  banner="${banner}## RED MAIN: PR #${pr} merged while NOT green — ${red}
##   marker: ${marker}
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
