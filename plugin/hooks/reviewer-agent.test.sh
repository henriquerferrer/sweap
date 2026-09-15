#!/usr/bin/env bash
#
# reviewer-agent.test.sh — the review-loop rules that live in prose (reviewer.md
# and the playbook's step 3) and have no other pre-merge check. Consumer A DV.9
# (2026-09-07): one reviewer re-messaged five times produced seven rounds and
# ~600k tokens, the last three rounds about comment wording; the CI reviewer
# approved the PR on its first pass. The remedy is on the reviewer side, and
# this pins it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWER="$HERE/../agents/reviewer.md"
PLAYBOOK="$HERE/../playbook/agentic-loop-playbook.md"
pass=0; fail=0
ok() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"; else fail=$((fail+1)); printf '  FAIL  %s\n' "$desc"; fi; }
echo "reviewer-agent.test.sh:"
ok "reviewer has an Advisory section for non-blocking remarks"   grep -qF '### Advisory' "$REVIEWER"
ok "Advisory never flips the verdict"                           grep -qF 'Advisory never flips the verdict' "$REVIEWER"
ok "a re-messaged reviewer answers only closure, no new class"  grep -qF 'do not open a new' "$REVIEWER"
ok "the verdict line is still the last line"                    grep -qF 'it must be the last line' "$REVIEWER"
ok "playbook: a re-review is a NEW dispatch"                    grep -qF 'A re-review is a NEW' "$PLAYBOOK"
ok "playbook records the DV.9 measurement"                      grep -qF 'consumer A DV.9, 2026-09-07' "$PLAYBOOK"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
