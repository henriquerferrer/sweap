#!/usr/bin/env bash
#
# sweap-merge.test.sh — offline tests for the merge driver (spec §10).
#
# A stub `gh` on PATH answers from fixture files under a per-case directory
# (GH_FIX): pr view, compare, actions/workflows, contents listings, raw workflow
# files, actions/runs (paged or sequenced), pr merge. The consumers' real
# workflow files (consumer-a, consumer-b) are VENDORED SNAPSHOTS under testdata/workflows
# (see its README: until 2026-08-30 they were cp'd out of ~/Documents at run time,
# which made this suite — sweap's merge bar — depend on another repo's current
# contents on one Mac; raising consumer-a's e2e timeout reddened four cases with no
# sweap commit, and elsewhere the cp silently yielded an empty fixture dir). A
# fake plugin dir carries a COPY of the driver next to an env-driven gate and
# post-merge scripts that count invocations (the driver resolves its hooks from
# its own directory, never from CLAUDE_PLUGIN_ROOT — that is the seam); cases
# that need the REAL gate or the REAL post-merge-cleanup.sh run a COPY of the
# whole hooks dir. Every fixture copy carries the `.sweap-merge-test-seams`
# sentinel that unlocks the SWEAP_MERGE_* seams; the repo driver itself never
# does (asserted below), so cases about "what a model can type" run THAT one.
#
# Run:  bash plugin/hooks/sweap-merge.test.sh      (no real sleeps; ~30 s)
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${SWEAP_MERGE_DRIVER_UNDER_TEST:-$HERE/sweap-merge.sh}"   # override: run this suite against another build
WORK="$(cd "$(mktemp -d)" && pwd -P)"   # physical path: <primary> is derived via pwd
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
check() {   # check <name> <cmd...> [-- <cmd...>]...: EVERY command must succeed.
  # A bare `--` separates conditions; a condition may start with `!` to negate it.
  # `check <name> C1 && C2` does NOT work and must never be written: check returns
  # 0 whether the assertion passed or failed, so C2 is evaluated and its result
  # thrown away — the second half of such an assertion asserts nothing at all.
  local name="$1" rc=0 all n a; shift
  all="$*"
  while [ $# -gt 0 ]; do
    n=0
    for a in "$@"; do [ "$a" = "--" ] && break; n=$((n + 1)); done
    if [ "$n" -gt 0 ]; then
      ( set -- "${@:1:$n}"; if [ "$1" = "!" ]; then shift; ! "$@"; else "$@"; fi ) || rc=1
    fi
    shift "$n"
    [ "${1:-}" = "--" ] && shift
  done
  if [ "$rc" = 0 ]; then ok "$name"; else bad "$name" "condition failed: $all"; fi
}
word_is() { [ "$(printf '%s\n' "$OUT" | tail -1 | cut -d' ' -f1)" = "$1" ]; }
word_in() {   # word_in <word>...: the terminal word is one of these (for cases where
              # more than one outcome is CORRECT, never to paper over one that is not)
  local w a; w="$(printf '%s\n' "$OUT" | tail -1 | cut -d' ' -f1)"
  for a in "$@"; do [ "$w" = "$a" ] && return 0; done
  return 1
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
quiet() { "$@" >/dev/null 2>&1; }   # a condition whose OUTPUT is noise (a redirect written
                                    # after a `check ... --` list would redirect check itself)
absent() { ! grep -qF -- "$1" "$2"; }
expect() {   # expect <name> <word> [substring-of-reason]
  local name="$1" w="$2" sub="${3:-}"
  if ! word_is "$w"; then bad "$name" "expected word '$w', got: $OUT (rc=$RC)"; return; fi
  if [ -n "$sub" ] && ! contains "$OUT" "$sub"; then bad "$name" "expected reason containing '$sub', got: $OUT"; return; fi
  ok "$name"
}

# --- constants ------------------------------------------------------------------------
PR=7
HEAD1="h1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD2="h2222222aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BSHA1="b1111111"
BSHA2="b2222222"
CI=".github/workflows/ci.yml"
AG=".github/workflows/audit-gate.yml"
CR=".github/workflows/claude-review.yml"
COMMIT_DATE="2026-08-25T10:00:00Z"
T0="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$COMMIT_DATE" +%s 2>/dev/null || date -u -d "$COMMIT_DATE" +%s)"
NOW=$((T0 + 120))   # inside the appear window (T0 + 300)
RUN_CREATED="2026-08-25T10:01:00Z"
RUN_STARTED="2026-08-25T10:01:05Z"
RUN_STARTED_EPOCH=$((T0 + 65))

# --- fixture repo (a real git repo: <primary> is derived from git-common-dir) ---------
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$REPO/.claude/worktrees"
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/x" -b wt-x >/dev/null 2>&1
WT="$REPO/.claude/worktrees/x"
STATE_DIR="$REPO/.claude/sweap-merge"

# --- consumer workflow fixtures --------------------------------------------------------
WFX="$WORK/wf"
mkdir -p "$WFX/consumer-a" "$WFX/consumer-b" "$WFX/synthetic"
# Vendored snapshots, NOT the live consumer checkouts — every number asserted below
# is a property of THESE files and changes only when someone refreshes them on
# purpose (testdata/workflows/README.md says why). The cp is checked: an empty
# fixture dir would make the parser cases vacuously pass instead of failing.
TESTDATA="$(dirname "$0")/testdata/workflows"
cp "$TESTDATA/consumer-a/"*.yml "$WFX/consumer-a/" || { echo "missing fixtures: $TESTDATA/consumer-a" >&2; exit 2; }
cp "$TESTDATA/consumer-b/"*.yml  "$WFX/consumer-b/"  || { echo "missing fixtures: $TESTDATA/consumer-b"  >&2; exit 2; }
cat >"$WFX/synthetic/paths.yml" <<'Y'
name: paths
on:
  pull_request:
    branches: [main]
    paths:
      - 'src/**'
jobs: {}
Y
cat >"$WFX/synthetic/target.yml" <<'Y'
name: target
on:
  pull_request_target:
    branches: [main]
jobs: {}
Y
cat >"$WFX/synthetic/push-only.yml" <<'Y'
name: push-only
on:
  push:
    branches: [main]
jobs: {}
Y
cat >"$WFX/synthetic/other-branch.yml" <<'Y'
name: other
on:
  pull_request:
    branches:
      - release
jobs: {}
Y
cat >"$WFX/synthetic/glob.yml" <<'Y'
name: glob
on:
  pull_request:
    branches: ['release/**']
jobs: {}
Y
cat >"$WFX/synthetic/ignore.yml" <<'Y'
name: ignore
on:
  pull_request:
    branches-ignore: [wip]
jobs: {}
Y
cat >"$WFX/synthetic/flow-list.yml" <<'Y'
name: flow
on: [push, pull_request]
jobs: {}
Y
cat >"$WFX/synthetic/scalar.yml" <<'Y'
name: scalar
on: push
jobs: {}
Y
cat >"$WFX/synthetic/flow-map.yml" <<'Y'
name: flowmap
on: {pull_request: {branches: [main]}}
jobs: {}
Y
cat >"$WFX/synthetic/list-form.yml" <<'Y'
name: listform
on:
  - push
  - pull_request
jobs:
  a:
    timeout-minutes: 50
Y
cat >"$WFX/synthetic/block-branches.yml" <<'Y'
name: blockbranches
on:
  pull_request:
    branches:
      - develop
      - main   # comment
    types: [opened, synchronize]
jobs: {}
Y
cat >"$WFX/synthetic/types-labeled.yml" <<'Y'
name: labeled
on:
  pull_request:
    types: [labeled]
jobs: {}
Y
cat >"$WFX/synthetic/types-block.yml" <<'Y'
name: typesblock
on:
  pull_request:
    types:
      - opened
      - ready_for_review
jobs: {}
Y

# --- fake plugin root: env-driven gate + counting post-merge scripts ------------------
FAKE_PLUGIN="$WORK/plugin"
mkdir -p "$FAKE_PLUGIN/hooks"
cp "$DRIVER" "$FAKE_PLUGIN/hooks/sweap-merge.sh"
FAKE_DRIVER="$FAKE_PLUGIN/hooks/sweap-merge.sh"
SENTINEL=".sweap-merge-test-seams"
: >"$FAKE_PLUGIN/hooks/$SENTINEL"
cat >"$FAKE_PLUGIN/hooks/pre-merge-gate.sh" <<'G'
#!/usr/bin/env bash
input="$(cat)"
[ -n "${GATE_IN:-}" ] && printf '%s\n' "$input" >>"$GATE_IN"
[ -n "${GATE_CWD_FILE:-}" ] && pwd >"$GATE_CWD_FILE"
[ -n "${GATE_ENV_FILE:-}" ] && env >"$GATE_ENV_FILE"
case "${FAKE_GATE:-allow}" in
  deny) jq -cn --arg r "${FAKE_GATE_REASON:-fake deny}" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
  text) printf 'DENY: PR not green\n' ;;
  junk) printf 'warning: something\n'; jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"after junk"}}' ;;
  hang) sleep 60 ;;
  *) : ;;
esac
exit 0
G
for s in post-merge-cleanup.sh post-merge-auditcheck.sh; do
  cat >"$FAKE_PLUGIN/hooks/$s" <<'P'
#!/usr/bin/env bash
me="$(basename "$0")"
input="$(cat)"
[ -n "${PM_LOG:-}" ] && { printf '%s\n' "$me" >>"$PM_LOG"; printf '%s\n' "$input" >"$PM_LOG.$me.in"; pwd >"$PM_LOG.$me.cwd"; }
if [ "$me" = post-merge-auditcheck.sh ] && [ "${PM_RED:-}" = 1 ]; then
  printf '\n################################################################\n## AUDIT DEBT ON MAIN after this merge — audit-gate.sh --check fails:\n##   FAIL: milestone F1 is complete but has no audit record\n################################################################\n' >&2
  exit 2
fi
if [ "$me" = post-merge-cleanup.sh ] && [ "${PM_CTX:-}" = 1 ]; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"sweap: backlog files are STRANDED on branch(es) that nothing will land"}}'
fi
exit 0
P
done
chmod +x "$FAKE_PLUGIN/hooks/"*.sh
# the flake note is written through the plugin's own note writer, resolved from
# the driver's dir as ../tools/sweap-note.mjs: the fake plugin carries a copy
mkdir -p "$FAKE_PLUGIN/tools"
cp "$HERE/../tools/sweap-note.mjs" "$HERE/../tools/sweap-board.lib.mjs" "$FAKE_PLUGIN/tools/"
# a plugin dir with a driver and NO gate (fail closed), and one whose only real
# hook is post-merge-cleanup.sh (the worktree self-skip case)
mkdir -p "$WORK/nowhere/hooks"; cp "$DRIVER" "$WORK/nowhere/hooks/sweap-merge.sh"; : >"$WORK/nowhere/hooks/$SENTINEL"
REALCLEAN_PLUGIN="$WORK/plugin-realclean"
mkdir -p "$REALCLEAN_PLUGIN/hooks"
cp "$FAKE_PLUGIN/hooks/"*.sh "$REALCLEAN_PLUGIN/hooks/"; : >"$REALCLEAN_PLUGIN/hooks/$SENTINEL"
cp "$HERE/post-merge-cleanup.sh" "$HERE/stranded-roadmap.sh" "$HERE/lib-merge-parse.sh" "$REALCLEAN_PLUGIN/hooks/" 2>/dev/null
# the whole REAL hooks dir (real gate, real post-merge hooks, the driver under
# test) with the sentinel: for cases that need the real gate's verdict
REAL_PLUGIN="$WORK/plugin-real"
mkdir -p "$REAL_PLUGIN/hooks"
cp "$HERE/"*.sh "$REAL_PLUGIN/hooks/"; cp "$DRIVER" "$REAL_PLUGIN/hooks/sweap-merge.sh"; : >"$REAL_PLUGIN/hooks/$SENTINEL"
REAL_DRIVER="$REAL_PLUGIN/hooks/sweap-merge.sh"

# --- stub gh ---------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
fix="${GH_FIX:?}"
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
[ -n "${GH_REPO:-}" ] && printf 'ENV GH_REPO=%s\n' "$GH_REPO" >>"${GH_LOG:-/dev/null}"
[ -n "${GH_STUB_SLEEP:-}" ] && sleep "$GH_STUB_SLEEP"
sub="${1:-}"; shift
case "$sub" in
  pr)
    case "${1:-}" in
      view)
        # GH_MUTATE_STATE=<spec file> (line 1: a state file; the rest: a jq
        # filter): rewrite that state file during this call — stands in for a
        # tick that wrote between a reader's snapshot and its claim (the rerun
        # verb's stale-snapshot case). A spec file, because the filter has
        # spaces and brackets and the test env list is word-split.
        if [ -n "${GH_MUTATE_STATE:-}" ] && [ -f "$GH_MUTATE_STATE" ]; then
          mf="$(head -1 "$GH_MUTATE_STATE")"; mfilter="$(tail -n +2 "$GH_MUTATE_STATE")"
          if [ -f "$mf" ]; then jq "$mfilter" "$mf" >"$mf.mut" && mv "$mf.mut" "$mf"; fi
        fi
        if [ -f "$fix/merged.flag" ] && [ -f "$fix/pr.after.json" ]; then cat "$fix/pr.after.json"; else cat "$fix/pr.json"; fi
        exit 0 ;;
      merge)
        : >"$fix/merged.flag"
        case "${GH_MERGE:-ok}" in
          ok) printf '✓ Squashed and merged pull request #%s\n' "$2"; exit 0 ;;
          *)  printf 'GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)\n' >&2; exit 1 ;;
        esac ;;
      list)   # post-merge-cleanup.sh: `gh pr list --head <br> --state merged`
        if [ "${GH_PRLIST_MERGED:-}" = 1 ]; then echo '[{"number":7}]'; else echo '[]'; fi
        exit 0 ;;
    esac ;;
  run)   # the rerun verb: `run list --branch <base> --workflow <file> ...` and `run rerun --failed <id>`
    case "${1:-}" in
      list)
        wf=""
        while [ $# -gt 0 ]; do case "$1" in --workflow) wf="$2"; shift ;; esac; shift; done
        if [ -f "$fix/baserun.$wf.json" ]; then cat "$fix/baserun.$wf.json"; else echo '[]'; fi
        exit 0 ;;
      rerun)
        shift; printf '%s\n' "$*" >>"$fix/rerun.log"
        # GH_RERUN=fail refuses every rerun; GH_RERUN_FAIL_ID=<id> refuses that one
        if [ "${GH_RERUN:-ok}" != ok ] || { [ -n "${GH_RERUN_FAIL_ID:-}" ] && [ "${2:-}" = "$GH_RERUN_FAIL_ID" ]; }; then
          printf 'HTTP 403: This workflow is already running (rerun)\n' >&2; exit 1
        fi
        printf '✓ Requested rerun of failed jobs\n'; exit 0 ;;
    esac
    printf 'stub gh: unhandled run %s\n' "${1:-}" >&2; exit 1 ;;
  api)
    path=""; jqf=""
    while [ $# -gt 0 ]; do
      case "$1" in -H) shift ;; --jq) jqf="$2"; shift ;; -*) ;; *) [ -z "$path" ] && path="$1" ;; esac
      shift
    done
    case "$path" in
      */compare/*)
        if [ -n "$jqf" ]; then printf '%s\n' "${GH_BEHIND:-0}"
        else printf '{"behind_by":%s,"base_commit":{"sha":"%s"}}\n' "${GH_BEHIND:-0}" "${GH_BASE_SHA:-b1111111}"; fi ;;
      */actions/workflows*) cat "$fix/workflows.json" ;;
      */contents/.github/workflows\?ref=*)
        ref="${path##*ref=}"; f="$fix/contents.$ref.json"
        [ -f "$f" ] || f="$fix/contents.json"
        [ -f "$f" ] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; }
        cat "$f" ;;
      */contents/.github/workflows/*)
        p="${path#*contents/.github/workflows/}"; p="${p%%\?*}"
        cat "$fix/wf/$p" 2>/dev/null || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; } ;;
      */actions/runs\?*)
        page="$(printf '%s' "$path" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')"; [ -n "$page" ] || page=1
        if [ -f "$fix/runs.p$page.json" ]; then cat "$fix/runs.p$page.json"
        elif [ -d "$fix/runs.seq" ]; then
          n="$(cat "$fix/runs.seq/n" 2>/dev/null || echo 0)"; n=$((n + 1))
          [ -f "$fix/runs.seq/$n.json" ] || n=$((n - 1))
          echo "$n" >"$fix/runs.seq/n"; cat "$fix/runs.seq/$n.json"
        elif [ "$page" -gt 1 ]; then echo '{"total_count":0,"workflow_runs":[]}'
        else cat "$fix/runs.json"; fi ;;
      *) printf 'stub gh: unhandled api %s\n' "$path" >&2; exit 1 ;;
    esac ;;
  *) printf 'stub gh: unhandled %s\n' "$sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# --- fixture helpers -------------------------------------------------------------------
