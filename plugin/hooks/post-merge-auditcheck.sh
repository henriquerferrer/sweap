#!/usr/bin/env bash
#
# post-merge-auditcheck.sh — backstop for the audit gate's ONE structural blind
# spot.
#
# Wired as a PostToolUse(Bash) hook (see plugin.json). Fires on every Bash call
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
# history, and this hook has a 25 s harness timeout. A timed-out backstop must
# stay SILENT rather than fire a false alarm — CI remains the real control.
TIMEOUT="${SWEAP_AUDITCHECK_TIMEOUT:-20}"
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

# Only a clean, non-zero verdict alarms. STALE: lines are pre-format records
# inherited from an older sweap — reported by --check, non-blocking by design,
# and emphatically not a "you just merged debt" event.
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
