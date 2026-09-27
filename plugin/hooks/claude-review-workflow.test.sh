#!/usr/bin/env bash
#
# claude-review-workflow.test.sh — static invariants of the managed reviewer
# workflow, templates/.github/workflows/claude-review.yml.
#
# Why static: a PR that edits this workflow makes the reviewer action self-skip
# and the verdict gate stand down, so a change to this file is never exercised
# by its own PR — it ships blind and is proven by the NEXT PR in every consumer.
# These greps are the only pre-merge check the file gets. Each one pins a
# control that was added because its absence cost a run:
#
#   - --disallowedTools Agent/Task/ScheduleWakeup: consumer PR #310 (2026-09-11), the
#     reviewer fanned out into background agents and ended its turn to wait;
#     an Action never re-invokes, so the verdict was lost three times.
#   - the retry pass: the one re-invocation that first pass assumed it would
#     get; guarded so it runs only on a verdict-less first pass.
#   - GH_TOKEN step-scoped: at job level it reaches the reviewer's own `gh`
#     and the verdict posts as github-actions[bot], which the gate rejects.
#   - the first transcript moved aside: the action writes ONE fixed path, so
#     the retry would overwrite the transcript that explains the retry.
#
# Run:  bash plugin/hooks/claude-review-workflow.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YML="$HERE/../templates/.github/workflows/claude-review.yml"

pass=0; fail=0
ok() { # ok <desc> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else fail=$((fail+1)); printf '  FAIL  %s\n' "$desc"; fi
}
count() { grep -c -- "$1" "$YML"; }

echo "claude-review-workflow.test.sh:"

# The control: tools removed, not merely un-approved.
args=$(grep -E '^      CLAUDE_ARGS:' "$YML")
ok "claude_args is defined once at job level"          test "$(count '^      CLAUDE_ARGS:')" = 1
ok "claude_args disallows Agent"                       grep -qE -- '--disallowedTools "[^"]*\bAgent\b' <<< "$args"
ok "claude_args disallows Task (Agent's former name)"  grep -qE -- '--disallowedTools "[^"]*\bTask\b' <<< "$args"
ok "claude_args disallows ScheduleWakeup"              grep -qE -- '--disallowedTools "[^"]*\bScheduleWakeup\b' <<< "$args"
ok "claude_args still allow-lists the posting form"    grep -qF -- 'Bash(gh pr comment:*)' <<< "$args"
ok "both action steps take the SAME claude_args"       test "$(count 'claude_args: \${{ env.CLAUDE_ARGS }}')" = 2
ok "both action steps pin the same action sha"         test "$(count 'uses: anthropics/claude-code-action@558b1d6cab4085c7753fe402c10bef0fbb92ac7a')" = 2

# The prompt: one copy, one-turn rule, sent by both passes.
ok "the prompt is defined once at job level"           test "$(count '^      REVIEW_PROMPT:')" = 1
ok "the prompt states the one-turn rule"               grep -qF 'Do the ENTIRE review in this one turn' "$YML"
ok "the prompt carries the in-session reviewer's needs-work bar"  grep -qF 'any access-control gap, any weakened or skipped' "$YML"
ok "the prompt has an Advisory section that never flips the verdict" grep -qF '"### Advisory" heading' "$YML"
ok "the prompt asks for the Findings count line, penultimate"      grep -qF '"Findings: important=N nit=M"' "$YML"
ok "the prompt still makes the verdict the LAST line"              grep -qF 'the LAST line is the verdict' "$YML"
ok "both passes post inline comments live (no Haiku buffer)"       test "$(count "classify_inline_comments: 'false'")" = 2
ok "pull-requests is read (the App token posts, not GITHUB_TOKEN)" grep -qE '^  pull-requests: read$' "$YML"
ok "no actions: read (nothing in this file uses it)"               bash -c '! grep -qE "^  actions: read" "$1"' _ "$YML"
ok "a PR from another repository skips at job level"               grep -qF 'github.event.pull_request.head.repo.full_name == github.repository' "$YML"
ok "the transcript upload can never red the job"                   bash -c 'awk "/name: Upload reviewer transcript/{f=1} f&&/continue-on-error: true/{print;exit}" "$1" | grep -q continue' _ "$YML"
ok "the size notice records model and effort"                      grep -qF 'model=$model effort=$effort' "$YML"
ok "no node20 action pins remain (GitHub drops node20 2026-09-23)" bash -c '! grep -qE "checkout@34e11487|upload-artifact@ea165f8d" "$1"' _ "$YML"
ok "the verdict step records the diff size beside the verdict" grep -qF '::notice::review-size:' "$YML"
ok "the size notice is a diagnostic, not a gate"           bash -c '! grep -E "review-size" "$1" | grep -q "exit"' _ "$YML"
ok "the prompt says an Action never re-invokes"        grep -qF 'invokes you exactly once and never again' "$YML"
ok "the prompt still demands the Verdict line"         grep -qF '"Verdict: approve" or "Verdict: needs-work"' "$YML"
ok "the first pass sends the shared prompt"            grep -qF 'prompt: ${{ env.REVIEW_PROMPT }}' "$YML"
ok "the retry pass embeds the shared prompt"           grep -qF '            ${{ env.REVIEW_PROMPT }}' "$YML"
ok "the retry preamble says why it is running"         grep -qF 'ended WITHOUT' "$YML"

