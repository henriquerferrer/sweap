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
# sm_post_merge). A full --check is 7 s idle on consumer A and ~3-4x that on a Mac
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
# and mandatory, so it earns the same durable marker as a real alarm — under a
# distinct name, with a distinct message, at exit 0. A reminder that blocks
# nothing, and that the next session still sees.
#
# rc=0 (a clean run) is required: on a watchdog kill `out` is partial, and a
# timed-out backstop raises no alarm — but it SAYS it timed out (one stderr
# line, exit 0), because a silent backstop is indistinguishable from a clean one.
if [ "$rc" = "143" ]; then
  printf 'post-merge-auditcheck: audit-gate.sh --check did not finish within %ss (the machine is loaded?) — nothing verified; run it yourself: bash %s --check\n' "$TIMEOUT" "$GATE" >&2
  exit 0
fi
if [ "$rc" = "0" ]; then
  deferred="$(printf '%s\n' "$out" | grep '^DEFERRED:' || true)"
  [ -n "$deferred" ] || exit 0
  due="$(printf '%s\n' "$deferred" | sed -n 's/^DEFERRED: milestone \([^ ]*\) .*/\1/p' | tr '\n' ' ')"
  marker_dir="$primary/.claude"
  if mkdir -p "$marker_dir" 2>/dev/null; then
    {
      printf 'AUDIT DUE on main after merge at %s\n' "$(git -C "$primary" rev-parse --short HEAD 2>/dev/null)"
      printf 'detected at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
      printf 'merge command: %s\n\n' "$cmd"
      printf 'This merge COMPLETED milestone(s): %s\n' "$due"
      printf 'The audit could not run before it (an audit reads the MERGED default\n'
      printf 'branch). It can now, and it must: the gate will deny every\n'
      printf 'backlog-advancing PR until each record lands and validates.\n\n'
      printf 'Run /milestone-audit for each, land the record + triage follow-ups,\n'
      printf 'then delete this marker.\n'
    } > "$marker_dir/audit-due-$(git -C "$primary" rev-parse --short HEAD 2>/dev/null || echo unknown).flag" 2>/dev/null || true
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

# Durable marker, same idiom (and same gitignored location) as
# post-merge-redcheck.sh's main-red flag. A banner is delivered once, to one
# session, which may compact it away or simply be the last session of the day —
# and "nobody noticed for three days" is the failure mode this whole change
# exists to end. The marker is state: the next session sees it in .claude/.
marker_dir="$primary/.claude"
if mkdir -p "$marker_dir" 2>/dev/null; then
  {
    printf 'AUDIT DEBT ON MAIN after merge at %s\n' "$(git -C "$primary" rev-parse --short HEAD 2>/dev/null)"
    printf 'detected at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    printf 'merge command: %s\n\n' "$cmd"
    printf '%s\n\n' "$fails"
    printf 'Remediation: fix the audit record through the gate BEFORE advancing the\n'
    printf 'backlog. Re-run: bash %s --check\n' "$GATE"
    printf 'Delete this marker once --check is clean.\n'
  } > "$marker_dir/audit-debt-$(git -C "$primary" rev-parse --short HEAD 2>/dev/null || echo unknown).flag" 2>/dev/null || true
fi

if command -v osascript >/dev/null 2>&1; then
  osascript -e 'display notification "A merge just landed on top of undischarged audit debt" with title "sweap: audit gate"' >/dev/null 2>&1 || true
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
  printf '## /agentic-loop-init to install it and make it a required check.\n'
  printf '################################################################\n'
} >&2
exit 2
