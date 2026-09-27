#!/usr/bin/env bash
# sweap test runner — the merge bar. sweap has no hosted CI, so a green run of
# this script is what stands in for it: run it before every PR.
#
#   ./test.sh            run every suite, print each suite's output
#   ./test.sh --quiet    print only the header, PASS/FAIL lines and the summary
#
# Suites: the version-bump gate first (it fails fast and costs nothing — a
# plugin/ change that does not bump plugin/.claude-plugin/plugin.json never
# reaches the consumers, because the consumer's plugin cache is keyed by version;
# SWEAP_SKIP_VERSION_CHECK=1 is the escape hatch), every plugin/hooks/*.test.sh
# plus scripts/version-bump-check.test.sh (serial, timed — pre-merge-gate.test.sh
# legitimately takes ~3-5 min because it sleeps through real gh-timeout paths;
# the per-suite seconds are how you tell a hang from that suite), one `node`
# suite over plugin/tools/*.test.mjs + plugin/workflows/*.test.mjs (file globs:
# Node 21+ rejects a bare directory as a --test argument), and shellcheck when it
# is installed (skipped with a message when it is not).
#
# Portable to the maintainer's /bin/bash 3.2: no mapfile, no associative arrays,
# no `timeout(1)` (macOS has none), failures accumulated in a string rather than
# an array (an empty array expands to an error under `set -u` on 3.2).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

quiet=0
for arg in "$@"; do
  case "$arg" in
    --quiet) quiet=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg (only --quiet is accepted)" >&2; exit 2 ;;
  esac
done

echo "node $(node --version 2>/dev/null || echo '(not found)')"
echo "bash $BASH_VERSION"

suites=0
failed=""
nfailed=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# run_suite <name> <command...>: runs the command with output captured, prints
# PASS/FAIL with elapsed seconds, replays the output on failure (and on pass
# unless --quiet), and records a failure.
run_suite() {
  name=$1; shift
  suites=$((suites + 1))
  start=$(date +%s)
  "$@" >"$tmp" 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name (${elapsed}s)"
    [ "$quiet" -eq 1 ] || cat "$tmp"
  else
    echo "FAIL $name (${elapsed}s) — exit $rc"
    cat "$tmp"
    failed="$failed $name"
    nfailed=$((nfailed + 1))
  fi
}

# First: the cheapest gate, and the one whose failure invalidates the release
# rather than the code. Skips itself (and passes) when there is no baseline to
# compare against — it never reds the bar for an environmental reason.
run_suite version-bump-check bash scripts/version-bump-check.sh

for f in plugin/hooks/*.test.sh scripts/*.test.sh; do
  [ -f "$f" ] || continue
  run_suite "$(basename "$f")" bash "$f"
done

run_suite node node --test plugin/tools/*.test.mjs plugin/workflows/*.test.mjs

if command -v shellcheck >/dev/null 2>&1; then
  run_suite shellcheck shellcheck -S warning plugin/hooks/*.sh plugin/hooks/*.test.sh plugin/bin/* scripts/*.sh test.sh
else
  echo "skip: shellcheck not installed (brew install shellcheck)"
fi

if [ "$nfailed" -gt 0 ]; then
  echo "$suites suites, $nfailed failed:$failed"
  exit 1
fi
echo "$suites suites, 0 failed"
