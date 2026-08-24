#!/usr/bin/env bash
#
# post-merge-cleanup.sh — end-of-run hygiene, mechanically enforced.
#
# Wired as a PostToolUse(Bash) hook gated on `gh pr merge` (see .claude/settings.json).
# After a PR merges it: (1) fast-forwards the primary checkout so `main` never drifts,
# (2) prunes stale remote-tracking refs left by `--delete-branch`, (3) removes any
# worktree whose branch has a MERGED PR and deletes that local branch, and (4) runs
# stranded-roadmap.sh and, if any branch carries backlog files that nothing is
# scheduled to land (PR closed unmerged, or no PR), says so to the session as
# additionalContext with the rescue recipe. (4) is report-only: a hook that opened
# PRs would be a side effect no one asked for; the playbook's End-of-run hygiene
# owns the rescue, this is what makes it impossible not to notice.
#
# SAFETY (why this can't eat in-flight work):
#   - It only acts on a branch that has a *merged* PR (`gh pr list --state merged`).
#     An in-flight worktree whose branch has no PR (or an open one) is never touched.
#   - `git worktree remove` runs WITHOUT --force, so it refuses on a dirty tree.
#   - Every step is idempotent and swallows its own errors — the hook never fails a run.
#
# Portable: derives the primary checkout from the shared git dir, no hard-coded paths.
set -uo pipefail

command -v gh >/dev/null 2>&1 || exit 0

GITDIR="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
PRIMARY="$(cd "$(dirname "$GITDIR")" 2>/dev/null && pwd)" || exit 0
[ -n "$PRIMARY" ] || exit 0

# The worktree the caller is standing in. NEVER remove it — deleting the live
# cwd out from under the session breaks the very next command. It's deferred to a
# later pass (when the session has moved on) or the explicit manual cleanup step.
SELF="$(pwd -P 2>/dev/null || true)"

# 1) Keep the primary checkout current (no-ops if it has local changes).
git -C "$PRIMARY" pull --ff-only >/dev/null 2>&1 || true
# 2) Drop remote-tracking refs for branches deleted on merge (`--delete-branch`).
git -C "$PRIMARY" fetch --prune >/dev/null 2>&1 || true

# 3) Retire worktrees/branches whose PR is merged. `git worktree list --porcelain`
#    emits a `worktree <path>` line then a `branch <ref>` line per entry.
git -C "$PRIMARY" worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{wt=$2} /^branch /{print wt"\t"$2}' \
  | while IFS=$'\t' read -r path ref; do
      br="${ref#refs/heads/}"
      [ "$path" = "$PRIMARY" ] && continue
      [ "$br" = "main" ] && continue
      # Skip the worktree the caller is currently inside (path == cwd or an ancestor).
      case "$SELF" in "$path" | "$path"/*) continue ;; esac
      # Protect in-flight work: only a MERGED PR for this exact branch qualifies.
      if gh pr list --head "$br" --state merged --limit 1 --json number 2>/dev/null | grep -q '"number"'; then
        if git -C "$PRIMARY" worktree remove "$path" >/dev/null 2>&1; then
          git -C "$PRIMARY" branch -D "$br" >/dev/null 2>&1 || true
          # Backstop for the remote: `gh pr merge --delete-branch` silently skips
          # the remote delete when run from inside a worktree (its switch-to-main
          # step aborts first), so the branch can still be on origin. Idempotent —
          # a no-op if already gone.
          git -C "$PRIMARY" push origin --delete "$br" >/dev/null 2>&1 || true
        fi
      fi
    done

git -C "$PRIMARY" worktree prune >/dev/null 2>&1 || true

# 4) Stranded backlog files. Runs AFTER the merge has been folded in (steps 1-3),
#    so the branch that just landed is never reported. Only closed/none states
#    are alarming: an open PR is a rider, which the board shows without alarm.
stranded="$(cd "$PRIMARY" && bash "$(dirname "${BASH_SOURCE[0]}")/stranded-roadmap.sh" 2>/dev/null | awk -F'\t' '$2=="closed" || $2=="none"')"
if [ -n "$stranded" ]; then
  msg="sweap: backlog files are STRANDED on branch(es) that nothing will land — they are invisible to the frontier, the board's backlog, audit-gate and /roadmap until they reach main:"
  while IFS=$'\t' read -r br state age paths; do
    [ -n "$br" ] || continue
    msg="$msg
  $br ($([ "$state" = closed ] && echo 'PR closed unmerged' || echo 'no PR'), ${age}d): $paths"
  done <<STRANDED_EOF
$stranded
STRANDED_EOF
  msg="$msg
Rescue (docs-only, rides the roadmap-only lane): git checkout -b roadmap/rescue-<6hex> origin/main && git checkout <branch> -- <the discovered/ and ideas/ paths above> && commit && open a PR. Top-level item files and index edits found here need /roadmap judgement before they land — list them for the human instead of relaying blindly. Then delete the dead branch so this stops firing."
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$msg"
  else
    printf '%s\n' "$msg"
  fi
fi
exit 0
