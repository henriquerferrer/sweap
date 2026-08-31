#!/usr/bin/env bash
#
# version-bump-check.test.sh — deterministic, offline tests for
# scripts/version-bump-check.sh. Every case builds a throwaway git repo in a
# temp dir; nothing outside that dir is read or written, and no network is used.
#
# Run:  bash scripts/version-bump-check.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/version-bump-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/version-bump-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

want() { # want <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n     got:    %s\n     wanted: %s\n' "$1" "$3" "$2"; fi
}
want_has() { # want_has <desc> <needle> <haystack>
  case "$3" in
    *"$2"*) pass=$((pass+1)); printf '  PASS  %s\n' "$1" ;;
    *) fail=$((fail+1)); printf '  FAIL  %s\n     output did not contain: %s\n%s\n' "$1" "$2" "$3" ;;
  esac
}

G() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

manifest() { printf '{\n  "name": "sweap",\n  "version": "%s"\n}\n' "$1"; }

# newrepo <name> [branch] — a repo whose first commit already carries the
# manifest, a shipped command and a test file, on `main` (or <branch>).
newrepo() {
  R="$WORK/$1"
  mkdir -p "$R/plugin/.claude-plugin" "$R/plugin/commands" "$R/plugin/hooks/testdata" "$R/plugin/tools"
  manifest 0.15.0 > "$R/plugin/.claude-plugin/plugin.json"
  printf 'base command\n' > "$R/plugin/commands/run.md"
  printf 'echo base\n' > "$R/plugin/hooks/thing.test.sh"
  printf 'fixture\n' > "$R/plugin/hooks/testdata/sample.json"
  printf 'export const a = 1;\n' > "$R/plugin/tools/lib.mjs"
  git init -q "$R"
  G "$R" add -A >/dev/null
  G "$R" commit -qm init
  G "$R" branch -M "${2:-main}"
  printf '%s' "$R"
}

# run <repo> [env...] — runs the check from inside the repo, capturing output
# and appending "rc=N" so a single string carries both.
run() { r=$1; shift; (cd "$r" && "$@" bash "$CHECK" 2>&1; printf 'rc=%s' "$?"); }
rc_of() { printf '%s' "${1##*rc=}"; }

echo "version-bump-check.test.sh:"

# --- consumer-visible change, no bump -> FAIL --------------------------------
R=$(newrepo novisible-nobump)
G "$R" checkout -q -b feat
printf 'walkthrough\n' > "$R/plugin/commands/walkthrough.md"
G "$R" add -A >/dev/null; G "$R" commit -qm "add walkthrough"
out=$(run "$R")
want     "consumer-visible change + no bump -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...names the offending file"        "plugin/commands/walkthrough.md" "$out"
want_has "  ...names the escape hatch"          "SWEAP_SKIP_VERSION_CHECK=1" "$out"
want_has "  ...prints the cache sentence"       "the plugin cache is keyed by version" "$out"
want_has "  ...prints the current version"      "0.15.0" "$out"
base_sha=$(G "$R" rev-parse main)
want_has "  ...prints the baseline sha"         "$base_sha" "$out"

# --- 5. escape hatch on that same repo ---------------------------------------
out=$(run "$R" env SWEAP_SKIP_VERSION_CHECK=1)
want     "SWEAP_SKIP_VERSION_CHECK=1 -> skip + pass" "0" "$(rc_of "$out")"
want_has "  ...prints the reason"               "SWEAP_SKIP_VERSION_CHECK=1" "$out"

# --- consumer-visible change + bump -> PASS ----------------------------------
manifest 0.16.0 > "$R/plugin/.claude-plugin/plugin.json"
G "$R" add -A >/dev/null; G "$R" commit -qm "bump"
out=$(run "$R")
want     "consumer-visible change + bump -> exit 0" "0" "$(rc_of "$out")"
want_has "  ...reports the bump"                "0.15.0 -> 0.16.0" "$out"

# --- only test files / testdata changed, no bump -> PASS ---------------------
R=$(newrepo testfiles-only)
G "$R" checkout -q -b feat
printf 'echo more\n' >> "$R/plugin/hooks/thing.test.sh"
printf 'import x;\n' > "$R/plugin/tools/lib.test.mjs"
printf 'more fixture\n' >> "$R/plugin/hooks/testdata/sample.json"
G "$R" add -A >/dev/null; G "$R" commit -qm "tests only"
out=$(run "$R")
want     "only *.test.sh / *.test.mjs / testdata/ changed, no bump -> exit 0" "0" "$(rc_of "$out")"
want_has "  ...says nothing consumer-visible changed" "no consumer-visible change" "$out"

