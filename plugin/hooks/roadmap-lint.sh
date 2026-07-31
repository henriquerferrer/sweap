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
# (`sub(/\r$/,"")` first so a CRLF checkout doesn't make line 1 `---\r` != `---`.)
fm="$(awk '{ sub(/\r$/,"") } NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$file")"
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

# --- depends_on: the flat inline [a, b] form the whole greppable substrate
# assumes. A YAML block list (or a bare scalar) reads as an empty inline value
# and would silently skip dependency resolution, so reject anything that is not
# `[...]` outright — the lint is where that format contract is enforced.
if printf '%s\n' "$fm" | grep -q '^depends_on:'; then
  dep_raw="$(get depends_on)"
  case "$dep_raw" in
    \[*\]) : ;;
    *) fail "depends_on must be an inline [a, b] list (got: '${dep_raw:-<empty or block-style>}')" ;;
  esac
fi

# Dependency resolution (dot-depth-agnostic, so a multi-segment id like the
# milestone `DS.2` with items `DS.2.1` works alongside `F1`/`F1.1`). Per entry:
#   - `<dep>.md` exists           -> an item dependency, OK
#   - any `<dep>.<x>.md` exists    -> a milestone dependency (it has items), OK
#   - the entry has no dot         -> a bare milestone, allowed as-is (may be a
#                                     forward reference to a milestone whose
#                                     items do not exist yet)
#   - otherwise (a dotted entry that is neither) -> dangling, almost always a typo
deps="$(get depends_on | tr -d '[]' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  [ -f "$dir/$dep.md" ] && continue                  # item dependency
  ls "$dir/$dep."*.md >/dev/null 2>&1 && continue    # milestone with items
  case "$dep" in *.*) fail "depends_on $dep: no item file $dir/$dep.md and no items under milestone $dep" ;; esac
done <<DEPS
$deps
DEPS

# --- body sections: gated to `todo` items (the runnable ones) ---------------
# A complete spec is a DISPATCH prerequisite, so `## Spec` (three bullets) +
# `## Acceptance` are required only for `todo` items. blocked/deferred/done are
# records — they need valid frontmatter, not a full spec (a deferred/blocked
# item earns its spec when it is promoted to todo). This is also what lets a
# legacy migration carry historical done items across as plain records.
if [ "$status" = "todo" ]; then
  body="$(awk '{ sub(/\r$/,"") } NR==1 && $0=="---" { infm=1; next } infm && /^---$/ { infm=0; next } !infm { print }' "$file")"
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
  # Unfilled template placeholders: an ellipsis (`<...>` / `<…>`) or an
  # angle-bracketed lowercase phrase (internal space; only [a-z], space, `/`,
  # `-`). Deliberately NOT matching generic types (`Array<string>`,
  # `Map<string, number>`), JSX, or signatures that legitimately appear in an
  # Interfaces bullet.
  if printf '%s\n%s\n' "$spec" "$acc" | grep -Eq '<\.\.\.>|<…>|<[a-z][a-z /-]*[[:space:]][a-z /-]*>'; then
    fail "unfilled placeholder (<...> or <lowercase phrase>) in Spec/Acceptance of a todo item"
  fi
fi

exit "$fails"