# The driver runs the gate and the post-merge hooks under `env -i` (pinned PATH +
# allowlist); the stub gh's and the fake hooks' knobs reach them only through
# this test-seam passthrough list (sentinel-gated).
HOOK_PASS="GH_FIX GH_LOG GH_STUB_SLEEP GH_MERGE GH_RERUN GH_RERUN_FAIL_ID GH_MUTATE_STATE GH_PRLIST_MERGED GH_BEHIND GH_BASE_SHA PM_LOG PM_RED PM_CTX GATE_IN GATE_CWD_FILE GATE_ENV_FILE FAKE_GATE FAKE_GATE_REASON"
FIX=""
write_pr() {   # write_pr [file] [state] [head] [rollup: green|failure]
  local f="${1:-pr.json}" st="${2:-OPEN}" h="${3:-$HEAD1}" roll="${4:-green}" mc="null" rollup
  [ "$st" = "MERGED" ] && mc='{"oid":"mmmmmmmm"}'
  case "$roll" in
    failure) rollup='[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
    *)       rollup='[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"review","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"audit-gate","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
  esac
  printf '{"number":%s,"state":"%s","headRefOid":"%s","baseRefName":"main","mergeCommit":%s,"commits":[{"oid":"%s","committedDate":"%s"}],"statusCheckRollup":%s,"mergeStateStatus":"CLEAN","files":[]}\n' \
    "$PR" "$st" "$h" "$mc" "$h" "$COMMIT_DATE" "$rollup" >"$FIX/$f"
}
write_workflows() {   # write_workflows path:state ...
  local first=1 e
  { printf '{"total_count":%s,"workflows":[' "$#"
    for e in "$@"; do
      [ "$first" = 1 ] || printf ','; first=0
      printf '{"id":1,"name":"%s","path":"%s","state":"%s"}' "${e%%:*}" "${e%%:*}" "${e##*:}"
    done
    printf ']}\n'; } >"$FIX/workflows.json"
}
write_contents() {   # write_contents <file> path ...
  local f="$1" first=1 p; shift
  { printf '['
    for p in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '{"name":"%s","path":"%s","type":"file"}' "$(basename "$p")" "$p"; done
    printf ']\n'; } >"$FIX/$f"
}
run() {   # run <id> <path> <status> <conclusion|null> [attempt] [created] [started] [pr|none]
  local concl="null" prs
  [ "$4" != "null" ] && concl="\"$4\""
  case "${8:-$PR}" in none) prs='[]' ;; *) prs="[{\"number\":${8:-$PR}}]" ;; esac
  printf '{"id":%s,"name":"%s","path":"%s","head_sha":"%s","event":"%s","status":"%s","conclusion":%s,"run_attempt":%s,"created_at":"%s","run_started_at":"%s","pull_requests":%s}' \
    "$1" "$(basename "$2" .yml)" "$2" "$HEAD1" "${EVT:-pull_request}" "$3" "$concl" "${5:-1}" "${6:-$RUN_CREATED}" "${7:-$RUN_STARTED}" "$prs"
}
runs_doc() {   # runs_doc <total> obj...  -> JSON document on stdout
  local total="$1" first=1 o; shift
  printf '{"total_count":%s,"workflow_runs":[' "$total"
  for o in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '%s' "$o"; done
  printf ']}\n'
}
write_runs() { runs_doc "$#" "$@" >"$FIX/runs.json"; }
all_green() { write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"; }

newcase() {   # newcase <name>: fresh fixtures (all green by default) + fresh state dir
  FIX="$WORK/fix/$1"
  rm -rf "$FIX" "$STATE_DIR"; mkdir -p "$FIX/wf"
  cp "$WFX/consumer-a/"*.yml "$FIX/wf/"
  write_pr
  write_workflows "$AG:active" "$CI:active" "$CR:active"
  write_contents contents.json "$AG" "$CI" "$CR"
  all_green
  : >"$FIX/gh.log"; : >"$FIX/pm.log"
  XENV=""
}
drive() {   # drive <verb> [args...] — runs the driver ($DRV, default the fake-plugin copy) with the stub env from $DIR (default REPO)
  local dir="${DIR:-$REPO}"
  # shellcheck disable=SC2086  # XENV is a deliberate list of K=V words
  OUT="$(cd "$dir" && env PATH="$STUB_BIN:$PATH" GH_FIX="$FIX" GH_LOG="$FIX/gh.log" PM_LOG="$FIX/pm.log" \
        SWEAP_MERGE_SLEEP=0 SWEAP_MERGE_MAX_ITER="${MAX_ITER:-1}" \
        SWEAP_MERGE_NOW="${TNOW:-$NOW}" SWEAP_MERGE_SESSION=test SWEAP_MERGE_GH_TIMEOUT=5 GH_BASE_SHA="${BASE_SHA:-$BSHA1}" \
        SWEAP_MERGE_GH="$STUB_BIN/gh" SWEAP_MERGE_HOOK_ENV_PASS="$HOOK_PASS" \
        $XENV bash "${DRV:-$FAKE_DRIVER}" "$@" 2>"$FIX/stderr")"
  RC=$?
}
drive_bg() {   # drive_bg <outfile> <verb> [args...] — same env, backgrounded, stdout to a file
  local out="$1"; shift
  ( cd "$REPO" && env PATH="$STUB_BIN:$PATH" GH_FIX="$FIX" GH_LOG="$FIX/gh.log" PM_LOG="$FIX/pm.log" \
        SWEAP_MERGE_SLEEP=0 SWEAP_MERGE_MAX_ITER=1 SWEAP_MERGE_NOW="$NOW" \
        SWEAP_MERGE_SESSION=test SWEAP_MERGE_GH_TIMEOUT=5 GH_BASE_SHA="$BSHA1" \
        SWEAP_MERGE_GH="$STUB_BIN/gh" SWEAP_MERGE_HOOK_ENV_PASS="$HOOK_PASS" \
        bash "$FAKE_DRIVER" "$@" >"$out" 2>/dev/null ) &
}
state() { jq -r "$1" "$STATE_DIR/$PR.json" 2>/dev/null; }
merges_in_log() { grep -c '^pr merge ' "$FIX/gh.log" 2>/dev/null | tr -d ' '; }
classify() {   # classify <file> <base> -> "result|why|timeout" (driver sourced as a library)
  # shellcheck disable=SC1090
  ( export SWEAP_MERGE_LIB=1; . "$DRIVER"; sm_classify_workflow "$1" "$2"; printf '%s|%s|%s' "$CW_RESULT" "$CW_WHY" "$CW_TIMEOUT" )
}
mk_lock() {   # mk_lock <owner> <epoch> <pid> <heartbeat>
  mkdir -p "$STATE_DIR/$PR.lock"
  printf 'owner=%s\nepoch=%s\npid=%s\nhost=%s\nheartbeat=%s\n' "$1" "$2" "$3" "$(hostname)" "$4" >"$STATE_DIR/$PR.lock/info"
}

# ======================================================================================
printf '== E: the expected set (§5)\n'
for repo in consumer-a consumer-b; do
  for f in ci.yml audit-gate.yml claude-review.yml; do
    r="$(classify "$WFX/$repo/$f" main)"
    check "E $repo/$f classifies as member" [ "${r%%|*}" = "member" ]
  done
done
r="$(classify "$WFX/consumer-a/ci.yml" main)"; check "E consumer-a/ci.yml timeout-minutes max = 60 (of 5/15/60/5 — the MAX, not the first or the last)" [ "${r##*|}" = "60" ]
r="$(classify "$WFX/consumer-a/ci.yml" develop)"; check "E branches: [main] excludes base develop" [ "${r%%|*}" = "excluded" ]
r="$(classify "$WFX/synthetic/paths.yml" main)"; check "E paths: => undecidable" [ "${r%%|*}" = "undecidable" ] && contains "$r" paths
r="$(classify "$WFX/synthetic/target.yml" main)"; check "E pull_request_target => undecidable" [ "${r%%|*}" = "undecidable" ]
r="$(classify "$WFX/synthetic/push-only.yml" main)"; check "E push-only => excluded" [ "${r%%|*}" = "excluded" ]
r="$(classify "$WFX/synthetic/other-branch.yml" main)"; check "E branches without base => excluded" [ "${r%%|*}" = "excluded" ]
r="$(classify "$WFX/synthetic/glob.yml" main)"; check "E glob in branches => undecidable" [ "${r%%|*}" = "undecidable" ]
r="$(classify "$WFX/synthetic/ignore.yml" main)"; check "E branches-ignore => undecidable" [ "${r%%|*}" = "undecidable" ]
r="$(classify "$WFX/synthetic/flow-list.yml" main)"; check "E on: [push, pull_request] => member" [ "${r%%|*}" = "member" ]
r="$(classify "$WFX/synthetic/scalar.yml" main)"; check "E on: push scalar => excluded" [ "${r%%|*}" = "excluded" ]
r="$(classify "$WFX/synthetic/flow-map.yml" main)"; check "E flow-style on: mapping => undecidable" [ "${r%%|*}" = "undecidable" ]
r="$(classify "$WFX/synthetic/list-form.yml" main)"; check "E on: list form with pull_request => member, timeout 50" [ "$r" = "member||50" ]
r="$(classify "$WFX/synthetic/block-branches.yml" main)"; check "E block-list branches naming main (with comment) => member" [ "${r%%|*}" = "member" ]
r="$(classify "$WFX/synthetic/types-labeled.yml" main)"; check "E types: [labeled] (never runs on synchronize) => undecidable" [ "${r%%|*}" = "undecidable" ] && contains "$r" "types:"
r="$(classify "$WFX/synthetic/types-block.yml" main)"; check "E block-list types: without synchronize => undecidable" [ "${r%%|*}" = "undecidable" ]
r="$(classify "$WFX/consumer-a/claude-review.yml" main)"; check "E consumer-a/claude-review.yml types: [opened, synchronize, ready_for_review] stays member" [ "${r%%|*}" = "member" ]

# --- DRIFT: the LIVE consumer checkouts, if this machine has them -------------------
# The snapshots above keep the suite reproducible; this section keeps it honest. It
# asserts only INVARIANTS — still a `member`, still a positive timeout — never a
# specific number, because a consumer retuning its own CI is not a sweap regression
# and must never red sweap's merge bar. What it does catch is a consumer editing its
# workflows into a shape the driver cannot classify (adding `paths:`, narrowing
# `types:`, switching to `pull_request_target`): that makes the expected set
# undecidable and stalls every merge in that repo, and it should be loud HERE rather
# than discovered by a session whose merge hangs. Skips silently when a checkout is
# absent. Opt in with SWEAP_LIVE_CONSUMERS, a colon-separated list of consumer
# checkout paths (e.g. SWEAP_LIVE_CONSUMERS=~/code/app:~/code/site).
IFS=: read -r -a live_consumers <<<"${SWEAP_LIVE_CONSUMERS:-}"
for live in ${live_consumers[@]+"${live_consumers[@]}"}; do
  [ -d "$live/.github/workflows" ] || continue
  repo="$(basename "$live")"
  for f in "$live"/.github/workflows/*.yml; do
    [ -f "$f" ] || continue
    r="$(classify "$f" main)"
    case "${r%%|*}" in
      member)
        check "DRIFT live $repo/$(basename "$f") member, timeout > 0" [ "${r##*|}" -gt 0 ] ;;
      undecidable)
        check "DRIFT live $repo/$(basename "$f") is UNDECIDABLE (${r#*|}) — merges in $repo will stall" false ;;
      *) : ;;  # `excluded` is legitimate: not every workflow runs on a PR to main
    esac
  done
done

newcase e-disabled
write_workflows "$AG:active" "$CI:disabled_manually" "$CR:active"
drive tick "$PR"; expect "E disabled workflow => undecidable" undecidable disabled_manually
check "E undecidable exits 1" [ "$RC" = 1 ]

newcase e-empty
cp "$WFX/synthetic/push-only.yml" "$FIX/wf/"
write_workflows ".github/workflows/push-only.yml:active"
write_contents contents.json ".github/workflows/push-only.yml"
drive tick "$PR"; expect "E empty => undecidable" undecidable "no pull_request workflow"

newcase e-paths
cp "$WFX/synthetic/paths.yml" "$FIX/wf/"
write_workflows "$AG:active" "$CI:active" "$CR:active" ".github/workflows/paths.yml:active"
write_contents contents.json "$AG" "$CI" "$CR" ".github/workflows/paths.yml"
drive tick "$PR"; expect "E paths: on base => undecidable (file named)" undecidable "paths.yml: paths"

newcase e-target
cp "$WFX/synthetic/target.yml" "$FIX/wf/"
write_contents contents.json "$AG" "$CI" "$CR" ".github/workflows/target.yml"
write_workflows "$AG:active" "$CI:active" "$CR:active" ".github/workflows/target.yml:active"
drive tick "$PR"; expect "E pull_request_target on base => undecidable" undecidable pull_request_target

newcase e-basemove
drive tick "$PR"; expect "E first tick on base b1 is green->merged" merged
check "E expected_from = b1" [ "$(state .expected_from)" = "$BSHA1" ]
check "E expected has 3 members" [ "$(state '.expected|length')" = 3 ]
newcase e-basemove2
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "E pending on base b1" pending
write_contents "contents.$BSHA2.json" "$AG" "$CI"
BASE_SHA="$BSHA2" drive tick "$PR"
check "E base move recomputes E (expected_from = b2)" [ "$(state .expected_from)" = "$BSHA2" ]
check "E base move recomputes E (2 members)" [ "$(state '.expected|length')" = 2 ]
check "E base_sha updated" [ "$(state .base_sha)" = "$BSHA2" ]

newcase e-removed
write_contents "contents.$HEAD1.json" "$AG" "$CI"   # head dropped claude-review.yml
drive tick "$PR"; expect "E path removed on head => failed" failed "removed on head"

newcase e-no-workflows-dir
rm -f "$FIX/contents.json"   # base has no .github/workflows at all (404)
drive tick "$PR"; expect "E base without .github/workflows => undecidable (not an API retry)" undecidable "no .github/workflows"
check "E no-workflows-dir: exits 1, no merge" [ "$RC" = 1 ] -- [ "$(merges_in_log)" = 0 ]

# ======================================================================================
printf '== §6 table, row by row\n'
newcase s-missing
write_runs
drive tick "$PR"; expect "§6 no run, before appear_deadline => missing" missing "no run yet"
check "§6 appear_deadline = max(committedDate, arm_at) + 300 (arm 120 s after the commit => arm_at + 300)" [ "$(state .appear_deadline)" = "$((NOW + 300))" ]
TNOW=$((NOW + 301)) drive tick "$PR"; expect "§6 no run, after appear_deadline => failed: missing <path>" failed "missing .github/workflows/"
check "deadline survived re-invocation (appear_deadline unchanged)" [ "$(state .appear_deadline)" = "$((NOW + 300))" ]
newcase s-missing-old-commit
write_runs
TNOW=$((T0 + 7200)) drive tick "$PR"; expect "§6 committedDate hours old (commit-then-push-later) + no runs yet => missing, not failed" missing "no run yet"
check "§6 old commit: appear_deadline anchored on arm time" [ "$(state .appear_deadline)" = "$((T0 + 7200 + 300))" ]
newcase s-missing-future-commit
write_runs
TNOW=$((T0 - 60)) drive tick "$PR"; expect "§6 committedDate after arm (clock skew) => still anchored on the later of the two" missing
check "§6 future commit: appear_deadline = committedDate + 300" [ "$(state .appear_deadline)" = "$((T0 + 300))" ]

newcase s-pending
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" queued null)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 queued/in_progress before complete_deadline => pending" pending queued
check "§6 complete_deadline = arm time + 2×60min (the later of run_started_at and arm_at; consumer-a's ci timeout, snapshot)" [ "$(state .complete_deadline)" = "$((NOW + 7200))" ]
check "§6 expected_timeout_min persisted" [ "$(state .expected_timeout_min)" = 60 ]
check "§6 observed records run_id/attempt/status" [ "$(state ".observed[\"$CI\"].run_id")" = 101 ]
TNOW=$((NOW + 7201)) drive tick "$PR"; expect "§6 in_progress after complete_deadline => timed_out" timed_out complete_deadline
# A stored timed_out is re-armed by the next deliberate tick with a FRESH window
# anchored on the new arm time (consumer PR #407/#408, 2026-09-24: every hand watch
# after the runner fleet came back died on the old deadline within seconds).
TNOW=$((NOW + 7300)) drive tick "$PR"; expect "§6 tick after timed_out re-arms => pending again" pending queued
check "§6 re-arm: arm_at is the new tick's time" [ "$(state .arm_at)" = "$((NOW + 7300))" ]
check "§6 re-arm: complete_deadline = new arm_at + window (run_started is older)" [ "$(state .complete_deadline)" = "$((NOW + 7300 + 7200))" ]
TNOW=$((NOW + 7300 + 7201)) drive tick "$PR"; expect "§6 the fresh window is finite: times out again" timed_out complete_deadline
newcase s-pending-armed-early
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" queued null)" "$(run 103 "$CR" completed success)"
TNOW=$((RUN_STARTED_EPOCH - 100)) drive tick "$PR"; expect "§6 a watch armed before the run started still anchors on the run start" pending queued
check "§6 early arm: complete_deadline = run_started_at + window (the later of the two)" [ "$(state .complete_deadline)" = "$((RUN_STARTED_EPOCH + 7200))" ]
newcase s-pending-armed-late
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" queued null)" "$(run 103 "$CR" completed success)"
TNOW=$((RUN_STARTED_EPOCH + 5000)) drive tick "$PR"; expect "§6 a watch armed long after the run was created is not born dead" pending queued
check "§6 late arm: complete_deadline anchored on arm_at, the later of the two" [ "$(state .complete_deadline)" = "$((RUN_STARTED_EPOCH + 5000 + 7200))" ]

newcase s-waiting
write_runs "$(run 101 "$CI" waiting null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 status waiting => attended" attended "needs approval"

newcase s-action-required
write_runs "$(run 101 "$CI" completed action_required)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 completed/action_required (0 check runs) => attended" attended "needs approval"

# A run GitHub reports as `pending` or `requested` is queued — behind a
# `concurrency:` group or a saturated self-hosted fleet — not awaiting a human.
# On a consumer every `attended` the driver ever emitted (10 of 145 state files, PRs
# #236 … #385) was this shape, and every one of those PRs then merged untouched;
# a genuine approval hold reports `waiting` or `action_required`. `attended` is
# terminal, so mislabelling the fleet's most common state halted unattended
# lanes on it (a consumer's roadmap/discovered/…-750948.md, lane lessons 10 and 17).
newcase s-pending-status
write_runs "$(run 101 "$CI" pending null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 status pending (queued behind concurrency/fleet) => pending, never attended" pending pending
newcase s-requested-status
write_runs "$(run 101 "$CI" requested null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 status requested => pending, never attended" pending requested

newcase s-green
drive tick "$PR"; expect "§6 all success + behind 0 => green -> merged" merged
check "§6 merged exits 0" [ "$RC" = 0 ]
check "§6 history shows missing->green->merging->merged" [ "$(state '[.history[].to] | join(",")')" = "green,merging,merged" ]
check "§6 verdict written at green" [ "$(state .verdict.head)" = "$HEAD1" ]

newcase s-startup
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 104 ".github/workflows/ci.yml" completed startup_failure 1 "2026-08-25T09:00:00Z" "" )"
jq '.workflow_runs[3].name = "BuildFailed" | .workflow_runs[3].path = ".github/workflows/BuildFailed" | .workflow_runs[3].workflow_id = 0' "$FIX/runs.json" >"$FIX/r.tmp" && mv "$FIX/r.tmp" "$FIX/runs.json"
drive tick "$PR"; expect "§6 startup_failure on synthetic BuildFailed => failed" failed startup_failure
newcase s-startup-push
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(EVT=push run 109 ".github/workflows/push-only.yml" completed startup_failure)"
drive tick "$PR"; expect "§6 startup_failure on a push-event run on H (any run on H) => failed" failed "push-only.yml startup_failure"
check "§6 push startup_failure: no merge" [ "$(merges_in_log)" = 0 ]

for c in failure cancelled timed_out skipped neutral stale; do
  newcase "s-$c"
  write_runs "$(run 101 "$CI" completed "$c")" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
  drive tick "$PR"; expect "§6 conclusion $c => failed: <path> $c" failed "ci.yml $c"
done

newcase s-unknown
write_runs "$(run 101 "$CI" completed null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 unknown status/conclusion pair => failed: unknown" failed "unknown completed/null"

newcase s-extra
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 105 ".github/workflows/extra.yml" completed failure)"
drive tick "$PR"; expect "§6 extra failing pull_request run on H (path not in E) => failed (not on base)" failed "extra.yml failure (not on base)"
check "§6 extra failing run: no merge issued" [ "$(merges_in_log)" = 0 ]

newcase s-extra-green
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 105 ".github/workflows/extra.yml" completed success)"
drive tick "$PR"; expect "§6 extra succeeding run on H still green" merged
newcase s-extra-pending
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 105 ".github/workflows/extra.yml" in_progress null)"
drive tick "$PR"; expect "§6 extra in_progress run on H (path not in E) => pending (not on base), waits" pending "extra.yml in_progress (not on base)"
check "§6 extra pending run: no merge issued" [ "$(merges_in_log)" = 0 ]

newcase s-reopen
write_runs "$(run 101 "$CI" completed success 1 "2026-08-25T10:01:00Z")" "$(run 106 "$CI" completed failure 1 "2026-08-25T10:03:00Z")" \
  "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 reopen duplicate: newest by created_at wins (failure)" failed "ci.yml failure"
newcase s-reopen2
write_runs "$(run 106 "$CI" completed failure 1 "2026-08-25T10:01:00Z")" "$(run 101 "$CI" completed success 1 "2026-08-25T10:03:00Z")" \
  "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 reopen duplicate: newest by created_at wins (success)" merged
check "§6 observed points at the newest run" [ "$(state ".observed[\"$CI\"].run_id")" = 101 ]

newcase s-attempt
write_runs "$(run 101 "$CI" completed failure 1)" "$(run 101 "$CI" completed success 2)" \
  "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "§6 same created_at: run_attempt 2 beats attempt 1" merged
check "§6 observed attempt = 2" [ "$(state ".observed[\"$CI\"].attempt")" = 2 ]

newcase s-prfilter
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 107 "$CI" completed failure 1 "2026-08-25T10:05:00Z" "$RUN_STARTED" 99)"
drive tick "$PR"; expect "§6 pull_requests[] filter: another PR's run on H is ignored" merged
newcase s-prfilter-empty
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(run 107 "$CI" completed failure 1 "2026-08-25T10:05:00Z" "$RUN_STARTED" none)"
drive tick "$PR"; expect "§6 pull_requests[] empty => run counts" failed "ci.yml failure"
newcase s-push-event
write_runs "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" \
  "$(EVT=push run 108 "$CI" completed failure 1 "2026-08-25T10:05:00Z")"
drive tick "$PR"; expect "§6 non-pull_request event runs are not evaluated" merged

newcase s-paginate
{ printf '{"total_count":150,"workflow_runs":['
  for i in $(seq 1 100); do [ "$i" = 1 ] || printf ','; run "$((200 + i))" ".github/workflows/w$i.yml" completed success; done
  printf ']}\n'; } >"$FIX/runs.p1.json"
echo '{"total_count":150,"workflow_runs":[]}' >"$FIX/runs.p2.json"
drive tick "$PR"; expect "§6 pagination overflow (total_count > returned) => undecidable" undecidable "total_count 150 > 100"
newcase s-total-nan
all_green; jq '.total_count = "many"' "$FIX/runs.json" >"$FIX/r.tmp" && mv "$FIX/r.tmp" "$FIX/runs.json"
drive tick "$PR"; expect "§6 non-numeric total_count => undecidable" undecidable "not a number"
newcase s-argmax
# 100 real-sized (~13 KB) run objects on one page: the array must never travel through argv
pad="$(head -c 13000 /dev/zero | tr '\0' x)"
{ printf '{"total_count":100,"workflow_runs":['
  printf '%s,%s,%s' "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
  for i in $(seq 1 97); do printf ',%s' "$(run "$((300 + i))" ".github/workflows/w$i.yml" completed success | sed "s/}\$/,\"pad\":\"$pad\"}/")"; done
  printf ']}\n'; } >"$FIX/runs.p1.json"
echo '{"total_count":100,"workflow_runs":[]}' >"$FIX/runs.p2.json"
drive tick "$PR"; expect "§6 100 × 13 KB runs (1.3 MB > ARG_MAX) evaluate => merged" merged

newcase s-behind
XENV="GH_BEHIND=2" drive tick "$PR"; expect "§6 compare behind_by > 0 => behind" behind "behind main by 2"
check "§6 behind: no merge issued" [ "$(merges_in_log)" = 0 ]

# ======================================================================================
printf '== Lease (§4)\n'
newcase l-double
sleep 30 & LIVE=$!
mk_lock "other:$LIVE" 1 "$LIVE" "$NOW"
drive tick "$PR"; expect "lease: double launch => held-by:<owner>" "held-by:other:$LIVE"
check "lease: held-by leaves the lock alone" [ -d "$STATE_DIR/$PR.lock" ]
check "lease: held-by makes no gh call" [ ! -s "$FIX/gh.log" ]
newcase l-stale
mk_lock "other:$LIVE" 4 "$LIVE" "$((NOW - 1000))"
drive tick "$PR"; expect "lease: stale heartbeat (live pid) => takeover proceeds" merged
check "lease: takeover increments epoch (4 -> 5)" [ "$(state .lease.epoch)" = 5 ]
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
newcase l-deadpid
true & DEAD=$!; wait "$DEAD" 2>/dev/null   # a pid that has exited (never kill a forking child: it may run our EXIT trap)
mk_lock "other:$DEAD" 2 "$DEAD" "$NOW"
drive tick "$PR"; expect "lease: fresh heartbeat but dead pid => takeover" merged
check "lease: dead-pid takeover increments epoch (2 -> 3)" [ "$(state .lease.epoch)" = 3 ]
check "lease: lock released after the tick" [ ! -d "$STATE_DIR/$PR.lock" ]

newcase l-fenced
r="$( cd "$REPO" && SWEAP_MERGE_LIB=1 SWEAP_MERGE_NOW="$NOW" SWEAP_MERGE_SESSION=test bash -c '
  . "$1"; sm_resolve_primary; sm_bind_pr "$2"; sm_state_read
  sm_lease_claim || { echo claim-failed; exit 0; }
  e1=$SM_EPOCH
  sm_set ".state = \"pending\""
  sm_state_write && w1=ok || w1=fail
  # another poller takes over: its info carries a higher epoch
  printf "owner=other:1\nepoch=%s\npid=1\nhost=%s\nheartbeat=%s\n" "$((e1 + 1))" "$(hostname)" "$SWEAP_MERGE_NOW" >"$SM_LOCK/info"
  sm_state_write && w2=ok || w2=fail
  # restore our lock, but a newer version file already exists (ln refuses)
  printf "owner=%s\nepoch=%s\npid=%s\nhost=%s\nheartbeat=%s\n" "$SM_OWNER" "$e1" "$$" "$(hostname)" "$SWEAP_MERGE_NOW" >"$SM_LOCK/info"
  seq=$(jq -r .seq "$SM_FILE"); : >"$SM_FILE.v$((seq + 1))"
  sm_state_write && w3=ok || w3=fail
  echo "$e1 $w1 $w2 $w3"' _ "$FAKE_DRIVER" "$PR" )"
check "lease: holder writes; stale holder (epoch superseded) fenced write fails; newer version file blocks ln" [ "$r" = "1 ok fail fail" ]

newcase l-race
# two ticks launched in the same instant, 10 times: exactly one held-by each time
race_bad=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  rm -rf "$STATE_DIR" "$FIX/merged.flag"
  drive_bg "$FIX/race.a" tick "$PR"; drive_bg "$FIX/race.b" tick "$PR"
  wait
  nheld="$(cat "$FIX/race.a" "$FIX/race.b" | grep -c '^held-by:')"
  nmerged="$(cat "$FIX/race.a" "$FIX/race.b" | grep -c '^merged ')"
  [ "$nheld" = 1 ] && [ "$nmerged" = 1 ] || { race_bad=$((race_bad + 1)); printf '     race %s: %s | %s\n' "$i" "$(cat "$FIX/race.a")" "$(cat "$FIX/race.b")"; }
done
check "lease: simultaneous double launch x10 => exactly one held-by and one merged every time" [ "$race_bad" = 0 ]
check "lease: simultaneous double launch never issued two merges" [ "$(merges_in_log)" = 10 ]

newcase l-renew-fenced
r="$( cd "$REPO" && SWEAP_MERGE_LIB=1 SWEAP_MERGE_NOW="$NOW" SWEAP_MERGE_SESSION=test bash -c '
  . "$1"; sm_resolve_primary; sm_bind_pr "$2"; sm_state_read
  sm_lease_claim || { echo claim-failed; exit 0; }
  e1=$SM_EPOCH
  # taken over: the lock now carries another owner with a higher epoch
  printf "owner=other:1\nepoch=%s\npid=1\nhost=%s\nheartbeat=%s\n" "$((e1 + 1))" "$(hostname)" "$SWEAP_MERGE_NOW" >"$SM_LOCK/info"
  sm_lease_renew && r=renewed || r=refused
  sm_lock_read
  echo "$r $LK_OWNER $LK_EPOCH $SM_STATE"' _ "$FAKE_DRIVER" "$PR" )"
check "lease: renew after a takeover is refused and leaves the lock untouched (owner/epoch of the taker)" [ "$r" = "refused other:1 2 failed" ]

newcase l-version-file
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "version file: tick 1 => pending" pending
seq0="$(state .seq)"
: >"$STATE_DIR/$PR.json.v$((seq0 + 1))"   # a writer crashed between ln and mv
all_green
drive tick "$PR"; expect "version file: a fresh leftover .v<N+1> is named, not blamed on the lease" failed "version file"
check "version file: the reason names the file" contains "$OUT" "$PR.json.v$((seq0 + 1))"
check "version file: no merge while blocked" [ "$(merges_in_log)" = 0 ]
touch -t 202001010000 "$STATE_DIR/$PR.json.v$((seq0 + 1))"   # older than SM_STALE
drive tick "$PR"; expect "version file: a leftover older than SM_STALE is swept and the PR proceeds" merged
check "version file: swept" [ ! -e "$STATE_DIR/$PR.json.v$((seq0 + 1))" ]

newcase l-takeover-storm
# H3: 40 simultaneous library-level claims on a STALE lock (epoch 5, live pid,
# heartbeat 1000 s old; state file epoch 1), five rounds. The SAFETY invariants
# are exact: exactly one claim, at epoch 6 (never the state file's 1+1), the
# lock left at 6, all 40 claimants accounted for, and nothing on stderr. Each
# claimant holds its claim for 0.3 s so a second "winner" cannot hide behind a
# fast release.
#
# The loser's `held-by=<owner>` is a DIAGNOSTIC MESSAGE, not a lock invariant:
# it is whatever sm_lease_lost_to could read from the lock path during a 0.5 s
# best-effort re-read, and the winner's rename-back may legitimately land after
# that window closes on a loaded machine. So "how many losers name the winner"
# is timing-bound and must never be asserted (a `>= 20` threshold here was the
# maintainer's flake: 16/39 on a loaded box, with every safety invariant intact).
# What IS an invariant is that no loser ever names an ILLEGITIMATE holder. The
# only owners that may ever appear on the lock path are the displaced stale
# owner (`other:$LIVE`) and the one winner, so a loser may print exactly:
#   - the winner            — it re-read after the rename-back landed;
#   - `other:$LIVE`         — it re-read the stale lock it is displacing, which
#                             genuinely held the path at that instant;
#   - `?`                   — the driver's explicit "I could not read the lock",
#                             which names nobody (mkdir/write gap, or the whole
#                             re-read window fell inside the rename gap).
# A THIRD party (any other `test:<pid>`) would mean a second claimant wrote the
# lock — a fencing bug — and an EMPTY owner would mean the verdict line
# `held-by:` names no one at all. Both are hard failures at any load.
LIVE=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
storm_bad=0
for round in 1 2 3 4 5; do
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  echo '{"state":"pending","seq":3,"lease":{"owner":"x","epoch":1,"heartbeat_at":0}}' >"$STATE_DIR/$PR.json"
  mk_lock "other:$LIVE" 5 "$LIVE" "$((NOW - 1000))"
  : >"$FIX/claims"
  for k in $(seq 1 40); do
    ( cd "$REPO" && SWEAP_MERGE_LIB=1 SWEAP_MERGE_NOW="$NOW" SWEAP_MERGE_SESSION=test bash -c '
      . "$1"; sm_resolve_primary; sm_bind_pr "$2"; sm_state_read
      if sm_lease_claim; then sleep 0.3; sm_lock_read; echo "claimed epoch=$SM_EPOCH lock=$LK_OWNER/$LK_EPOCH me=$SM_OWNER"; else echo "held-by=$SM_HELD_BY"; fi' _ "$FAKE_DRIVER" "$PR" >>"$FIX/claims" 2>>"$FIX/claims.err" ) &
  done
  wait
  nc="$(grep -c '^claimed' "$FIX/claims")"
  winner="$(sed -n 's/^claimed .* me=\(.*\)$/\1/p' "$FIX/claims" | head -1)"
  nlose="$(grep -c '^held-by=' "$FIX/claims")"
  # every loser line that is NOT one of the three legitimate namings (see above)
  bogus="$(grep '^held-by=' "$FIX/claims" \
           | grep -v -x -F -e "held-by=$winner" -e "held-by=other:$LIVE" -e 'held-by=?' | tr '\n' ';')"
  lock_epoch="$(sed -n 's/^epoch=//p' "$STATE_DIR/$PR.lock/info" 2>/dev/null)"
  if [ "$nc" != 1 ] || ! grep -q "^claimed epoch=6 lock=$winner/6 " "$FIX/claims" || [ "$lock_epoch" != 6 ] \
     || [ "$nlose" != 39 ] || [ -n "$bogus" ] || [ -s "$FIX/claims.err" ]; then
    storm_bad=$((storm_bad + 1))
    printf '     round %s: claimed=%s lock_epoch=%s losers=%s illegitimate-naming=[%s] | %s | err: %s\n' \
      "$round" "$nc" "$lock_epoch" "$nlose" "$bogus" \
      "$(grep '^claimed' "$FIX/claims" | tr '\n' ';')" "$(head -2 "$FIX/claims.err" | tr '\n' ' ')"
  fi
done
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
check "lease: 40-way takeover storm x5 => exactly one claim at epoch 6, lock at 6, all 39 losers name a legitimate holder (winner, the displaced owner, or '?'), no stderr" [ "$storm_bad" = 0 ]
check "lease: takeover storm leaves no mutex or renamed lock behind" [ -z "$(ls -d "$STATE_DIR/$PR.lock.takeover" "$STATE_DIR/$PR.lock.stale."* 2>/dev/null)" ]
newcase l-takeover-crashed
# a claimant that died mid-takeover: mutex + renamed lock (epoch 7) older than
# SM_STALE. The next claim restores it and takes it over: epoch 8, not 2.
echo '{"state":"pending","seq":3,"lease":{"owner":"x","epoch":1,"heartbeat_at":0}}' >"$STATE_DIR/$PR.json"
mkdir -p "$STATE_DIR/$PR.lock.takeover" "$STATE_DIR/$PR.lock.stale.99999"
printf 'owner=dead:1\nepoch=7\npid=1\nhost=%s\nheartbeat=%s\n' "$(hostname)" "$((NOW - 1000))" >"$STATE_DIR/$PR.lock.stale.99999/info"
touch -t 202001010000 "$STATE_DIR/$PR.lock.takeover"
drive tick "$PR"; expect "lease: crashed takeover (stale mutex + renamed lock) is recovered and the tick proceeds" merged
check "lease: recovered epoch continues from the renamed lock (7 -> 8)" [ "$(state .lease.epoch)" = 8 ]
check "lease: recovery leaves no mutex or renamed lock" [ -z "$(ls -d "$STATE_DIR/$PR.lock.takeover" "$STATE_DIR/$PR.lock.stale."* 2>/dev/null)" ]
newcase l-fresh-floor
# a renamed lock at epoch 9 still present (takeover in flight elsewhere, no
# mutex): a fresh claim must not restart at 2
mkdir -p "$STATE_DIR/$PR.lock.stale.4242"
printf 'owner=o:1\nepoch=9\npid=1\nhost=h\nheartbeat=0\n' >"$STATE_DIR/$PR.lock.stale.4242/info"
drive tick "$PR"; expect "lease: fresh claim beside a renamed lock proceeds" merged
check "lease: fresh epoch = max(state, renamed lock) + 1 = 10" [ "$(state .lease.epoch)" = 10 ]
rm -rf "$STATE_DIR/$PR.lock.stale.4242"

# ======================================================================================
printf '== Gate integration (D3)\n'
newcase g-deny
XENV="FAKE_GATE=deny FAKE_GATE_REASON=merge-gate:_PR_not_green GATE_IN=$FIX/gate.in" drive tick "$PR"
expect "gate: deny => failed: gate: <reason>" failed "gate: merge-gate:_PR_not_green"
check "gate: deny => the stub never saw gh pr merge" [ "$(merges_in_log)" = 0 ]
check "gate: state is failed, verdict kept" [ "$(state .state)" = failed ] -- [ "$(state .verdict.head)" = "$HEAD1" ]
gin="$(cat "$FIX/gate.in")"
check "gate: payload is PreToolUse Bash 'gh pr merge <pr> --squash' with cwd=<primary>" \
  [ "$(printf '%s' "$gin" | jq -r '.tool_name + "|" + .tool_input.command + "|" + .cwd')" = "Bash|gh pr merge $PR --squash|$REPO" ]
newcase g-allow
XENV="FAKE_GATE=allow GATE_CWD_FILE=$FIX/gate.cwd" drive tick "$PR"
expect "gate: allow => merged" merged
check "gate: merge is pinned: gh pr merge <pr> --squash --match-head-commit <head>" grep -q "^pr merge $PR --squash --match-head-commit $HEAD1\$" "$FIX/gh.log"
check "gate: gate ran with cwd <primary>" [ "$(cat "$FIX/gate.cwd")" = "$REPO" ]
newcase g-missing
DRV="$WORK/nowhere/hooks/sweap-merge.sh" drive tick "$PR"; expect "gate: gate script absent => failed (fail closed), no merge" failed "pre-merge-gate.sh not found"
check "gate: absent gate => no merge issued" [ "$(merges_in_log)" = 0 ]
newcase g-text
XENV="FAKE_GATE=text" drive tick "$PR"; expect "gate: plain-text stdout (no decision object) => failed: unparseable (fail closed)" failed "gate output unparseable"
check "gate: unparseable text => no merge" [ "$(merges_in_log)" = 0 ]
newcase g-junk
XENV="FAKE_GATE=junk" drive tick "$PR"; expect "gate: junk line before a deny JSON => failed: unparseable, never allow" failed "gate output unparseable"
check "gate: junk-before-JSON => no merge" [ "$(merges_in_log)" = 0 ]

newcase g-real-allow
DRV="$REAL_DRIVER" drive tick "$PR"
expect "gate: REAL pre-merge-gate.sh allows a green rollup => merged" merged
check "gate: real gate consulted the stub (pr view with statusCheckRollup)" grep -q 'pr view 7 --json statusCheckRollup' "$FIX/gh.log"
newcase g-real-deny
write_pr pr.json OPEN "$HEAD1" failure
DRV="$REAL_DRIVER" drive tick "$PR"
expect "gate: REAL pre-merge-gate.sh denies a red rollup => failed: gate:" failed "gate: merge-gate: PR #7 is NOT green"
check "gate: real deny => no merge issued" [ "$(merges_in_log)" = 0 ]
newcase g-plugin-root-ignored
write_pr pr.json OPEN "$HEAD1" failure
DRV="$REAL_DRIVER" XENV="CLAUDE_PLUGIN_ROOT=$FAKE_PLUGIN FAKE_GATE=allow" drive tick "$PR"
expect "gate: CLAUDE_PLUGIN_ROOT pointing at a stub-allow gate is ignored; the REAL gate next to the driver still denies" failed "gate: merge-gate: PR #7 is NOT green"
check "gate: CLAUDE_PLUGIN_ROOT override => no merge issued" [ "$(merges_in_log)" = 0 ]
newcase g-env-scrub
XENV="FAKE_GATE=allow GATE_ENV_FILE=$FIX/gate.env SWEAP_MAIN_REF=origin/evil MERGE_GATE_GH_TIMEOUT=1 MERGE_GATE_TOTAL_BUDGET=1 SWEAP_PUSH_GATE=off SWEAP_BASE_BRANCH=x" drive tick "$PR"
expect "gate: env-scrub case still merges" merged
for k in SWEAP_MAIN_REF MERGE_GATE_GH_TIMEOUT MERGE_GATE_TOTAL_BUDGET SWEAP_PUSH_GATE SWEAP_BASE_BRANCH GH_REPO; do
  check "gate: $k does not reach the gate's environment" [ -z "$(grep -E "^$k=" "$FIX/gate.env")" ]
done

newcase g-pinned-gh
# H1: a PATH-shadowed gh that rewrites FAILURE -> SUCCESS on rollup queries (and
# forwards everything else to the stub). The driver resolves gh once (here the
# SWEAP_MERGE_GH seam = the stub) and runs the gate under env -i with a pinned
# PATH, so neither the driver nor the gate ever executes the shadow.
write_pr pr.json OPEN "$HEAD1" failure
mkdir -p "$FIX/evilbin"
cat >"$FIX/evilbin/gh" <<G
#!/usr/bin/env bash
: >"$FIX/evil.ran"
case "\$*" in *statusCheckRollup*) sed 's/"FAILURE"/"SUCCESS"/g' "$FIX/pr.json"; exit 0;; esac
exec "$STUB_BIN/gh" "\$@"
G
chmod +x "$FIX/evilbin/gh"
DRV="$REAL_DRIVER" XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH GATE_ENV_FILE=$FIX/gate.env" drive tick "$PR"
expect "gate: PATH-shadowed gh (FAILURE->SUCCESS rewrite) => the REAL gate still denies" failed "gate: merge-gate: PR #7 is NOT green"
check "gate: PATH-shadowed gh => no merge issued" [ "$(merges_in_log)" = 0 ]
check "gate: the shadow gh never ran (driver and gate both used the resolved binary)" [ ! -e "$FIX/evil.ran" ]
newcase g-hook-env-allowlist
XENV="FAKE_GATE=allow GATE_ENV_FILE=$FIX/gate.env CLAUDE_PROJECT_DIR=/evil GH_HOST=evil.example GH_CONFIG_DIR=/evil BASH_ENV=/evil CDPATH=/evil LC_ALL=evil GH_TOKEN=tok-x" drive tick "$PR"
expect "gate: allowlisted env case still merges" merged
for k in CLAUDE_PROJECT_DIR GH_HOST GH_CONFIG_DIR BASH_ENV CDPATH LC_ALL CLAUDE_PLUGIN_ROOT SWEAP_MERGE_GH SWEAP_MERGE_HOOK_ENV_PASS; do
  check "gate: $k does not reach the gate (env -i + allowlist)" [ -z "$(grep -E "^$k=" "$FIX/gate.env")" ]
done
check "gate: HOME and GH_TOKEN pass through" grep -q "^HOME=$HOME\$" "$FIX/gate.env" -- grep -q '^GH_TOKEN=tok-x$' "$FIX/gate.env"
check "gate: runs under env -i: PATH = <resolved gh dir>:<pinned>" grep -q "^PATH=$STUB_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$FIX/gate.env"
newcase g-gh-unresolvable
XENV="SWEAP_MERGE_GH=relative/gh" drive tick "$PR"
expect "gate: gh not resolvable under the pinned PATH (seam must be absolute) => failed (fail closed), before any gh call" failed "gh not found under pinned PATH"
check "gate: unresolvable gh => no gh call at all" [ ! -s "$FIX/gh.log" ]
newcase g-cdpath
# H2: `bash hooks/sweap-merge.sh` with CDPATH pointing at a dir whose `hooks`
# is a stub-allow gate. bash's `cd hooks` under CDPATH would echo the found dir,
# and $(cd .. && pwd -P) would name "<E>/hooks\n<E>/hooks" — so that very
# directory exists here, with a stub allow gate inside. The driver must still
# resolve its own directory and run the REAL gate next to it.
write_pr pr.json OPEN "$HEAD1" failure
E="$WORK/evil"; NL="$E/hooks"$'\n'"$E/hooks"
mkdir -p "$E/hooks" "$NL"
cp "$FAKE_PLUGIN/hooks/pre-merge-gate.sh" "$FAKE_PLUGIN/hooks/post-merge-"*.sh "$NL/"
mkdir -p "$REPO/hooks"; cp "$HERE/"*.sh "$REPO/hooks/"; : >"$REPO/hooks/$SENTINEL"
DRV="hooks/sweap-merge.sh" XENV="CDPATH=$E FAKE_GATE=allow GATE_ENV_FILE=$FIX/gate.env" drive tick "$PR"
expect "gate: CDPATH-relative invocation => the REAL gate next to the driver denies" failed "gate: merge-gate: PR #7 is NOT green"
check "gate: CDPATH => no merge, stub gate never ran" [ "$(merges_in_log)" = 0 ] -- [ ! -f "$FIX/gate.env" ]
rm -rf "$REPO/hooks" "$E"

# --- round-2 repros: one inline env prefix on the Bash call that launches the
# driver. Each was a single-command red merge before the pinned PATH.
evil_gh() {   # a gh that rewrites FAILURE -> SUCCESS on rollup queries, else forwards to the stub
  mkdir -p "$FIX/evilbin"
  cat >"$FIX/evilbin/gh" <<G
#!/usr/bin/env bash
: >"$FIX/evil.ran"
case "\$*" in *statusCheckRollup*) sed 's/"FAILURE"/"SUCCESS"/g' "$FIX/pr.json"; exit 0;; esac
exec "$STUB_BIN/gh" "\$@"
G
  chmod +x "$FIX/evilbin/gh"
}
newcase g-p3-seam-inline
# P3: `SWEAP_MERGE_GH=/evil/gh bash <plugin>/hooks/sweap-merge.sh tick 7` against
# the REPO driver (no sentinel): the seam is unset, the pinned gh answers (no
# remote here => an error, never a merge), the evil gh never runs.
write_pr pr.json OPEN "$HEAD1" failure
evil_gh
DRV="$DRIVER" XENV="SWEAP_MERGE_GH=$FIX/evilbin/gh" drive tick "$PR" --budget 5
check "P3: inline SWEAP_MERGE_GH on the repo driver (no sentinel) => no merge, still a state word, rc 1" \
  bash -c '[ "$1" = 1 ] && { [ "$2" = missing ] || [ "$2" = failed ]; }' _ "$RC" "$(printf '%s\n' "$OUT" | tail -1 | cut -d' ' -f1)"
check "P3: the evil gh never ran and the stub never heard a merge" [ ! -e "$FIX/evil.ran" ] -- [ "$(merges_in_log)" = 0 ]
# the seam DOES work where the sentinel is (else every case above is vacuous)
r="$(cd "$REPO" && SWEAP_MERGE_LIB=1 SWEAP_MERGE_GH="$STUB_BIN/gh" bash -c '. "$1"; sm_resolve_tools; echo "$SM_GH|$SM_SEAMS"' _ "$FAKE_DRIVER")"
check "P3: next to the sentinel the same seam selects the stub gh" [ "$r" = "$STUB_BIN/gh|1" ]
r="$(cd "$REPO" && SWEAP_MERGE_LIB=1 SWEAP_MERGE_GH="$STUB_BIN/gh" bash -c '. "$1"; sm_resolve_tools; echo "${SWEAP_MERGE_GH:-unset}|$SM_SEAMS|$SM_GH"' _ "$DRIVER")"
check "P3: without the sentinel SM_SEAMS=0, the seam is unset and gh is the pinned one" [ "${r%%|*}" = unset ] -- contains "$r" "|0|/" -- [ "${r##*|}" != "$STUB_BIN/gh" ]

newcase g-p4-fake-jq
# P4: a caller-PATH jq that rewrites failure -> success / deny -> allow. Runs
# red + rollup red: the driver's own evaluation must see red (pinned jq), and the
# fake must never execute.
write_pr pr.json OPEN "$HEAD1" failure
write_runs "$(run 101 "$CI" completed failure)" "$(run 102 "$AG" completed failure)" "$(run 103 "$CR" completed success)"
mkdir -p "$FIX/evilbin"
cat >"$FIX/evilbin/jq" <<'J'
#!/usr/bin/env bash
: >"${EVIL_JQ_RAN:-/dev/null}"
args=(); for a in "$@"; do
  if [ -f "$a" ] && [ "$a" != "-" ]; then t="$(mktemp)"; sed 's/"failure"/"success"/g; s/"FAILURE"/"SUCCESS"/g; s/"deny"/"allow"/g' "$a" >"$t"; args+=("$t"); else args+=("$a"); fi
done
if [ -t 0 ]; then exec /usr/bin/jq "${args[@]}"; fi
sed 's/"failure"/"success"/g; s/"FAILURE"/"SUCCESS"/g; s/"deny"/"allow"/g' | exec /usr/bin/jq "${args[@]}"
J
chmod +x "$FIX/evilbin/jq"
DRV="$REAL_DRIVER" XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH EVIL_JQ_RAN=$FIX/evil.ran" drive tick "$PR"
expect "P4: caller-PATH jq (red->green, deny->allow rewrite) => the driver's own evaluation still says failed" failed "$AG failure"
check "P4: no merge; the fake jq never ran (driver under the pinned PATH, jq absolute)" [ "$(merges_in_log)" = 0 ] -- [ ! -e "$FIX/evil.ran" ]
# same fake jq, runs green, rollup red: the REAL gate's deny must be read by the pinned jq
all_green
DRV="$REAL_DRIVER" XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH EVIL_JQ_RAN=$FIX/evil.ran" drive tick "$PR"
expect "P4: caller-PATH jq cannot flip the REAL gate's deny into allow" failed "gate: merge-gate: PR #7 is NOT green"
check "P4: no merge, fake jq never ran (gate deny parsed with the pinned jq)" [ "$(merges_in_log)" = 0 ] -- [ ! -e "$FIX/evil.ran" ]

newcase g-p5-fake-env
# P5: a caller-PATH env(1) that ignores -i and the K=V prefix, so the gate would
# inherit the caller's PATH (evil gh first). env is resolved absolute under the
# pinned PATH, so the gate still runs under the real `env -i`.
write_pr pr.json OPEN "$HEAD1" failure
evil_gh
cat >"$FIX/evilbin/env" <<'V'
#!/bin/bash
: >"${EVIL_ENV_RAN:-/dev/null}"
[ "$1" = -i ] && shift
while [ $# -gt 0 ]; do case "$1" in *=*) shift ;; *) break ;; esac; done
exec "$@"
V
chmod +x "$FIX/evilbin/env"
DRV="$REAL_DRIVER" XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH EVIL_ENV_RAN=$FIX/evilenv.ran GATE_ENV_FILE=$FIX/gate.env" drive tick "$PR"
expect "P5: caller-PATH env(1) that ignores -i => the REAL gate still denies" failed "gate: merge-gate: PR #7 is NOT green"
check "P5: no merge; neither the fake env nor the shadow gh ran" [ "$(merges_in_log)" = 0 ] -- [ ! -e "$FIX/evilenv.ran" ] -- [ ! -e "$FIX/evil.ran" ]
# the env the gate actually receives (fake gate records it): pinned, evilbin absent
XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH EVIL_ENV_RAN=$FIX/evilenv.ran FAKE_GATE=allow GATE_ENV_FILE=$FIX/gate.env" drive tick "$PR"
check "P5: the gate's PATH is the pinned one (evilbin absent), fake env never ran" \
  [ -f "$FIX/gate.env" ] -- ! grep -q "^PATH=.*evilbin" "$FIX/gate.env" -- grep -q "^PATH=$STUB_BIN:/opt/homebrew/bin:" "$FIX/gate.env" -- [ ! -e "$FIX/evilenv.ran" ]

newcase g-p7-fake-git
# P7: a caller-PATH git that answers `rev-parse --git-common-dir` with another
# checkout: <primary> (state dir, gate cwd) would move there. git is pinned +
# absolute, so the state lands under the real primary and the forged dir stays
# empty.
FORGED="$WORK/forged"; rm -rf "$FORGED"; mkdir -p "$FORGED"; git -C "$FORGED" init -q; git -C "$FORGED" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$FIX/evilbin"
cat >"$FIX/evilbin/git" <<G
#!/usr/bin/env bash
: >"$FIX/evilgit.ran"
case "\$*" in "rev-parse --git-common-dir") echo "$FORGED/.git"; exit 0;; esac
exec /usr/bin/git "\$@"
G
chmod +x "$FIX/evilbin/git"
DRV="$REAL_DRIVER" XENV="PATH=$FIX/evilbin:$STUB_BIN:$PATH" drive tick "$PR"
expect "P7: caller-PATH git forging <primary> => the driver runs (green fixture) with the REAL primary" merged
check "P7: state file under the real primary, none under the forged one, fake git never ran" \
  [ -f "$STATE_DIR/$PR.json" ] -- [ ! -d "$FORGED/.claude/sweap-merge" ] -- [ ! -e "$FIX/evilgit.ran" ]
check "P7: the state file and the lease record the primary they were written under" [ "$(state .primary)" = "$REPO" ] -- [ "$(state .lease.primary)" = "$REPO" ]
rm -rf "$FORGED"
newcase g-p7-state-split
# the belt: a state file written under another primary is refused, never split
drive tick "$PR"; expect "P7 belt: first tick merges (green)" merged
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
printf '{"pr":%s,"state":"pending","head":"%s","primary":"/elsewhere/checkout","seq":1}\n' "$PR" "$HEAD1" >"$STATE_DIR/$PR.json"
rm -f "$FIX/merged.flag"; : >"$FIX/gh.log"
drive tick "$PR"
expect "P7 belt: a state file recorded under another <primary> => failed: state split (fail closed)" failed "state split"
check "P7 belt: no gh call, no merge, the file is left as found" [ ! -s "$FIX/gh.log" ] -- [ "$(state .primary)" = "/elsewhere/checkout" ]
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/$PR.lock"
printf 'owner=other:1\nepoch=3\npid=1\nhost=%s\nheartbeat=%s\nprimary=/elsewhere/checkout\n' "$(hostname)" "$NOW" >"$STATE_DIR/$PR.lock/info"
drive tick "$PR"
expect "P7 belt: a lease taken under another <primary> => failed: state split" failed "lease was taken under /elsewhere/checkout"
check "P7 belt: no gh call" [ ! -s "$FIX/gh.log" ]

# --- round-3 repros: channels the in-script scrub cannot reach in time.
newcase g-f1-bash-env
# F1: `BASH_ENV=/abs/be.sh bash <plugin>/hooks/sweap-merge.sh tick 7` on the
# REPO driver (no sentinel). bash sources be.sh BEFORE the script body, so a
# `command` override there poisons `command -v gh` inside sm_resolve_tools.
# Belt A re-execs under env -i + bash -p before anything else runs: the file
# is sourced by the first process (marker) and by nothing after it.
write_pr pr.json OPEN "$HEAD1" failure
mkdir -p "$FIX/evilbin"
cat >"$FIX/evilbin/gh" <<G
#!/usr/bin/env bash
: >"$FIX/evil.ran"
case "\$*" in "pr merge"*) : >"$FIX/evil.merged"; echo merged; exit 0;; esac
exec "$STUB_BIN/gh" "\$@"
G
chmod +x "$FIX/evilbin/gh"
cat >"$FIX/be.sh" <<B
: >"$FIX/be.sourced"
command() { if [ "\${1:-}" = -v ]; then case "\${2:-}" in gh) printf '%s\n' "$FIX/evilbin/gh"; return 0;; esac; fi; builtin command "\$@"; }
B
DRV="$DRIVER" XENV="BASH_ENV=$FIX/be.sh" drive tick "$PR" --budget 5
check "F1: BASH_ENV prefix on the repo driver => no merge, still a state word, rc 1" \
  bash -c '[ "$1" = 1 ] && { [ "$2" = missing ] || [ "$2" = failed ]; }' _ "$RC" "$(printf '%s\n' "$OUT" | tail -1 | cut -d' ' -f1)"
check "F1: the BASH_ENV file WAS sourced by the first process, yet the evil gh never ran (belt A: env -i + bash -p re-exec)" \
  [ -e "$FIX/be.sourced" ] -- [ ! -e "$FIX/evil.ran" ] -- [ ! -e "$FIX/evil.merged" ]
# the verifier's end-to-end shape: the REAL gate denies a red rollup, and a
# BASH_ENV-injected jq that flips deny->allow must not be the jq that reads it
newcase g-f1-bash-env-jq
write_pr pr.json OPEN "$HEAD1" failure
mkdir -p "$FIX/evilbin"
cat >"$FIX/evilbin/jq" <<J
#!/usr/bin/env bash
: >"$FIX/eviljq.ran"
args=(); for a in "\$@"; do
  if [ -f "\$a" ] && [ "\$a" != "-" ]; then t="\$(mktemp)"; sed 's/"failure"/"success"/g; s/"FAILURE"/"SUCCESS"/g; s/"deny"/"allow"/g' "\$a" >"\$t"; args+=("\$t"); else args+=("\$a"); fi
done
if [ -t 0 ]; then exec /usr/bin/jq "\${args[@]}"; fi
sed 's/"failure"/"success"/g; s/"FAILURE"/"SUCCESS"/g; s/"deny"/"allow"/g' | exec /usr/bin/jq "\${args[@]}"
J
chmod +x "$FIX/evilbin/jq"
cat >"$FIX/be.sh" <<B
command() { if [ "\${1:-}" = -v ]; then case "\${2:-}" in jq) printf '%s\n' "$FIX/evilbin/jq"; return 0;; esac; fi; builtin command "\$@"; }
B
DRV="$REAL_DRIVER" XENV="BASH_ENV=$FIX/be.sh" drive tick "$PR"
expect "F1: BASH_ENV-injected jq (deny->allow) => the REAL gate's deny is still read as a deny" failed "gate: merge-gate: PR #7 is NOT green"
check "F1: no merge, the evil jq never ran" [ "$(merges_in_log)" = 0 ] -- [ ! -e "$FIX/eviljq.ran" ]
r="$(cd "$REPO" && SWEAP_MERGE_LIB=1 bash -c '. "$1"; echo "${SM_REEXEC:-unset}"' _ "$FAKE_DRIVER")"
check "F1: sourcing as a library (SWEAP_MERGE_LIB=1) never re-execs" [ "$r" = unset ]

newcase g-f2-git-dir
# F2: `GIT_DIR=/forged/.git bash sweap-merge.sh tick 7` moved <primary> — the
# state file, the lease and the gate's cwd — into the forged checkout, and
# sm_primary_check is blind to a consistently forged primary. Belt A drops the
# whole GIT_* family (and the scrub unsets it again); <primary> is the real one.
FORGED="$WORK/forged"; rm -rf "$FORGED"; mkdir -p "$FORGED"; git -C "$FORGED" init -q; git -C "$FORGED" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
XENV="GIT_DIR=$FORGED/.git GIT_WORK_TREE=$FORGED" drive tick "$PR"
expect "F2: inline GIT_DIR=<forged>/.git => the driver still derives the REAL primary and merges (green)" merged
check "F2: state + lease under the real primary, the forged tree untouched" \
  [ -f "$STATE_DIR/$PR.json" ] -- [ "$(state .primary)" = "$REPO" ] -- [ "$(state .lease.primary)" = "$REPO" ] -- [ ! -d "$FORGED/.claude/sweap-merge" ]
# a state file that consistently records the forged primary is a split now, not a home
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
printf '{"pr":%s,"state":"pending","head":"%s","primary":"%s","seq":1}\n' "$PR" "$HEAD1" "$FORGED" >"$STATE_DIR/$PR.json"
: >"$FIX/gh.log"
XENV="GIT_DIR=$FORGED/.git GIT_WORK_TREE=$FORGED" drive tick "$PR"
expect "F2: a forged-primary state file + GIT_DIR prefix => failed: state split (fail closed)" failed "state split"
check "F2: no gh call, no merge" [ ! -s "$FIX/gh.log" ]
# sm_resolve_primary's own sanity: <primary> must carry a .git and be git's toplevel
mkdir -p "$FIX/evilbin" "$REPO/sub/.git"
git init -q --bare "$WORK/bare/repo.git" 2>/dev/null
cat >"$FIX/evilbin/git" <<G
#!/usr/bin/env bash
case "\$*" in "rev-parse --git-common-dir") printf '%s\n' "\$FORGED_GITDIR"; exit 0;; esac
exec /usr/bin/git "\$@"
G
chmod +x "$FIX/evilbin/git"
probe_primary() {   # probe_primary <common-dir answer> -> resolved:<primary> | refused
  ( cd "$REPO" && FORGED_GITDIR="$1" SWEAP_MERGE_LIB=1 bash -c '. "$1"; SM_GIT="$2"; if sm_resolve_primary; then echo "resolved:$SM_PRIMARY"; else echo refused; fi' _ "$FAKE_DRIVER" "$FIX/evilbin/git" )
}
check "F2: a common-dir whose parent has no .git (bare repo) is refused" [ "$(probe_primary "$WORK/bare/repo.git")" = refused ]
check "F2: a common-dir whose parent is not git's toplevel (a bare .git dir inside the repo) is refused" [ "$(probe_primary "$REPO/sub/.git")" = refused ]
check "F2: the real common-dir still resolves" [ "$(probe_primary "$REPO/.git")" = "resolved:$REPO" ]
rm -rf "$FORGED" "$REPO/sub" "$WORK/bare"

# ======================================================================================
printf '== Merge outcomes (D4, E2)\n\'
newcase m-success
drive tick "$PR"; expect "merge: success => merged" merged
check "merge: post-merge scripts invoked once each, in order" [ "$(tr '\n' ' ' <"$FIX/pm.log")" = "post-merge-cleanup.sh post-merge-auditcheck.sh " ]
check "merge: post_merge_done flag set" [ "$(state .post_merge_done)" = true ]
pin="$(cat "$FIX/pm.log.post-merge-auditcheck.sh.in")"
check "merge: PostToolUse payload carries the merge command + tool_response" \
  [ "$(printf '%s' "$pin" | jq -r '.hook_event_name + "|" + .tool_name + "|" + .tool_input.command + "|" + .cwd')" = "PostToolUse|Bash|gh pr merge $PR --squash|$REPO" ]
check "merge: tool_response.stdout is the merge output" contains "$(printf '%s' "$pin" | jq -r .tool_response.stdout)" "Squashed and merged"
check "merge: post-merge scripts run in <primary>" [ "$(cat "$FIX/pm.log.post-merge-cleanup.sh.cwd")" = "$REPO" ]
drive tick "$PR"; expect "merge: re-entry on merged => merged again (idempotent)" merged
check "merge: re-entry does not re-run post-merge scripts" [ "$(wc -l <"$FIX/pm.log" | tr -d ' ')" = 2 ]
check "merge: re-entry issues no second merge" [ "$(merges_in_log)" = 1 ]
# the payload satisfies the real hooks' parser, and the real redcheck (no longer on
# the driver's list, still wired for a session-issued merge) accepts the same shape
r="$(bash -c '. "$1"; parse_merge_command "$2"; echo "$MC_MERGE_RELATED $MC_PRS"' _ "$HERE/lib-merge-parse.sh" "gh pr merge $PR --squash")"
check "merge: lib-merge-parse extracts the PR from the synthetic command" [ "$r" = "1 $PR" ]
( cd "$REPO" && printf '%s' "$pin" | env PATH="$STUB_BIN:$PATH" GH_FIX="$FIX" bash "$HERE/post-merge-redcheck.sh" >/dev/null 2>&1 ); rrc=$?
check "merge: REAL post-merge-redcheck.sh accepts the payload (green rollup, exit 0)" [ "$rrc" = 0 ]

newcase m-reconcile-merged
write_pr pr.after.json MERGED
XENV="GH_MERGE=fail" drive tick "$PR"; expect "merge: gh pr merge fails but reconcile says MERGED => merged" merged "reconciled"
check "merge: reconcile-merged runs post-merge once" [ "$(wc -l <"$FIX/pm.log" | tr -d ' ')" = 2 ]
check "merge: exactly one merge attempt" [ "$(merges_in_log)" = 1 ]

newcase m-reconcile-moved
write_pr pr.after.json OPEN "$HEAD2"
XENV="GH_MERGE=fail" drive tick "$PR"; expect "merge: fails, PR open with head moved => superseded" superseded "head moved"
check "merge: superseded stores the new head" [ "$(state .head)" = "$HEAD2" ]
check "merge: superseded is re-armed on the next tick (fresh deadlines, new head)" true
write_pr pr.json OPEN "$HEAD2"
write_runs
drive tick "$PR"; expect "merge: next tick after superseded re-arms => missing on new head" missing
check "merge: re-arm never issued a second merge" [ "$(merges_in_log)" = 1 ]

newcase m-reconcile-same
write_pr pr.after.json OPEN "$HEAD1"
XENV="GH_MERGE=fail" drive tick "$PR"; expect "merge: fails, PR open same head => pending (re-evaluate)" pending "did not land"
check "merge: first refusal recorded as attempt 1" [ "$(state .merge_attempts)" = 1 ]
newcase m-persistent-fail
write_pr pr.after.json OPEN "$HEAD1"
XENV="GH_MERGE=fail" drive watch "$PR"
check "merge: persistent refusal under watch => terminal failed (no livelock)" word_is failed -- contains "$OUT" "after 2 attempts"
check "merge: persistent refusal => exits 1" [ "$RC" = 1 ]
check "merge: persistent refusal => at most 2 merge calls" [ "$(merges_in_log)" -le 2 ]
newcase m-attempts-reset
write_pr pr.after.json OPEN "$HEAD1"
XENV="GH_MERGE=fail" drive tick "$PR"; expect "merge: attempt 1 => pending" pending
write_pr pr.after.json OPEN "$HEAD2"   # (the stub serves pr.after.json once a merge was attempted)
drive tick "$PR"; expect "merge: head moved => superseded" superseded
check "merge: superseded resets merge_attempts" [ "$(state .merge_attempts)" = 0 ]

newcase m-postmerge-alarm
XENV="PM_RED=1" drive tick "$PR"
expect "merge: a post-merge hook's exit 2 => still merged, banner folded into the reason" merged "AUDIT DEBT"
check "merge: alarm stderr forwarded, prefixed by hook name" grep -q '^\[post-merge-auditcheck.sh\] ## AUDIT DEBT' "$FIX/stderr"
check "merge: alarm recorded in the state file" [ "$(state '.post_merge_alerts[0].hook + "|" + (.post_merge_alerts[0].rc|tostring)')" = "post-merge-auditcheck.sh|2" ]
check "merge: stdout stays one line" [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]
drive tick "$PR"; expect "merge: re-entry on merged still carries the recorded alarm" merged "AUDIT DEBT"
newcase m-cleanup-context
XENV="PM_CTX=1" drive tick "$PR"; expect "merge: cleanup additionalContext => merged" merged
check "merge: cleanup's additionalContext forwarded to stderr" grep -q '^\[post-merge-cleanup.sh\] sweap: backlog files are STRANDED' "$FIX/stderr"

newcase m-hand-edited
mkdir -p "$STATE_DIR"
jq -n --arg h "$HEAD1" --arg b "$BSHA1" '{pr:7, state:"merging", head:$h, base:"main", base_sha:$b, expected:[], expected_from:$b, seq:3, history:[]}' >"$STATE_DIR/$PR.json"
drive tick "$PR"; expect "merge: a hand-edited merging file is reconciled, never merged (open, same head => pending)" pending
check "merge: hand-edited merging => the stub never saw gh pr merge" [ "$(merges_in_log)" = 0 ]
check "merge: reconcile is read-only (only pr view calls)" [ "$(grep -vc '^pr view' "$FIX/gh.log" | tr -d ' ')" = 0 ]

newcase m-external
write_pr pr.json MERGED
drive tick "$PR"; expect "merge: PR already merged outside the driver => merged (no merge call)" merged "outside the driver"
check "merge: external merge => no gh pr merge" [ "$(merges_in_log)" = 0 ]

newcase m-superseded-loop
write_pr pr.json OPEN "$HEAD2"
drive tick "$PR"; expect "head moved on h2 before green => merged on h2" merged
check "head recorded" [ "$(state .head)" = "$HEAD2" ]
newcase m-head-moved
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "pending on h1" pending
write_pr pr.json OPEN "$HEAD2"
drive tick "$PR"; expect "head moved while pending => superseded" superseded "head moved"

# ======================================================================================
printf '== Argv (§3)\n'
newcase a-argv
drive tick abc; check "argv: bad <pr> rejected (exit 2)" [ "$RC" = 2 ]
drive tick; check "argv: missing <pr> rejected" [ "$RC" = 2 ]
drive tick "$PR" --repo o/r; check "argv: --repo rejected" [ "$RC" = 2 ]
drive tick "$PR" -R o/r; check "argv: -R rejected" [ "$RC" = 2 ]
drive tick "$PR" --admin; check "argv: --admin rejected" [ "$RC" = 2 ]
drive rerun "$PR"; check "argv: rerun without --reason is a usage error (a hand rerun carries its reason)" [ "$RC" = 2 ]
drive rerun "$PR" --reason ""; check "argv: rerun with an empty --reason rejected" [ "$RC" = 2 ]
drive rerun "$PR" --reason "x" --budget 5; check "argv: rerun takes no --budget" [ "$RC" = 2 ]
drive tick "$PR" --reason "x"; check "argv: --reason belongs to rerun only" [ "$RC" = 2 ]
drive tick "$PR" --budget 0; check "argv: --budget 0 rejected" [ "$RC" = 2 ]
check "argv: rejected argv made no gh call" [ ! -s "$FIX/gh.log" ]
XENV="GH_REPO=evil/repo" drive tick "$PR"; expect "argv: GH_REPO in the environment is unset by the driver" merged
check "argv: the stub never saw GH_REPO" absent 'ENV GH_REPO' "$FIX/gh.log"
newcase a-seams-off
write_runs
# seams off = the REPO driver (no sentinel next to it): SWEAP_MERGE_GH is
# ignored, so the driver asks the PINNED gh (the real one; this fixture repo
# has no remote, so it answers with an error) and the stub never hears from
# it; the clock/session knobs are ignored likewise.
check "seams: the plugin's hooks dir carries no $SENTINEL (the seams are off for the shipped driver)" [ ! -e "$HERE/$SENTINEL" ]
DRV="$DRIVER" drive tick "$PR" --budget 5
check "seams: without the sentinel the terminal word is still a state (missing/failed), rc 1" \
  bash -c '[ "$1" = 1 ] && { [ "$2" = missing ] || [ "$2" = failed ]; }' _ "$RC" "$(printf '%s\n' "$OUT" | tail -1 | cut -d' ' -f1)"
check "seams: SWEAP_MERGE_GH ignored (the stub gh is never called; the pinned gh answers)" [ ! -s "$FIX/gh.log" ]
r="$(SWEAP_MERGE_LIB=1 SWEAP_MERGE_NOW="$NOW" SWEAP_MERGE_SESSION=test SWEAP_MERGE_GH=/x SWEAP_MERGE_STALE=1 \
     bash -c '. "$1"; echo "$(sm_now) $SM_SESSION ${SWEAP_MERGE_GH:-unset} $SM_STALE"' _ "$DRIVER")"
check "seams: SWEAP_MERGE_NOW ignored (sm_now is the real clock)" [ "${r%% *}" != "$NOW" ]
check "seams: SWEAP_MERGE_SESSION / SWEAP_MERGE_GH / SWEAP_MERGE_STALE ignored (unset at the scrub)" \
  [ "$(printf '%s' "$r" | cut -d' ' -f2-)" != "test /x 1" ] -- contains "$r" " unset 130"
newcase a-nojq
# a PATH with every usual tool except jq (symlinks), plus the stub gh
mkdir -p "$WORK/nojq"
for t in /usr/bin/* /bin/*; do b="$(basename "$t")"; [ "$b" = jq ] && continue; [ -e "$WORK/nojq/$b" ] || ln -s "$t" "$WORK/nojq/$b" 2>/dev/null; done
# the driver's own PATH is pinned, so a jq-less host is emulated by pinning THAT
# list (library source, then sm_main): every tool but jq resolves, jq fails first
OUT="$(cd "$REPO" && env PATH="$WORK/nojq:$STUB_BIN" GH_FIX="$FIX" GH_LOG="$FIX/gh.log" SWEAP_MERGE_LIB=1 \
      bash -c '. "$1"; SM_PINNED_PATH="$2"; PATH="$2"; sm_main tick "$3"' _ "$DRIVER" "$WORK/nojq:$STUB_BIN" "$PR" 2>/dev/null)"; RC=$?
expect "jq: unavailable under the pinned PATH => failed (fail closed)" failed "jq is required"
check "jq: unavailable => no merge, no gh call" [ ! -s "$FIX/gh.log" ]
newcase a-outside-git
DIR="$WORK" drive tick "$PR"; expect "primary: not in a git repo => failed" failed "not inside a git repository"

# ======================================================================================
printf '== Worktree (E3)\n'
newcase w-worktree
DIR="$WT" drive tick "$PR"; expect "worktree: tick from .claude/worktrees/x merges" merged
check "worktree: state lives under <primary>/.claude/sweap-merge" [ -f "$STATE_DIR/$PR.json" ]
check "worktree: nothing written under the worktree" [ ! -d "$WT/.claude/sweap-merge" ]
check "worktree: post-merge hooks run in the SESSION's cwd (the worktree), payload cwd likewise" \
  [ "$(cat "$FIX/pm.log.post-merge-cleanup.sh.cwd")" = "$WT" ] -- [ "$(jq -r .cwd "$FIX/pm.log.post-merge-cleanup.sh.in")" = "$WT" ]
newcase w-real-cleanup
# the REAL post-merge-cleanup.sh, driven from inside worktree x, with the stub
# saying every branch has a merged PR: it must retire the OTHER worktree and
# leave the one the session stands in
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/y" -b wt-y >/dev/null 2>&1
DIR="$WT" DRV="$REALCLEAN_PLUGIN/hooks/sweap-merge.sh" XENV="GH_PRLIST_MERGED=1" drive tick "$PR"
expect "worktree: real cleanup through the driver => merged" merged
check "worktree: real cleanup consulted gh pr list (it ran)" grep -q '^pr list --head wt-' "$FIX/gh.log"
check "worktree: the OTHER merged worktree was retired" [ ! -d "$REPO/.claude/worktrees/y" ]
check "worktree: the session's own worktree survives cleanup" [ -d "$WT" ] -- quiet git -C "$WT" rev-parse --is-inside-work-tree

# ======================================================================================
printf '== tick budget, watch, status\n'
newcase b-budget
# CI in_progress, so a tick that DOES evaluate ends `pending`. A 2 s budget on a
# loaded box may expire inside the first gh call instead, and then nothing was
# evaluated and the tick ends `missing` — both are correct, so the word is
# asserted as "no verdict was reached", not as one fixed string. What is exact
# either way: the budget was honoured, no merge was issued, and the arm-time
# checkpoint put the lease on disk (SWEAP_MERGE_NOW is fixed, so the heartbeat
# value is deterministic) — before sm_checkpoint the state file did not exist at
# all on the died-in-the-first-gh-call path and this assert flaked.
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
t0=$(date +%s)
MAX_ITER=0 drive tick "$PR" --budget 2
el=$(( $(date +%s) - t0 ))
check "budget: tick stops at --budget with the current state, never a verdict" word_in pending missing
check "budget: 2 s budget never merged" [ "$(merges_in_log)" = 0 ]
check "budget: 2 s budget ended within 6 s (elapsed ${el}s)" [ "$el" -le 6 ]
check "budget: heartbeat written" [ "$(state .lease.heartbeat_at)" = "$NOW" ]
check "budget: the checkpoint carries owner, epoch, primary and pr" \
  [ "$(state '[.lease.owner, (.lease.epoch|tostring), .primary, (.pr|tostring), .state] | map(select(. != null and . != "")) | length')" = 5 ]
newcase b-arm-time-state
# the same tick, but gh is guaranteed to outlive the budget: the tick dies in
# its FIRST gh call, having reached no evaluation at all. The state file must
# still exist (arm-time checkpoint) and `status` must list the PR — a PR whose
# watch is armed is never invisible.
XENV="GH_STUB_SLEEP=5 SWEAP_MERGE_GH_TIMEOUT=1" drive tick "$PR" --budget 1
check "arm-time: a tick that dies in its first gh call still ends on a state word" word_is missing
check "arm-time: the state file exists after a tick that never evaluated" [ -f "$STATE_DIR/$PR.json" ]
check "arm-time: it carries pr, state and the lease" \
  [ "$(state '.pr')" = "$PR" ] -- [ "$(state .state)" = missing ] -- [ "$(state .lease.heartbeat_at)" = "$NOW" ] -- [ "$(state .primary)" = "$REPO" ]
check "arm-time: no history row was invented for a state that did not change" [ "$(state '(.history // []) | length')" = 0 ]
drive status "$PR"
check "arm-time: status lists a PR whose tick died in its first gh call" contains "$OUT" "#$PR missing head= owner="
newcase b-slow-gh
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
t0=$(date +%s)
XENV="GH_STUB_SLEEP=3 SWEAP_MERGE_GH_TIMEOUT=1" drive tick "$PR" --budget 3
el=$(( $(date +%s) - t0 ))
check "budget: a hung gh is cut by bounded_run (elapsed ${el}s <= 6)" [ "$el" -le 6 ]
check "budget: hung gh => no verdict, reason names the call" word_is missing -- contains "$OUT" "gh pr view"

newcase wt-watch
mkdir -p "$FIX/runs.seq"
runs_doc 3 "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" >"$FIX/runs.seq/1.json"
runs_doc 3 "$(run 101 "$CI" completed success)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)" >"$FIX/runs.seq/2.json"
drive watch "$PR"
check "watch: exits 0 on merged" [ "$RC" = 0 ]
check "watch: one line per transition (pending green merging merged)" [ "$(printf '%s\n' "$OUT" | cut -d' ' -f1 | tr '\n' ' ')" = "pending green merging merged " ]
check "watch: post-merge ran once" [ "$(wc -l <"$FIX/pm.log" | tr -d ' ')" = 2 ]
newcase wt-watch-fail
write_runs "$(run 101 "$CI" completed failure)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive watch "$PR"
check "watch: exits 1 on failed" [ "$RC" = 1 ]
check "watch: terminal line is failed" word_is failed
newcase wt-watch-held
sleep 30 & LIVE2=$!
mk_lock "other:$LIVE2" 1 "$LIVE2" "$NOW"
drive watch "$PR"; expect "watch: held-by is terminal for watch" "held-by:other:$LIVE2"
check "watch: held-by exits 1" [ "$RC" = 1 ]
kill "$LIVE2" 2>/dev/null; wait "$LIVE2" 2>/dev/null
newcase wt-watch-cap
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
XENV="SWEAP_MERGE_MAX_TICKS=2" drive watch "$PR"
check "watch: pending ticks keep looping (test cap stops it)" word_is pending -- contains "$OUT" "watch stopped after 2"

newcase st-status
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"
drive status; check "status: lists the PR with its state and head" contains "$OUT" "#$PR pending head=${HEAD1:0:12}"
check "status: exits 0" [ "$RC" = 0 ]
mk_lock "other:99" 9 "$DEAD" "$NOW"
drive status "$PR"; check "status: flags a dead poller" contains "$OUT" "dead poller"
mk_lock "other:99" 9 "$$" "$((NOW - 5000))"
drive status "$PR"; check "status: flags a stale heartbeat" contains "$OUT" "stale"
drive status 123; check "status: unknown PR prints nothing" [ -z "$OUT" ]
# NO LOCK is the case that cost a consumer 26 minutes: `status` said nothing, and
# silence read as health. It must now say which of the two it is.
rm -rf "$STATE_DIR/$PR.lock"
# The owner recorded in the state file is `<session>:<pid>`; the tick that wrote
# it is long gone here, so status must say so outright rather than hedge.
TNOW=$((NOW + 5)) drive status "$PR"
check "status: no lock and a dead owner pid => NO WATCHER, not silence" contains "$OUT" "NO WATCHER"
check "status: it names the dead pid" contains "$OUT" "is gone"
check "status: and names the command that arms one" contains "$OUT" "sweap-merge watch $PR"
# A LIVE owner pid must read as live, or the command cries wolf on every poll.
sleep 30 & LIVE4=$!
jq --arg o "test:$LIVE4" '.lease.owner = $o' "$STATE_DIR/$PR.json" > "$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
TNOW=$((NOW + 5)) drive status "$PR"
check "status: a live owner pid reads as a live watcher" contains "$OUT" "watcher pid $LIVE4 alive"
check "status: a live watcher is not nagged about" ! contains "$OUT" "NO WATCHER"
# Alive but not ticking: a stalled watcher or a recycled pid. Neither is evidence.
TNOW=$((NOW + 9000)) drive status "$PR"
check "status: alive pid with a stale heartbeat is not called healthy" contains "$OUT" "not evidence of one waiting"
kill "$LIVE4" 2>/dev/null; wait "$LIVE4" 2>/dev/null
# A non-numeric heartbeat used to abort the loop mid-run under set -u, so every
# PR after it went unprinted — silence, in the command that exists to break it.
jq '.lease.heartbeat_at = "2026-09-02T10:00:00Z"' "$STATE_DIR/$PR.json" > "$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
cp "$STATE_DIR/$PR.json" "$STATE_DIR/999.json"
jq '.state = "pending"' "$STATE_DIR/999.json" > "$STATE_DIR/999.tmp" && mv "$STATE_DIR/999.tmp" "$STATE_DIR/999.json"
drive status
check "status: a non-numeric heartbeat does not abort the listing" [ "$RC" = 0 ]
check "status: every PR is still listed after a corrupt one" contains "$OUT" "#999"
rm -f "$STATE_DIR/999.json"
# The exemption list was untested: deleting it left the suite green.
for terminal in merged failed attended undecidable timed_out behind; do
  jq --arg s "$terminal" '.state = $s' "$STATE_DIR/$PR.json" > "$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
  drive status "$PR"
  check "status: $terminal is terminal and gets no watcher nag" ! contains "$OUT" "NO WATCHER" -- ! contains "$OUT" "sweap-merge watch"
done
for live in pending green merging superseded missing; do
  jq --arg s "$live" '.state = $s' "$STATE_DIR/$PR.json" > "$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
  drive status "$PR"
  check "status: $live is in flight and IS nagged about" contains "$OUT" "NO WATCHER"
done

# ======================================================================================
printf '== rerun (a hand verb, one per head) + the flake note\n'
INBOX="$REPO/roadmap/discovered"
reruns_in_log() { if [ -f "$FIX/rerun.log" ]; then wc -l <"$FIX/rerun.log" | tr -d ' '; else echo 0; fi; }
red_ci() { write_runs "$(run 101 "$CI" completed failure)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"; }
green_ci_attempt2() { write_runs "$(run 101 "$CI" completed success 2)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"; }

# (a) accepted: a completed failure run, base green, first rerun on this head
newcase r-accept
rm -rf "$INBOX"; mkdir -p "$INBOX"
red_ci
drive tick "$PR"; expect "rerun: the red tick ends failed" failed "ci.yml failure"
drive rerun "$PR" --reason "runner contention, e2e timed out under load"
check "rerun: accepted => exit 0, word pending" [ "$RC" = 0 ] -- word_is pending -- contains "$OUT" "recorded"
check "rerun: gh run rerun --failed <id> issued once, for the red run" [ "$(reruns_in_log)" = 1 ] -- [ "$(cat "$FIX/rerun.log")" = "--failed 101" ]
check "rerun: base tip was checked for the same workflow first" grep -q '^run list --branch main --workflow ci.yml --limit 1' "$FIX/gh.log"
check "rerun: state is pending" [ "$(state .state)" = pending ]
check "rerun: one reruns[] entry with head, run_ids, reason, at, by" \
  [ "$(state '.reruns | length')" = 1 ] -- [ "$(state '.reruns[0].head')" = "$HEAD1" ] -- [ "$(state '.reruns[0].run_ids | join(",")')" = 101 ] \
  -- [ "$(state '.reruns[0].reason')" = "runner contention, e2e timed out under load" ] -- [ "$(state '.reruns[0].at')" = "$NOW" ] -- [ -n "$(state '.reruns[0].by')" ]
check "rerun: history row failed -> pending, why names the reason" \
  [ "$(state '.history | last | .from + ">" + .to')" = "failed>pending" ] -- contains "$(state '.history | last | .why')" "manual rerun (runner contention"
check "rerun: existing keys untouched (head, expected, base_sha)" [ "$(state .head)" = "$HEAD1" ] -- [ "$(state '.expected|length')" = 3 ] -- [ "$(state .base_sha)" = "$BSHA1" ]
check "rerun: disarmed the way a superseded head is (arm_at/appear/complete cleared, observed emptied)" \
  [ "$(state '.arm_at')" = null ] -- [ "$(state '.appear_deadline')" = null ] -- [ "$(state '.complete_deadline')" = null ] -- [ "$(state '.observed|length')" = 0 ]
check "rerun: the lease was released" [ ! -d "$STATE_DIR/$PR.lock" ]
# the next tick re-arms through the SAME branch a superseded head uses
green_ci_attempt2
TNOW=$((NOW + 60)) drive tick "$PR"; expect "rerun: next tick re-arms and, with attempt 2 green, merges" merged
check "rerun: re-armed with fresh deadlines (arm_at = the re-arm tick's now, appear = +300)" [ "$(state .arm_at)" = "$((NOW + 60))" ] -- [ "$(state .appear_deadline)" = "$((NOW + 60 + 300))" ]
check "rerun: history reads failed, pending, green, merging, merged" [ "$(state '[.history[].to] | join(",")')" = "failed,pending,green,merging,merged" ]
# (f) the flake note: exactly one, kind gap, from the PR, by the verb, body names head/run/attempt/base/reason
check "flake: exactly one discovered note was filed" [ "$(ls "$INBOX"/*.md 2>/dev/null | wc -l | tr -d ' ')" = 1 ]
NOTE="$(ls "$INBOX"/*.md 2>/dev/null | head -1)"
check "flake: title is flaky: <path> went red then green on rerun for PR #<n> (<reason>)" \
  grep -q "^title: flaky: $CI went red then green on rerun for PR #$PR (runner contention, e2e timed out under load)$" "$NOTE"
check "flake: frontmatter kind gap, discovered_from PR #<n>, discovered_by sweap-merge rerun" \
  grep -q '^kind: gap$' "$NOTE" -- grep -q "^discovered_from: PR #$PR$" "$NOTE" -- grep -q '^discovered_by: sweap-merge rerun$' "$NOTE"
check "flake: body names the head SHA, the failed run id, both attempts, the base SHA and the reason" \
  grep -q "head $HEAD1" "$NOTE" -- grep -q "run 101 attempt 1" "$NOTE" -- grep -q "green on attempt 2" "$NOTE" -- grep -q "base $BSHA1" "$NOTE" -- grep -q "reason: runner contention" "$NOTE"
check "flake: body ends with the occurrence line" grep -q "^- PR #$PR head $HEAD1 run 101 at 2026-08-25T10:03:00Z$" "$NOTE"
check "flake: the rerun entry is marked noted (never filed twice)" [ "$(state '.reruns[0].flake_noted')" = true ]
check "flake: filing is reported on stderr, not stdout (stdout stays one line)" grep -q '^\[sweap-merge\] flake: .*filed roadmap/discovered/' "$FIX/stderr" -- [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ]
# a second PR with the same workflow flake APPENDS to that note, never a second file
PR=8
newcase r-flake-second
red_ci
drive tick "$PR"; expect "flake: second PR (#8) goes red on the same workflow" failed
drive rerun "$PR" --reason "same e2e timeout"
check "flake: second PR's rerun accepted" [ "$RC" = 0 ] -- word_is pending
green_ci_attempt2
drive tick "$PR"; expect "flake: second PR turns green on the rerun and merges" merged
check "flake: still exactly one note (appended, not a second file)" [ "$(ls "$INBOX"/*.md 2>/dev/null | wc -l | tr -d ' ')" = 1 ]
check "flake: the second occurrence is one appended line" grep -q "^- PR #8 head $HEAD1 run 101 at " "$NOTE" -- [ "$(grep -c '^- PR #' "$NOTE" | tr -d ' ')" = 2 ]
check "flake: the append left the title and the first occurrence intact" grep -q "^title: flaky: $CI went red then green on rerun for PR #7 " "$NOTE" -- grep -q "^- PR #7 head" "$NOTE"
check "flake: append reported on stderr" grep -q '^\[sweap-merge\] flake: .*appended to roadmap/discovered/' "$FIX/stderr"
PR=7
# (f') no discovered inbox => skip with a log line, never a merge blocker
newcase r-no-inbox
rm -rf "$INBOX"
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "flake"
green_ci_attempt2
drive tick "$PR"; expect "flake: without a discovered inbox the merge still lands" merged
check "flake: the skip is logged and nothing was created" grep -q '^\[sweap-merge\] flake note skipped: no discovered inbox' "$FIX/stderr" -- [ ! -d "$INBOX" ]
check "flake: the entry is marked skipped (no retry on a later pass)" [ "$(state '.reruns[0].flake_noted')" = skipped ]
mkdir -p "$INBOX"

# (b) one rerun per head, ever
newcase r-twice
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "first"
check "rerun: first accepted" [ "$RC" = 0 ]
write_runs "$(run 101 "$CI" completed failure 2)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "rerun: attempt 2 is red again => failed" failed "ci.yml failure"
seq_before="$(state .seq)"
drive rerun "$PR" --reason "second"
check "rerun: a second rerun of the same workflow on the same head is refused (exit 1, word refused, says why)" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "already rerun once" -- contains "$OUT" "$CI at" -- contains "$OUT" "reason: first"
check "rerun: refusal changed nothing (state failed, one entry, no new rerun call, no write)" \
  [ "$(state .state)" = failed ] -- [ "$(state '.reruns|length')" = 1 ] -- [ "$(reruns_in_log)" = 1 ] -- [ "$(state .seq)" = "$seq_before" ]
check "rerun: refusal released no lease it never took" [ ! -d "$STATE_DIR/$PR.lock" ]

# (c) the same workflow red on the base tip
newcase r-base-red
red_ci
drive tick "$PR"
printf '[{"status":"completed","conclusion":"failure","headSha":"%s","databaseId":555}]\n' "$BSHA1" >"$FIX/baserun.ci.yml.json"
seq_before="$(state .seq)"
drive rerun "$PR" --reason "flake?"
check "rerun: base tip red on the same workflow => refused, names the base run" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "also red on main's tip (run 555: failure)"
check "rerun: red base => no rerun issued, state untouched" [ "$(reruns_in_log)" = 0 ] -- [ "$(state .state)" = failed ] -- [ "$(state '.reruns // [] | length')" = 0 ] -- [ "$(state .seq)" = "$seq_before" ]
printf '[{"status":"in_progress","conclusion":null,"headSha":"%s","databaseId":556}]\n' "$BSHA1" >"$FIX/baserun.ci.yml.json"
drive rerun "$PR" --reason "base still running"
check "rerun: a base run still in progress is not red (accepted)" [ "$RC" = 0 ] -- word_is pending

# (d) not failed: pending, missing-after-deadline (failed but nothing completed), no state file, head moved
newcase r-not-failed
write_runs "$(run 101 "$CI" in_progress null)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "rerun: pending PR" pending
drive rerun "$PR" --reason "impatient"
check "rerun: state pending => refused, nothing written" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "'pending', not failed" -- [ "$(state '.reruns // [] | length')" = 0 ] -- [ "$(reruns_in_log)" = 0 ]
newcase r-failed-not-completed
write_runs
drive tick "$PR"; expect "rerun: no runs yet => missing (arms the appear deadline)" missing
TNOW=$((NOW + 301)) drive tick "$PR"; expect "rerun: missing past appear_deadline => failed" failed "missing"
drive rerun "$PR" --reason "flake"
check "rerun: failed without a completed failure run => refused (nothing to rerun)" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "without a completed 'failure' run" -- [ "$(reruns_in_log)" = 0 ]
newcase r-cancelled
write_runs "$(run 101 "$CI" completed cancelled)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "rerun: cancelled => failed" failed cancelled
drive rerun "$PR" --reason "flake"
check "rerun: a cancelled run is not a flake => refused" [ "$RC" = 1 ] -- word_is refused -- [ "$(reruns_in_log)" = 0 ]
newcase r-no-state
drive rerun "$PR" --reason "flake"
check "rerun: no state file => refused, no gh call, none created" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "no state file" -- [ ! -s "$FIX/gh.log" ] -- [ ! -f "$STATE_DIR/$PR.json" ]
newcase r-head-moved
red_ci
drive tick "$PR"
write_pr pr.json OPEN "$HEAD2"
drive rerun "$PR" --reason "flake"
check "rerun: head moved since the red => refused (a rerun would test the old commit), nothing issued" \
  [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "head moved" -- [ "$(reruns_in_log)" = 0 ] -- [ "$(state .state)" = failed ]
newcase r-held
red_ci
drive tick "$PR"
sleep 30 & LIVE5=$!
mk_lock "other:$LIVE5" 1 "$LIVE5" "$NOW"
drive rerun "$PR" --reason "flake"; expect "rerun: a live poller holds the lease => held-by" "held-by:other:$LIVE5"
check "rerun: held-by issued no rerun" [ "$(reruns_in_log)" = 0 ]
kill "$LIVE5" 2>/dev/null; wait "$LIVE5" 2>/dev/null
newcase r-gh-refuses
red_ci
drive tick "$PR"
XENV="GH_RERUN=fail" drive rerun "$PR" --reason "flake"
check "rerun: gh run rerun refused => refused, nothing recorded" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "no rerun was issued" -- [ "$(state '.reruns // [] | length')" = 0 ] -- [ "$(state .state)" = failed ]
# partial issue: two red runs, the second rerun call is refused => the one that
# WAS issued is recorded (it counts against this head), state pending, exit 1
newcase r-partial
write_runs "$(run 101 "$CI" completed failure)" "$(run 102 "$AG" completed failure)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "rerun: two red expected runs => failed" failed
XENV="GH_RERUN_FAIL_ID=102" drive rerun "$PR" --reason "two flakes"
check "rerun: partial issue => word failed, exit 1, names the refused run" [ "$RC" = 1 ] -- word_is failed -- contains "$OUT" "issued for 101 but not all" -- contains "$OUT" "run 102"
check "rerun: partial issue is RECORDED (issued=[101], run_ids=[101,102]) and the state is pending" \
  [ "$(state '.reruns | length')" = 1 ] -- [ "$(state '.reruns[0].issued | join(",")')" = 101 ] -- [ "$(state '.reruns[0].run_ids | sort | join(",")')" = "101,102" ] -- [ "$(state .state)" = pending ]
check "rerun: both reruns were attempted" [ "$(reruns_in_log)" = 2 ]
drive rerun "$PR" --reason "again"
check "rerun: the partial record still consumes the head's one rerun" [ "$RC" = 1 ] -- word_is refused
# the run that was NOT issued is a verdict on the next tick, not a stale attempt
write_runs "$(run 101 "$CI" completed success 2)" "$(run 102 "$AG" completed failure)" "$(run 103 "$CR" completed success)"
drive tick "$PR"; expect "rerun: the un-issued red run is still a real failure on the next tick" failed "audit-gate.yml failure"
# PR state from GitHub: CLOSED / MERGED / missing all refuse (fail closed)
for st in CLOSED MERGED; do
  newcase "r-pr-$st"
  red_ci
  drive tick "$PR"
  write_pr pr.json "$st"
  drive rerun "$PR" --reason "flake"
  check "rerun: PR $st on GitHub => refused, nothing issued" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "is $st" -- [ "$(reruns_in_log)" = 0 ]
done
newcase r-pr-nostate
red_ci
drive tick "$PR"
jq 'del(.state)' "$FIX/pr.json" >"$FIX/pr.tmp" && mv "$FIX/pr.tmp" "$FIX/pr.json"
drive rerun "$PR" --reason "flake"
check "rerun: gh pr view without a state => refused (fail closed), not treated as OPEN" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "returned no state" -- [ "$(reruns_in_log)" = 0 ]
# A. the snapshot judged before the claim is not what gets written: a tick that
# wrote between our read and our claim (here: the stub rewrites the file during
# `pr view`, after our snapshot) must be re-read under the lease and re-judged
newcase r-stale-snapshot
red_ci
drive tick "$PR"
printf '%s\n%s\n' "$STATE_DIR/$PR.json" '.state = "pending" | .history += [{at:1, from:"failed", to:"pending", why:"another tick"}]' >"$FIX/mutate.spec"
XENV="GH_MUTATE_STATE=$FIX/mutate.spec" drive rerun "$PR" --reason "flake"
check "rerun: state changed to pending under us => refused, nothing issued" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "'pending', not failed" -- [ "$(reruns_in_log)" = 0 ]
check "rerun: the other writer's row survived (not clobbered by our snapshot)" [ "$(state '.history | last | .why')" = "another tick" ] -- [ "$(state '.reruns // [] | length')" = 0 ]
newcase r-stale-head
red_ci
drive tick "$PR"
printf '%s\n%s\n' "$STATE_DIR/$PR.json" ".head = \"$HEAD2\"" >"$FIX/mutate.spec"
XENV="GH_MUTATE_STATE=$FIX/mutate.spec" drive rerun "$PR" --reason "flake"
check "rerun: head rewritten under us => refused, nothing issued" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "changed under us" -- [ "$(reruns_in_log)" = 0 ] -- [ "$(state .head)" = "$HEAD2" ]
newcase r-stale-observed
red_ci
drive tick "$PR"
# still failed, same head, but the red run's observation was replaced: the
# write must carry what is on disk now, not our snapshot's observed/history
printf '%s\n%s\n' "$STATE_DIR/$PR.json" ".observed[\"$CI\"].run_id = 777 | .history += [{at:1, from:\"failed\", to:\"failed\", why:\"rewritten\"}]" >"$FIX/mutate.spec"
XENV="GH_MUTATE_STATE=$FIX/mutate.spec" drive rerun "$PR" --reason "flake"
check "rerun: accepted on the re-read: the rerun targets the run the FILE names now (777), not the snapshot's 101" \
  [ "$RC" = 0 ] -- word_is pending -- [ "$(cat "$FIX/rerun.log")" = "--failed 777" ] -- [ "$(state '.reruns[0].run_ids | join(",")')" = 777 ]
check "rerun: the other writer's history row is still there after our write" [ "$(state '[.history[].why] | index("rewritten")')" != null ]
# B. the note writer is charged against the tick budget: a tiny budget defers
# the note, the merge still lands, and the merged re-entry files it
newcase r-note-deferred
mkdir -p "$INBOX"; rm -f "$INBOX"/*.md
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "budget"
green_ci_attempt2
drive tick "$PR" --budget 5; expect "flake: with a 5 s budget the merge still lands" merged
check "flake: the note was deferred, not filed, and the entry is not marked" \
  grep -q '^\[sweap-merge\] flake note deferred' "$FIX/stderr" -- [ "$(ls "$INBOX"/*.md 2>/dev/null | wc -l | tr -d ' ')" = 0 ] -- [ "$(state '.reruns[0].flake_noted // "unset"')" = unset ]
drive tick "$PR"; expect "flake: the merged re-entry tick still says merged" merged
check "flake: the deferred note is filed on the re-entry pass, once" [ "$(ls "$INBOX"/*.md 2>/dev/null | wc -l | tr -d ' ')" = 1 ] -- [ "$(state '.reruns[0].flake_noted')" = true ]
drive tick "$PR"
check "flake: a third pass files nothing more" [ "$(ls "$INBOX"/*.md 2>/dev/null | wc -l | tr -d ' ')" = 1 ] -- [ "$(grep -c '^- PR #' "$INBOX"/*.md | tr -d ' ')" = 1 ]
rm -f "$INBOX"/*.md
# C. the listing lags the rerun: attempt 1 still reported completed/failure for
# the rerun's run id is a stale observation, not a verdict — pending until the
# attempt advances or the appear deadline passes
newcase r-stale-attempt
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "lagging listing"
drive tick "$PR"; expect "rerun: the run listing still shows attempt 1 failure right after the rerun => pending, not failed" pending "rerun of run 101 not yet visible"
check "rerun: the head's one rerun was not consumed by the stale tick (still one entry, state pending)" [ "$(state '.reruns | length')" = 1 ] -- [ "$(state .state)" = pending ] -- [ "$(reruns_in_log)" = 1 ]
green_ci_attempt2
drive tick "$PR"; expect "rerun: attempt 2 success => green => merged" merged
newcase r-stale-attempt-deadline
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "lagging listing"
drive tick "$PR"; expect "rerun: stale attempt => pending (arms the appear deadline)" pending
TNOW=$((NOW + 301)) drive tick "$PR"; expect "rerun: attempt 1 still reported after appear_deadline => failed (the rerun never appeared)" failed "never appeared"
drive rerun "$PR" --reason "once more"
check "rerun: and the workflow's rerun on this head is spent" [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "already rerun once"
# the cap is per (head, workflow): consumer PR #319 — ci.yml red, rerun, then
# claude-review.yml red on the SAME head. The second workflow's first red gets
# its own rerun; a second red of ci.yml on that head does not.
newcase r-per-workflow
red_ci
drive tick "$PR"
drive rerun "$PR" --reason "ci flake"
check "rerun: ci.yml rerun recorded" [ "$RC" = 0 ] -- [ "$(state '.reruns[0].runs[0].path')" = "$CI" ]
write_runs "$(run 101 "$CI" completed success 2)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed failure)"
drive tick "$PR"; expect "rerun: ci.yml green on attempt 2 but claude-review.yml red on the same head => failed" failed "claude-review.yml failure"
drive rerun "$PR" --reason "review flake"
check "rerun: a DIFFERENT workflow's first red on the same head is accepted, rerun issued for it only" \
  [ "$RC" = 0 ] -- word_is pending -- [ "$(tail -1 "$FIX/rerun.log")" = "--failed 103" ] -- [ "$(reruns_in_log)" = 2 ] \
  -- [ "$(state '.reruns | length')" = 2 ] -- [ "$(state '.reruns[1].runs | map(.path) | join(",")')" = "$CR" ]
write_runs "$(run 101 "$CI" completed failure 3)" "$(run 102 "$AG" completed success)" "$(run 103 "$CR" completed success 2)"
drive tick "$PR"; expect "rerun: review green on attempt 2, ci red AGAIN on attempt 3 => failed" failed "ci.yml failure"
drive rerun "$PR" --reason "ci again"
check "rerun: ci.yml's second red on the same head is refused (per head+workflow), review's spent too" \
  [ "$RC" = 1 ] -- word_is refused -- contains "$OUT" "already rerun once" -- contains "$OUT" "$CI" -- [ "$(reruns_in_log)" = 2 ] -- [ "$(state '.reruns | length')" = 2 ]
# a hand-shaped state file (the refuter's fixture): reruns for ci.yml on H, review red on H
newcase r-per-workflow-fixture
red_ci
drive tick "$PR"
jq --arg h "$HEAD1" --arg ci "$CI" --arg cr "$CR" '.reruns = [{head:$h, run_ids:[101], runs:[{path:$ci, run_id:101, attempt:1}], issued:[101], reason:"earlier", at:1, by:"t"}]
   | .observed[$ci] = {run_id:101, attempt:2, status:"completed", conclusion:"success"}
   | .observed[$cr] = {run_id:103, attempt:1, status:"completed", conclusion:"failure"}' "$STATE_DIR/$PR.json" >"$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
drive rerun "$PR" --reason "review flake"
check "rerun: fixture — review red with ci already rerun on H => pending, rerun issued for review only" \
  [ "$RC" = 0 ] -- word_is pending -- [ "$(cat "$FIX/rerun.log")" = "--failed 103" ] -- [ "$(state '.reruns | length')" = 2 ]
jq --arg ci "$CI" '.state = "failed" | .observed[$ci] = {run_id:101, attempt:3, status:"completed", conclusion:"failure"}' "$STATE_DIR/$PR.json" >"$STATE_DIR/$PR.tmp" && mv "$STATE_DIR/$PR.tmp" "$STATE_DIR/$PR.json"
drive rerun "$PR" --reason "ci again"
check "rerun: fixture — a second call for ci.yml on H => refused" [ "$RC" = 1 ] -- word_is refused -- [ "$(reruns_in_log)" = 1 ]

# (e) --reason is required (argv section also covers this; here: nothing touched)
newcase r-no-reason
red_ci
drive tick "$PR"
seq_before="$(state .seq)"
drive rerun "$PR"
check "rerun: without --reason => usage (exit 2), no gh call, no state change" [ "$RC" = 2 ] -- [ "$(reruns_in_log)" = 0 ] -- [ "$(state .seq)" = "$seq_before" ] -- [ "$(state .state)" = failed ]
drive rerun "$PR" --reason "   "
check "rerun: a whitespace-only --reason is no reason" [ "$RC" = 2 ]
# the driver never reruns on its own (memo D5): a red tick followed by a watch
# that goes red again issues no `run rerun` — only the hand verb ever does
drive watch "$PR"
check "rerun: a red tick and a red watch issued no rerun on their own" word_is failed -- [ "$(grep -c '^run rerun ' "$FIX/gh.log" | tr -d ' ')" = 0 ]
rm -rf "$INBOX"

# ======================================================================================
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
