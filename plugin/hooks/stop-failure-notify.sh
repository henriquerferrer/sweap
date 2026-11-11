#!/usr/bin/env bash
#
# stop-failure-notify.sh — StopFailure hook: the orchestrator's own turn just
# ended on an API error. Say so where the next reader will look.
#
# A consumer, 2026-09-09: a lane runner died on an API 500 at 23:31:50Z, its failure
# notification woke the orchestrator, and the orchestrator's own next turn ended
# on the same 500 two seconds later. Nothing re-drives a main session whose turn
# ended in an API error; it sat until a human typed "can you continue?" ten
# hours later. Claude Code does resume a usage-limit pause on its own, but not
# a server error. A StopFailure hook cannot re-enter the turn either — its
# output is discarded except for side effects — so this one does the two
# things that ARE possible: it writes a `stalled:` line into the run record
# (`.claude/sweap-run.md`, the file /sweap:milestone keeps for the duration of a run)
# so the human and the resuming session both see when and on what the run
# stopped, and it fires a desktop notification.
#
# Scope: fires only while a run is active (the run file exists and carries no
# `ended:` line). Outside a run an API error is the user's own session and
# not this hook's business. Never fails, never blocks (exit codes are ignored
# by this event anyway), never touches anything but the gitignored run file.
set -uo pipefail
input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"
run_file="$cwd/.claude/sweap-run.md"
[ -f "$run_file" ] || exit 0
if grep -qE '^ended:' "$run_file" 2>/dev/null; then exit 0; fi

# The event names the error TYPE `error` (and the text `error_details` /
# `last_assistant_message`) — witnessed on Claude Code 2.1.295 with a real
# StopFailure. This hook read `error_type`, which that payload does not carry,
# so every line said "unknown" with the type in the text slot. `error_type` is
# still read first for a harness that sends the older documented shape.
etype="$(printf '%s' "$input" | jq -r '.error_type // .error // "unknown"' 2>/dev/null || echo unknown)"
emsg="$(printf '%s' "$input" | jq -r 'if .error_type then (.error // .message // "") else (.error_details // .last_assistant_message // .message // "") end' 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# WHAT HAPPENS NEXT DEPENDS ON THE HARNESS VERSION, so say which. Claude Code
# 2.1.269 (2026-09-11): "Fixed /goal runs silently stalling after API errors,
# network drops, or token limits: the goal now retries with backoff, or pauses
# and says why". A consumer's stall was on 2.1.263. On >= 2.1.269 a /goal run
# retries this on its own and pauses only after the retries; the human is
# needed when it is still idle after that, or when the run is not /goal-driven.
# Below 2.1.269 nothing retries and the human is needed now. Version read from
# the installed binary at fire time; unreadable => treated as old (the honest
# side: it tells the human to look, never that the harness will handle it).
ver="$(claude --version 2>/dev/null | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)"
retries=no
if [ -n "$ver" ]; then
  retries="$(printf '%s\n' "$ver" | awk -F. '{ if ($1 > 2 || ($1 == 2 && ($2 > 1 || ($2 == 1 && $3 >= 269)))) print "yes"; else print "no" }')"
fi
if [ "$retries" = yes ]; then
  next="a /goal run retries this on its own with backoff (Claude Code $ver), then pauses and says why; if no turn follows within ~25 min, or this run is not /goal-driven, send any message to continue"
else
  next="nothing retries this on Claude Code ${ver:-of unknown version} (< 2.1.269); send any message to continue the run"
fi
# One line, append-only, same key on every occurrence so a run that stalls
# twice shows twice. Read by the human, and by the session that resumes
# (playbook "pick up cold").
printf 'stalled: %s %s — turn ended on an API error; the run is not over: %s (%s)\n' "$ts" "$etype" "$next" "$emsg" >> "$run_file" 2>/dev/null || true
printf 'sweap: run stalled at %s on %s — the orchestrator turn ended on an API error; %s.\n' "$ts" "$etype" "$next" >&2
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-notify.sh" 2>/dev/null || true
if declare -F sweap_notify >/dev/null 2>&1; then
  if [ "$retries" = yes ]; then
    sweap_notify "$cwd" "run paused by an API error" "Error: $etype. It retries by itself. Look only if nothing moves in 25 min."
  else
    sweap_notify "$cwd" "run stopped by an API error" "Error: $etype. Nothing retries it. Open the session and send any message to resume."
  fi
fi
exit 0
