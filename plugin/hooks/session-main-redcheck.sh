#!/usr/bin/env bash
#
# session-main-redcheck.sh — is the base branch RED right now?
#
# Wired as a SessionStart hook (hooks/hooks.json). Asks GitHub for the check
# runs on the tip of the base branch; if any is DEFINITIVELY red it drops the
# same gitignored `.claude/main-red-<sha>.flag` marker post-merge-redcheck.sh
# uses and returns a SessionStart `additionalContext` banner, so the session
# opens knowing main is broken instead of discovering it sideways.
#
# WHY IT EXISTS. post-merge-redcheck.sh cannot cover this, for two independent
# reasons: it is a PostToolUse(Bash) hook keyed off `gh pr merge`, so it only
# ever sees a merge an AGENT performed inside a session; and it reads the merged
# PR's `statusCheckRollup`, which is a PR object. A HUMAN's direct push to the
# base branch is neither — it is not a tool call, and it has no PR. That push is
# not an edge case: the merge gate denies CI-control PRs to sessions so a human
# lands them, and the scaffold's managed-file heal ("review the diff and commit
# it") produces the same shape. So the one path with no automated review also
# had no automated alarm.
#
# What that cost (2026-08-31): both consumers sat red for hours. It never
# presented as "main is broken" — a PR branched off a red main inherits the
# failure and the merge gate then denies it, so it presented as "every open PR
# is inexplicably failing", and was diagnosed backwards. The detector was bound
# to a tool call; the fault is a property of the branch. This asks the second
# question, at session start: not "did a merge just go wrong" but "is the base
# branch red RIGHT NOW".
#
# DEFINITIVELY red only (FAILURE/TIMED_OUT/CANCELLED/ACTION_REQUIRED) — the same
# set post-merge-redcheck.sh alarms on. PENDING is not red: a run in flight is
# the normal state at session start and must never produce a banner.
#
# NEVER blocks and never fails the session: every step swallows its own errors
# and the hook exits 0 on any doubt (no gh, no jq, no remote, a slow or failed
# API call, an unparseable payload). A session that cannot start because its
# smoke alarm could not reach the network is a worse failure than the one this
# detects. Deliberately NOT in scope: deleting stale markers when main is green
# again — that destroys evidence of a flake, and is the human's call.
#
# Portable to bash 3.2: no timeout(1), no mapfile, no process substitution.
set -uo pipefail

GH_TIMEOUT="${SWEAP_MAIN_REDCHECK_TIMEOUT:-8}"

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null)"

# SessionStart `source`: skip the compact/clear resumes, which are the same
# session continuing — the banner was already delivered when it started.
src="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)"
case "$src" in compact|clear) exit 0 ;; esac

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] && { cd "$cwd" 2>/dev/null || true; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- base branch --------------------------------------------------------------
# Same precedence the push gate uses: an explicit override, then what the remote
# says its default is, then the conventional names. Never guess past that.
base="${SWEAP_BASE_BRANCH:-}"
if [ -z "$base" ]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
fi
if [ -z "$base" ]; then
  for c in main master; do
    if git show-ref -q --verify "refs/remotes/origin/$c" 2>/dev/null; then base="$c"; break; fi
  done
fi
[ -n "$base" ] || exit 0

# --- ask GitHub, under a hard deadline ----------------------------------------
tmp="$(mktemp 2>/dev/null)" || exit 0
gh api "repos/{owner}/{repo}/commits/${base}/check-runs?per_page=100" >"$tmp" 2>/dev/null &
ghpid=$!
( sleep "$GH_TIMEOUT"; kill -TERM "$ghpid" 2>/dev/null ) >/dev/null 2>&1 &
watcher=$!
wait "$ghpid" 2>/dev/null
kill -TERM "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

json="$(cat "$tmp" 2>/dev/null)"
rm -f "$tmp" 2>/dev/null
[ -n "$json" ] || exit 0
printf '%s' "$json" | jq -e . >/dev/null 2>&1 || exit 0

red="$(printf '%s' "$json" | jq -r '
  [ .check_runs[]?
    | select((.status // "") == "completed")
    | {n: (.name // "unknown"), c: ((.conclusion // "") | ascii_upcase)}
    | select(.c == "FAILURE" or .c == "TIMED_OUT" or .c == "CANCELLED" or .c == "ACTION_REQUIRED")
    | "\(.n)=\(.c)" ] | join(", ")' 2>/dev/null)"
[ -n "$red" ] || exit 0   # green, pending, or no checks at all — say nothing

sha="$(printf '%s' "$json" | jq -r '[.check_runs[]?.head_sha] | map(select(. != null)) | first // empty' 2>/dev/null)"
[ -n "$sha" ] || sha="$base"

# --- marker, in the PRIMARY checkout so it survives worktree cleanup -----------
marker_dir=""
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
if [ -n "$gitdir" ]; then
  primary="$(cd "$(dirname "$gitdir")" 2>/dev/null && pwd)" || primary=""
  [ -n "$primary" ] && marker_dir="$primary/.claude"
fi
[ -n "$marker_dir" ] || marker_dir="$(pwd)/.claude"
marker="$marker_dir/main-red-${sha}.flag"

if [ ! -f "$marker" ]; then
  mkdir -p "$marker_dir" 2>/dev/null || true
  {
    printf 'RED %s DETECTED at session start (not via a merge)\n' "$base"
    printf 'commit: %s\n' "$sha"
    printf 'detected at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    printf 'failing checks: %s\n' "$red"
    printf '\nThis is the branch tip, so it was most likely a DIRECT PUSH (a human\n'
    printf 'landing a CI change, or committing the sweap managed-file heal) rather\n'
    printf 'than a merge — post-merge-redcheck.sh never sees those.\n'
    printf '\nRemediation: open a fix PR through the gate. Do NOT commit to %s.\n' "$base"
    printf 'Delete this marker once %s is green.\n' "$base"
  } >"$marker" 2>/dev/null || true
fi

msg="sweap: ${base} IS RED right now — ${red} (commit ${sha}). This was detected by reading the branch tip at session start, not from a merge, so it is most likely a DIRECT PUSH: a human landing a CI change, or the sweap managed-file heal committed straight to ${base}. Marker: ${marker}. WHY THIS MATTERS BEFORE YOU START: a PR branched off a red ${base} inherits the failure, and pre-merge-gate.sh then denies it — so every PR you open now will be un-mergeable for a reason that has nothing to do with your change. Fix ${base} first, or expect that. Before assuming a regression, check whether the failing job is a known flake (re-run it on ${base}); if the commits since the last green run touch only .github/, .claude/ and the backlog, a product-test failure cannot be a regression. Remediate with a PR through the gate — never a commit to ${base}."

if printf '%s' "$msg" | jq -Rs . >/dev/null 2>&1; then
  jq -n --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$msg"
else
  printf '%s\n' "$msg"
fi
exit 0
