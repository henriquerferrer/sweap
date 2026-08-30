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

# --- bin/: the model's entry points -------------------------------------------
# Claude Code adds <plugin-root>/bin to the Bash tool's PATH for every enabled
# plugin, so these are the bare commands a session types and a project
# allowlists (`Bash(sweap-merge:*)`). A wrapper that is not executable, or that
# points at a file that moved, is a silently dead command — and the last time a
# model-facing launch line was dead (the `${CLAUDE_PLUGIN_ROOT}` expansion) it
# cost a whole run before anyone noticed.
ok "bin/ exists" test -d "$ROOT/bin"
for w in sweap-merge sweap-roadmap-lint sweap-stranded sweap-note; do
  ok "bin/$w is present" test -f "$ROOT/bin/$w"
done
b=0
for w in "$ROOT"/bin/*; do
  [ -f "$w" ] || continue
  b=$((b+1))
  ok "bin/$(basename "$w") is executable" test -x "$w"
  # every wrapper ends in `exec <runner> "$root/<relative path>" "$@"`
  t="$(sed -n 's#^exec .*"\$root/\([^"]*\)".*#\1#p' "$w" | head -1)"
  ok "bin/$(basename "$w") names a target" test -n "$t"
  ok "bin/$(basename "$w") target exists: $t" test -f "$ROOT/$t"
  # the whole reason bin/ exists: that variable is UNSET in a model-issued call,
  # so no wrapper may depend on it (naming it in a comment is the explanation)
  ok "bin/$(basename "$w") does not depend on \$CLAUDE_PLUGIN_ROOT" \
    test "$(grep -v '^[[:space:]]*#' "$w" | grep -c 'CLAUDE_PLUGIN_ROOT')" -eq 0
done
ok "every declared bin wrapper was checked" test "$b" -ge 4

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
