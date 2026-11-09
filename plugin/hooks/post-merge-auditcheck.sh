#!/usr/bin/env bash
#
# post-merge-auditcheck.sh — backstop for the audit gate's ONE structural blind
# spot.
#
# Wired as a PostToolUse(Bash) hook (see hooks/hooks.json). Fires on every Bash call
# and self-filters to `gh pr merge`, exactly like post-merge-redcheck.sh — this
# is that hook's sibling: redcheck asks "did we break main?", this asks "did we
# just merge undischarged audit debt?".
#
# WHY THIS EXISTS: audit-gate.sh's merge mode (--files) detects debt discharge at
# PATH level only — it cannot validate the record, because the record being
# discharged is not merged yet and so is not in the local checkout. That was
# always documented as safe on the grounds that "record validity is re-checked at
# the next --check". On 2026-08-11 a consumer repo proved the deferral hollow:
# a prose-only, frontmatter-less record merged (PR #122), nothing ever ran a
# --check, and three PRs later a whole new milestone was authored on top of the
# debt. Nobody noticed for days.
#
# The CI audit-gate job (templates/.github/workflows/audit-gate.yml) is the
# PRIMARY fix — it validates the record on the PR itself, before it can merge.
# This hook is the local belt-and-suspenders for the window that matters most:
# a repo whose CI job is missing, not yet required, or skew-broken. It cannot
# prevent the bad merge, but it collapses time-to-detection from days to one PR.
#
# It NEVER commits, NEVER touches main's content, and never fails a run on its
# own bookkeeping. Exit 2 (loud) ONLY when real audit debt is confirmed on the
# merged mainline.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# Shared shell-aware `gh pr merge` detector/parser (see lib-merge-parse.sh).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-merge-parse.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-notify.sh" 2>/dev/null || true
declare -F sweap_notify >/dev/null 2>&1 || sweap_notify() { return 0; }
declare -F sweap_run_active >/dev/null 2>&1 || sweap_run_active() { return 1; }

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

declare -F parse_merge_command >/dev/null 2>&1 || exit 0
parse_merge_command "$cmd"
[ "$MC_MERGE_RELATED" = "1" ] || exit 0

if [ -n "$cwd" ]; then cd "$cwd" 2>/dev/null || true; fi

# Check the PRIMARY checkout, not a worktree: that is where main lives and where
# the merged record actually landed (same primary-derivation trick as the
# cleanup/redcheck hooks).
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
primary="$(cd "$(dirname "$gitdir")" 2>/dev/null && pwd)" || exit 0
[ -n "$primary" ] || exit 0

# Bring the primary current so we check the state that actually landed, not a
# stale main. Idempotent and best-effort — post-merge-cleanup.sh does the same
# pull, and the two must not depend on each other's ordering. If the pull fails
# (dirty tree, no network) we still check whatever main we have; a false quiet is
# acceptable here because CI is the primary control.
git -C "$primary" pull --ff-only >/dev/null 2>&1 || true

GATE="$(dirname "${BASH_SOURCE[0]}")/audit-gate.sh"
[ -f "$GATE" ] || exit 0

# Anchor legacy classification at the state BEFORE this merge.
#
# audit-gate's default anchor is origin/main, which asks "is this record already
# merged?" — and after a merge the answer is always yes, so a record that JUST
# landed would be classified as inherited-legacy and pass silently. That is this
# exact incident (a prose record merged by PR #122) sailing straight through the
# hook written to catch it. Verified: without this, the replay is silent.
#
# HEAD^ is the first parent of the tip, i.e. the mainline as it stood before the
# most recent merge. A record introduced BY that merge is not reachable from it
# and is judged strictly; a record genuinely inherited from an older sweap still
# is, and stays quiet. Using HEAD^ rather than a pre-pull snapshot is deliberate:
# post-merge-cleanup.sh pulls the same checkout concurrently, so any "capture
# HEAD before pulling" scheme races it. HEAD^ is a property of history, not of
# who pulled first.
#
# If HEAD has no parent (root commit) we leave the anchor at its default rather
# than judging everything strictly — a repo whose root commit is an audit record
# is degenerate, not an incident.
anchor="$(git -C "$primary" rev-parse --verify -q 'HEAD^{commit}^' 2>/dev/null)" || anchor=""
[ -n "$anchor" ] && export SWEAP_MAIN_REF="$anchor"

