#!/usr/bin/env bash
#
# run-end-notify.sh — Stop hook: a milestone run just stopped because it is
# waiting on the human. Tell them which item, and the command that answers it.
#
# The human asked for this (2026-10-10): "Milestone stopped due to a blocked
# item FQ.14". The session already sends a push at the end of a run, but that
# is prose the model follows, and the harness drops it while the terminal is
# active. This is the desktop floor under it, raised from what the run RECORDED:
# `ended:` + `reason: awaiting-human` + `needs: [ids]` in the run file
# (`.claude/sweap-run.md`, kept on awaiting-human and deleted on every other
# reason — playbook "Ending the run"). A run that ended clean deletes the file,
# and its message is the audit's own ("<M> is complete").
#
# Once per recorded end: it appends `notified: <the ended value>` to the run
# file (gitignored; the board reads only the keys it knows) and stays quiet on
# every later Stop of the same end. Not a notification per blocked flip: most
# flips gate nothing, and that variant was refused (2026-09-28).
#
# A Stop hook's stdout is a decision channel. This one prints nothing, never
# blocks and always exits 0.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"
gitdir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
case "$gitdir" in
  "") primary="$cwd" ;;
  /*) primary="$(dirname "$gitdir")" ;;
  *)  primary="$(cd "$cwd" 2>/dev/null && cd "$(dirname "$gitdir")" 2>/dev/null && pwd)" ;;
esac
[ -n "${primary:-}" ] || exit 0
run_file="$primary/.claude/sweap-run.md"
[ -f "$run_file" ] || exit 0

last() { sed -n "s/^$1:[[:space:]]*//p" "$run_file" 2>/dev/null | tail -1 | sed 's/[[:space:]]*$//'; }
ended="$(last ended)"
[ -n "$ended" ] || exit 0
[ "$(last reason)" = "awaiting-human" ] || exit 0
if grep -qxF "notified: $ended" "$run_file" 2>/dev/null; then exit 0; fi

m="$(last milestone | tr -cd 'A-Za-z0-9._-')"
ids="$(last needs | tr -d '[]' | tr ',' ' ' | tr -cd 'A-Za-z0-9._ -' | tr -s ' ' | sed 's/^ //; s/ $//')"
backlog="$(sed -n 's/^backlog\.dir:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$primary/CLAUDE.md" 2>/dev/null | head -1)"
backlog="${backlog:-roadmap/}"; backlog="${backlog#./}"
case "$backlog" in */) : ;; *) backlog="$backlog/" ;; esac

# Each id's command comes from the item's CURRENT status, never from the record:
# a blocked item is answered with /sweap:unblock, an attended one with /sweap:handoff.
blocked=""; attended=""; other=""
for id in $ids; do
  st="$(sed -n 's/^status:[[:space:]]*\([a-z]*\).*/\1/p' "$primary/$backlog$id.md" 2>/dev/null | head -1)"
  case "$st" in
    blocked)  blocked="$blocked $id" ;;
    attended) attended="$attended $id" ;;
    *)        other="$other $id" ;;
  esac
done
blocked="${blocked# }"; attended="${attended# }"; other="${other# }"
first() { printf '%s' "$1" | cut -d' ' -f1; }
count() { printf '%s' "$1" | wc -w | tr -d ' '; }

if [ -n "$blocked" ] && [ -z "$attended$other" ]; then
  if [ "$(count "$blocked")" = 1 ]; then body="It needs your answer on $blocked. Next step: /sweap:unblock $blocked"
  else body="It needs your answer on $(count "$blocked") items: $blocked. Start with /sweap:unblock $(first "$blocked")"; fi
elif [ -n "$attended" ] && [ -z "$blocked$other" ]; then
  if [ "$(count "$attended")" = 1 ]; then body="$attended is a step only you can do. Next step: /sweap:handoff $attended"
  else body="$(count "$attended") steps only you can do: $attended. Start with /sweap:handoff $(first "$attended")"; fi
elif [ -n "$ids" ]; then
  body="It is waiting on you for: $ids. Next step: /sweap:board"
else
  body="It is waiting on you. Next step: /sweap:board"
fi

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-notify.sh" 2>/dev/null || exit 0
sweap_notify "$primary" "${m:+$m }run stopped" "$body"
printf 'notified: %s\n' "$ended" >> "$run_file" 2>/dev/null || true
exit 0