# --- mixed: a test file and a real file, no bump -> FAIL ---------------------
R=$(newrepo mixed)
G "$R" checkout -q -b feat
printf 'echo more\n' >> "$R/plugin/hooks/thing.test.sh"
printf 'export const b = 2;\n' >> "$R/plugin/tools/lib.mjs"
G "$R" add -A >/dev/null; G "$R" commit -qm "mixed"
out=$(run "$R")
want     "mixed test file + real file, no bump -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...lists only the real file"       "- plugin/tools/lib.mjs" "$out"
case "$out" in
  *"- plugin/hooks/thing.test.sh"*) fail=$((fail+1)); printf '  FAIL  %s\n' "  ...does not list the test file" ;;
  *) pass=$((pass+1)); printf '  PASS  %s\n' "  ...does not list the test file" ;;
esac

# --- staged but not committed -> FAIL (the working-tree arm) -----------------
R=$(newrepo staged)
printf 'staged change\n' > "$R/plugin/commands/staged.md"
G "$R" add -A >/dev/null
out=$(run "$R")
want     "staged, uncommitted change -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...names the staged file"          "plugin/commands/staged.md" "$out"

# --- unstaged working-tree change -> FAIL ------------------------------------
R=$(newrepo unstaged)
printf 'edited in place\n' >> "$R/plugin/commands/run.md"
out=$(run "$R")
want     "unstaged working-tree change -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...names the edited file"          "plugin/commands/run.md" "$out"

# --- committed on a branch -> FAIL (already covered above, asserted explicitly)
R=$(newrepo branchcommit)
G "$R" checkout -q -b feat/thing
printf 'board\n' > "$R/plugin/tools/sweap-board.lib.mjs"
G "$R" add -A >/dev/null; G "$R" commit -qm "board work"
out=$(run "$R")
want     "committed on a branch -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...names the branch's file"        "plugin/tools/sweap-board.lib.mjs" "$out"

# --- on main, baseline == HEAD, clean tree -> PASS ---------------------------
R=$(newrepo clean-main)
out=$(run "$R")
want     "on main with baseline == HEAD and a clean tree -> exit 0" "0" "$(rc_of "$out")"
want_has "  ...says nothing consumer-visible changed" "no consumer-visible change" "$out"

# --- neither origin/main nor main -> SKIP + PASS -----------------------------
R=$(newrepo no-main trunk)
G "$R" checkout -q -b feat
printf 'x\n' > "$R/plugin/commands/x.md"
G "$R" add -A >/dev/null; G "$R" commit -qm x
out=$(run "$R")
want     "no origin/main and no main -> exit 0" "0" "$(rc_of "$out")"
want_has "  ...prints the reason"              "no origin/main and no main" "$out"

# --- origin/main is preferred over main when both resolve --------------------
# Local main has moved one un-pushed commit past origin/main. Against `main` the
# baseline would be HEAD itself and the check would see nothing; against
# origin/main it sees the un-bumped commit. Only the latter can fail, so a
# failure here is the proof that origin/main won.
R=$(newrepo prefers-origin)
ORIGIN="$WORK/prefers-origin.git"; git init -q --bare "$ORIGIN"
G "$R" remote add origin "$ORIGIN"
G "$R" push -q origin main 2>/dev/null
printf 'later\n' > "$R/plugin/commands/later.md"
G "$R" add -A >/dev/null; G "$R" commit -qm "local main moved ahead, no bump"
out=$(run "$R")
want     "origin/main beats a local main that moved ahead -> exit 1" "1" "$(rc_of "$out")"
want_has "  ...names origin/main as the baseline ref" "merge-base HEAD origin/main" "$out"
want_has "  ...names the un-pushed file"       "plugin/commands/later.md" "$out"

# --- baseline has no manifest at that path -> SKIP + PASS --------------------
R="$WORK/no-manifest"
mkdir -p "$R/plugin/commands"
printf 'old\n' > "$R/plugin/commands/old.md"
git init -q "$R"; G "$R" add -A >/dev/null; G "$R" commit -qm "history before the manifest"; G "$R" branch -M main
G "$R" checkout -q -b feat
mkdir -p "$R/plugin/.claude-plugin"
manifest 0.15.0 > "$R/plugin/.claude-plugin/plugin.json"
printf 'new\n' > "$R/plugin/commands/new.md"
G "$R" add -A >/dev/null; G "$R" commit -qm "add manifest and a command"
out=$(run "$R")
want     "baseline missing the manifest -> exit 0" "0" "$(rc_of "$out")"
want_has "  ...prints the reason"              "has no plugin/.claude-plugin/plugin.json" "$out"

# --- hermeticity: no read outside the repo -----------------------------------
# The check must never consult a consumer checkout or ~/.claude. Assert on the
# source rather than on behaviour: those paths must not appear at all.
offenders=$(grep -n -E '\.claude/|installed_plugins|\$HOME|~/' "$CHECK" | grep -v '^[0-9]*:#' || true)
want "no reference to ~/.claude, \$HOME or installed_plugins.json outside comments" "" "$offenders"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
