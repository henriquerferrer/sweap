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

# --- --tested-tree: the push run may skip e2e only on a tree a PR already passed ---
# `gh` and `timeout` are stubbed on PATH. The gh stub serves canned JSON per
# endpoint and applies the caller's REAL --jq filter with jq, so the filters in
# ci-lane.sh are what is under test, not a re-implementation of them.
T="$WORK/tt"; mkdir -p "$T/bin" "$T/api"
cat >"$T/bin/timeout" <<'S'
#!/usr/bin/env bash
shift; exec "$@"
S
cat >"$T/bin/gh" <<'S'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1; ep="$2"; shift 2; f=""
while [ $# -gt 0 ]; do [ "$1" = --jq ] && { f="$2"; shift; }; shift; done
case "$ep" in
  */check-runs*) file=checks ;;
  */pulls)       file=pulls ;;
  */git/commits/*) file=commit ;;
  */compare/*)   file=compare ;;
  *) exit 1 ;;
esac
[ -f "$TT_API/$file.fail" ] && exit 22
jq -r "$f" "$TT_API/$file.json"
S
chmod +x "$T/bin/timeout" "$T/bin/gh"
R="$T/repo"; mkdir -p "$R"; tg() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
tg init -q -b main; printf 'a\n' > "$R/a.ts"; tg add -A; tg commit -qm base
TBEFORE="$(tg rev-parse HEAD)"
tg checkout -q -b feat; printf 'b\n' > "$R/b.ts"; tg add -A; tg commit -qm work
THEAD="$(tg rev-parse HEAD)"; THTREE="$(tg rev-parse 'HEAD^{tree}')"
tg checkout -q main; tg merge -q --squash feat; tg commit -qm 'work (#7)'
TSHA="$(tg rev-parse HEAD)"
tt() { (cd "$R" && env PATH="$T/bin:$PATH" TT_API="$T/api" GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=main bash "$LANE" --tested-tree "${1:-$TBEFORE}" 2>"$T/err"); }
good() { # reset every endpoint to the all-conditions-hold answer
  rm -f "$T/api/"*.fail
  printf '[{"merge_commit_sha":"%s","merged_at":"2026-09-20T00:00:00Z","base":{"ref":"main"},"head":{"sha":"%s"}}]' "$TSHA" "$THEAD" > "$T/api/pulls.json"
  printf '{"tree":{"sha":"%s"}}' "$THTREE" > "$T/api/commit.json"
  printf '{"behind_by":0,"status":"ahead"}' > "$T/api/compare.json"
  printf '{"check_runs":[{"id":10,"name":"e2e","status":"completed","conclusion":"failure_was_rerun"},{"id":11,"name":"e2e","status":"completed","conclusion":"success"}]}' > "$T/api/checks.json"
}
good; want "tested-tree: every condition holds"                      tested "$(tt)"
want "tested-tree: ...and says so on stderr" 1 "$(grep -c 'tested-tree: yes' "$T/err")"
printf '[]' > "$T/api/pulls.json"
want "tested-tree: a direct push (no merged PR) runs e2e"            code "$(tt)"
want "tested-tree: ...and says why on stderr" 1 "$(grep -c 'tested-tree: no' "$T/err")"
good; printf '[{"merge_commit_sha":"%s","merged_at":null,"base":{"ref":"main"},"head":{"sha":"%s"}}]' "$TSHA" "$THEAD" > "$T/api/pulls.json"
want "tested-tree: an OPEN PR's test-merge sha does not count"       code "$(tt)"
good; printf '[{"merge_commit_sha":"%s","merged_at":"x","base":{"ref":"main"},"head":{"sha":"%s"}}]' "$THEAD" "$THEAD" > "$T/api/pulls.json"
want "tested-tree: a PR merely CONTAINING the commit does not count" code "$(tt)"
good; printf '{"tree":{"sha":"%s"}}' "$(printf '%040d' 1)" > "$T/api/commit.json"
want "tested-tree: tree differs from the PR head"                    code "$(tt)"
good; printf '{"behind_by":2,"status":"diverged"}' > "$T/api/compare.json"
want "tested-tree: PR head was behind main (the revert history)"     code "$(tt)"
good; printf '{"check_runs":[{"id":11,"name":"e2e","status":"completed","conclusion":"skipped"}]}' > "$T/api/checks.json"
want "tested-tree: a SKIPPED e2e (roadmap-only PR) is not a pass"    code "$(tt)"
good; printf '{"check_runs":[{"id":11,"name":"e2e","status":"completed","conclusion":"success"},{"id":12,"name":"e2e","status":"in_progress","conclusion":null}]}' > "$T/api/checks.json"
want "tested-tree: the NEWEST e2e (highest id) is still running"     code "$(tt)"
good; printf '{"check_runs":[{"id":12,"name":"e2e","status":"completed","conclusion":"success"},{"id":9,"name":"e2e","status":"completed","conclusion":"failure"}]}' > "$T/api/checks.json"
want "tested-tree: any surviving red e2e row vetoes"                 code "$(tt)"
good; printf '{"check_runs":[]}' > "$T/api/checks.json"
want "tested-tree: no e2e check-run at all"                          code "$(tt)"
for ep in pulls commit compare checks; do good; : > "$T/api/$ep.fail"
  want "tested-tree: API error on $ep fails closed"                  code "$(tt)"; done
good
want "tested-tree: before is not HEAD^ (multi-commit push)"          code "$(tt "$THEAD")"
want "tested-tree: a before-sha that is not a commit id"             code "$(tt main)"
want "tested-tree: no GITHUB_REPOSITORY"   code "$( (cd "$R" && env PATH="$T/bin:$PATH" TT_API="$T/api" GITHUB_REF_NAME=main bash "$LANE" --tested-tree "$TBEFORE" 2>/dev/null) )"
mkdir -p "$T/nobin"; cp "$T/bin/gh" "$T/nobin/gh"   # gh present, timeout absent
NOTIMEOUT_PATH="$T/nobin:$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"
if ! PATH="$NOTIMEOUT_PATH" command -v timeout >/dev/null 2>&1; then
  want "tested-tree: no timeout(1) — never an unbounded API call"    code "$( (cd "$R" && env PATH="$NOTIMEOUT_PATH" TT_API="$T/api" GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=main bash "$LANE" --tested-tree "$TBEFORE" 2>/dev/null) )"
fi
# a push that touches .github/ runs the pipeline it edits, whatever the PR run said
tg checkout -q -b cifeat "$TSHA"; mkdir -p "$R/.github/workflows"; printf 'x\n' > "$R/.github/workflows/ci.yml"; tg add -A; tg commit -qm ci
CHEAD="$(tg rev-parse HEAD)"; CTREE="$(tg rev-parse 'HEAD^{tree}')"
tg checkout -q main; tg merge -q --squash cifeat; tg commit -qm 'ci (#8)'; CSHA="$(tg rev-parse HEAD)"
good; printf '[{"merge_commit_sha":"%s","merged_at":"x","base":{"ref":"main"},"head":{"sha":"%s"}}]' "$CSHA" "$CHEAD" > "$T/api/pulls.json"
printf '{"tree":{"sha":"%s"}}' "$CTREE" > "$T/api/commit.json"
want "tested-tree: a push touching .github/ always runs e2e"         code "$(tt "$TSHA")"
want "tested-tree: usage exits 2" 2 "$( (cd "$R" && bash "$LANE" --tested-tree >/dev/null 2>&1); echo $?)"
# the offline modes can never say `tested` — that is what keeps a PR from claiming it
want "--files never prints tested"  code "$(run --files src/a.ts)"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
