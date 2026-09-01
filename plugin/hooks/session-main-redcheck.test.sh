#!/usr/bin/env bash
#
# session-main-redcheck.test.sh — deterministic, OFFLINE tests for the
# SessionStart base-branch red check. `gh` is stubbed on PATH, so nothing here
# touches the network; the point is the decision table, not GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/session-main-redcheck.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$3" "$2"; fi; }
has()  { if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL  %s (missing %s in: %s)\n' "$1" "$3" "$2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -q "$3"; then fail=$((fail+1)); printf '  FAIL  %s (unexpected %s)\n' "$1" "$3"
         else pass=$((pass+1)); printf '  PASS  %s\n' "$1"; fi; }

echo "session-main-redcheck.test.sh:"

# --- a repo to run in ---------------------------------------------------------
R="$WORK/repo"; mkdir -p "$R"
git -C "$R" init -q
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# --- a stubbed gh whose payload the test controls -----------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
[ -n "${FAKE_GH_OUT:-}" ] || exit 1
[ "${FAKE_GH_FAIL:-0}" = "1" ] && exit 1
cat "$FAKE_GH_OUT"
GH
chmod +x "$BIN/gh"

run() { # run <source> ; stdout of the hook
  printf '{"source":"%s","cwd":"%s"}' "$1" "$R" \
    | PATH="$BIN:$PATH" SWEAP_BASE_BRANCH=main bash "$HOOK" 2>/dev/null
}
clean_markers() { rm -f "$R/.claude/main-red-"*.flag 2>/dev/null; }
markers() { ls "$R"/.claude/main-red-*.flag 2>/dev/null | wc -l | tr -d ' '; }

red_json='{"check_runs":[{"name":"checks","status":"completed","conclusion":"failure","head_sha":"abc123"},{"name":"lint","status":"completed","conclusion":"success","head_sha":"abc123"}]}'
green_json='{"check_runs":[{"name":"checks","status":"completed","conclusion":"success","head_sha":"abc123"}]}'
pending_json='{"check_runs":[{"name":"checks","status":"in_progress","conclusion":null,"head_sha":"abc123"}]}'
empty_json='{"check_runs":[]}'
skipped_json='{"check_runs":[{"name":"e2e","status":"completed","conclusion":"skipped","head_sha":"abc123"},{"name":"checks","status":"completed","conclusion":"success","head_sha":"abc123"}]}'
timeout_json='{"check_runs":[{"name":"e2e","status":"completed","conclusion":"timed_out","head_sha":"def456"}]}'

export FAKE_GH_OUT="$WORK/gh.json"

# --- red -> banner + marker ---------------------------------------------------
clean_markers; printf '%s' "$red_json" > "$FAKE_GH_OUT"
out="$(run startup)"
has  "red: banner names the branch as red"      "$out" "IS RED"
has  "red: banner names the failing check"      "$out" "checks=FAILURE"
hasnt "red: a passing check is not reported"    "$out" "lint=SUCCESS"
has  "red: banner explains the PR knock-on"     "$out" "inherits the failure"
has  "red: banner is SessionStart JSON"         "$out" "additionalContext"
ok   "red: marker written" 1 "$(markers)"
has  "red: marker says it was not a merge"      "$(cat "$R"/.claude/main-red-*.flag)" "DIRECT PUSH"

# --- rerunning does not rewrite an existing marker ----------------------------
before="$(cat "$R"/.claude/main-red-abc123.flag)"
out="$(run startup)"
ok   "red: marker count stays 1 on a second session" 1 "$(markers)"
ok   "red: existing marker is left untouched" "$before" "$(cat "$R"/.claude/main-red-abc123.flag)"

# --- terminal-but-not-failure states -----------------------------------------
clean_markers; printf '%s' "$timeout_json" > "$FAKE_GH_OUT"
out="$(run startup)"
has  "timed_out counts as red"                  "$out" "e2e=TIMED_OUT"
ok   "timed_out: marker written" 1 "$(markers)"

# --- quiet paths --------------------------------------------------------------
for case_name in green pending empty skipped; do
  clean_markers
  case "$case_name" in
    green)   printf '%s' "$green_json"   > "$FAKE_GH_OUT" ;;
    pending) printf '%s' "$pending_json" > "$FAKE_GH_OUT" ;;
    empty)   printf '%s' "$empty_json"   > "$FAKE_GH_OUT" ;;
    skipped) printf '%s' "$skipped_json" > "$FAKE_GH_OUT" ;;
  esac
  out="$(run startup)"
  ok "$case_name: says nothing" "" "$out"
  ok "$case_name: writes no marker" 0 "$(markers)"
done

# --- compact/clear are the same session continuing ----------------------------
clean_markers; printf '%s' "$red_json" > "$FAKE_GH_OUT"
ok "compact: silent even when red" "" "$(run compact)"
ok "compact: writes no marker" 0 "$(markers)"
ok "clear: silent even when red"   "" "$(run clear)"
ok "resume: still reports (a resume is a new session)" \
   "0" "$( [ -n "$(run resume)" ] && echo 0 || echo 1 )"

# --- fail-open: never block a session -----------------------------------------
clean_markers; printf 'not json at all' > "$FAKE_GH_OUT"
ok "unparseable payload: silent" "" "$(run startup)"
ok "unparseable payload: no marker" 0 "$(markers)"

clean_markers; printf '%s' "$red_json" > "$FAKE_GH_OUT"
ok "gh failure: silent" "" "$(FAKE_GH_FAIL=1 run startup)"
ok "gh failure: no marker" 0 "$(markers)"

# a PATH with jq and git but deliberately NO gh
clean_markers
NOGH="$WORK/nogh"; mkdir -p "$NOGH"
for t in jq git mktemp date sed dirname; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$NOGH/$t"
done
ok "no gh on PATH: silent" "" \
  "$(printf '{"source":"startup","cwd":"%s"}' "$R" | PATH="$NOGH" SWEAP_BASE_BRANCH=main bash "$HOOK" 2>/dev/null)"
ok "no gh on PATH: no marker" 0 "$(markers)"
ok "outside a git repo: silent" "" "$(printf '{"source":"startup","cwd":"%s"}' "$WORK" | PATH="$BIN:$PATH" SWEAP_BASE_BRANCH=main bash "$HOOK" 2>/dev/null)"

# --- exit status is always 0 (a smoke alarm must never fail the session) ------
clean_markers; printf '%s' "$red_json" > "$FAKE_GH_OUT"
printf '{"source":"startup","cwd":"%s"}' "$R" | PATH="$BIN:$PATH" SWEAP_BASE_BRANCH=main bash "$HOOK" >/dev/null 2>&1
ok "exit 0 even when red" 0 "$?"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
