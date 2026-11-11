#!/usr/bin/env bash
#
# post-merge-cleanup.sh — end-of-run hygiene, mechanically enforced.
#
# Wired as a PostToolUse(Bash) hook (hooks/hooks.json); it filters itself to a merge.
# After a PR merges it: (1) fast-forwards the primary checkout so `main` never drifts,
# (2) prunes stale remote-tracking refs left by `--delete-branch`, (3) removes any
# worktree whose branch has a MERGED PR, deletes that local branch and its origin
# branch (the origin branch also for the worktree the caller stands in), and (4) runs
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

# SELF-FILTER to a merge, like post-merge-redcheck.sh and post-merge-auditcheck.sh.
# The registration's `if: Bash(gh pr merge:*)` does not hold on compound commands:
# in one consumer run 314 of 315 firings were on commands with no merge in them
# (`until gh run view ...`, `cd ... && ...`), each spending 8-13s in gh and
# re-injecting the stranded-backlog banner. Anything we cannot judge (no jq, no
# parser beside us, an unreadable payload, run by hand on a TTY) keeps the old
# behaviour: run.
parse_lib="$(dirname "${BASH_SOURCE[0]}")/lib-merge-parse.sh"
if command -v jq >/dev/null 2>&1 && [ -r "$parse_lib" ] && [ ! -t 0 ]; then
  cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)"
  if [ -n "$cmd" ]; then
    # shellcheck source=/dev/null
    . "$parse_lib"
    parse_merge_command "$cmd"
    [ "${MC_MERGE_RELATED:-1}" = "1" ] || exit 0
  fi
fi

command -v gh >/dev/null 2>&1 || exit 0

GITDIR="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
PRIMARY="$(cd "$(dirname "$GITDIR")" 2>/dev/null && pwd)" || exit 0
[ -n "$PRIMARY" ] || exit 0

# The worktree the caller is standing in. NEVER remove it — deleting the live
# cwd out from under the session breaks the very next command. It's deferred to a
# later pass (when the session has moved on) or the explicit manual cleanup step.
# Its origin branch is not deferred: step 3 deletes that regardless.
SELF="$(pwd -P 2>/dev/null || true)"

# 1) Keep the primary checkout current. git refuses the fast-forward when an
#    uncommitted file is among the paths the incoming commits change, identical
#    bytes or not; primary_ff (lib-primary-ff.sh) then fast-forwards past the
#    files that already hold the incoming content, without writing the working
#    tree, or leaves everything alone and says what is in the way. That line is
#    handed to the session at the end (step 4's channel): a refusal used to be
#    discarded here, and the primary sat stale for a whole run.
ff_msg=""
ff_lib="$(dirname "${BASH_SOURCE[0]}")/lib-primary-ff.sh"
if [ -r "$ff_lib" ]; then
  # shellcheck source=/dev/null
  . "$ff_lib"
  primary_ff "$PRIMARY" || ff_msg="${PRIMARY_FF_MSG:-}"
else
  git -C "$PRIMARY" pull --ff-only >/dev/null 2>&1 || true
fi
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
      # Protect in-flight work: only a MERGED PR for this exact branch qualifies.
      merged_sha="$(gh pr list --head "$br" --state merged --limit 1 --json headRefOid --jq '.[0].headRefOid // empty' 2>/dev/null)"
      case "$merged_sha" in "" | *[!0-9a-f]*) continue ;; esac
      # The worktree the caller is currently inside (path == cwd or an ancestor)
      # stays, and so does its local branch; a dirty one refuses removal. So
      # does a branch holding commits the merged PR never had: a name reused
      # after an earlier PR merged would otherwise lose its unpushed work to
      # `branch -D` (a consumer note, 2026-10). An unknown merged head (never
      # fetched) counts as "not contained" and keeps the branch.
      case "$SELF" in
        "$path" | "$path"/*) ;;
        *) if git -C "$PRIMARY" merge-base --is-ancestor "refs/heads/$br" "$merged_sha" >/dev/null 2>&1; then
             git -C "$PRIMARY" worktree remove "$path" >/dev/null 2>&1 \
               && git -C "$PRIMARY" branch -D "$br" >/dev/null 2>&1
           fi ;;
      esac
      # The remote branch goes either way: deleting it touches no cwd, and the
      # driver runs this hook from the PR's own worktree, so tying it to the
      # worktree removal left every such branch on origin (a consumer run: 11 of
      # 11). `gh pr merge --delete-branch` cannot be relied on for it in a
      # worktree flow (its switch-to-main step aborts first). The lease deletes
      # only while origin still holds the merged PR's head, so a branch name
      # reused for new commits is kept. Idempotent — a no-op if already gone.
      git -C "$PRIMARY" push origin --force-with-lease="refs/heads/$br:$merged_sha" ":refs/heads/$br" >/dev/null 2>&1 || true
    done

git -C "$PRIMARY" worktree prune >/dev/null 2>&1 || true

# 4) Stranded backlog files. Runs AFTER the merge has been folded in (steps 1-3),
#    so the branch that just landed is never reported. Only closed/none states
#    are alarming: an open PR is a rider, which the board shows without alarm.
stranded="$(cd "$PRIMARY" && bash "$(dirname "${BASH_SOURCE[0]}")/stranded-roadmap.sh" 2>/dev/null | awk -F'\t' '$2=="closed" || $2=="none"')"
msg=""
[ -n "$ff_msg" ] && msg="sweap: the $ff_msg"
if [ -n "$stranded" ]; then
  msg="${msg}${msg:+
}sweap: backlog files are STRANDED on branch(es) that nothing will land — they are invisible to the frontier, the board's backlog, audit-gate and /sweap:roadmap until they reach main:"
  while IFS=$'\t' read -r br state age paths; do
    [ -n "$br" ] || continue
    msg="$msg
  $br ($([ "$state" = closed ] && echo 'PR closed unmerged' || echo 'no PR'), ${age}d): $paths"
  done <<STRANDED_EOF
$stranded
STRANDED_EOF
  msg="$msg
Rescue (docs-only, rides the roadmap-only lane): git checkout -b roadmap/rescue-<6hex> origin/main && git checkout <branch> -- <the discovered/ and ideas/ paths above> && commit && open a PR. Top-level item files and index edits found here need /sweap:roadmap judgement before they land — list them for the human instead of relaying blindly. Then delete the dead branch so this stops firing."
fi
if [ -n "$msg" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$msg"
  else
    printf '%s\n' "$msg"
  fi
fi
exit 0
