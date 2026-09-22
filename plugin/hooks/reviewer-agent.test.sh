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
# The Run core is what an item driver reads and nothing else up front, and the
# worker brief inside it is dispatched BY REFERENCE to its two markers. A
# restructure that drops a marker, or pushes the core past where a short read
# reaches, fails silently everywhere but here.
core_end="$(grep -n -m1 '^<!-- run-core:end -->' "$PLAYBOOK" | cut -d: -f1)"
ok "playbook: the Run core is the first section"                [ "$(grep -n -m1 '^## ' "$PLAYBOOK" | cut -d: -f2-)" = "## Run core (read this; the rest is reference)" ]
ok "playbook: the Run core ends within the first 210 lines"     [ -n "$core_end" ] && [ "$core_end" -le 210 ]
ok "playbook: the worker brief has both markers, in order"      [ "$(grep -c '^<!-- worker-brief:\(begin\|end\) -->' "$PLAYBOOK")" = 2 ] && [ "$(grep -n -m1 'worker-brief:begin' "$PLAYBOOK" | cut -d: -f1)" -lt "$(grep -n -m1 'worker-brief:end' "$PLAYBOOK" | cut -d: -f1)" ]
ok "playbook: the brief sits inside the core"                   [ "$(grep -n -m1 'worker-brief:end' "$PLAYBOOK" | cut -d: -f1)" -lt "${core_end:-0}" ]
brief="$(sed -n '/worker-brief:begin/,/worker-brief:end/p' "$PLAYBOOK")"
ok "brief: no full e2e suite locally — CI is the gate"          grep -qF 'Do NOT run the full e2e suite' <<<"$brief"
ok "brief: never edit a test to make it pass"                   grep -qF 'Never edit' <<<"$brief"
ok "core: fixes stay local until every reviewer approves"       grep -qF 'keep fixes local' "$PLAYBOOK"
ok "core: the run-end record's four keys are inline"            grep -qF 'why_not_agent: [<id>=identity|money|terms|taste|authority, ...]' "$PLAYBOOK"
ok "the Hard rules heading survives (agents navigate to it)"    grep -q '^## Hard rules for unattended runs$' "$PLAYBOOK"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
