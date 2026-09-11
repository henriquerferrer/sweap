#!/usr/bin/env bash
#
# claude-review-verdict.test.sh — deterministic, offline tests for the verdict
# resolver embedded in templates/.github/workflows/claude-review.yml (the final
# job of the `review` check, which is what makes a green `review` mean "the
# reviewer approved").
#
# The jq program is EXTRACTED FROM the workflow file rather than copied here, so
# these cases test the text that actually ships (since 0.21.0 it lives inside
# the read-verdict.sh heredoc the workflow writes; the extraction keys on the
# `jq -rs ... --arg since "$head_ts" '` opening line and the closing `'`). Fixtures stand in for the three
# GitHub API reads (issue comments, review bodies, inline review comments), each
# an object of {t: timestamp, u: author login, ty: user.type, b: body}.
#
# Run:  bash plugin/hooks/claude-review-verdict.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YML="$HERE/../templates/.github/workflows/claude-review.yml"

PROG=$(awk '
  /jq -rs .*--arg since/ { inprog=1; sub(/.*--arg since "\$head_ts" \x27/, ""); }
  inprog {
    if ($0 ~ /\x27$/ && !/--arg since/) { sub(/\x27$/, ""); print; exit }
    print
  }
' "$YML")

if [ -z "$PROG" ]; then
  echo "FAIL: could not extract the jq verdict program from $YML"
  echo "      (did the '| jq -rs --arg since \"\$head_ts\"' line change shape?)"
  exit 1
fi

HEAD_TS="2026-08-11T20:00:00Z"   # the PR head commit
AFTER="2026-08-11T20:05:00Z"     # a comment from this run
BEFORE="2026-08-11T19:00:00Z"    # a comment from a previous push

WHO="claude[bot]"                # the reviewer login the gate expects (default)

pass=0; fail=0
check() { # check <desc> <expected-verdict-line> <fixture lines on stdin>
  local desc="$1" want="$2" got
  got=$(cat | jq -rs --arg who "$WHO" --arg since "$HEAD_TS" "$PROG")
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail+1)); printf '  FAIL  %s\n        expected [%s]\n        got      [%s]\n' "$desc" "$want" "$got"
  fi
}
check_as() { local WHO="$1"; shift; check "$@"; } # check_as <login> <desc> <expected>
fx() { jq -c -n --arg t "$1" --arg u "$2" --arg b "$3" --arg ty "${4:-Bot}" '{t:$t,u:$u,ty:$ty,b:$b}'; }

echo "claude-review-verdict.test.sh:"

# The 2026-08-11 incident that motivated the multi-surface read: the reviewer
# submitted a review with an EMPTY body plus one inline comment, and posted no
# issue comment. Nothing carries a verdict, so the gate must still fail closed.
check "incident: empty review body + verdictless inline comment -> no verdict" "" <<EOF
$(fx "$AFTER" "claude[bot]" "")
$(fx "$AFTER" "claude[bot]" "**Correctness: the ordering contradicts the rationale.**

Worth fixing before this is picked up.")
EOF

check "issue comment carries the verdict" "Verdict: approve" <<EOF
$(fx "$AFTER" "claude[bot]" "Reviewed the diff.

Verdict: approve")
EOF

# The surface the issue-comments-only read could not see.
check "review body carries the verdict" "Verdict: needs-work" <<EOF
$(fx "$AFTER" "claude[bot]" "Two findings inline.

Verdict: needs-work")
EOF

# The old substring match tested approve FIRST, so a quoted approve anywhere in
# the body outranked the real trailing needs-work.
check "quoted approve does not beat a trailing needs-work" "Verdict: needs-work" <<EOF
$(fx "$AFTER" "claude[bot]" "The gate greps for \"Verdict: approve\", which is the bug.

Verdict: needs-work")
EOF

# Widening the search widens what a stale approve can do — hence the head-commit
# freshness rule.
check "stale approve from a previous push is ignored" "" <<EOF
$(fx "$BEFORE" "claude[bot]" "Verdict: approve")
EOF

check "bolded verdict parses" "**Verdict: approve**" <<EOF
$(fx "$AFTER" "claude[bot]" "Looks good.

**Verdict: approve**")
EOF

check "newest verdict wins" "Verdict: approve" <<EOF
$(fx "2026-08-11T20:05:00Z" "claude[bot]" "Verdict: needs-work")
$(fx "2026-08-11T20:30:00Z" "claude[bot]" "Fixed.

Verdict: approve")
EOF

check "a human comment cannot drive the gate" "" <<EOF
$(fx "$AFTER" "some-human" "Verdict: approve" "User")
EOF

# Identity is exact login + user.type Bot: the old `test("claude"; "i")`
# substring match accepted any of the following.
check "human handle containing 'claude' cannot drive the gate" "" <<EOF
$(fx "$AFTER" "claudette-dev" "Verdict: approve" "User")
EOF

check "a different bot cannot drive the gate" "" <<EOF
$(fx "$AFTER" "claude-helper[bot]" "Verdict: approve" "Bot")
EOF

check "exact login but type User is rejected" "" <<EOF
$(fx "$AFTER" "claude[bot]" "Verdict: approve" "User")
EOF

# A projection regression (ty dropped) must fail closed, not crash.
check "missing type field is rejected, not fatal" "" <<EOF
$(jq -c -n --arg t "$AFTER" '{t:$t,u:"claude[bot]",b:"Verdict: approve"}')
EOF

# CLAUDE_REVIEWER_LOGIN override (custom github_token app).
check_as "acme-reviewer[bot]" "override login is honored" "Verdict: approve" <<EOF
$(fx "$AFTER" "acme-reviewer[bot]" "Verdict: approve")
EOF

check_as "acme-reviewer[bot]" "default login is rejected under an override" "" <<EOF
$(fx "$AFTER" "claude[bot]" "Verdict: approve")
EOF

check "CRLF body + trailing blank lines parse" "Verdict: approve" <<EOF
$(fx "$AFTER" "claude[bot]" "$(printf 'Summary.\r\nVerdict: approve\r\n\r\n')")
EOF

# A pending review has submitted_at: null.
check "null timestamp is skipped, not fatal" "" <<EOF
$(jq -c -n '{t:null,u:"claude[bot]",b:"Verdict: approve"}')
EOF

check "verdict must be the last line" "" <<EOF
$(fx "$AFTER" "claude[bot]" "Verdict: approve

But actually I want to reconsider.")
EOF

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
