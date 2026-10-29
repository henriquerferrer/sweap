#!/bin/sh
# sweap-playbook.sh — the body of bin/sweap-playbook (read its header). The
# wrapper execs this by its real path inside the plugin, so the plugin root is
# this file's parent directory.
set -u

root=$(CDPATH='' cd -P -- "$(dirname "$0")/.." && pwd -P) || exit 1
book=$root/playbook/agentic-loop-playbook.md
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
if [ -n "$top" ] && [ -f "$top/docs/agentic-loop-playbook.md" ]; then
  book=$top/docs/agentic-loop-playbook.md
fi

case ${1:-} in
  '') printf '%s\n' "$book" ;;
  --run-core) sed '/^<!-- run-core:end -->/q' "$book" ;;
  *) echo 'usage: sweap-playbook [--run-core]' >&2; exit 2 ;;
esac
