#!/usr/bin/env bash
#
# audit-gate.sh — mechanical enforcement of the milestone-audit invariant.
#
# Invariant: a milestone whose items are all `status: done` and which is not
# listed in `audit.baseline` must have a VALID audit record at
# <backlog.dir>audits/<milestone>.md before any backlog-advancing merge lands.
# This converts the playbook's "the audit is part of the milestone's definition
# of done" from doctrine into mechanism (see the 2026-08-09 design spec and the
# 2026-08-08 research memo: enforcement of "a valid audit EXISTS" is cheap and
# deterministic even though the audit itself is expensive and session-run).
#
# Modes:
#   audit-gate.sh --check
#       Repo-state mode (CI, /milestone & /roadmap pre-flights, and
#       /milestone-audit's own self-check). Exit 0 = no audit debt and every
#       record under audits/ is valid. Exit 1 = "FAIL: ..." lines on stdout.
#   audit-gate.sh --files <path>...
#       Merge mode (pre-merge-gate, CI diff classification). Given a PR's
#       changed paths: exit 0 if the merge is allowed under the roadmap-scoped
#       denial, exit 1 with "FAIL: ..." lines if it must be denied.
#
# Both modes run from the repo root (cwd). Deterministic and OFFLINE: bash +
# git only — network trust lives in the callers (pre-merge-gate / CI).
#
# Format contract (playbook "Backlog format"): flat single-line frontmatter
# keys; inline [a, b] lists. That contract is what keeps this script trivial —
# do not grow a YAML parser here (same rule as roadmap-lint.sh).
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
  --check|--files) : ;;
  *) echo "usage: audit-gate.sh --check | --files <path>..."; exit 2 ;;
esac
shift

fails=0
fail() { echo "FAIL: $1"; fails=1; }

# --- frontmatter helpers (same idiom as roadmap-lint.sh) ------------------------
frontmatter() { awk '{ sub(/\r$/,"") } NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$1"; }
fm_get() { frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }

# --- config from CLAUDE.md's `## sweap config` block ----------------------------
# Keys are unique single-line `key: value` entries; match anywhere in the file
# (same relaxation sweap-board.lib.mjs#readConfig uses).
cfg_get() { [ -f CLAUDE.md ] && sed -n "s/^$1:[[:space:]]*//p" CLAUDE.md | head -1 | sed 's/[[:space:]]*$//' || true; }

BACKLOG_DIR="$(cfg_get 'backlog\.dir')"
BACKLOG_DIR="${BACKLOG_DIR:-roadmap/}"
case "$BACKLOG_DIR" in */) : ;; *) BACKLOG_DIR="$BACKLOG_DIR/" ;; esac

BASELINE="$(cfg_get 'audit\.baseline' | tr -d '[]' | tr ',' ' ')"
in_baseline() { local m; for m in $BASELINE; do [ "$m" = "$1" ] && return 0; done; return 1; }

# --- enumerate item files (TOP-LEVEL only — audits/, ideas/, archive/ are not
# item files) and compute complete milestones: milestone = id minus last dot
# segment (parity with sweap-board.lib.mjs#milestoneOf); complete = every item
# under the prefix is done. awk aggregation keeps this bash-3.2 safe.
item_rows() { # "<milestone> <status>" per item file
  local f id status
  for f in "${BACKLOG_DIR}"*.md; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .md)"
    case "$id" in *.*) : ;; *) continue ;; esac   # no dot => not an item file
    status="$(fm_get "$f" status)"
    printf '%s %s\n' "${id%.*}" "${status:-unknown}"
  done
}
COMPLETE="$(item_rows | awk '{tot[$1]++; if($2=="done") d[$1]++} END{for(m in tot) if(d[m]==tot[m]) print m}' | sort)"

# --- record validation ----------------------------------------------------------
# Task 2 (binding) and Task 3 (triage closure) extend this function. A record
# failing here does NOT crash the gate: the milestone stays in debt and the
# reason is reported.
validate_record() { # validate_record <milestone> <file> ; 0 = valid
  local m="$1" rec="$2"
  local ok=1
  [ "$(fm_get "$rec" milestone)" = "$m" ] || { fail "record $rec: milestone key != $m"; ok=0; }
  [ "$ok" = 1 ]
}

# --- debt set -------------------------------------------------------------------
DEBT=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  in_baseline "$m" && continue
  rec="${BACKLOG_DIR}audits/$m.md"
  if [ ! -f "$rec" ]; then
    DEBT="$DEBT$m"$'\n'
    [ "$MODE" = "--check" ] && fail "milestone $m is complete but has no audit record ($rec) — run /milestone-audit for it"
  elif ! validate_record "$m" "$rec"; then
    DEBT="$DEBT$m"$'\n'
  fi
done <<COMPLETE_EOF
$COMPLETE
COMPLETE_EOF

if [ "$MODE" = "--check" ]; then
  exit "$fails"
fi

# --- merge mode (--files): roadmap-scoped denial --------------------------------
# Deny iff debt exists AND the PR touches top-level item files AND it does not
# discharge the debt (contain the audit record for a debt milestone). Follow-up
# and blocked items ride the same PR as the record, so path-level detection of
# the record is sufficient (record validity is re-checked at the next --check).
[ -n "$(printf '%s' "$DEBT")" ] || exit 0
touches_items=0; discharges=0
for f in "$@"; do
  case "$f" in
    "${BACKLOG_DIR}audits/"*.md)
      m="$(basename "$f" .md)"
      while IFS= read -r d; do [ "$m" = "$d" ] && discharges=1; done <<DEBT_EOF
$DEBT
DEBT_EOF
      ;;
    "${BACKLOG_DIR}"*/*) : ;;              # other subdirs (ideas/, archive/) — not item files
    "${BACKLOG_DIR}"*.md) touches_items=1 ;;
  esac
done
if [ "$touches_items" = 1 ] && [ "$discharges" = 0 ]; then
  debt_list="$(printf '%s' "$DEBT" | tr '\n' ' ')"
  fail "audit debt exists for milestone(s): ${debt_list}— this PR advances the backlog without discharging it. Run /milestone-audit and land its record (+ follow-ups) first; code-only PRs are unaffected."
fi
exit "$fails"
