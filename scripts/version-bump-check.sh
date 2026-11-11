#!/usr/bin/env bash
#
# version-bump-check.sh — the merge bar's version gate.
#
# A consumer's plugin cache is keyed by the "version" field in
# plugin/.claude-plugin/plugin.json: `claude plugin update` compares versions and
# does nothing when they match ("already at the latest version"). So a merged
# change under plugin/ that does not bump that version never reaches a consumer,
# silently and indefinitely. That trap has fired three times — an 18-day hooks
# outage, #32's arm-time checkpoint, and #36-#38's /sweap:walkthrough and board work.
# "Remember to bump" demonstrably failed, so it is a gate instead.
#
# Run:  bash scripts/version-bump-check.sh     (from anywhere inside the repo)
# Exit: 0 = pass, or skipped for an environmental reason (printed)
#       1 = consumer-visible files under plugin/ changed without a version bump
#
# HERMETIC by construction: it reads this repo's git history and this repo's own
# manifest, and nothing else. It never reads ~/.claude, installed_plugins.json,
# or a consumer checkout — a merge bar that can go red without a commit to this
# repo is exactly the defect #36 fixed, and this check must not reintroduce it.
#
# Portable to the maintainer's /bin/bash 3.2: no mapfile, no associative arrays,
# no `timeout(1)`, no process substitution.
set -uo pipefail

MANIFEST="plugin/.claude-plugin/plugin.json"
LABEL="version-bump-check"

echo "$LABEL:"

# skip <reason>: an environmental reason never fails the bar — it prints why and
# passes. No remote, a shallow clone and a detached CI checkout all land here.
skip() {
  printf '  SKIP  %s\n' "$1"
  printf 'RESULT: skipped (pass)\n'
  exit 0
}

pass() {
  printf '  PASS  %s\n' "$1"
  printf 'RESULT: pass\n'
  exit 0
}

# read_version <file-or-->: prints the "version" string from a JSON manifest on
# stdin. No jq dependency (the merge bar must run on a bare machine).
read_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p
}

# --- 5. escape hatch ----------------------------------------------------------
if [ "${SWEAP_SKIP_VERSION_CHECK:-0}" = "1" ]; then
  skip "SWEAP_SKIP_VERSION_CHECK=1 — version bump not required for this run"
fi

root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$root" ]; then
  skip "not inside a git work tree — nothing to compare against"
fi
cd "$root" || skip "cannot enter the repo root ($root)"

# --- 1. baseline --------------------------------------------------------------
base=""
base_ref=""
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  base=$(git merge-base HEAD origin/main 2>/dev/null) || base=""
  [ -n "$base" ] && base_ref="origin/main"
fi
if [ -z "$base" ] && git rev-parse --verify -q main >/dev/null 2>&1; then
  base=$(git merge-base HEAD main 2>/dev/null) || base=""
  [ -n "$base" ] && base_ref="main"
fi
if [ -z "$base" ]; then
  skip "no origin/main and no main to diff against (no remote, shallow clone, or detached checkout)"
fi

# --- 2. changed set: committed on this branch + unstaged + staged --------------
# All three arms matter: the change may be committed on a branch, sitting
# unstaged in the working tree, or staged and not yet committed.
changed=$(
  {
    git diff --name-only "$base" HEAD -- plugin/ 2>/dev/null
    git diff --name-only -- plugin/ 2>/dev/null
    git diff --cached --name-only -- plugin/ 2>/dev/null
  } | sort -u
)

# --- 3. drop consumer-invisible paths ----------------------------------------
# Test files and hook fixtures ship in the tarball but change nothing a consumer
# can observe, so they must not oblige a bump on their own.
visible=$(
  printf '%s\n' "$changed" \
    | grep -v -E '\.test\.(sh|mjs)$' \
    | grep -v -E '^plugin/hooks/testdata/' \
    | grep -v -E '^[[:space:]]*$'
)

if [ -z "$visible" ]; then
  pass "no consumer-visible change under plugin/ since ${base_ref} ($(echo "$base" | cut -c1-8))"
fi

nvisible=$(printf '%s\n' "$visible" | wc -l | tr -d ' ')

# --- 4. compare the manifest version at HEAD/worktree vs at the baseline -------
base_manifest=$(git show "$base:$MANIFEST" 2>/dev/null)
if [ -z "$base_manifest" ]; then
  skip "the baseline commit has no $MANIFEST — nothing to compare (old history)"
fi
base_version=$(printf '%s\n' "$base_manifest" | read_version)

if [ -f "$MANIFEST" ]; then
  cur_version=$(read_version < "$MANIFEST")
else
  cur_version=$(git show "HEAD:$MANIFEST" 2>/dev/null | read_version)
fi

if [ -z "$cur_version" ] || [ -z "$base_version" ]; then
  skip "could not read a \"version\" string from $MANIFEST on both sides"
fi

if [ "$cur_version" != "$base_version" ]; then
  pass "version bumped $base_version -> $cur_version for $nvisible consumer-visible file(s)"
fi

# --- the failure -------------------------------------------------------------
printf '  FAIL  %s changed but %s was not bumped\n' "plugin/" "$MANIFEST"
printf '        baseline:  %s (merge-base HEAD %s)\n' "$base" "$base_ref"
printf '        version:   %s at the baseline and %s now — unchanged\n' "$base_version" "$cur_version"
printf '        %s consumer-visible file(s) oblige a bump:\n' "$nvisible"
printf '%s\n' "$visible" | sed -n '1,10p' | sed 's/^/          - /'
if [ "$nvisible" -gt 10 ]; then
  printf '          ... and %s more\n' "$((nvisible - 10))"
fi
printf '\n'
printf '        the plugin cache is keyed by version — a merged change that does not bump it never reaches the consumers\n'
printf '\n'
printf '        Fix:     bump "version" in %s.\n' "$MANIFEST"
printf '        Escape:  SWEAP_SKIP_VERSION_CHECK=1 ./test.sh — for a change that truly ships nothing.\n'
printf 'RESULT: fail\n'
exit 1
