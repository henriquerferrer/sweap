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

# osascript is stubbed on PATH: the suite must not raise real notifications on
# the maintainer's desktop, and the wording is asserted below.
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${OSA_LOG:?}"\n' > "$BIN/osascript"
chmod +x "$BIN/osascript"
export PATH="$BIN:$PATH"
export OSA_LOG="$WORK/osa.log"; : > "$OSA_LOG"
check_note() { # check_note <desc> <grep-pattern> (asserts on the notifications raised since the last reset)
  if grep -q -- "$2" "$OSA_LOG"; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s (no match: %s)\n%s\n' "$1" "$2" "$(cat "$OSA_LOG")"; fi
}

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

check_out() { # check_out <desc> <grep-pattern> (asserts on last run's OUT)
  local desc="$1" pat="$2"
  if printf '%s\n' "$OUT" | grep -q "$pat"; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s (no match: %s)\n%s\n' "$desc" "$pat" "$OUT"; fi
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
# ran (consumer PR #122, 2026-08-11) must ALARM. Anchored at origin/main this is
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
check_note "incomplete report: the title names the repo, the milestone and what is wrong" "title \"t2: F9 audit report is incomplete\""
check_note "incomplete report: the body says what it means and what to do" "F9 does not count as audited. Run /sweap:milestone-audit F9 again."
check_out "invalid record: the banner is the debt banner" "AUDIT DEBT ON MAIN"

# T3: a pre-format record that was ALREADY on the mainline alarms too. There is no
# grandfathering any more — the exemption let any merged record's failure be
# downgraded by deleting one key — so this is debt, and the gate is already
# denying every backlog-advancing PR over it. Pre-adoption milestones belong in
# `audit.baseline`.
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
check "a pre-format record already on the mainline => alarms (no grandfathering)" 2

# T4: a complete milestone with no record, where THIS merge is what completed it.
# Not an alarm: the audit reads the MERGED branch, so it could not have run
# before now, and the pre-merge gate allowed this merge deliberately (audit-gate,
# "the milestone boundary"). It is a REMINDER — exit 0, distinct banner — because
# "milestone completed, nobody audited, a new milestone authored on top" is the
# 2026-08-11 incident itself. It leaves no file: nothing read the audit-due
# marker it used to write, and the gate is what outlasts the session.
R="$(new_repo t4)"
mk_done_item "$R" F9.1
commit_all "$R"
anchor_main "$R"
run_hook "$R" "gh pr merge 130 --squash"
check "merge that COMPLETES a milestone => reminder, not alarm" 0
check_out "reminder names the milestone" "AUDIT DUE — this merge completed milestone(s): F9"
check_out "reminder does not cry debt" "Not debt and not a failure"
if ls "$R/.claude"/audit-due-*.flag >/dev/null 2>&1; then
  fail=$((fail+1)); printf '  FAIL  %s\n' "reminder leaves no audit-due marker"
else
  pass=$((pass+1)); printf '  PASS  %s\n' "reminder leaves no audit-due marker"
fi
if ls "$R/.claude"/audit-debt-*.flag >/dev/null 2>&1; then
  fail=$((fail+1)); printf '  FAIL  %s\n' "reminder must NOT leave an alarm marker"
else
  pass=$((pass+1)); printf '  PASS  %s\n' "reminder must NOT leave an alarm marker"
fi

# T4b: the milestone was ALREADY complete before this merge and still has no
# record — real debt, and the exemption must not launder it. Alarm, exit 2.
# This is what T4 used to assert and what must survive the boundary change.
R="$(new_repo t4b)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 completes"
anchor_main "$R"
printf 'x\n' > "$R/src.ts"
commit_all "$R" "PR #131: unrelated code"
anchor_main "$R"
: > "$OSA_LOG"
run_hook "$R" "gh pr merge 131 --squash"
check "milestone complete BEFORE this merge, no record => alarms" 2
# The words for this case used to be the invalid-record ones ("landed on top of
# undischarged audit debt", "MALFORMED record"), which read as damage. The audit
# is due; nothing is broken.
check_note "not audited, no run: the title names the repo and the milestone" "title \"t4b: F9 is not audited yet\""
check_note "not audited, no run: the body gives the next step" "Next step: /sweap:milestone-audit F9"
check_out "audit due: the banner says still due, not malformed" "AUDIT STILL DUE"
if printf '%s\n' "$OUT" | grep -q "MALFORMED"; then fail=$((fail+1)); printf '  FAIL  %s\n' "audit due: the banner does not call the record malformed"
else pass=$((pass+1)); printf '  PASS  %s\n' "audit due: the banner does not call the record malformed"; fi

# T4c: the same state while a milestone run is active. The run audits its own
# milestone when its workflow returns, so telling the human to start the audit
# is wrong: the session still gets the banner, the human gets no notification.
R="$(new_repo t4c)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 completes"
anchor_main "$R"
printf 'x\n' > "$R/src.ts"
commit_all "$R" "PR #131: unrelated code"
anchor_main "$R"
mkdir -p "$R/.claude"; printf 'milestone: F9\nstarted: 2026-10-08T21:05:30Z\n' > "$R/.claude/sweap-run.md"
: > "$OSA_LOG"
run_hook "$R" "gh pr merge 131 --squash"
check "not audited, run active => the session is still told" 2
if [ -s "$OSA_LOG" ]; then fail=$((fail+1)); printf '  FAIL  %s\n%s\n' "not audited, run active => no notification (the run audits by itself)" "$(cat "$OSA_LOG")"
else pass=$((pass+1)); printf '  PASS  %s\n' "not audited, run active => no notification (the run audits by itself)"; fi
# An ENDED run is not an active one.
printf 'ended: 2026-10-09T00:00:00Z\nreason: awaiting-human\n' >> "$R/.claude/sweap-run.md"
run_hook "$R" "gh pr merge 131 --squash"
check_note "not audited, run ended => the human is told the next step" "Next step: /sweap:milestone-audit F9"

# T4d: BUILT. The merge that completes a milestone tells the human so, and says
# who starts the audit: the run when one is active, the human otherwise.
R="$(new_repo t4d)"
mk_done_item "$R" F9.1
commit_all "$R"
anchor_main "$R"
: > "$OSA_LOG"
run_hook "$R" "gh pr merge 130 --squash"
check_note "built, no run: the title says the milestone is built" "title \"t4d: F9 is built\""
check_note "built, no run: the body gives the next step" "Next step: /sweap:milestone-audit F9"
mkdir -p "$R/.claude"; printf 'milestone: F9\nstarted: 2026-10-08T21:05:30Z\n' > "$R/.claude/sweap-run.md"
: > "$OSA_LOG"
run_hook "$R" "gh pr merge 130 --squash"
check_note "built, run active: the body says the audit starts by itself" "The audit starts by itself."

# T4e: AUDIT FINISHED. The merge that adds a VALID audit record says so, with
# the count the record carries. An invalid one never reaches this message (T2).
R="$(new_repo t4e)"
base="$(git -C "$R" rev-parse HEAD)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 completes"
anchor_main "$R"
printf -- '---\nsweap_format: 1\nmilestone: F9\nrange_base: %s\nrange_head: %s\nlens_mode: default\nlenses: [correctness, authz]\nraw: 0\nrefuted: 0\nconfirmed: 0\nfinders_reporting: 6\nworkflow_run: wf_test\njournal_sha256: 0123abcd\n---\n\n# F9 audit\n' "$base" "$(git -C "$R" rev-parse HEAD)" > "$R/roadmap/audits/F9.md"
commit_all "$R" "PR #140: F9 audit record"
anchor_main "$R"
: > "$OSA_LOG"
run_hook "$R" "gh pr merge 140 --squash"
check "merge that adds a valid record => quiet for the session" 0
check_note "complete: the title says the milestone is complete" "title \"t4e: F9 is complete\""
check_note "complete, zero findings: built and audited, nothing needed" "Built and audited. No problems found. Nothing to do."

# T5: a clean repo stays quiet (no false alarm on the happy path).
: > "$OSA_LOG"
R="$(new_repo t5)"
mk_done_item "$R" F9.1
printf -- '---\nid: F9.2\ntitle: x\nstatus: todo\ndepends_on: []\nreview-dimensions: []\n---\n' > "$R/roadmap/F9.2.md"
commit_all "$R"
anchor_main "$R"
run_hook "$R" "gh pr merge 131 --squash"
check "incomplete milestone => no debt, quiet" 0
if [ -s "$OSA_LOG" ]; then fail=$((fail+1)); printf '  FAIL  %s\n' "an ordinary merge raises no notification"
else pass=$((pass+1)); printf '  PASS  %s\n' "an ordinary merge raises no notification"; fi

# T6: the alarm leaves NO marker in .claude/ (nothing read the audit-debt flag
# it used to write; post-merge-redcheck.sh dropped its marker for the same
# reason). The exit and banner are asserted too, or a hook that quit early would
# pass the absence check.
R="$(new_repo t6)"
mk_done_item "$R" F9.1
commit_all "$R" "F9 done"
anchor_main "$R"
printf '# F9 audit\n\nprose only.\n' > "$R/roadmap/audits/F9.md"
commit_all "$R" "bad record"
anchor_main "$R"
run_hook "$R" "gh pr merge 122 --squash"
check "malformed record on the mainline => alarm" 2
check_out "alarm banner" "AUDIT DEBT ON MAIN after this merge"
if ls "$R"/.claude/audit-debt-*.flag >/dev/null 2>&1; then
  fail=$((fail+1)); printf '  FAIL  %s\n' "alarm writes no .claude/ marker"
else
  pass=$((pass+1)); printf '  PASS  %s\n' "alarm writes no .claude/ marker"
fi


# T12: a --check that outruns the watchdog is not a silent backstop: one stderr
# line naming the timeout, exit 0 (never an alarm on partial output). The hook
# resolves the gate beside itself, so a copy of the hook next to a gate that
# sleeps is the fixture; the 1 s watchdog comes from SWEAP_AUDITCHECK_TIMEOUT.
SLOW="$WORK/slow"; mkdir -p "$SLOW"
cp "$HOOK" "$SLOW/post-merge-auditcheck.sh"
cp "$HERE/lib-merge-parse.sh" "$SLOW/"     # the hook sources its command parser beside itself
printf '#!/usr/bin/env bash\nsleep 5\nexit 0\n' > "$SLOW/audit-gate.sh"
R="$(new_repo t12)"
OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"},"cwd":"%s"}' "$R" \
      | SWEAP_AUDITCHECK_TIMEOUT=1 bash "$SLOW/post-merge-auditcheck.sh" 2>&1)"; RC=$?
check "T12: watchdog kill => exit 0, not an alarm" 0
check_out "T12: and it says the check did not finish" "did not finish within 1s"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