# Bounded: audit-gate's per-item `git log -S` pickaxe scales with roadmap size ×
# history, and this hook has a 30 s harness timeout (hooks.json; sweap-merge allows the same 30 s). A timed-out backstop must
# stay SILENT rather than fire a false alarm — CI remains the real control.
# 28 s, under the 30 s the merge driver allows a post-merge hook (sweap-merge.sh,
# sm_post_merge). A full --check is 7 s idle on a consumer repo and ~3-4x that on a Mac
# whose CI runners are busy, so 20 s went quiet under exactly the load that
# makes a backstop worth having (2026-09-23 memo).
TIMEOUT="${SWEAP_AUDITCHECK_TIMEOUT:-28}"
tmp="$(mktemp 2>/dev/null)" || exit 0
( cd "$primary" && bash "$GATE" --check ) >"$tmp" 2>&1 &
gpid=$!
( sleep "$TIMEOUT"; kill -TERM "$gpid" 2>/dev/null ) &
watcher=$!
wait "$gpid" 2>/dev/null
rc=$?
kill -TERM "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
out="$(cat "$tmp" 2>/dev/null)"
rm -f "$tmp"

# A merge that COMPLETED a milestone is the one case that is neither clean nor an
# alarm. The gate exempts it deliberately (audit-gate.sh, "the milestone
# boundary"): the audit is only legal against the merged mainline, so it could
# NOT have run before this merge. Alarming here would cry wolf on the normal
# happy path and contradict the pre-merge gate that just — correctly — allowed
# the merge. Two controls disagreeing is worse than either alone.
#
# But it must not go silent either. "F9 completed, nobody ran its audit, three
# PRs later a whole new milestone was authored on top" IS the 2026-08-11
# incident. This merge is precisely the moment the audit becomes both possible
# and mandatory, so it earns a distinct message at exit 0: a reminder that
# blocks nothing. What outlasts the session is not a file: the gate denies every
# backlog-advancing PR until the record lands and validates, a milestone run
# audits by itself, and the human gets a desktop notification. (This hook used
# to drop .claude/audit-due-<sha>.flag; nothing ever read it, and it outlived
# its audit as an untracked file agents kept offering to delete.)
#
# rc=0 (a clean run) is required: on a watchdog kill `out` is partial, and a
# timed-out backstop raises no alarm — but it SAYS it timed out (one stderr
# line, exit 0), because a silent backstop is indistinguishable from a clean one.
if [ "$rc" = "143" ]; then
  printf 'post-merge-auditcheck: audit-gate.sh --check did not finish within %ss (the machine is loaded?) — nothing verified; run it yourself: bash %s --check\n' "$TIMEOUT" "$GATE" >&2
  exit 0
fi
if [ "$rc" = "0" ]; then
  # COMPLETE: this merge ADDED an audit record and the whole check is clean, so
  # the record validates — the milestone is built AND audited. One message says
  # both (the human asked for "milestone and audit ran successfully"), with the
  # one number they want.
  # `defects` is the collapsed count when the record has one, else `confirmed`.
  for rec in $(git -C "$primary" diff --name-only --diff-filter=A 'HEAD^' HEAD 2>/dev/null | grep -E '(^|/)audits/[A-Za-z0-9._-]+\.md$' || true); do
    am="$(basename "$rec" .md)"
    n="$(sed -n 's/^defects: *\([0-9][0-9]*\).*/\1/p' "$primary/$rec" 2>/dev/null | head -1)"
    [ -n "$n" ] || n="$(sed -n 's/^confirmed: *\([0-9][0-9]*\).*/\1/p' "$primary/$rec" 2>/dev/null | head -1)"
    case "$n" in
      "") sweap_notify "$primary" "$am is complete" "Built and audited. Follow-ups, if any, are in the roadmap." ;;
      0)  sweap_notify "$primary" "$am is complete" "Built and audited. No problems found. Nothing to do." ;;
      1)  sweap_notify "$primary" "$am is complete" "Built and audited. 1 problem confirmed. Its follow-up is in the roadmap." ;;
      *)  sweap_notify "$primary" "$am is complete" "Built and audited. $n problems confirmed. The follow-ups are in the roadmap." ;;
    esac
  done
  deferred="$(printf '%s\n' "$out" | grep '^DEFERRED:' || true)"
  [ -n "$deferred" ] || exit 0
  due="$(printf '%s\n' "$deferred" | sed -n 's/^DEFERRED: milestone \([^ ]*\) .*/\1/p' | tr '\n' ' ')"
  # BUILT: the last item of a milestone just merged. A milestone run audits it
  # by itself when its workflow returns; outside a run the human starts it.
  due_trim="$(printf '%s' "$due" | sed 's/ *$//')"
  if sweap_run_active "$primary"; then
    sweap_notify "$primary" "$due_trim is built" "All its items are merged. The audit starts by itself."
  else
    sweap_notify "$primary" "$due_trim is built" "All its items are merged. Next step: /milestone-audit $due_trim"
  fi
  {
    printf '\n################################################################\n'
    printf '## AUDIT DUE — this merge completed milestone(s): %s\n' "$due"
    printf '## Not debt and not a failure: the audit reads the MERGED branch, so it\n'
    printf '## could not have run before now. It can now, and the gate will deny the\n'
    printf '## next backlog-advancing PR until its record lands.\n'
    printf '## Run /milestone-audit for each BEFORE authoring new backlog items.\n'
    printf '################################################################\n'
  } >&2
  exit 0
