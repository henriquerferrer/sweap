#!/usr/bin/env bash
#
# run-end-notify.test.sh — the "run stopped, waiting on you" notification.
# osascript is stubbed on PATH. The table: no run file, a run still going, or a
# run that ended for any reason but awaiting-human => nothing; awaiting-human =>
# one notification naming the item and the command its CURRENT status calls
# for, once per recorded end; always silent, always exit 0.
#
# Run:  bash plugin/hooks/run-end-notify.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/run-end-notify.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${OSA_LOG:?}"\n' > "$BIN/osascript"
chmod +x "$BIN/osascript"
export PATH="$BIN:$PATH"
export OSA_LOG="$WORK/osa.log"
R="$WORK/shop"; mkdir -p "$R/.claude" "$R/roadmap"; git -C "$R" init -q
RUN="$R/.claude/sweap-run.md"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s (wanted %s, got %s)\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s (missing %s in: %s)\n' "$1" "$3" "$2"; fi; }
fire() { : > "$OSA_LOG"; OUT="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s"}' "$R" | bash "$HOOK" 2>&1)"; RC=$?; N="$(wc -l < "$OSA_LOG" | tr -d ' ')"; }
item() { printf -- '---\nid: %s\ntitle: x\nstatus: %s\n---\n' "$1" "$2" > "$R/roadmap/$1.md"; }
start() { printf -- '---\nmilestone: F14\nstarted: 2026-10-08T21:05:30Z\n---\n\n/goal ...\n' > "$RUN"; }

echo "run-end-notify.test.sh:"

fire
ok "no run file => exit 0" 0 "$RC"; ok "no run file => no notification" 0 "$N"

start; fire
ok "a run still going => no notification" 0 "$N"

start; printf 'ended: 2026-10-09T01:00:00Z\nreason: frontier-empty\n' >> "$RUN"; fire
ok "ended for another reason => no notification" 0 "$N"

# One blocked item: the user's own sentence.
start; item FQ.14 blocked
printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\nneeds: [FQ.14]\nwhy_not_agent: [FQ.14=taste]\n' >> "$RUN"; fire
ok "awaiting-human => exit 0" 0 "$RC"
ok "awaiting-human => silent (stdout is a decision channel)" "" "$OUT"
ok "awaiting-human => one notification" 1 "$N"
has "the title names the repo, the milestone and that the run stopped" "$(cat "$OSA_LOG")" 'title "shop: F14 run stopped"'
has "the body names the blocked item and its command" "$(cat "$OSA_LOG")" "It needs your answer on FQ.14. Next step: /sweap:unblock FQ.14"
has "the end is marked notified" "$(cat "$RUN")" "^notified: 2026-10-09T02:00:00Z$"
fire
ok "the same end again => no second notification" 0 "$N"

# A later end of the same run file notifies again.
printf 'ended: 2026-10-10T03:00:00Z\nreason: awaiting-human\nneeds: [FQ.14]\n' >> "$RUN"; fire
ok "a later end => notified again" 1 "$N"

# An attended item is a hand-off, not a question.
start; item F14.6 attended
printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\nneeds: [F14.6]\n' >> "$RUN"; fire
has "an attended item => /sweap:handoff" "$(cat "$OSA_LOG")" "F14.6 is a step only you can do. Next step: /sweap:handoff F14.6"

# Several blocked items: count, list, and where to start.
start; item FQ.14 blocked; item FQ.15 blocked
printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\nneeds: [FQ.14, FQ.15]\n' >> "$RUN"; fire
has "two blocked items => count and first command" "$(cat "$OSA_LOG")" "2 items: FQ.14 FQ.15. Start with /sweap:unblock FQ.14"

# Mixed, or an id whose status the hook cannot read: point at the board.
start; item FQ.14 blocked; item F14.6 attended
printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\nneeds: [FQ.14, F14.6]\n' >> "$RUN"; fire
has "mixed => the board" "$(cat "$OSA_LOG")" "waiting on you for: FQ.14 F14.6. Next step: /sweap:board"
start; printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\n' >> "$RUN"; fire
has "no ids recorded => still says it is waiting" "$(cat "$OSA_LOG")" "It is waiting on you. Next step: /sweap:board"

# The status is read from the item NOW: an id answered since is not sent to /sweap:unblock.
start; item FQ.14 todo
printf 'ended: 2026-10-09T02:00:00Z\nreason: awaiting-human\nneeds: [FQ.14]\n' >> "$RUN"; fire
has "an id no longer blocked => the board, never a stale command" "$(cat "$OSA_LOG")" "Next step: /sweap:board"

: > "$OSA_LOG"; OUT="$(printf 'not json' | (cd "$R" && bash "$HOOK") 2>&1)"; RC=$?
ok "garbage input => exit 0" 0 "$RC"; ok "garbage input => silent" "" "$OUT"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
