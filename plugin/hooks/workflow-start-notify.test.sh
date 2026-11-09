#!/usr/bin/env bash
#
# workflow-start-notify.test.sh — the "audit started" notification.
# osascript is stubbed on PATH. The table: the audit workflow, under either
# name and either args shape => one notification naming the repo and the
# milestone; any other workflow or tool => none; always exit 0 and silent.
#
# Run:  bash plugin/hooks/workflow-start-notify.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/workflow-start-notify.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${OSA_LOG:?}"\n' > "$BIN/osascript"
chmod +x "$BIN/osascript"
export PATH="$BIN:$PATH"
export OSA_LOG="$WORK/osa.log"
R="$WORK/shop"; mkdir -p "$R"; git -C "$R" init -q

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s (wanted %s, got %s)\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s (missing %s in: %s)\n' "$1" "$3" "$2"; fi; }
fire() { : > "$OSA_LOG"; OUT="$(printf '%s' "$1" | bash "$HOOK" 2>&1)"; RC=$?; N="$(wc -l < "$OSA_LOG" | tr -d ' ')"; }

echo "workflow-start-notify.test.sh:"

fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"name\":\"sweap:milestone-audit-workflow\",\"args\":{\"milestone\":\"F14\"}},\"cwd\":\"$R\"}"
ok "audit launch => exit 0" 0 "$RC"
ok "audit launch => silent" "" "$OUT"
ok "audit launch => one notification" 1 "$N"
has "the title names the repo and the milestone" "$(cat "$OSA_LOG")" 'title "shop: F14 audit started"'
has "the body says another note follows" "$(cat "$OSA_LOG")" "You get another note when the milestone is complete."

fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"name\":\"sweap:milestone-audit\",\"args\":\"F13\"},\"cwd\":\"$R\"}"
has "a bare-id args string still names the milestone" "$(cat "$OSA_LOG")" 'title "shop: F13 audit started"'

fire '{"tool_name":"Workflow","tool_input":{"name":"sweap:milestone-audit-workflow","args":"{\"milestone\":\"F12\"}"},"cwd":"'"$R"'"}'
has "a JSON-string args still names the milestone" "$(cat "$OSA_LOG")" 'title "shop: F12 audit started"'

fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"name\":\"milestone-audit-workflow\",\"args\":{\"milestone\":\"F11\"}},\"cwd\":\"$R\"}"
has "the bare workflow name => notifies" "$(cat "$OSA_LOG")" 'title "shop: F11 audit started"'

fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"name\":\"milestone-audit\"},\"cwd\":\"$R\"}"
has "no milestone given => still says an audit started" "$(cat "$OSA_LOG")" 'title "shop: audit started"'

fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"name\":\"sweap:run\",\"args\":{\"ids\":[],\"milestone\":\"F14\"}},\"cwd\":\"$R\"}"
ok "the run workflow => no notification" 0 "$N"
fire "{\"tool_name\":\"Workflow\",\"tool_input\":{\"script\":\"export const meta = {}\"},\"cwd\":\"$R\"}"
ok "an inline workflow => no notification" 0 "$N"
fire "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo sweap:milestone-audit\"},\"cwd\":\"$R\"}"
ok "another tool => no notification" 0 "$N"
fire "not json"
ok "garbage input => exit 0" 0 "$RC"
ok "garbage input => no notification" 0 "$N"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
