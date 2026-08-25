#!/usr/bin/env bash
# hooks-manifest.test.sh — the plugin's hooks are declared where Claude Code
# reads them (hooks/hooks.json), never inline in the manifest (silently ignored
# by the loader), and every declared command resolves to a file under hooks/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
pass=0; fail=0
ok() { local d="$1"; shift; if "$@"; then pass=$((pass+1)); printf '  PASS  %s\n' "$d"; else fail=$((fail+1)); printf '  FAIL  %s\n' "$d"; fi; }
echo "hooks-manifest.test.sh:"
ok "manifest lives at .claude-plugin/plugin.json" test -f "$ROOT/.claude-plugin/plugin.json"
ok "no manifest at the plugin root (it would shadow nothing and mislead)" test ! -e "$ROOT/plugin.json"
parses() { jq -e "$1" "$2" >/dev/null 2>&1; }
ok "manifest parses" parses . "$ROOT/.claude-plugin/plugin.json"
ok "manifest has no inline hooks key (the loader drops non-string entries silently)" test "$(jq -r 'has("hooks")' "$ROOT/.claude-plugin/plugin.json")" = "false"
ok "hooks/hooks.json exists and parses" parses .hooks "$ROOT/hooks/hooks.json"
ok "declares SessionStart, PreToolUse and PostToolUse" test "$(jq -r '.hooks | keys | join(",")' "$ROOT/hooks/hooks.json")" = "PostToolUse,PreToolUse,SessionStart"
n=0
while IFS= read -r cmd; do
  f="$(printf '%s' "$cmd" | sed -E 's#.*/(hooks/[^" ]+).*#\1#')"
  ok "command resolves: $f" test -x "$ROOT/$f"; n=$((n+1))
done < <(jq -r '.hooks[][] | .hooks[] | .command' "$ROOT/hooks/hooks.json")
ok "at least six hook commands declared" test "$n" -ge 6
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
