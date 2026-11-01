#!/usr/bin/env bash
# Tests for no-private-names.sh. Hermetic: a throwaway repo and name list.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/no-private-names.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

names="$tmp/names"
echo 'secretproject' >"$names"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$repo" update-ref refs/remotes/origin/main HEAD

run() { # run <list> <command>
  jq -n --arg c "$2" '{tool_input:{command:$c}}' |
    CLAUDE_PROJECT_DIR="$repo" SWEAP_PRIVATE_NAMES="$1" bash "$hook" 2>/dev/null
  echo $?
}
check() { # check <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL $1: wanted $2, got $3"
  fi
}

check 'an unrelated command is ignored' 0 "$(run "$names" 'ls secretproject')"
check 'a clean PR passes' 0 "$(run "$names" 'gh pr create --title ok --body fine')"
check 'an inline PR body is denied' 2 "$(run "$names" 'gh pr create --title ok --body "from SecretProject"')"

echo 'ported from secretproject' >"$tmp/body.md"
check 'a body file is denied' 2 "$(run "$names" "gh pr create --title ok --body-file $tmp/body.md")"

check 'a push with clean commits passes' 0 "$(run "$names" 'git push origin HEAD')"
echo 'text' >"$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m 'fix for secretproject'
check 'a commit message on push is denied' 2 "$(run "$names" 'git push origin HEAD')"
git -C "$repo" update-ref refs/remotes/origin/main HEAD

echo 'secretproject' >"$repo/b.txt"
git -C "$repo" add b.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m clean
check 'a diff on push is denied' 2 "$(run "$names" 'git push origin HEAD')"

check 'a missing list fails closed' 2 "$(run "$tmp/nope" 'git push origin HEAD')"
: >"$tmp/empty"
check 'an empty list fails closed' 2 "$(run "$tmp/empty" 'gh pr create --title ok')"

echo "no-private-names: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
