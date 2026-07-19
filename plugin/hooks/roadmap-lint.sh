#!/usr/bin/env bash
#
# roadmap-lint.sh — the mechanical spec gate on roadmap item files.
#
# One gate, two call sites: /roadmap runs it on every new/changed item file
# before the milestone PR opens; the dispatching session (serial loop or
# coordinator) runs it on an item before dispatch. Fail = the item is not
# runnable — fix mechanically or escalate; never dispatch past a failing lint.
#
# Usage: roadmap-lint.sh <item-file> [items-dir]
#   items-dir defaults to the item file's own directory (where item-level
#   depends_on entries must resolve to <ID>.md files).
# Exit: 0 = pass; 1 = fail (one "FAIL: reason" per line on stdout); 2 = usage.
#
# Format contract (playbook "Backlog format"): flat single-line frontmatter
# keys; depends_on is an inline [a, b] list. This constraint is what keeps
# this script trivial — do not grow a YAML parser here.
set -uo pipefail

file="${1:-}"
if [ -z "$file" ]; then
  echo "usage: roadmap-lint.sh <item-file> [items-dir]"
  exit 2
fi
if [ ! -f "$file" ]; then
  echo "FAIL: no such file: $file"
  exit 1
fi
dir="${2:-$(dirname "$file")}"

fails=0
fail() { echo "FAIL: $1"; fails=1; }

# --- frontmatter: first block delimited by --- lines, must start at line 1 ---
fm="$(awk 'NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$file")"
if [ -z "$fm" ]; then
  fail "missing frontmatter (file must start with a --- block)"
fi

get() { printf '%s\n' "$fm" | sed -n "s/^$1:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }

id="$(get id)"
status="$(get status)"
base="$(basename "$file" .md)"

[ -n "$id" ] || fail "missing id:"
if [ -n "$id" ] && [ "$id" != "$base" ]; then
  fail "id ($id) != filename ($base)"
fi

case "$status" in
  todo|blocked|deferred|done|dropped) : ;;
  "") fail "missing status:" ;;
  *)  fail "invalid status: $status (todo|blocked|deferred|done|dropped)" ;;
esac
if [ "$status" = "deferred" ] && [ -z "$(get premise)" ]; then
  fail "deferred item missing premise: (the machine-checkable predicate it waits on)"
fi
if [ "$status" = "blocked" ] && [ -z "$(get blocked)" ]; then
  fail "blocked item missing blocked: (the question awaiting an ANSWER)"
fi

# --- depends_on: inline [a, b]; entries containing a dot are item-level and
# must resolve to a file; bare milestone tags (no dot) are allowed as-is -----
deps="$(get depends_on | tr -d '[]' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  case "$dep" in
    *.*)
      [ -f "$dir/$dep.md" ] || fail "depends_on $dep: no file $dir/$dep.md"
      ;;
  esac
done <<DEPS
$deps
DEPS

# --- body sections: ## Spec (three named bullets) + ## Acceptance ------------
body="$(awk 'NR==1 && $0=="---" { infm=1; next } infm && /^---$/ { infm=0; next } !infm { print }' "$file")"
section() { printf '%s\n' "$body" | awk -v h="^## $1" 'BEGIN{on=0} $0~h{on=1;next} /^## /{on=0} on{print}'; }

spec="$(section "Spec")"
acc="$(section "Acceptance")"
printf '%s' "$spec" | grep -q '[^[:space:]]' || fail "missing/empty '## Spec' section"
printf '%s' "$acc"  | grep -q '[^[:space:]]' || fail "missing/empty '## Acceptance' section"
if printf '%s' "$spec" | grep -q '[^[:space:]]'; then
  for bullet in "Surface" "Interfaces" "Out of scope"; do
    printf '%s\n' "$spec" | grep -q "^- \*\*$bullet" || fail "Spec missing '- **$bullet:**' bullet"
  done
fi

# Unfilled <...> placeholders make a todo item undispatched-able; done/other
# statuses are historical records and are not re-gated.
if [ "$status" = "todo" ]; then
  if printf '%s\n%s\n' "$spec" "$acc" | grep -q '<[^>]*>'; then
    fail "unfilled <...> placeholder in Spec/Acceptance of a todo item"
  fi
fi

exit "$fails"
