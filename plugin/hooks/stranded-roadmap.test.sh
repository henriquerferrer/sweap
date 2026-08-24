#!/usr/bin/env bash
#
# stranded-roadmap.test.sh — deterministic, offline tests for stranded-roadmap.sh.
# Builds a bare "origin" plus a clone, pushes branches in every shape the scanner
# distinguishes, and stubs `gh` on PATH so PR state is driven by an env var.
#
# Run:  bash plugin/hooks/stranded-roadmap.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/stranded-roadmap.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
want() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s\n     got:    %s\n     wanted: %s\n' "$1" "$3" "$2"; fi; }

# --- gh stub: `gh pr list --head <name> ... --jq ...` -> state from GH_STATES
# ("name=OPEN,name2=CLOSED"); names absent print nothing (no PR); GH_FAIL=1 -> exit 1
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = "1" ] && exit 1
head=""; prev=""
for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
IFS=, read -ra pairs <<<"${GH_STATES:-}"
for p in "${pairs[@]}"; do [ "${p%%=*}" = "$head" ] && { printf '%s\n' "${p#*=}"; exit 0; }; done
exit 0
STUB
chmod +x "$WORK/bin/gh"

G() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
ORIGIN="$WORK/origin.git"; git init -q --bare "$ORIGIN"
R="$WORK/repo"; git clone -q "$ORIGIN" "$R" 2>/dev/null
mkdir -p "$R/roadmap/discovered" "$R/src"
printf '## sweap config\n' > "$R/CLAUDE.md"
printf -- '---\nid: F1.1\nstatus: todo\n---\n' > "$R/roadmap/F1.1.md"
printf 'code' > "$R/src/a.ts"
G "$R" add -A >/dev/null; G "$R" commit -qm init; G "$R" branch -M main; G "$R" push -q -u origin main 2>/dev/null

branch() { # branch <name> <file> <content> [push]
  G "$R" checkout -q -b "$1" main
  mkdir -p "$(dirname "$R/$2")"; printf '%s' "$3" > "$R/$2"
  G "$R" add -A >/dev/null; G "$R" commit -qm "$1"
  [ "${4:-push}" = "push" ] && G "$R" push -q -u origin "$1" 2>/dev/null
  G "$R" checkout -q main
}
branch feat-a   roadmap/F1.2.md "---\nid: F1.2\nstatus: todo\n---\n"
branch old-b    roadmap/discovered/x-0a1b2c.md "---\ntitle: x\nkind: gap\n---\nwhy\n"
branch code-c   src/b.ts "more code"
branch merged-d roadmap/F1.3.md "---\nid: F1.3\nstatus: todo\n---\n"
branch local-e  roadmap/ideas/e.md "---\ntitle: e\n---\n" nopush
# A local checkout of a pushed branch must not be reported twice.
G "$R" checkout -q feat-a; G "$R" checkout -q main

run() { (cd "$R" && PATH="$WORK/bin:$PATH" "$@" bash "$SCAN" 2>/dev/null | sort); }

echo "stranded-roadmap.test.sh:"
out="$(run env GH_STATES='feat-a=OPEN,old-b=CLOSED,merged-d=MERGED')"
want "open rider, closed stranded, no-PR local stranded; code-only and MERGED skipped; pushed branch reported once" \
"feat-a	open	0	roadmap/F1.2.md
local-e	none	0	roadmap/ideas/e.md
old-b	closed	0	roadmap/discovered/x-0a1b2c.md" "$out"

out="$(run env GH_FAIL=1)"
want "gh failing -> unknown state, never a crash" \
"feat-a	unknown	0	roadmap/F1.2.md
local-e	unknown	0	roadmap/ideas/e.md
merged-d	unknown	0	roadmap/F1.3.md
old-b	unknown	0	roadmap/discovered/x-0a1b2c.md" "$out"

out="$(run env SWEAP_STRANDED_NO_GH=1 GH_STATES='feat-a=OPEN')"
want "SWEAP_STRANDED_NO_GH skips the lookup" "$(printf 'feat-a\tunknown\t0\troadmap/F1.2.md\nlocal-e\tunknown\t0\troadmap/ideas/e.md\nmerged-d\tunknown\t0\troadmap/F1.3.md\nold-b\tunknown\t0\troadmap/discovered/x-0a1b2c.md')" "$out"

# Multiple files on one branch are comma-joined; a branch that also touches
# code is still reported (the roadmap part is what can strand).
G "$R" checkout -q feat-a; printf -- '---\nid: F1.4\nstatus: todo\n---\n' > "$R/roadmap/F1.4.md"; printf 'x' > "$R/src/c.ts"
G "$R" add -A >/dev/null; G "$R" commit -qm more; G "$R" push -q origin feat-a 2>/dev/null; G "$R" checkout -q main
out="$(run env GH_STATES='feat-a=OPEN,old-b=CLOSED,merged-d=MERGED' | grep '^feat-a')"
want "multiple roadmap paths comma-joined, code on the same branch ignored" "feat-a	open	0	roadmap/F1.2.md,roadmap/F1.4.md" "$out"

# Merged-for-real (fast-forward) branches are not candidates at all.
G "$R" merge -q --ff-only origin/feat-a 2>/dev/null; G "$R" push -q origin main 2>/dev/null
out="$(run env GH_STATES='feat-a=OPEN' | grep -c '^feat-a' || true)"
want "a branch whose commits are on main is not listed" "0" "$out"

# SWEAP_MAIN_REF override and the no-main failure.
out="$(cd "$R" && SWEAP_MAIN_REF=nope bash "$SCAN" 2>/dev/null; echo "rc=$?")"
want "unresolvable SWEAP_MAIN_REF exits 1" "rc=1" "$out"
# backlog.dir from CLAUDE.md
printf '## sweap config\nbacklog.dir: items/\n' > "$R/CLAUDE.md"
out="$(run env GH_STATES='old-b=CLOSED')"
want "configured backlog.dir: nothing under items/ -> nothing reported" "" "$out"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
