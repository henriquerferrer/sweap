#!/usr/bin/env bash
#
# lib-notify.sh — the one place a hook raises a desktop notification.
#
#   sweap_notify <repo-dir> <headline> <body>
#
# A desktop notification shows a title and about two lines, and the human reads
# it away from the session, with no context. So every one has the same shape:
# the title is "<repo>: <what happened>", the body is one or two short plain
# sentences that end with what to do, or say that nothing is needed. The repo
# leads because one person runs more than one consumer. Text is reduced to a
# plain-ASCII allowlist before it reaches osascript: it is interpolated into an
# AppleScript string, and item titles and error text are not ours.
#
# Never fails and never prints: a notification is a courtesy, not a control.
# Sourced; defines one function and no globals.

sweap_notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  local repo title body
  repo="$(basename "${1:-.}" | tr -cd 'A-Za-z0-9._ -')"
  title="$(printf '%s: %s' "$repo" "${2:-}" | tr -cd 'A-Za-z0-9 .,:;()#/_+-')"
  body="$(printf '%s' "${3:-}" | tr -cd 'A-Za-z0-9 .,:;()#/_+-')"
  osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
  return 0
}

# sweap_run_active <primary-checkout>: 0 when a milestone run is under way there
# (the run file /milestone keeps exists and carries no `ended:` line). A run
# audits its own milestone when its workflow returns drained, so a message that
# would tell the human to start the audit is wrong while one is active.
sweap_run_active() {
  local f="${1:-.}/.claude/sweap-run.md"
  [ -f "$f" ] || return 1
  if grep -qE '^ended:' "$f" 2>/dev/null; then return 1; fi
  return 0
}
