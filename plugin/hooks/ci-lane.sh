#!/usr/bin/env bash
#
# ci-lane.sh — which CI lane does a change belong in: `roadmap-only` or `code`?
#
# The one classification behind the roadmap-only fast lane. A PR that changes
# nothing but backlog files (item files, the two inboxes, audit records), docs
# and markdown cannot change what e2e tests, so CI may skip the e2e job for it —
# and pre-merge-gate.sh accepts a SKIPPED e2e check ONLY when this script, run
# on the PR's own file list, says `roadmap-only`. Two readers, one rule: the
# workflow (templates/.github/workflows/ci.yml, vendored copy under
# .github/scripts/) and the merge hook both call this script, so the lane CI
# took and the lane the gate accepts can never drift apart.
#
# WHY AN ALLOWLIST, NOT A DENYLIST: the whole value of a skippable e2e is also
# its risk — a job skipped by an `if:` reports SUCCESS (see audit-gate.yml's
# hard rules). Listing what MAY skip (and treating everything else, including
# an empty file list, as code) means a mis-globbed path can only ever make the
# lane too slow, never too permissive. `.github/**` is deliberately code: a
# workflow edit must run the full pipeline it edits.
#
# WHY IT EXISTS (research memo, 2026-08-22): on consumer A a docs-only PR ran
# 24.8 minutes of e2e on a self-hosted runner that shares the agents' CPU, and
# every merge re-ran it on the `push` event — so a captured backlog item cost
# two e2e runs. That price is what pushed agents to bundle item files onto
# unrelated feature branches (#181), and the evidence says a rule against
# bundling cannot hold while the sanctioned path is the expensive one. The fix
# is to make the small change cheap, which is what this lane does.
#
# Usage:
#   ci-lane.sh --files <path>...     classify an explicit list (NUL-safe via
#                                    --files0 on stdin: `ci-lane.sh --files0 < list`)
#   ci-lane.sh --base <ref>          classify `git diff --name-only <ref>...HEAD`
# Prints exactly one word on stdout: `roadmap-only` or `code`. Exit 0 on a
# classification, 2 on usage. Reads `backlog.dir` from CLAUDE.md's
# `## sweap config` block (default `roadmap/`), like audit-gate.sh does.
set -uo pipefail

BACKLOG_DIR="$(sed -n 's/^backlog\.dir:[[:space:]]*\([^[:space:]#]*\).*/\1/p' CLAUDE.md 2>/dev/null | head -1)"
BACKLOG_DIR="${BACKLOG_DIR:-roadmap/}"
case "$BACKLOG_DIR" in */) : ;; *) BACKLOG_DIR="$BACKLOG_DIR/" ;; esac
BACKLOG_DIR="${BACKLOG_DIR#./}"
# Fail closed on a degenerate configured value: `backlog.dir: ./` (or `.`)
# normalises to an EMPTY prefix above, and an empty prefix string-matches every
# path — which would classify a code PR `roadmap-only` and let the gate bless
# its skipped e2e (found by an adversarial review, 2026-08-24). "The repo root
# is the backlog" cannot be allowlisted; fall back to the default so the
# allowlist stays narrow. (A leading-slash or `..` value is harmless: it can
# never prefix-match a repo-relative path, so it only narrows the lane.)
[ -n "$BACKLOG_DIR" ] || BACKLOG_DIR="roadmap/"

mode="${1:-}"
[ -n "$mode" ] || { echo "usage: ci-lane.sh --files <path>... | --files0 | --base <ref>" >&2; exit 2; }
shift

# classify <path>: 0 = may skip e2e, 1 = code. Patterns are STRING matches
# (`*` also matches `/`), the same convention as audit-gate.sh's --files arm.
classify() {
  local p="${1#./}"
  case "$p" in
    .github/*) return 1 ;;               # a workflow/script edit is code, even a .md in there
    "${BACKLOG_DIR}"*) return 0 ;;        # items, ideas/, discovered/, audits/, archive/
    docs/*) return 0 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

lane=roadmap-only
n=0
emit() { printf '%s\n' "$lane"; exit 0; }
case "$mode" in
  --files)
    for p in "$@"; do [ -n "$p" ] || continue; n=$((n + 1)); classify "$p" || { lane=code; emit; }; done ;;
  --files0)
    while IFS= read -r -d '' p; do [ -n "$p" ] || continue; n=$((n + 1)); classify "$p" || { lane=code; emit; }; done ;;
  --base)
    ref="${1:-}"; [ -n "$ref" ] || { echo "usage: ci-lane.sh --base <ref>" >&2; exit 2; }
    # Fail closed: a diff that cannot be computed (unknown ref, shallow clone
    # without the base) is code — e2e runs, nothing is skipped on uncertainty.
    # Streamed NUL-delimited (never through `$(...)`, which drops NUL bytes).
    git merge-base "$ref" HEAD >/dev/null 2>&1 || { lane=code; emit; }
    while IFS= read -r -d '' p; do [ -n "$p" ] || continue; n=$((n + 1)); classify "$p" || { lane=code; emit; }; done \
      < <(git diff --name-only -z "${ref}...HEAD" 2>/dev/null) ;;
  *) echo "usage: ci-lane.sh --files <path>... | --files0 | --base <ref>" >&2; exit 2 ;;
esac
# An empty change set is not "only roadmap files" — it is unknown, so code.
[ "$n" -gt 0 ] || lane=code
emit
