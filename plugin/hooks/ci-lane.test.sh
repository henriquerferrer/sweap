#!/usr/bin/env bash
#
# ci-lane.test.sh — deterministic, offline tests for ci-lane.sh (the roadmap-only
# fast-lane classifier shared by the CI template and pre-merge-gate.sh).
#
# Run:  bash plugin/hooks/ci-lane.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE="$HERE/ci-lane.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
want() { # want <desc> <expected> <actual> [rc]
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$3" "$2"; fi
}
run() { (cd "$WORK" && bash "$LANE" "$@" 2>/dev/null); }

echo "ci-lane.test.sh:"
cd "$WORK" || exit 1
# --- explicit file lists, default backlog.dir ---------------------------------
want "item file alone"                  roadmap-only "$(run --files roadmap/F1.2.md)"
want "discovered + ideas + audits"      roadmap-only "$(run --files roadmap/discovered/a-0a1b2c.md roadmap/ideas/x.md roadmap/audits/F1.md roadmap/archive/F1.9.md)"
want "index + docs + README"            roadmap-only "$(run --files ROADMAP.md docs/research/x.md src/README.md)"
want "CLAUDE.md is markdown"            roadmap-only "$(run --files CLAUDE.md)"
want "one code file flips it"           code "$(run --files roadmap/F1.2.md src/a.ts)"
want "a workflow edit is code"          code "$(run --files .github/workflows/ci.yml)"
want "a .md under .github is code"      code "$(run --files .github/PULL_REQUEST_TEMPLATE.md)"
want "a vendored script is code"        code "$(run --files .github/scripts/ci-lane.sh)"
want "empty list is code (fail closed)" code "$(run --files)"
want "blank entries ignored, else roadmap-only" roadmap-only "$(run --files '' roadmap/F1.1.md)"
want "lookalike prefix is code"         code "$(run --files roadmapper/x.md.bak)"
want "justfile is code"                 code "$(run --files justfile)"
want "--files0 reads NUL list"          roadmap-only "$(printf 'roadmap/F1.1.md\0docs/a.md\0' | (cd "$WORK" && bash "$LANE" --files0))"
want "--files0 code"                    code "$(printf 'roadmap/F1.1.md\0src/x.go\0' | (cd "$WORK" && bash "$LANE" --files0))"
want "usage exits 2" 2 "$( (cd "$WORK" && bash "$LANE" >/dev/null 2>&1); echo $?)"

# --- backlog.dir override from CLAUDE.md --------------------------------------
mkdir -p "$WORK/cfg" && printf '## sweap config\n```\nbacklog.dir:      items/   # one file per item\n```\n' > "$WORK/cfg/CLAUDE.md"
want "configured backlog.dir honoured"   roadmap-only "$( (cd "$WORK/cfg" && bash "$LANE" --files items/F1.2.md items/discovered/x-000000.md) )"
want "override: a non-md file under the old dir is code" code "$( (cd "$WORK/cfg" && bash "$LANE" --files roadmap/F1.2.json) )"
want "override: a non-md file under the new dir is roadmap-only" roadmap-only "$( (cd "$WORK/cfg" && bash "$LANE" --files items/F1.2.json) )"

# --- degenerate backlog.dir values fail closed (2026-08-24 finding) ------------
mkdir -p "$WORK/cfg2" && printf '## sweap config\n```\nbacklog.dir:      ./\n```\n' > "$WORK/cfg2/CLAUDE.md"
want "backlog.dir ./ : code file stays code"       code "$( (cd "$WORK/cfg2" && bash "$LANE" --files src/a.ts) )"
want "backlog.dir ./ : falls back to default dir"  roadmap-only "$( (cd "$WORK/cfg2" && bash "$LANE" --files roadmap/F1.2.md) )"
mkdir -p "$WORK/cfg3" && printf '## sweap config\n```\nbacklog.dir:      .\n```\n' > "$WORK/cfg3/CLAUDE.md"
want "backlog.dir . : code file stays code"        code "$( (cd "$WORK/cfg3" && bash "$LANE" --files packages/api/x.go) )"

# --- --base against a real repo -----------------------------------------------
R="$WORK/repo"; mkdir -p "$R/roadmap" "$R/src"
git -C "$R" init -q && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" branch -M main 2>/dev/null || true
git -C "$R" checkout -q -b feat
printf 'x' > "$R/roadmap/F1.1.md"; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm items
want "--base: roadmap-only branch"      roadmap-only "$( (cd "$R" && bash "$LANE" --base main) )"
printf 'y' > "$R/src/a.ts"; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm code
want "--base: code on the branch"       code "$( (cd "$R" && bash "$LANE" --base main) )"
want "--base: is literal — HEAD^ diffs the tip commit only" code "$( (cd "$R" && bash "$LANE" --base HEAD^) )"
want "--base: unknown ref fails closed"  code "$( (cd "$R" && bash "$LANE" --base nope) )"
want "--base: no diff (same ref) is code" code "$( (cd "$R" && bash "$LANE" --base HEAD) )"

# --- push-to-main shape: the base must be the ref's tip BEFORE the push --------
# ci.yml's `changes` job used to pass --base HEAD^ here, on the premise that a
# squash merge is one commit. True of the agent path (sweap-merge.sh always
# merges --squash), false of the human path — and CI changes ARE the human path,
# because the merge gate denies those PRs to sessions. Consumer A, 2026-08-30: a
# ci.yml edit (892147d, rewriting the e2e job) and its roadmap update (5964666)
# went up in ONE push; HEAD^ saw only the roadmap file and e2e skipped the job
# the first commit had just changed. The base is github.event.before instead.
P="$WORK/push"; mkdir -p "$P/roadmap" "$P/.github/workflows"
gc() { git -C "$P" -c user.email=t@t -c user.name=t "$@"; }
git -C "$P" init -q && gc commit -q --allow-empty -m init
BEFORE="$(git -C "$P" rev-parse HEAD)"
printf 'x' > "$P/.github/workflows/ci.yml"; gc add -A; gc commit -qm ci
printf 'y' > "$P/roadmap/DP.3.md"; gc add -A; gc commit -qm item
want "push: HEAD^ misses a code commit earlier in the push (the 2026-08-30 bug)" \
  roadmap-only "$( (cd "$P" && bash "$LANE" --base HEAD^) )"
want "push: event.before classifies the whole push"          code "$( (cd "$P" && bash "$LANE" --base "$BEFORE") )"
want "push: all-zeros before (branch created) fails closed"  code "$( (cd "$P" && bash "$LANE" --base 0000000000000000000000000000000000000000) )"
want "push: unreachable before (force push) fails closed"    code "$( (cd "$P" && bash "$LANE" --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef) )"
# ...and the saving the lane exists for survives: an all-backlog push still skips.
gc checkout -q -b allroadmap "$BEFORE"; mkdir -p "$P/roadmap"   # git tracks no empty dirs
printf 'a' > "$P/roadmap/a.md"; gc add -A; gc commit -qm a
printf 'b' > "$P/roadmap/b.md"; gc add -A; gc commit -qm b
want "push: multi-commit backlog-only push still skips e2e" roadmap-only "$( (cd "$P" && bash "$LANE" --base "$BEFORE") )"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
