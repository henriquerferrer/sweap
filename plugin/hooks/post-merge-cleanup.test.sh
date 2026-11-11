#!/usr/bin/env bash
#
# post-merge-cleanup.test.sh — the hook filters ITSELF to a merge, and a merged
# PR's origin branch is deleted even when its worktree has to stay.
#
# The registration's `if: Bash(gh pr merge:*)` did not hold on compound commands:
# in one consumer run 314 of 315 firings were on commands with no merge in them,
# each spending 8-13s in gh.
#
# Run:  bash plugin/hooks/post-merge-cleanup.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/post-merge-cleanup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo"
( cd "$WORK/repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

pass=0; fail=0
# The observable is whether execution gets PAST the filter: the first statement
# after it is `command -v gh`, read off an xtrace. (Counting gh calls does not
# work in a fixture — with no remote the hook returns before it ever needs gh.)
past_filter() { # past_filter <stdin-payload> ; echoes 1 if the filter let it through
  ( cd "$WORK/repo" && printf '%s' "$1" | bash -x "$HOOK" 2>&1 >/dev/null | grep -c '^+ command -v gh' )
}
run() { past_filter "$(jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
check() { # check <desc> <want: zero|some> <times past the filter>
  if { [ "$2" = zero ] && [ "$3" = 0 ]; } || { [ "$2" = some ] && [ "$3" -gt 0 ]; }; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail+1)); printf '  FAIL  %s (past the filter: %s, wanted %s)\n' "$1" "$3" "$2"
  fi
}

check "a CI wait loop is not a merge -> stops at the filter"   zero "$(run 'until gh run view 123 --json status -q .status | grep -q completed; do sleep 5; done')"
check "a cd && chain is not a merge -> stops at the filter"    zero "$(run 'cd /tmp && ls -la && git status')"
check "a bare gh pr merge -> the hook runs"                 some "$(run 'gh pr merge 42 --squash')"
check "a merge inside a compound command -> the hook runs"  some "$(run 'cd /tmp && gh pr merge 42 --squash')"
check "an unreadable payload keeps the old behaviour: run"  some "$(past_filter 'not json')"

# --- the origin branch of a merged PR goes even when its worktree stays ---------
# The driver runs this hook from the PR's own worktree; the worktree is skipped
# (it is the live cwd) and the remote delete used to be skipped with it: in one
# consumer run 11 of 11 merged branches stayed on origin.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
# stub: `gh pr list --head <br> --state merged ...` prints the merged head sha
br=""; merged=0
while [ $# -gt 0 ]; do
  case "$1" in --head) br="$2"; shift ;; merged) merged=1 ;; esac
  shift
