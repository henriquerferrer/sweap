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

mk fix/open >/dev/null
hook_from "$WORK/primary"
is "no merged PR -> the worktree is untouched"                       yes "$([ -d "$WORK/wt-fix_open" ] && echo yes || echo no)"
is "no merged PR -> the origin branch is untouched"                  yes "$(on_origin fix/open)"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
