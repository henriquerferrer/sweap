#!/usr/bin/env bash
#
# workflow-start-notify.sh — PreToolUse(Workflow) hook: tell the human a
# milestone audit has started.
#
# The human asked for the three moments of a milestone's end as notifications
# (2026-10-10): built, audit started, audit finished. Built and finished are
# merges, so post-merge-auditcheck.sh raises them. Started is not a merge: it is
# the session launching the `sweap:milestone-audit-workflow` workflow (named
# `milestone-audit` up to 0.42.0, still matched for a session on an older
# build), and a PreToolUse
# hook on the Workflow tool is the only mechanical place that sees it (witnessed
# on Claude Code 2.1.295: the hook fires with the call's `name` and `args`).
#
# It fires on the launch, not on the workflow's first step: a launch the harness
# then refuses still notifies once. Never blocks, never prints, always exit 0 —
# it must not be able to stand between a session and its workflow.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "Workflow" ] || exit 0
name="$(printf '%s' "$input" | jq -r '.tool_input.name // empty' 2>/dev/null)"
case "$name" in
  sweap:milestone-audit-workflow|milestone-audit-workflow|sweap:milestone-audit|milestone-audit) ;;
  *) exit 0 ;;
esac
# args is an object ({milestone, range}) or, from an older call, a bare id.
m="$(printf '%s' "$input" | jq -r '.tool_input.args | if type == "string" then (fromjson? // .) else . end | if type == "object" then (.milestone // "") elif type == "string" then . else "" end' 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
# Name the repo, not a worktree: the primary checkout's directory.
gitdir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
case "$gitdir" in
  "") repo_dir="$cwd" ;;
  /*) repo_dir="$(dirname "$gitdir")" ;;
  *)  repo_dir="$(cd "$cwd" 2>/dev/null && cd "$(dirname "$gitdir")" 2>/dev/null && pwd)" ;;
esac
[ -n "${repo_dir:-}" ] || repo_dir="$cwd"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-notify.sh" 2>/dev/null || exit 0
sweap_notify "$repo_dir" "${m:+$m }audit started" "Reviewers are checking the merged work. You get another note when the milestone is complete."
exit 0
