#!/usr/bin/env bash
#
# stop-failure-notify.test.sh — deterministic, OFFLINE tests for the StopFailure
# hook. osascript is stubbed on PATH; the decision table is: no run file →
# silent; run already ended → silent; active run → one `stalled:` line and a
# notification; garbage input → still exit 0 and still record the stall.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/stop-failure-notify.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$3" "$2"; fi; }
has()  { if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s (missing %s in: %s)\n' "$1" "$3" "$2"; fi; }

echo "stop-failure-notify.test.sh:"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/osascript" <<'OSA'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OSA_LOG:?}"
OSA
chmod +x "$BIN/osascript"
cat > "$BIN/claude" <<'CL'
#!/usr/bin/env bash
[ "$1" = "--version" ] && printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:?}"
CL
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"
export OSA_LOG="$WORK/osa.log"
export FAKE_CLAUDE_VERSION=2.1.270

R="$WORK/repo"; mkdir -p "$R/.claude"
# The shape a real StopFailure carries (captured on Claude Code 2.1.295): the
# type is `error`, the text `last_assistant_message`. This fixture used to send
# `error_type` + `error`, the shape the hook read and the harness never sent,
# so the suite was green while every real line said "unknown".
payload() { printf '{"session_id":"s1","hook_event_name":"StopFailure","cwd":"%s","error":"%s","last_assistant_message":"%s"}' "$R" "$1" "$2"; }
old_payload() { printf '{"session_id":"s1","hook_event_name":"StopFailure","cwd":"%s","error_type":"%s","error":"%s"}' "$R" "$1" "$2"; }

# 1. No run file: nothing happens.
: > "$OSA_LOG"
out="$(payload server_error "500 Internal server error" | bash "$HOOK" 2>&1)"; rc=$?
ok "no run file => exit 0" 0 "$rc"
ok "no run file => silent" "" "$out"
ok "no run file => no notification" 0 "$(wc -l < "$OSA_LOG" | tr -d ' ')"
ok "no run file => none created" "absent" "$([ -e "$R/.claude/sweap-run.md" ] && echo present || echo absent)"

# 2. Active run: one stalled line, one notification, message on stderr.
: > "$OSA_LOG"
printf 'milestone: F12\nstarted: 2026-09-08T00:48:00Z\n' > "$R/.claude/sweap-run.md"
out="$(payload server_error "500 Internal server error" | bash "$HOOK" 2>&1)"; rc=$?
ok "active run => exit 0" 0 "$rc"
ok "active run => one stalled line appended" 1 "$(grep -c '^stalled:' "$R/.claude/sweap-run.md")"
has "the line names the error type" "$(cat "$R/.claude/sweap-run.md")" "stalled: .* server_error"
has "the line carries the error text" "$(cat "$R/.claude/sweap-run.md")" "500 Internal server error"
has "the line says the run is not over" "$(cat "$R/.claude/sweap-run.md")" "the run is not over"
has "on >= 2.1.269 the line says the harness retries first" "$(cat "$R/.claude/sweap-run.md")" "retries this on its own"
has "on >= 2.1.269 the line names the installed version" "$(cat "$R/.claude/sweap-run.md")" "Claude Code 2.1.270"
ok "the original run lines are untouched" "milestone: F12" "$(head -1 "$R/.claude/sweap-run.md")"
ok "active run => one notification" 1 "$(wc -l < "$OSA_LOG" | tr -d ' ')"
has "notification names the repo and the subject" "$(cat "$OSA_LOG")" "title \"repo: run paused by an API error\""
has "notification names the error type" "$(cat "$OSA_LOG")" "Error: server_error."
has "stderr tells the human when to look" "$out" "if no turn follows within ~25 min"
has "stderr names the error type, not unknown" "$out" "on server_error"

# 2b. The older documented shape (`error_type` + `error`) still reads right.
printf 'milestone: F12\nstarted: 2026-09-08T00:48:00Z\n' > "$R/.claude/sweap-run.md"
old_payload rate_limit "429 Too many requests" | bash "$HOOK" >/dev/null 2>&1
has "older shape: the line names the error type" "$(cat "$R/.claude/sweap-run.md")" "stalled: .* rate_limit"
has "older shape: the line carries the error text" "$(cat "$R/.claude/sweap-run.md")" "429 Too many requests"
has "the notification says the harness is retrying" "$(cat "$OSA_LOG")" "It retries by itself"

# 3. A second stall appends a second line (append-only, never rewrites).
out="$(payload overloaded "529 overloaded" | bash "$HOOK" 2>&1)"
ok "second stall => two stalled lines" 2 "$(grep -c '^stalled:' "$R/.claude/sweap-run.md")"
has "second line names its own type" "$(tail -1 "$R/.claude/sweap-run.md")" "overloaded"

# 3b. Below 2.1.269 nothing retries: the line says so and asks for a message now.
: > "$OSA_LOG"
printf 'milestone: F12\n' > "$R/.claude/sweap-run.md"
out="$(FAKE_CLAUDE_VERSION=2.1.263 payload server_error "500" | FAKE_CLAUDE_VERSION=2.1.263 bash "$HOOK" 2>&1)"
has "on 2.1.263 the line says nothing retries" "$(cat "$R/.claude/sweap-run.md")" "nothing retries this on Claude Code 2.1.263"
has "on 2.1.263 the notification asks to resume" "$(cat "$OSA_LOG")" "Nothing retries it. Open the session and send any message to resume."
ok "on 2.1.263 no false promise of a retry" 0 "$(grep -c 'retries this on its own' "$R/.claude/sweap-run.md")"

# 3c. Unreadable version: treated as old (tell the human to look, never that the harness will).
printf 'milestone: F12\n' > "$R/.claude/sweap-run.md"
out="$(PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" OSA_LOG="$OSA_LOG" payload server_error "500" | PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" bash "$HOOK" 2>&1)"
has "no claude on PATH => told to continue now" "$(cat "$R/.claude/sweap-run.md")" "of unknown version"

# 4. Run already ended: silent, no append.
: > "$OSA_LOG"
printf 'milestone: F12\nended: 2026-09-13T01:41:00Z\nreason: goal-met\n' > "$R/.claude/sweap-run.md"
out="$(payload server_error "500" | bash "$HOOK" 2>&1)"; rc=$?
ok "ended run => exit 0" 0 "$rc"
ok "ended run => no stalled line" 0 "$(grep -c '^stalled:' "$R/.claude/sweap-run.md")"
ok "ended run => no notification" 0 "$(wc -l < "$OSA_LOG" | tr -d ' ')"

# 5. Garbage on stdin with an active run in $PWD: still exit 0, still records.
printf 'milestone: F12\n' > "$R/.claude/sweap-run.md"
out="$(cd "$R" && printf 'not json' | bash "$HOOK" 2>&1)"; rc=$?
ok "garbage input => exit 0" 0 "$rc"
ok "garbage input => stall still recorded from \$PWD" 1 "$(grep -c '^stalled:' "$R/.claude/sweap-run.md")"
has "garbage input => type falls back to unknown" "$(cat "$R/.claude/sweap-run.md")" "stalled: .* unknown"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
