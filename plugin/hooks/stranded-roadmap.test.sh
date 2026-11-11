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

# --- parked: a no-PR branch checked out in a LINKED worktree is an item's work in
# progress, not a dead branch. Every row below differs from `none` by one fact.
wt() { G "$R" worktree add -q "$WORK/wt-$1" "$1" 2>/dev/null; }
branch park-note  roadmap/discovered/p-111111.md "---\ntitle: p\nkind: gap\n---\n" nopush   # a note only
branch park-item  roadmap/F1.1.md "---\nid: F1.1\nstatus: todo\n---\nnotes\n" nopush       # F1.1 is todo on main
branch dead-item  roadmap/F1.9.md "x" nopush
branch bare-note  roadmap/discovered/b-222222.md "---\ntitle: b\nkind: gap\n---\n" nopush   # no worktree
# F1.9 exists on main and is DONE there; dead-item's worktree is a leftover.
printf -- '---\nid: F1.9\nstatus: done\n---\n' > "$R/roadmap/F1.9.md"; G "$R" add -A >/dev/null; G "$R" commit -qm f19; G "$R" push -q origin main 2>/dev/null
wt park-note; wt park-item; wt dead-item
pk() { run env GH_STATES='old-b=CLOSED' | awk -F'\t' -v b="$1" '$1==b{print $2}'; }
want "no PR + linked worktree, a note only -> parked"                          "parked" "$(pk park-note)"
want "no PR + linked worktree, its item still todo on main -> parked"          "parked" "$(pk park-item)"
want "no PR + linked worktree, but its only item is done on main -> none"      "none"   "$(pk dead-item)"
want "no PR, no worktree -> none (unchanged)"                                  "none"   "$(pk bare-note)"
want "a parked branch is still LISTED with its paths"                          "roadmap/discovered/p-111111.md" "$(run env GH_STATES='' | awk -F'\t' '$1=="park-note"{print $4}')"
want "PR closed unmerged stays closed even in a worktree"                      "closed" "$(run env GH_STATES='park-note=CLOSED' | awk -F'\t' '$1=="park-note"{print $2}')"
G "$R" worktree remove --force "$WORK/wt-park-note" 2>/dev/null
want "worktree removed -> the same branch is none again"                       "none"   "$(pk park-note)"
want "gh unavailable -> unknown, never parked"                                 "unknown" "$(run env GH_FAIL=1 | awk -F'\t' '$1=="park-item"{print $2}')"
G "$R" worktree remove --force "$WORK/wt-park-item" 2>/dev/null; G "$R" worktree remove --force "$WORK/wt-dead-item" 2>/dev/null
G "$R" branch -q -D park-note park-item dead-item bare-note 2>/dev/null

# One row per way the rule could be loosened or tightened by mistake.
printf -- '---\nid: F1.8\nstatus: dropped\n---\n' > "$R/roadmap/F1.8.md"                        # dropped, still top-level
mkdir -p "$R/roadmap/discovered"; mkdir -p "$R/roadmap/archive"; printf -- '---\nid: F1.7\nstatus: dropped\n---\n' > "$R/roadmap/archive/F1.7.md"   # dropped, archived
printf -- '---\ntitle: old\nstatus: done\n---\n' > "$R/roadmap/discovered/old-333333.md"       # a NOTE that happens to carry a status line
G "$R" add -A >/dev/null; G "$R" commit -qm closed-items; G "$R" push -q origin main 2>/dev/null
branch two-items   roadmap/F1.1.md "---\nid: F1.1\nstatus: todo\n---\nmore\n" nopush
G "$R" checkout -q two-items; printf 'y' >> "$R/roadmap/F1.9.md"; G "$R" add -A >/dev/null; G "$R" commit -qm also-f19; G "$R" checkout -q main
branch top-dropped roadmap/F1.8.md "x" nopush
branch arch-dropped roadmap/F1.7.md "---\nid: F1.7\nstatus: todo\n---\n" nopush              # edits the path main moved to archive/
branch sub-status  roadmap/discovered/old-333333.md "---\ntitle: old\nstatus: done\n---\nedited\n" nopush
branch pre         roadmap/discovered/s-444444.md "---\ntitle: s\nkind: gap\n---\n" nopush     # no worktree; `pre-fix` has one
branch pre-fix     roadmap/discovered/t-555555.md "---\ntitle: t\nkind: gap\n---\n" nopush
branch on-primary  roadmap/discovered/u-666666.md "---\ntitle: u\nkind: gap\n---\n" nopush
wt two-items; wt top-dropped; wt arch-dropped; wt sub-status; wt pre-fix
want "one of its items is still open, another is done -> parked (all closed, not any)"   "parked" "$(pk two-items)"
want "its only item reads dropped at the top level on main -> none"                     "none"   "$(pk top-dropped)"
want "its only item was moved to archive/ on main -> none"                              "none"   "$(pk arch-dropped)"
want "a status line in a file under discovered/ is not an item's status -> parked"      "parked" "$(pk sub-status)"
want "a branch whose name is a PREFIX of a worktree's branch is not in a worktree"      "none"   "$(pk pre)"
G "$R" checkout -q on-primary
want "checked out in the PRIMARY checkout only -> none (linked worktrees only)"          "none"   "$(pk on-primary)"
G "$R" checkout -q main
mv "$WORK/wt-pre-fix" "$WORK/wt-pre-fix.gone"
want "a worktree whose directory is gone (prunable) parks nothing -> none"              "none"   "$(pk pre-fix)"
mv "$WORK/wt-pre-fix.gone" "$WORK/wt-pre-fix"
for b in two-items top-dropped arch-dropped sub-status pre-fix; do G "$R" worktree remove --force "$WORK/wt-$b" 2>/dev/null; done
G "$R" branch -q -D two-items top-dropped arch-dropped sub-status pre pre-fix on-primary 2>/dev/null

# SWEAP_MAIN_REF override and the no-main failure.
out="$(cd "$R" && SWEAP_MAIN_REF=nope bash "$SCAN" 2>/dev/null; echo "rc=$?")"
want "unresolvable SWEAP_MAIN_REF exits 1" "rc=1" "$out"
# backlog.dir from CLAUDE.md
printf '## sweap config\nbacklog.dir: items/\n' > "$R/CLAUDE.md"
out="$(run env GH_STATES='old-b=CLOSED')"
want "configured backlog.dir: nothing under items/ -> nothing reported" "" "$out"

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
