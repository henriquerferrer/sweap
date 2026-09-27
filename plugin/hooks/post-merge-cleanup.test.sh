#!/usr/bin/env bash
#
# post-merge-cleanup.test.sh — the hook filters ITSELF to a merge.
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

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