fi

# Only a clean, non-zero verdict alarms.
[ "$rc" = "1" ] || exit 0
fails="$(printf '%s\n' "$out" | grep '^FAIL:' || true)"
[ -n "$fails" ] || exit 0

# No marker file. This hook used to drop .claude/audit-debt-<sha>.flag so "the
# next session sees it", but nothing in sweap ever read it — the same finding
# that removed post-merge-redcheck.sh's main-red marker. What outlasts this
# session is the gate (CI and /milestone pre-flight run --check, and the merge
# gate denies backlog-advancing PRs) plus the desktop notification below.

# WHAT THE HUMAN IS TOLD. Two different things reach this point and they used to
# share one sentence ("A merge just landed on top of undischarged audit debt"),
# which read as damage in both and told the human nothing to do:
#   - NOT AUDITED YET: a milestone is built, its audit report has not landed,
#     and a PR the gate allowed merged meanwhile. Nothing is broken. While a
#     milestone run is active it audits by itself, so the human is told nothing;
#     outside a run the audit is theirs to start, so they are told that.
#   - REPORT INCOMPLETE: the audit report ON the default branch does not
#     validate (the 2026-08-11 incident this hook exists for), so the milestone
#     does not count as audited however the file looks.
# Both still alarm to the SESSION (exit 2); only the words differ.
due_ms="$(printf '%s\n' "$fails" | sed -nE 's/^FAIL: milestone ([A-Za-z0-9._-]+) is complete but has no audit record.*/\1/p' | tr '\n' ' ' | sed 's/ *$//')"
invalid="$(printf '%s\n' "$fails" | grep -v 'is complete but has no audit record' || true)"
if [ -z "$invalid" ] && [ -n "$due_ms" ]; then
  if ! sweap_run_active "$primary"; then
    sweap_notify "$primary" "$due_ms is not audited yet" "$due_ms is built but its audit has not run. Next step: /milestone-audit $due_ms"
  fi
else
  bad_recs="$(printf '%s\n' "$invalid" | sed -nE 's/^FAIL: record [^ ]*audits\/([A-Za-z0-9._-]+)\.md:.*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$bad_recs" ] || bad_recs="a milestone"
  sweap_notify "$primary" "$bad_recs audit report is incomplete" "The report that was merged is missing required parts, so $bad_recs does not count as audited. Run /milestone-audit $bad_recs again."
fi

if [ -z "$invalid" ] && [ -n "$due_ms" ]; then
  {
    printf '\n################################################################\n'
    printf '## AUDIT STILL DUE on the default branch — this merge landed before the audit of: %s\n' "$due_ms"
    printf '%s\n' "$fails" | sed 's/^/##   /'
    printf '##\n'
    printf '## Nothing this merge did is wrong: the gate allowed it. But the milestone\n'
    printf '## is complete and unaudited, and the gate denies every backlog-advancing\n'
    printf '## PR until its record lands. Run /milestone-audit for it BEFORE authoring\n'
    printf '## new backlog items. Re-check: bash %s --check\n' "$GATE"
    printf '################################################################\n'
  } >&2
  exit 2
fi

{
  printf '\n################################################################\n'
  printf '## AUDIT DEBT ON MAIN after this merge — audit-gate.sh --check fails:\n'
  printf '%s\n' "$fails" | sed 's/^/##   /'
  printf '##\n'
  printf '## The merge-time gate detects discharge by PATH, so a MALFORMED record\n'
  printf '## still counts as "the record landed". This is that miss, caught one PR\n'
  printf '## later instead of days later.\n'
  printf '## FIX THE RECORD FIRST, through the gate — do not author new backlog\n'
  printf '## items on top of this. Run: bash %s --check\n' "$GATE"
  printf '## If this repo has no audit-gate CI job, that is the real bug: run\n'
  printf '## /sweap:init to install it and make it a required check.\n'
  printf '################################################################\n'
} >&2
exit 2
