#!/usr/bin/env bash
#
# post-merge-auditcheck.test.sh — the backstop that catches a malformed audit
# record ONE PR after it lands, for repos whose audit-gate CI job is missing.
#
# The load-bearing case is T2/T3: the hook must distinguish a record that JUST
# merged (strict — alarm) from one genuinely inherited from an older sweap
# (quiet). Anchoring that distinction at origin/main does NOT work, because after
# a merge every record is "already merged" — the first version of this hook was
# silent on the very incident it was written for. It anchors at HEAD^ instead.
#
# Run:  bash plugin/hooks/post-merge-auditcheck.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/post-merge-auditcheck.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
OUT=""; RC=0
run_hook() { # run_hook <repo> <command>
  local r="$1" cmd="$2"
  OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$r" \
        | bash "$HOOK" 2>&1)"
  RC=$?
}
check() { # check <desc> <wanted-rc>
  local desc="$1" want="$2"
  if [ "$RC" = "$want" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s (exit %s, wanted %s)\n%s\n' "$desc" "$RC" "$want" "$OUT"; fi
}

new_repo() {
  local r="$WORK/$1"
  mkdir -p "$r/roadmap/audits"
  git -C "$r" init -q
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  git -C "$r" commit -q --allow-empty -m init
  printf '%s\n' "$r"
}
mk_done_item() {
  printf -- '---\nid: %s\ntitle: %s\nstatus: done\ndepends_on: []\nreview-dimensions: []\n---\n' "$2" "$2" \
    > "$1/roadmap/$2.md"
}
commit_all() { git -C "$1" add -A; git -C "$1" commit -qm "${2:-c}"; }
anchor_main() { git -C "$1" update-ref refs/remotes/origin/main HEAD; }

echo "post-merge-auditcheck.test.sh:"

# T1: not a merge command => silent no-op, whatever the repo state.
R="$(new_repo t1)"
mk_done_item "$R" F9.1
commit_all "$R"
run_hook "$R" "ls -la"
check "non-merge command => silent no-op" 0

# T2: THE REGRESSION. A prose, frontmatter-less record merged by the PR we just
# ran (consumer A PR #122, 2026-08-11) must ALARM. Anchored at origin/main this is
# silent, because the record is trivially "already merged" the moment it lands.
R="$(new_repo t2)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 done"
anchor_main "$R"
printf '# F9 audit\n\nprose only, no frontmatter.\n' > "$R/roadmap/audits/F9.md"
commit_all "$R" "PR #122: F9 audit record"
anchor_main "$R"
run_hook "$R" "gh pr merge 122 --squash"
check "record malformed BY this merge => alarms" 2

# T3: the mirror image. A record inherited from an older sweap — already on the
# mainline before this merge — is pre-format debt, not something this merge did.
# It must stay quiet, or every merge in a migrating repo cries wolf forever.
R="$(new_repo t3)"
mk_done_item "$R" F9.1
printf '# F9 audit\n\nprose only, no frontmatter.\n' > "$R/roadmap/audits/F9.md"
commit_all "$R" "inherited pre-format record"
anchor_main "$R"
# PR #125 AUTHORED F10 — its items are todo, so F10 is not itself complete and
# contributes no debt of its own. The only question under test is F9's record.
printf -- '---\nid: F10.1\ntitle: x\nstatus: todo\ndepends_on: []\nreview-dimensions: []\n---\n' > "$R/roadmap/F10.1.md"
commit_all "$R" "PR #125: author F10"
anchor_main "$R"
run_hook "$R" "gh pr merge 125 --squash"
check "record inherited from an older sweap => stays quiet" 0

# T4: a complete milestone with NO record at all is unambiguous debt — no
# format-version subtlety involved, alarm regardless of when it landed.
R="$(new_repo t4)"
mk_done_item "$R" F9.1
commit_all "$R"
anchor_main "$R"
run_hook "$R" "gh pr merge 130 --squash"
check "complete milestone with no record => alarms" 2

# T5: a clean repo stays quiet (no false alarm on the happy path).
R="$(new_repo t5)"
mk_done_item "$R" F9.1
printf -- '---\nid: F9.2\ntitle: x\nstatus: todo\ndepends_on: []\nreview-dimensions: []\n---\n' > "$R/roadmap/F9.2.md"
commit_all "$R"
anchor_main "$R"
run_hook "$R" "gh pr merge 131 --squash"
check "incomplete milestone => no debt, quiet" 0

# T6: the alarm leaves a DURABLE marker in .claude/ (same idiom as
# post-merge-redcheck.sh). A banner reaches one session and can be compacted
# away; "nobody noticed for three days" is the failure this ends.
R="$(new_repo t6)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 done"
anchor_main "$R"
printf '# F9 audit\n\nprose only.\n' > "$R/roadmap/audits/F9.md"
commit_all "$R" "bad record"
anchor_main "$R"
run_hook "$R" "gh pr merge 122 --squash"
if ls "$R"/.claude/audit-debt-*.flag >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "alarm writes a durable .claude/ marker"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "alarm writes a durable .claude/ marker"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
