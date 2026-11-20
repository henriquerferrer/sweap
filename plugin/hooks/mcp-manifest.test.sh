#!/usr/bin/env bash
# mcp-manifest.test.sh — the plugin bundles the Mobbin MCP server where Claude
# Code reads it (.mcp.json at the plugin root), and the ui-critic agent's tool
# allowlist names the tools that server actually registers.
#
# A plugin-bundled server's tools are `mcp__plugin_<plugin>_<server>__<tool>`:
# the name is built from the manifest's `name` and the server's key in
# .mcp.json. The critic's `tools:` line is an allowlist, so renaming either one
# without it leaves the critic with no Mobbin tools and no error — it just
# reports "Mobbin unavailable" on every dispatch. A wrong URL fails the same
# quiet way, so the URL is pinned too.
#
# The allowlist also keeps the `mcp__mobbin__*` names: a session with its own
# server at the same URL keeps that one (Claude Code drops the bundled
# duplicate, matching on URL), and `mobbin` is the name the docs tell people to
# give it. A personal server under any other name is not covered.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
pass=0; fail=0
ok() { local d="$1"; shift; if "$@"; then pass=$((pass+1)); printf '  PASS  %s\n' "$d"; else fail=$((fail+1)); printf '  FAIL  %s\n' "$d"; fi; }
echo "mcp-manifest.test.sh:"
MCP="$ROOT/.mcp.json"; AGENT="$ROOT/agents/ui-critic.md"
parses() { jq -e "$1" "$2" >/dev/null 2>&1; }
ok ".mcp.json exists at the plugin root and parses" parses .mcpServers "$MCP"
ok "manifest has no inline mcpServers key (one place declares the servers)" test "$(jq -r 'has("mcpServers")' "$ROOT/.claude-plugin/plugin.json")" = "false"
ok "the only bundled server is mobbin" test "$(jq -r '.mcpServers | keys | join(",")' "$MCP")" = "mobbin"
ok "mobbin is a remote http server (nothing to install, sign-in is OAuth)" test "$(jq -r '.mcpServers.mobbin.type' "$MCP")" = "http"
ok "mobbin points at Mobbin's endpoint, exactly" test "$(jq -r '.mcpServers.mobbin.url' "$MCP")" = "https://api.mobbin.com/mcp"
# type and url only: no headers, env, helper or oauth block can carry a
# credential into a public repo, and the pinned url carries no query or userinfo
ok "the server entry is type and url, nothing else" test "$(jq -r '.mcpServers.mobbin | keys | join(",")' "$MCP")" = "type,url"

plugin="$(jq -r .name "$ROOT/.claude-plugin/plugin.json")"
# the allowlist is the frontmatter's `tools:` line, not any later line that
# happens to start the same way
fm="$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$AGENT")"
ok "ui-critic frontmatter has exactly one tools: line" test "$(printf '%s\n' "$fm" | grep -c '^tools: ')" -eq 1
ok "ui-critic frontmatter has no disallowedTools: line" test "$(printf '%s\n' "$fm" | grep -c '^disallowedTools:')" -eq 0
tools="$(printf '%s\n' "$fm" | sed -n 's/^tools: //p' | tr -d ' ' | tr ',' '\n')"
has_tool() { printf '%s\n' "$tools" | grep -qx "$1"; }
n=0
while IFS= read -r server; do
  for t in search_flows search_screens search_sections; do
    ok "ui-critic allows the bundled name mcp__plugin_${plugin}_${server}__$t" has_tool "mcp__plugin_${plugin}_${server}__$t"
    ok "ui-critic allows the session-server name mcp__${server}__$t" has_tool "mcp__${server}__$t"
    n=$((n+1))
  done
done < <(jq -r '.mcpServers | keys[]' "$MCP" 2>/dev/null)
ok "all three search tools were checked" test "$n" -eq 3
# the critic only searches: the six names above and no other Mobbin tool — none
# that writes to the account, none that reads its private collections
ok "ui-critic allows those six Mobbin tools and no other" test "$(printf '%s\n' "$tools" | grep -c -i 'mobbin')" -eq 6
# prose that names the bundled form must name the real one
ok "every bundled tool name written in agents/ and skills/ uses the real prefix" \
  test "$(grep -rhoE 'mcp__plugin_[A-Za-z0-9_-]+__' "$ROOT/agents" "$ROOT/skills" | sort -u | tr '\n' ',')" = "mcp__plugin_${plugin}_mobbin__,"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
