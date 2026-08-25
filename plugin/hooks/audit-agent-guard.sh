#!/usr/bin/env bash
#
# audit-agent-guard.sh — execution-time containment for the audit's sub-agents.
#
# Wired as a PreToolUse hook (see hooks/hooks.json). Hooks fire INSIDE subagents and
# the payload carries `agent_type`, so this can deny at the moment of the write
# rather than trusting that a toolset was applied correctly upstream.
#
# WHY THIS EXISTS, when agents/audit-reader.md already grants only Read/Grep/Glob:
# that `tools:` line is a definition-time restriction, and three things can make
# it not hold at run time — a botched edit that drops the line entirely (per
# Claude Code's docs, omitting `tools:` inherits EVERY tool and never errors), an
# agent definition that drifts in a plugin cache, or the dispatch resolving to
# something other than what the workflow named. Meanwhile workflow sub-agents run
# with file edits auto-approved and no human prompt behind them. This hook is the
# seccomp-shaped answer: verify at the syscall, not by asking the process what
# its filter says.
#
# It is deliberately NOT a self-report canary. A preflight that asks an agent to
# describe its own tools checks a probabilistic claim about a property the
# runtime already knows exactly, and it says nothing about the agent dispatched
# one second later (the agent files hot-reload mid-session).
#
# Two policies:
#   audit-reader — denies Write/Edit/NotebookEdit/Bash outright. It is the
#     finder/refuter tier; it has no legitimate reason to mutate or execute.
#   audit-prover — MAY write and run (that is its whole job), but only inside
#     the throwaway worktree it was given. Denies a Write/Edit whose file_path
#     is absolute and outside the session cwd, which is the one way the
#     "relative paths only" rule in its definition can be broken by accident.
#     Bash is NOT path-checked — a shell line cannot be parsed reliably enough
#     to be a security control, and pretending otherwise would be worse than
#     saying so. That residue is instruction-governed; see audit-prover.md.
#
# Invariants (same as the other hooks): only ever DENY or stay silent, never
# approve; always exit 0 and speak via stdout JSON; a missing/unknown agent_type
# is not our business (silence), because this hook governs the audit tier only
# and must never interfere with ordinary sessions.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
atype="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
[ -n "$tool" ] && [ -n "$atype" ] || exit 0

# Match bare and plugin-scoped forms alike (`audit-reader`, `sweap:audit-reader`)
# — the scoping of a plugin sub-agent's identifier is not something this hook
# should have an opinion about, and guessing wrong would silently disable it.
case "$atype" in
  *audit-reader) role=reader ;;
  *audit-prover) role=prover ;;
  *) exit 0 ;;
esac

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if [ "$role" = "reader" ]; then
  case "$tool" in
    Write|Edit|NotebookEdit|Bash)
      deny "audit-reader is the audit's READ-ONLY tier and may not use $tool. If this claim can only be settled by running something, return verdict 'unverifiable' and name the experiment — a later sandboxed stage runs it. (A refuter once wrote a test file into a human's checkout to settle a claim; this is why it cannot.)"
      ;;
  esac
  exit 0
fi

# --- prover: writes are fine, but only where it was put ------------------------
case "$tool" in
  Write|Edit|NotebookEdit) : ;;
  *) exit 0 ;;
esac
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
# A relative path is resolved against cwd by definition, so it is already inside.
case "$path" in
  ""|/*) : ;;
  *) exit 0 ;;
esac
[ -n "$path" ] || exit 0
if [ -z "$cwd" ]; then
  deny "audit-prover attempted an absolute-path $tool but the hook could not read the session's working directory to confirm it is inside the sandbox. Denying (fail closed) — use a path relative to your worktree."
fi
case "$path" in
  "$cwd"/*) exit 0 ;;
esac
deny "audit-prover may only write inside its own throwaway worktree ($cwd). Refusing an absolute write to '$path' — that is how audit residue ends up in a human's checkout. Use a path relative to your working directory."
