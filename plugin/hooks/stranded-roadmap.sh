#!/usr/bin/env bash
#
# stranded-roadmap.sh — which branches carry <backlog.dir> changes that are NOT
# on main, and is anything scheduled to ever land them?
#
# The detector behind the playbook's stranded-backlog backstop. A backlog file
# committed on a feature branch (a discovered note, an idea, an item file that
# rode along) is durable only as long as that branch is headed for main. When
# the PR is closed unmerged, or there never was one, the file is invisible to
# every reader the pipeline has — the frontier, the board, audit-gate, /sweap:roadmap
# all read main — and nothing is scheduled to relay it. That is the one loss
# the 2026-08-22 research memo found sweap could not see: consumer PR #181 carried
# three filed items and an index retitle on a code branch, and the only guard
# was the session diff-verifying them by hand after every rebase.
#
# One implementation, three readers: post-merge-cleanup.sh (warns after every
# merge), the board (a section + a note), and the stop path (the playbook's
# End-of-run hygiene tells a session to run it before it abandons a branch).
# Read-only: fetches nothing, diffs only refs already local, never writes.
#
# Output: one line per not-merged branch whose <backlog.dir> differs from main —
#   <branch>\t<pr-state>\t<age-days>\t<path,path,...>
# pr-state: open (a rider on a live PR — fine until it isn't), closed (PR
# closed unmerged), none (no PR was ever opened), parked (no PR, but the branch
# is an open item's work in progress: see below), unknown (gh unavailable).
#
# PARKED is not stranded. A run leaves an item's work branch unpushed in its
# worktree while the item is reviewed, or blocked and waiting for an answer,
# and that branch differs from main under <backlog.dir> (a note the implementer
# filed, the item file's own notes). Reporting it as `none` told the session
# after every merge that "nothing will land" those files and to delete the
# branch, when the item's own PR lands them. A `none` branch is parked when it
# is checked out in a linked worktree, unless every existing top-level item
# file it changes already reads `status: done` or `dropped` on main (then the
# item closed some other way and the worktree is a leftover). Both are read
# from git and nothing else. Remove the worktree and the branch is `none` again.
# A parked branch can still be deleted by hand with its notes on it, so it is
# always LISTED with its paths and post-merge-cleanup still names its inbox
# files after every merge: the state changes what the reader is told (leave
# the branch, rescue before you delete), never whether they are told.
#
# Usage: stranded-roadmap.sh            (SWEAP_MAIN_REF overrides origin/main|main;
#                                         SWEAP_STRANDED_NO_GH=1 skips the PR lookup)
set -uo pipefail

BACKLOG_DIR="$(sed -n 's/^backlog\.dir:[[:space:]]*\([^[:space:]#]*\).*/\1/p' CLAUDE.md 2>/dev/null | head -1)"
BACKLOG_DIR="${BACKLOG_DIR:-roadmap/}"
case "$BACKLOG_DIR" in */) : ;; *) BACKLOG_DIR="$BACKLOG_DIR/" ;; esac
BACKLOG_DIR="${BACKLOG_DIR#./}"

MAIN="${SWEAP_MAIN_REF:-}"
if [ -z "$MAIN" ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then MAIN=origin/main
  elif git rev-parse --verify -q main >/dev/null 2>&1; then MAIN=main
  else echo "stranded-roadmap: no origin/main or main to compare against" >&2; exit 1; fi
fi
git rev-parse --verify -q "$MAIN" >/dev/null 2>&1 || { echo "stranded-roadmap: cannot resolve $MAIN" >&2; exit 1; }

have_gh=0
if [ "${SWEAP_STRANDED_NO_GH:-0}" != "1" ] && command -v gh >/dev/null 2>&1; then have_gh=1; fi
now="$(date +%s)"

# Branches checked out in a LINKED worktree (the first entry is the primary
# checkout, which is never an item's worktree). A `prunable` entry is a worktree
# whose directory is gone: nothing is parked there.
wt_branches="$(git worktree list --porcelain 2>/dev/null | awk '
  function flush() { if (n > 1 && b != "" && !gone) print b; b = ""; gone = 0 }
  /^worktree / { flush(); n++ }
  /^branch refs\/heads\// { b = $0; sub(/^branch refs\/heads\//, "", b) }
  /^prunable/ { gone = 1 }
  END { flush() }')"

# is_parked <branch> <comma-joined paths>: see PARKED in the header.
is_parked() {
  printf '%s\n' "$wt_branches" | grep -Fxq -- "$1" || return 1
  local p rest st items=0 closed=0
  local IFS=,
  set -f                                     # a path is data: `F?.md` must not glob
  for p in $2; do
    rest="${p#"$BACKLOG_DIR"}"
    case "$rest" in "$p"|*/*) continue ;; *.md) : ;; *) continue ;; esac
    st="$(git show "$MAIN:$p" 2>/dev/null | sed -n 's/^status:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)"
    if [ -z "$st" ]; then
      # Not at the top level on main. A dropped item lives in archive/; a file
      # that is nowhere on main is new on the branch and says nothing.
      git cat-file -e "$MAIN:${BACKLOG_DIR}archive/$rest" 2>/dev/null || continue
      st=dropped
    fi
    items=$((items+1))
    case "$st" in done|dropped) closed=$((closed+1)) ;; esac
  done
  set +f
  [ "$items" -gt 0 ] && [ "$items" -eq "$closed" ] && return 1
  return 0
}

# Candidates: every remote-tracking and local branch not merged into main.
# Remote first; a local branch whose name also exists on origin is the same
# branch (the worktree's checkout) and is reported once, under that name.
remote_names=""
candidates=""
while read -r ref date; do
  [ -n "$ref" ] || continue
  case "$ref" in
    refs/remotes/origin/HEAD|refs/remotes/origin/main|refs/heads/main) continue ;;
    refs/remotes/origin/*) name="${ref#refs/remotes/origin/}"; remote_names="$remote_names
$name" ;;
    refs/heads/*) name="${ref#refs/heads/}"
      printf '%s\n' "$remote_names" | grep -Fxq -- "$name" && continue ;;
    *) continue ;;
  esac
  candidates="$candidates
$name	$ref	$date"
done < <(git for-each-ref --no-merged="$MAIN" --format='%(refname) %(committerdate:unix)' refs/remotes/origin refs/heads 2>/dev/null | sort -k1,1r)
# (sorted descending so refs/remotes/* come before refs/heads/* — the dedupe
# above depends on remote names being known first)

printf '%s\n' "$candidates" | while IFS=$'\t' read -r name ref date; do
  [ -n "$name" ] || continue
  paths="$(git diff --name-only "$MAIN...$ref" -- "$BACKLOG_DIR" 2>/dev/null | paste -sd, -)"
  [ -n "$paths" ] || continue
  state=unknown
  if [ "$have_gh" = 1 ]; then
    s="$(gh pr list --head "$name" --state all --limit 1 --json state --jq '.[0].state // ""' 2>/dev/null)" && {
      case "$s" in
        MERGED) continue ;;          # squash-merged: content is on main, git just can't tell
        OPEN) state=open ;;
        CLOSED) state=closed ;;
        "") state=none ;;
        *) state=unknown ;;
      esac
    }
  fi
  if [ "$state" = none ] && is_parked "$name" "$paths"; then state=parked; fi
  age=0
  case "$date" in *[!0-9]*|"") : ;; *) age=$(( (now - date) / 86400 )); [ "$age" -lt 0 ] && age=0 ;; esac
  printf '%s\t%s\t%s\t%s\n' "$name" "$state" "$age" "$paths"
done
exit 0