# The retry pass: guarded on a verdict-less first pass, and not on self-edits.
retry_if=$(awk '/id: retry$/{f=1} f && /^        if:/{print; exit}' "$YML")
ok "retry step exists"                                 test -n "$retry_if"
ok "retry runs only when the first pass posted nothing" grep -qF "steps.first.outputs.verdict == ''" <<< "$retry_if"
ok "retry skips a PR that edits this workflow"         grep -qF "steps.first.outputs.self_edit != 'true'" <<< "$retry_if"
ok "retry skips when there is no OAuth token"          grep -qF "steps.token.outputs.present == 'true'" <<< "$retry_if"
ok "first pass is continue-on-error (a crash can be rescued)" awk '/id: reviewer$/{f=1} f && /continue-on-error: true/{found=1} /id: first$/{exit} END{exit !found}' "$YML"
ok "retry pass is continue-on-error too (the gate is the control)" awk '/id: retry$/{f=1} f && /continue-on-error: true/{found=1} /Upload reviewer transcript/{exit} END{exit !found}' "$YML"
ok "exactly two action steps: one retry, never more"   test "$(count 'uses: anthropics/claude-code-action@')" = 2
ok "two passes fit the job timeout"                    awk '/timeout-minutes:/{split($0,a,":"); m=a[2]+0; exit !(m>=45)}' "$YML"

# The reader: every GitHub read is checked, so empty means "none posted".
ok "each API surface is read through the checked helper" test "$(count '^          read_surface "repos/')" = 3
ok "a failed API read fails closed, not empty"         grep -qF 'GitHub API read failed' "$YML"
ok "a crashed first pass gets its own warning"         grep -qF 'First pass FAILED' "$YML"

# Token scoping: GH_TOKEN only at step indent (10 spaces), never job indent (6).
ok "GH_TOKEN is never a job-level env"                 test "$(count '^      GH_TOKEN:')" = 0
ok "GH_TOKEN is step-scoped where gh runs"             test "$(count '^          GH_TOKEN:')" = 2

# Transcripts: the first pass's file survives the retry and is uploaded.
ok "first transcript is moved aside before the retry"  grep -qF 'mv "$RUNNER_TEMP/claude-execution-output.json" "$RUNNER_TEMP/claude-execution-output.pass1.json"' "$YML"
ok "upload carries the first-pass transcript"          grep -qF '${{ runner.temp }}/claude-execution-output.pass1.json' "$YML"
ok "upload carries the retry transcript"               grep -qF '${{ runner.temp }}/claude-execution-output.json' "$YML"
ok "upload runs on always()"                           awk '/Upload reviewer transcript/{f=1} f && /if: always\(\)/{found=1} /Enforce reviewer verdict/{exit} END{exit !found}' "$YML"

# The gate: one reader, re-read after the retry, rescue made visible.
ok "the verdict reader is written once"                test "$(count "cat > \"\$RUNNER_TEMP/read-verdict.sh\"")" = 1
ok "the reader is run by the first-pass check and the gate" test "$(count 'verdict=$(bash "$RUNNER_TEMP/read-verdict.sh") || exit 1')" = 2
ok "the jq program appears exactly once (the verdict test extracts it)" test "$(count 'jq -rs --arg who "$REVIEWER_LOGIN" --arg since "$head_ts"')" = 1
ok "a verdict from the retry pass is announced, not silent" grep -qF 'The verdict came from the RETRY pass' "$YML"
ok "the gate still fails closed on no verdict"         grep -qF 'after TWO passes' "$YML"
ok "the gate still fails on needs-work"                grep -qF 'Reviewer verdict is needs-work' "$YML"

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
