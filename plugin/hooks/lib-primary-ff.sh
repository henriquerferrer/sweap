#!/usr/bin/env bash
#
# lib-primary-ff.sh — fast-forward the primary checkout, and do not let it stay
# behind over a file that already holds what the pull would write.
#
# Sourced by post-merge-cleanup.sh. Defines one function and runs nothing when
# sourced.
#
# WHY. `git pull --ff-only` refuses when an uncommitted tracked file is among
# the paths the incoming commits change, even when the uncommitted bytes are
# IDENTICAL to the incoming ones. scaffold.sh's managed-file sync produces
# exactly that: a new plugin version rewrites the vendored controls in the
# working tree at session start, and the adoption PR then merges the same bytes.
# The hook used to discard the refusal (`pull ... >/dev/null 2>&1 || true`), so
# the primary sat at one commit for a whole run while the base moved on.
# Everything that reads the backlog from disk went stale with it: twice in a
# consumer (2026-09-25 for 2 h 45 min, 2026-11-09 for 20 h, 21 commits behind),
# and the second time `sweap-frontier` kept listing merged items as todo and
# hiding the item they unblocked, so the run reported the frontier drained with
# a runnable item left.
#
# WHAT. primary_ff <dir>
#   1. Plain `git pull --ff-only`. Done if it works.
#   2. Otherwise, when the checkout is strictly behind its upstream, nothing is
#      staged and no merge, rebase, cherry-pick, revert or bisect is under way:
#      take the tracked files that are modified in the working tree AND changed
#      by the incoming commits. If every one of them hashes to the upstream's
#      blob, STAGE them and `git merge --ff-only <the upstream commit just
#      checked>`. Git accepts a fast-forward over an index entry that already
#      equals the incoming one, and leaves the file on disk alone.
#   3. If git still refuses, the staging is undone (`git reset -- <files>`).
#
# THE WORKING TREE IS NEVER WRITTEN. The only thing this changes is the index,
# and only for files nothing was staged in; a refusal after staging puts the
# index back. So an edit made between the check and the staging, a filter that
# makes two different files hash alike, a mode that differs, an untracked file
# where the pull would create one — each ends as git's own refusal with every
# byte on disk as it was. (The first version restored the files to HEAD and
# pulled again; a hostile review of that diff destroyed staged work, wiped an
# uncommitted merge and lost bytes through a clean filter with it.)
# No stash, for the same reason: a stash that does not re-apply leaves conflict
# markers, an unmerged index and a checkout whose every later pull dies.
# No second network pull: the fast-forward goes to the commit that was checked.
#
# Returns 0 when the checkout is current afterwards, 1 otherwise. Never exits,
# never fails the caller. On 1, when the checkout is known to be behind,
# PRIMARY_FF_MSG holds one line saying how far and what is in the way, for the
# caller to hand to the session; it is empty when there is nothing to say (no
# upstream, nothing fetched, a diverged branch). A heal prints one stderr line.
#
# Bounded: more than 100 modified files is not this problem, and is reported
# without a per-file scan. Portable to bash 3.2: no mapfile, no process
# substitution.

PRIMARY_FF_MSG=""

