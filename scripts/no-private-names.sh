#!/usr/bin/env bash
# no-private-names.sh — PreToolUse(Bash) hook: this repo is public, so nothing an
# agent pushes or posts may name a private project or a person. The list of names
# lives outside the repo (SWEAP_PRIVATE_NAMES, default
# ~/.config/sweap/private-names, one extended regex per line), because listing them
# here would publish them. A missing or empty list denies: this fails closed.
#
# It checks the three ways text leaves this machine: the commits a `git push` would
# send (diffs and messages), the command line of a `gh` call that writes (an inline
# PR title or body), and any file that call reads with --body-file / -F. A silent
# no-op for every other command. Exit 2 is Claude Code's "deny", with stderr as the
# reason the agent sees.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
case "$cmd" in
  *"git push"* | *"gh pr "* | *"gh issue "* | *"gh api "* | *"gh release "*) ;;
  *) exit 0 ;;
esac

list="${SWEAP_PRIVATE_NAMES:-$HOME/.config/sweap/private-names}"
if [ ! -s "$list" ]; then
  echo "no-private-names: $list is missing or empty, so this push or post can't be checked. Create it, one name per line." >&2
  exit 2
fi

hit() { grep -inE -f "$list" | head -5; }
found=$(printf '%s\n' "$cmd" | hit)

case "$cmd" in
  *"git push"*)
    root="${CLAUDE_PROJECT_DIR:-.}"
    range=$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)
    found="$found$(git -C "$root" log -p --format=%B "$range..HEAD" 2>/dev/null | hit)"
    ;;
esac

for f in $(printf '%s\n' "$cmd" | grep -oE -- '(--body-file|-F)[ =][^ ]+' | sed -E 's/^(--body-file|-F)[ =]//'); do
  if [ -f "$f" ]; then
    found="$found$(hit <"$f")"
  fi
done

if [ -n "$found" ]; then
  {
    echo "no-private-names: this would publish a private name. Say \"consumer A/B/C\" or remove it, then retry:"
    printf '%s\n' "$found" | cut -c1-160
  } >&2
  exit 2
fi
exit 0