done
[ "$merged" = 1 ] && [ -n "$br" ] && cat "$GH_DIR/$(printf '%s' "$br" | tr / _)" 2>/dev/null
exit 0
GH
chmod +x "$WORK/bin/gh"
export GH_DIR="$WORK/gh"; mkdir -p "$GH_DIR"
G() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/primary" 2>/dev/null
( cd "$WORK/primary" && G commit -q --allow-empty -m init && git branch -M main && git push -q -u origin main ) 2>/dev/null
mk() { # mk <branch> : a pushed worktree branch; echoes its head sha
  ( cd "$WORK/primary" && git worktree add -q "$WORK/wt-$(printf '%s' "$1" | tr / _)" -b "$1" 2>/dev/null \
    && cd "$WORK/wt-$(printf '%s' "$1" | tr / _)" && G commit -q --allow-empty -m work && git push -q origin "$1" 2>/dev/null && git rev-parse HEAD )
}
merged_pr() { printf '%s\n' "$2" >"$GH_DIR/$(printf '%s' "$1" | tr / _)"; }
hook_from() { ( cd "$1" && jq -cn '{tool_name:"Bash",tool_input:{command:"gh pr merge 42 --squash"}}' | PATH="$WORK/bin:$PATH" bash "$HOOK" >/dev/null 2>&1 ); }
on_origin() { git -C "$WORK/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null 2>&1 && echo yes || echo no; }
is() { # is <desc> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$3" "$2"; fi
}

merged_pr fix/own "$(mk fix/own)"
hook_from "$WORK/wt-fix_own"
is "run from the PR's own worktree -> the worktree stays"            yes "$([ -d "$WORK/wt-fix_own" ] && echo yes || echo no)"
is "run from the PR's own worktree -> its origin branch is deleted"  no  "$(on_origin fix/own)"

merged_pr fix/other "$(mk fix/other)"
hook_from "$WORK/primary"
is "run from elsewhere -> the merged worktree is removed"            no  "$([ -d "$WORK/wt-fix_other" ] && echo yes || echo no)"
is "run from elsewhere -> its local branch is deleted"               no  "$(git -C "$WORK/primary" rev-parse -q --verify refs/heads/fix/other >/dev/null && echo yes || echo no)"
is "run from elsewhere -> its origin branch is deleted"              no  "$(on_origin fix/other)"

merged_pr fix/reused "$(mk fix/reused)"
( cd "$WORK/wt-fix_reused" && G commit -q --allow-empty -m "new work after the merge" && git push -q origin fix/reused ) 2>/dev/null
hook_from "$WORK/wt-fix_reused"
is "origin moved past the merged head -> the origin branch is kept"  yes "$(on_origin fix/reused)"

merged_pr fix/again "$(mk fix/again)"
( cd "$WORK/wt-fix_again" && G commit -q --allow-empty -m "unpushed work on a reused name" ) 2>/dev/null
hook_from "$WORK/primary"
is "a reused name with unpushed commits -> the worktree is kept"      yes "$([ -d "$WORK/wt-fix_again" ] && echo yes || echo no)"
is "a reused name with unpushed commits -> the local branch is kept"  yes "$(git -C "$WORK/primary" rev-parse -q --verify refs/heads/fix/again >/dev/null && echo yes || echo no)"

mk fix/open >/dev/null
hook_from "$WORK/primary"
is "no merged PR -> the worktree is untouched"                       yes "$([ -d "$WORK/wt-fix_open" ] && echo yes || echo no)"
is "no merged PR -> the origin branch is untouched"                  yes "$(on_origin fix/open)"

# --- the primary does not stay behind over a file that already holds the pull ---
# git refuses a fast-forward when an uncommitted tracked file is among the
# incoming paths, identical bytes or not. The scaffold's managed-file sync plus
# its adoption PR is exactly that, and the refusal used to be discarded: a
# consumer's primary sat 21 commits behind for a whole run (2026-11-09), the
# frontier read from it went stale, and the run reported drained with an item
# left. primary_ff fast-forwards past files that already hold the incoming
# content WITHOUT WRITING THE WORKING TREE (it stages them, and unstages on a
# refusal), and hands the session one line when something else is in the way.
P="$WORK/primary"
git clone -q "$WORK/origin.git" "$WORK/other" 2>/dev/null
upstream() { # upstream <file> <content> [<file> <content> ...] : one commit on origin/main made elsewhere
  ( cd "$WORK/other" && git pull -q --ff-only origin main 2>/dev/null
    while [ $# -gt 1 ]; do mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; git add "$1"; shift 2; done
    G commit -q -m upstream && git push -q origin HEAD:main ) 2>/dev/null
}
hook() { ( cd "$P" && jq -cn '{tool_name:"Bash",tool_input:{command:"gh pr merge 42 --squash"}}' | PATH="$WORK/bin:$PATH" bash "$HOOK" 2>"$WORK/hook.err" >"$WORK/hook.out" ); }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' "$WORK/hook.out" 2>/dev/null; }
has() { grep -q -- "$1" && echo yes || echo no; }
behind() { git -C "$P" fetch -q origin 2>/dev/null; git -C "$P" rev-list --count HEAD..origin/main; }
tree() { git -C "$P" status --short --untracked-files=no | tr -s '\n' ' ' | sed 's/ $//'; }   # e.g. " M note.md"
staged() { git -C "$P" diff --cached --quiet && echo no || echo yes; }

upstream ctl.yml v1 other.yml v1 "it em.md" todo note.md n1
( cd "$P" && git pull -q --ff-only ) 2>/dev/null
is "fixture: the primary starts current"                              0 "$(behind)"

upstream ctl.yml v2 "it em.md" "done"
printf 'v2\n' >"$P/ctl.yml"; printf 'n1\nmine\n' >"$P/note.md"
is "fixture: plain git refuses the pull over the identical file"      refused "$(git -C "$P" pull -q --ff-only >/dev/null 2>&1 && echo pulled || echo refused)"
hook
is "identical file in the way -> the primary is current afterwards"   0 "$(behind)"
is "identical file in the way -> the backlog on disk is the base's"   "done" "$(cat "$P/it em.md")"
is "identical file in the way -> only the unrelated edit is left, nothing staged" " M note.md|no" "$(tree)|$(staged)"
is "identical file in the way -> stderr says which file it went past" yes "$(has 'fast-forwarded 1 commit(s) to origin/main past 1 uncommitted file(s) that already held the incoming content: ctl.yml' <"$WORK/hook.err")"
is "identical file in the way -> nothing to tell the session"         "" "$(ctx)"

upstream ctl.yml v3 other.yml v2
printf 'v3\n' >"$P/ctl.yml"; printf 'local\n' >"$P/other.yml"
head_before="$(git -C "$P" rev-parse HEAD)"
hook
is "a differing file also in the way -> the primary does not move"    "$head_before" "$(git -C "$P" rev-parse HEAD)"
is "a differing file also in the way -> both files are as they were, nothing staged" "v3|local|no" "$(cat "$P/ctl.yml")|$(cat "$P/other.yml")|$(staged)"
is "a differing file also in the way -> the session is told which one" yes "$(ctx | has 'primary checkout is 1 commit(s) behind origin/main and cannot fast-forward: uncommitted other.yml there differ(s) from the incoming copy. Nothing was touched')"
git -C "$P" checkout -q HEAD -- other.yml
hook
is "once the differing file is gone -> the next merge heals it"       "0| M note.md" "$(behind)|$(tree)"

upstream ctl.yml v4 new.sh fresh
printf 'v4\n' >"$P/ctl.yml"; printf 'fresh\n' >"$P/new.sh"
head_before="$(git -C "$P" rev-parse HEAD)"
hook
is "an untracked file where the pull creates one -> git still refuses; the staging is undone" "$head_before|v4|no" "$(git -C "$P" rev-parse HEAD)|$(cat "$P/ctl.yml")|$(staged)"
is "an untracked file where the pull creates one -> the session gets git's reason" yes "$(ctx | has 'cannot fast-forward: .*untracked working tree files would be overwritten.*new.sh')"
rm -f "$P/new.sh"; hook
is "fixture: current again"                                           0 "$(behind)"

# Someone's staged work: the index is theirs. (The first version of the heal
# compared the working tree and then ran `git checkout HEAD -- f`, which
# overwrote a staged edit.)
upstream ctl.yml v5
printf 'HUMAN\n' >"$P/ctl.yml"; git -C "$P" add ctl.yml; printf 'v5\n' >"$P/ctl.yml"
hook
is "staged work on the file -> index and working tree are untouched"   "HUMAN|v5|1" "$(git -C "$P" show :ctl.yml)|$(cat "$P/ctl.yml")|$(behind)"
is "staged work on the file -> the session is told why"               yes "$(ctx | has 'staged changes or an unfinished operation there, left alone')"
git -C "$P" reset -q -- ctl.yml; hook
is "fixture: current again once nothing is staged"                    0 "$(behind)"

# An uncommitted merge with no conflicts has MERGE_HEAD and a staged index.
upstream ctl.yml v6
git -C "$P" fetch -q origin
( cd "$P" && G merge -q --no-commit --no-ff origin/main ) >/dev/null 2>&1
before="$(git -C "$P" status --porcelain=v2 --branch | grep -v '^# branch.ab')"
hook
is "an uncommitted merge -> nothing changes"                          "$before|yes" "$(git -C "$P" status --porcelain=v2 --branch | grep -v '^# branch.ab')|$([ -f "$P/.git/MERGE_HEAD" ] && echo yes || echo no)"
is "an uncommitted merge -> the session is told it is in progress"    yes "$(ctx | has 'MERGE_HEAD in progress')"
git -C "$P" merge --abort; hook
is "fixture: current again after the merge is aborted"                0 "$(behind)"

# An operation that owns the checkout with nothing staged (a bisect).
upstream ctl.yml v6b
printf 'v6b\n' >"$P/ctl.yml"; git -C "$P" bisect start >/dev/null 2>&1
hook
is "a bisect under way -> left alone, and the session is told"         "1|v6b|yes" "$(behind)|$(cat "$P/ctl.yml")|$(ctx | has 'BISECT_LOG in progress')"
git -C "$P" bisect reset >/dev/null 2>&1; hook
is "fixture: current again after the bisect ends"                      0 "$(behind)"

# A clean filter can make two different files hash alike. The working tree is
# never written, so the bytes git would not have kept are still there.
upstream ctl.yml v7
git -C "$P" config filter.strip.clean 'grep -v SECRET'; printf 'ctl.yml filter=strip\n' >"$P/.git/info/attributes"
printf 'v7\nSECRET local\n' >"$P/ctl.yml"
hook
is "a lossy clean filter -> current, and the local bytes are still on disk" "0|v7 SECRET local" "$(behind)|$(tr '\n' ' ' <"$P/ctl.yml" | sed 's/ $//')"
rm -f "$P/.git/info/attributes"; git -C "$P" config --unset filter.strip.clean; git -C "$P" checkout -q HEAD -- ctl.yml

upstream ctl.yml v8
printf 'v8\n' >"$P/ctl.yml"; chmod +x "$P/ctl.yml"
hook
is "same bytes, different mode -> git refuses; file, mode and index as they were" "1|v8|x|no" "$(behind)|$(cat "$P/ctl.yml")|$([ -x "$P/ctl.yml" ] && echo x || echo -)|$(staged)"
chmod -x "$P/ctl.yml"; hook
is "fixture: current again once the mode matches"                     0 "$(behind)"

upstream ctl.yml v9
printf 'v9\n' >"$P/ctl.yml"
( cd "$P" && G commit -q --allow-empty -m "a local commit: diverged" )
hook
is "a diverged primary -> untouched, and nothing is said (not this problem)" "v9|no|" "$(cat "$P/ctl.yml")|$(staged)|$(ctx)"
( cd "$P" && git reset -q --soft HEAD~1 ); hook
is "fixture: current again after the divergence is undone"            0 "$(behind)"

# More than 100 modified files is not a managed-file collision: no per-file scan.
i=0; set --; while [ "$i" -lt 101 ]; do set -- "$@" "many/f$i" a; i=$((i + 1)); done
upstream "$@"; hook
i=0; set --; while [ "$i" -lt 101 ]; do set -- "$@" "many/f$i" b; printf 'b\n' >"$P/many/f$i"; i=$((i + 1)); done
upstream "$@"; hook
is "over 100 modified files (101 identical + the note) -> left alone, reported by count" "1|yes|no" "$(behind)|$(ctx | has '(102 modified files there, left alone)')|$(staged)"
git -C "$P" checkout -q HEAD -- many; hook
git -C "$P" checkout -q HEAD -- note.md
is "fixture: current and clean at the end"                            "0|" "$(behind)|$(tree)"

# --- backlog files on a branch nothing will land, and on a PARKED work branch ----
# A no-PR branch is stranded: the hook says so and gives the rescue. The SAME
# branch checked out in a linked worktree is an item's unfinished work: the hook
# must not call it dead, but it still names the note, because the branch can be
# deleted by hand with the note on it.
( cd "$P" && git worktree add -q "$WORK/wt-park" -b feat/park main 2>/dev/null \
  && cd "$WORK/wt-park" && mkdir -p roadmap/discovered && printf -- '---\ntitle: n\nkind: gap\n---\n' > roadmap/discovered/n-0a1b2c.md \
  && printf -- '---\nid: F9.1\nstatus: todo\n---\n' > roadmap/F9.1.md && git add -A && G commit -q -m wip ) 2>/dev/null
hook
is "parked branch -> named as PARKED with its note, never as dead"   "yes|yes|no|no" "$(ctx | has 'PARKED work branch')|$(ctx | has 'feat/park (0d): roadmap/discovered/n-0a1b2c.md$')|$(ctx | has 'STRANDED')|$(ctx | has 'delete the dead branch')"
is "parked branch -> the item file on it is not listed (work in progress)" no "$(ctx | has 'roadmap/F9.1.md')"
is "parked branch -> the rescue recipe is still given"                yes "$(ctx | has 'rescue the notes first: git checkout -b roadmap/rescue-')"
git -C "$P" worktree remove --force "$WORK/wt-park" 2>/dev/null
hook
is "the same branch with its worktree gone -> STRANDED, with the rescue" "yes|yes|no" "$(ctx | has 'STRANDED on branch')|$(ctx | has 'feat/park (no PR, 0d): roadmap/')|$(ctx | has 'PARKED')"
( cd "$P" && git worktree add -q "$WORK/wt-wip" -b feat/wip main 2>/dev/null \
  && cd "$WORK/wt-wip" && mkdir -p roadmap && printf -- '---\nid: F9.2\nstatus: todo\n---\n' > roadmap/F9.2.md && git add -A && G commit -q -m wip ) 2>/dev/null
git -C "$P" branch -q -D feat/park 2>/dev/null
hook
is "a parked branch with no note on it -> the hook says nothing about it" "no|no" "$(ctx | has 'feat/wip')|$(ctx | has 'PARKED')"
git -C "$P" worktree remove --force "$WORK/wt-wip" 2>/dev/null; git -C "$P" branch -q -D feat/wip 2>/dev/null

# The hook must still work beside an older or partial install with no lib.
mkdir -p "$WORK/nolib"; cp "$HOOK" "$HERE/lib-merge-parse.sh" "$WORK/nolib/"
[ -f "$HERE/stranded-roadmap.sh" ] && cp "$HERE/stranded-roadmap.sh" "$WORK/nolib/"
upstream ctl.yml v10
( cd "$P" && jq -cn '{tool_name:"Bash",tool_input:{command:"gh pr merge 42 --squash"}}' | PATH="$WORK/bin:$PATH" bash "$WORK/nolib/post-merge-cleanup.sh" >/dev/null 2>&1 )
is "without lib-primary-ff.sh beside it -> the plain pull still runs"  0 "$(behind)"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