# shellcheck disable=SC2034  # PRIMARY_FF_MSG is read by the caller
primary_ff() {
  local dir="${1:-}" err up upname behind gd f tmp same n=0 total=0 stuck="" op=""
  PRIMARY_FF_MSG=""
  [ -n "$dir" ] || return 1
  err="$(git -C "$dir" pull --ff-only 2>&1 >/dev/null)" && return 0

  up="$(git -C "$dir" rev-parse -q --verify '@{upstream}^{commit}' 2>/dev/null)" || return 1
  [ -n "$up" ] || return 1
  git -C "$dir" merge-base --is-ancestor HEAD "$up" 2>/dev/null || return 1   # diverged: a person's
  behind="$(git -C "$dir" rev-list --count "HEAD..$up" 2>/dev/null)"
  case "$behind" in ''|0|*[!0-9]*) return 1 ;; esac   # nothing fetched (no network): not this problem
  upname="$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
  [ -n "$upname" ] || upname="its upstream"
  err="$(printf '%s' "$err" | tr '\t\n' '  ' | cut -c1-400)"

  # Someone's work in progress is never touched: anything staged, or an
  # operation that owns the index.
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    [ -n "$gd" ] && [ -e "$gd/$f" ] && op="$f"
  done
  if [ -z "$gd" ] || [ -n "$op" ] || ! git -C "$dir" diff --cached --quiet --ignore-submodules=all 2>/dev/null; then
    PRIMARY_FF_MSG="primary checkout is $behind commit(s) behind $upname and cannot fast-forward (${op:+$op in progress; }staged changes or an unfinished operation there, left alone): $err"
    return 1
  fi

  tmp="$(mktemp 2>/dev/null)" || return 1
  same="$(mktemp 2>/dev/null)" || { rm -f "$tmp"; return 1; }
  # Tracked files modified in the working tree...
  git -C "$dir" diff --name-only -z --no-renames --ignore-submodules=all >"$tmp" 2>/dev/null
  total="$(tr -cd '\0' <"$tmp" | wc -c | tr -d ' ')"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  if [ "$total" -gt 100 ]; then
    rm -f "$tmp" "$same"
    PRIMARY_FF_MSG="primary checkout is $behind commit(s) behind $upname and cannot fast-forward ($total modified files there, left alone): $err"
    return 1
  fi
  while IFS= read -r -d '' f; do
    # ...that the incoming commits change too.
    git --literal-pathspecs -C "$dir" diff --quiet --no-renames HEAD "$up" -- "$f" 2>/dev/null && continue
    if [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] \
       && [ "$(git -C "$dir" hash-object -- "$f" 2>/dev/null)" = "$(git -C "$dir" rev-parse -q --verify "$up:$f" 2>/dev/null)" ]; then
      printf '%s\0' "$f" >>"$same"; n=$((n + 1))
    else
      stuck="${stuck}${stuck:+, }$f"
    fi
  done <"$tmp"
  rm -f "$tmp"

  if [ -n "$stuck" ]; then
    rm -f "$same"
    PRIMARY_FF_MSG="primary checkout is $behind commit(s) behind $upname and cannot fast-forward: uncommitted $(printf '%s' "$stuck" | tr '\n' ' ' | cut -c1-400) there differ(s) from the incoming copy. Nothing was touched. Commit, move or restore that, then \`git pull --ff-only\` there — until then the backlog on disk is stale (the frontier and the board read it)."
    return 1
  fi
  if [ "$n" -eq 0 ]; then
    rm -f "$same"
    PRIMARY_FF_MSG="primary checkout is $behind commit(s) behind $upname and cannot fast-forward: $err"
    return 1
  fi

  # Every file in the way already holds the incoming content: stage exactly
  # those, fast-forward to the commit that was checked, unstage on any refusal.
  while IFS= read -r -d '' f; do
    git --literal-pathspecs -C "$dir" add -- "$f" >/dev/null 2>&1
  done <"$same"
  if err="$(git -C "$dir" merge --ff-only -q "$up" 2>&1 >/dev/null)"; then
    printf 'primary checkout fast-forwarded %s commit(s) to %s past %s uncommitted file(s) that already held the incoming content: %s\n' \
      "$behind" "$upname" "$n" "$(tr '\0\n' '  ' <"$same" | cut -c1-400)" >&2
    rm -f "$same"
    return 0
  fi
  while IFS= read -r -d '' f; do
    git --literal-pathspecs -C "$dir" reset -q -- "$f" >/dev/null 2>&1
  done <"$same"
  rm -f "$same"
  PRIMARY_FF_MSG="primary checkout is $behind commit(s) behind $upname and cannot fast-forward: $(printf '%s' "$err" | tr '\t\n' '  ' | cut -c1-400)"
  return 1
}
