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
# The one merge this cannot ask for is the one that COMPLETES a milestone: the
# audit is only legal against the merged mainline, so its record cannot exist
# yet. That merge is exempt (see "the milestone boundary"); every merge after it
# is not.
#
# Modes:
#   audit-gate.sh --check
#       Repo-state mode (CI, /milestone & /roadmap pre-flights, and
#       /milestone-audit's own self-check). Exit 0 = no audit debt, every
#       record under audits/ is valid, and every hand-off item's provenance is
#       clean. Exit 1 = "FAIL: ..." lines on stdout.
#       TWO invariants share this mode, and callers that ACT on a failure must
#       tell them apart by the line's prefix: "FAIL: milestone <m> ..." /
#       "FAIL: record ..." is AUDIT DEBT (discharge it with /milestone-audit),
#       while "FAIL: hand-off <id> ..." is a backlog-integrity violation that is
#       not debt and is not discharged by an audit. They live in one script
#       because both are deterministic git-provenance questions about the
#       backlog, run by the same CI job on the same checkout — and adding a mode
#       (or a script) would mean a consumer repo's workflow file had to change
#       before the control could reach it.
#       This mode also prints NON-FAILING "AGING: blocked <id> ..." lines, one
#       per open blocked question, so the boundary that reads this output learns
#       what is pending on the human. Informational by design — see the block
#       that emits them.
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

# Record format version. Bump ONLY together with a migration story: every
# already-merged record written under an older format is classified LEGACY (see
# record_is_legacy) and reported without blocking, so a tightening can never
# retroactively wedge a consumer repo's loop. New records must carry the current
# version — that is what keeps "legacy" a closing door rather than a loophole.
RECORD_FORMAT=1

# The mainline anchor used to tell "already merged" from "introduced by the work
# under review". origin/main by default; CI on a PR sets it to origin/<base_ref>.
MAIN_REF="${SWEAP_MAIN_REF:-origin/main}"

# --- frontmatter helpers (same idiom as roadmap-lint.sh) ------------------------
frontmatter() { awk '{ sub(/\r$/,"") } NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$1"; }
fm_get() { frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }

# --- config from CLAUDE.md's `## sweap config` block ----------------------------
# Keys are unique single-line `key: value` entries; match anywhere in the file.
# NOT the same capture as sweap-board.lib.mjs#readConfig: that grabs only the
# first `\S+` token (comments dropped by construction). This script instead
# captures the rest of the line and then strips a trailing ` #...` comment
# suffix, so inline-list values like `[F1, F7]` survive intact.
cfg_get() { [ -f CLAUDE.md ] && sed -n "s/^$1:[[:space:]]*//p" CLAUDE.md | head -1 | sed 's/[[:space:]]*$//' | sed 's/[[:space:]]#.*$//' | sed 's/[[:space:]]*$//' || true; }

BACKLOG_DIR="$(cfg_get 'backlog\.dir')"
BACKLOG_DIR="${BACKLOG_DIR:-roadmap/}"
case "$BACKLOG_DIR" in */) : ;; *) BACKLOG_DIR="$BACKLOG_DIR/" ;; esac

BASELINE="$(cfg_get 'audit\.baseline' | tr -d '[]' | tr ',' ' ')"
in_baseline() { local m; for m in $BASELINE; do [ "$m" = "$1" ] && return 0; done; return 1; }

# --- enumerate item files (TOP-LEVEL only — audits/, ideas/, archive/ are not
# item files) and compute complete milestones: milestone = id minus last dot
# segment (parity with sweap-board.lib.mjs#milestoneOf); complete = every item
# under the prefix is done. awk aggregation keeps this bash-3.2 safe.
item_rows() { # item_rows [dir] -> "<milestone> <status>" per item file
  local dir="${1:-$BACKLOG_DIR}" f id status
  for f in "${dir}"*.md; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .md)"
    case "$id" in *.*) : ;; *) continue ;; esac   # no dot => not an item file
    status="$(fm_get "$f" status)"
    # Follow-up/blocked items created by an audit's triage are DEBT OF the
    # milestone, not members of it — they must not flip it back to incomplete
    # (they drain in the next /milestone run per the playbook).
    [ -n "$(fm_get "$f" followup_of)" ] && continue
    printf '%s %s\n' "${id%.*}" "${status:-unknown}"
  done
}
complete_from() { item_rows "$@" | awk '{tot[$1]++; if($2=="done") d[$1]++} END{for(m in tot) if(d[m]==tot[m]) print m}' | sort; }
COMPLETE="$(complete_from)"

# --- the milestone boundary -----------------------------------------------------
# A milestone becomes complete in the very diff that flips its LAST item to done.
# Both modes above compute COMPLETE from the tree they run in, so on that diff's
# own checkout the milestone reads complete-with-no-record — and the audit that
# would discharge it CANNOT have run yet: the playbook (§"Audit evidence") requires
# the audit to run against the merged default branch, and validate_record enforces
# that mechanically (range_head must be an ancestor of HEAD). The record is
# unwritable before the merge and the merge was unreachable without the record.
#
# That deadlock was total: it blocked the final PR of EVERY milestone, forever.
# Consumer A hit it on F10.4 (2026-08-15) the first time a milestone completed with the
# CI job installed, and no ordering of merges escapes it.
#
# So: a milestone that is NOT complete at the mainline anchor but IS complete here
# became complete in the state under review, and its missing record is not debt yet.
# It becomes debt the moment this lands, and from then on the ordinary controls
# hold the line one PR later, with no new machinery:
#   - --files denies every subsequent backlog-advancing PR until the record lands
#     (the anchor then contains the completion, so this exemption stops applying),
#   - --check on push-to-main goes red immediately,
#   - post-merge-auditcheck.sh raises it locally after the merge.
# The first two are the enforcement. post-merge-auditcheck is a LOCAL PostToolUse
# hook — stale-cacheable, silent on a web-UI merge, and it only writes a marker —
# so do not rewrite this exemption as "deferred to the post-merge check". Resting
# the invariant on that hook is precisely the hollow deferral the header comment
# on merge mode warns about.
#
# SCOPE, deliberately narrow — this exempts a MISSING record only. A record that
# is present is validated strictly even on the diff that completes its milestone,
# because CI is the only surface that catches a malformed record before it merges.
#
# FAILS CLOSED: if the anchor cannot be resolved (no remote, offline, bad ref) the
# base is unknown, nothing is exempt, and the gate behaves exactly as it did before.
# The one relaxation is a local checkout whose main is ahead of an unpushed
# origin/main: a completion merged locally reads as "new" until it is pushed.
# push-to-main --check closes that window as soon as it exists.
BASE_KNOWN=0
BASE_COMPLETE=""
if git rev-parse --verify -q "${MAIN_REF}^{commit}" >/dev/null 2>&1; then
  if git rev-parse --verify -q "${MAIN_REF}:${BACKLOG_DIR%/}" >/dev/null 2>&1; then
    # The backlog dir exists at the anchor: extract that tree and run the SAME
    # parser over it. Reusing item_rows is the point — a second, divergent reading
    # of the format is how the two states would drift apart.
    if _bt="$(mktemp -d 2>/dev/null)"; then
      if git archive --format=tar "${MAIN_REF}:${BACKLOG_DIR%/}" 2>/dev/null | (cd "$_bt" && tar -xf - 2>/dev/null); then
        BASE_COMPLETE="$(complete_from "$_bt/")"
        BASE_KNOWN=1
      fi
      rm -rf "$_bt"
    fi
  else
    # Anchor resolves but has no backlog dir (the scaffolding commit): nothing was
    # complete there. Known base, empty set — not the unknown-base case.
    BASE_KNOWN=1
  fi
fi
newly_complete() { # newly_complete <milestone>; 0 = became complete in the state under review
  [ "$BASE_KNOWN" = 1 ] || return 1
  local b
  while IFS= read -r b; do [ "$b" = "$1" ] && return 1; done <<BASE_EOF
$BASE_COMPLETE
BASE_EOF
  return 0
}

# --- record validation ----------------------------------------------------------
# Task 2 (binding) and Task 3 (triage closure) extend this function. A record
# failing here does NOT crash the gate: the milestone stays in debt and the
# reason is reported.
validate_record() { # validate_record <milestone> <file> ; 0 = valid
  local m="$1" rec="$2"
  local ok=1 k v base head f id flip
  # Required keys — a record missing provenance/scope fields is not a record.
  for k in sweap_format milestone range_base range_head lens_mode lenses raw refuted confirmed workflow_run journal_sha256; do
    v="$(fm_get "$rec" "$k")"
    [ -n "$v" ] || { fail "record $rec: missing $k:"; ok=0; }
  done
  v="$(fm_get "$rec" sweap_format)"
  [ -z "$v" ] || [ "$v" = "$RECORD_FORMAT" ] \
    || { fail "record $rec: sweap_format: $v but this gate speaks format $RECORD_FORMAT"; ok=0; }
  [ "$(fm_get "$rec" milestone)" = "$m" ] || { fail "record $rec: milestone key != $m"; ok=0; }
  base="$(fm_get "$rec" range_base)"; head="$(fm_get "$rec" range_head)"
  # Binding (the mistarget rule): recompute, never trust. Any git uncertainty
  # is a validation failure — fail closed, the milestone stays in debt.
  if [ -n "$base" ] && [ -n "$head" ]; then
    git cat-file -e "$base^{commit}" 2>/dev/null || { fail "record $rec: range_base is not a commit here"; ok=0; }
    git cat-file -e "$head^{commit}" 2>/dev/null || { fail "record $rec: range_head is not a commit here"; ok=0; }
    if [ "$ok" = 1 ]; then
      git merge-base --is-ancestor "$base" "$head" 2>/dev/null || { fail "record $rec: range_base is not an ancestor of range_head"; ok=0; }
      git merge-base --is-ancestor "$head" HEAD 2>/dev/null || { fail "record $rec: range_head is not an ancestor of HEAD"; ok=0; }
    fi
    if [ "$ok" = 1 ]; then
      # Every done item of M must have completed WITHIN the audited range:
      # the commit that introduced its `status: done` (oldest -S hit) must be
      # reachable from range_head. This is what makes "audited F1's real
      # merges" checkable — an audit of a stale range fails structurally.
      for f in "${BACKLOG_DIR}"*.md; do
        [ -f "$f" ] || continue
        id="$(basename "$f" .md)"
        case "$id" in *.*) [ "${id%.*}" = "$m" ] || continue ;; *) continue ;; esac
        # Follow-up items created by an audit's triage are DEBT OF the milestone,
        # not members of it — their later completion must not retroactively fail the record.
        [ -n "$(fm_get "$f" followup_of)" ] && continue
        [ "$(fm_get "$f" status)" = "done" ] || continue
        flip="$(git log --format=%H -S'status: done' -- "$f" 2>/dev/null | tail -1)"
        if [ -z "$flip" ]; then
          fail "record $rec: cannot locate the commit that completed $id (uncommitted flip?) — fail closed"; ok=0
        elif ! git merge-base --is-ancestor "$flip" "$head" 2>/dev/null; then
          fail "record $rec: $id completed outside the audited range (flip $flip not reachable from range_head)"; ok=0
        fi
      done
    fi
  fi

  # --- triage closure: counts add up and every confirmed finding lands somewhere
  local raw refuted confirmed body blocks dispo ref reftype reffile finders
  raw="$(fm_get "$rec" raw)"; refuted="$(fm_get "$rec" refuted)"; confirmed="$(fm_get "$rec" confirmed)"
  case "$raw$refuted$confirmed" in *[!0-9]*) fail "record $rec: raw/refuted/confirmed must be numeric"; ok=0 ;; esac
  if [ "$ok" = 1 ] && [ "$raw" -ne $((refuted + confirmed)) ]; then
    fail "record $rec: raw ($raw) != refuted ($refuted) + confirmed ($confirmed)"; ok=0
  fi

  # --- "this audit ran", which is not the same claim as "this audit was clean"
  # A zero-findings record is the one shape that satisfies every other check here
  # while asserting nothing at all: 0 == 0 + 0, no blocks to dispose of, binding
  # intact, required keys present (`raw: 0` is non-empty). It is also exactly
  # what a totally BROKEN run produces — consumer A's F11 audit lost all eleven finder
  # agents to an unresolvable agent type, and the record that fell out of that
  # would have passed here as a clean milestone.
  #
  # So a record claiming zero findings must carry affirmative evidence of work:
  # `finders_reporting`, the number of lenses that actually returned a result,
  # emitted by the workflow itself (which now refuses to return at all when that
  # number is 0). Demanded ONLY when raw is 0, so every record written before the
  # key existed still validates — purely additive, no sweap_format bump, the same
  # move `axes:` and `unverified:` made.
  #
  # Scoped to the PRIMARY axis on purpose. A `ui.raw: 0` comes from a different
  # workflow (the Tier-2 UI critique, deliberately frozen as a control), and this
  # gate does not get to invent keys for a producer that does not emit them.
  if [ "$ok" = 1 ] && [ "$raw" -eq 0 ]; then
    finders="$(fm_get "$rec" finders_reporting)"
    case "$finders" in
      "") fail "record $rec: raw: 0 but no finders_reporting: — a zero-findings record is indistinguishable from a run whose finders all died, so it must state how many lenses actually reported. Re-run the audit with a current plugin, or add finders_reporting: <n> if you can attest they ran."; ok=0 ;;
      *[!0-9]*) fail "record $rec: finders_reporting must be numeric"; ok=0 ;;
      *) [ "$finders" -ge 1 ] || { fail "record $rec: finders_reporting: 0 — this audit reported nothing because nothing ran; it is not a clean milestone"; ok=0; } ;;
    esac
  fi

  # --- additional audit axes -----------------------------------------------
  # A milestone can be audited on more than one axis: the code audit plus, for a
  # UI-heavy milestone, a Tier-2 UI audit (playbook, "UI audit"). Those are
  # SEPARATE runs with their own lens sets, their own stats and their own
  # journals — consumer A's F9 was audited 54/34/20 on code and 11/9/2 on UI, and the
  # single stat set here could only describe one of them, leaving the UI
  # survivors (FK.4, FK.5) as disposition blocks that no `confirmed` count
  # accounted for.
  #
  # The unprefixed keys describe the PRIMARY audit. `axes: [ui, ...]` declares
  # additional ones, each carrying the same seven keys under an `<axis>.` prefix.
  # Flat, single-line, inline lists — the format contract is intact and no YAML
  # parser appears here (same rule as roadmap-lint.sh).
  #
  # PURELY ADDITIVE: a record with no `axes:` key validates exactly as before, so
  # this does NOT bump sweap_format. Adding an optional key that invalidates
  # nothing is the kind of change the version exists to make unnecessary.
  local axes ax axkey axraw axref axconf k2 total_confirmed
  total_confirmed="$confirmed"
  axes="$(fm_get "$rec" axes | tr -d '[]' | tr ',' ' ')"
  for ax in $axes; do
    # Axis names are restricted so an axis can never inject regex into the key
    # lookups below (fm_get builds a sed pattern from the key).
    case "$ax" in
      *[!a-z0-9-]*|"" ) fail "record $rec: axis '$ax' must be lowercase [a-z0-9-]"; ok=0; continue ;;
    esac
    axkey="$ax\\."
    for k2 in raw refuted confirmed lens_mode lenses workflow_run journal_sha256; do
      [ -n "$(fm_get "$rec" "$axkey$k2")" ] || { fail "record $rec: axis '$ax' is declared but $ax.$k2: is missing"; ok=0; }
    done
    axraw="$(fm_get "$rec" "${axkey}raw")"
    axref="$(fm_get "$rec" "${axkey}refuted")"
    axconf="$(fm_get "$rec" "${axkey}confirmed")"
    case "$axraw$axref$axconf" in
      ""|*[!0-9]*) fail "record $rec: $ax.raw/$ax.refuted/$ax.confirmed must be numeric"; ok=0; continue ;;
    esac
    if [ "$axraw" -ne $((axref + axconf)) ]; then
      fail "record $rec: $ax.raw ($axraw) != $ax.refuted ($axref) + $ax.confirmed ($axconf)"; ok=0; continue
    fi
    total_confirmed=$((total_confirmed + axconf))
  done
  body="$(awk '{ sub(/\r$/,"") } NR==1 && $0=="---" { infm=1; next } infm && /^---$/ { infm=0; next } !infm { print }' "$rec")"
  blocks="$(printf '%s\n' "$body" | grep -c '^### ' || true)"
  # Blocks are DISPOSITIONS, not findings, and the two have different
  # cardinalities: a multi-lens ensemble converging on one defect is the normal
  # case (consumer A's F9: six lenses hit the same claim-lease bug — the record called
  # that convergence "the strongest signal this audit produced"). Requiring one
  # block per confirmed finding would force that correct collapse to be undone
  # into six blocks saying the same thing. So `defects:` may declare the distinct
  # count after collapse; blocks are matched against THAT. It defaults to
  # `confirmed` (no collapse), which keeps every pre-existing record valid.
  # A collapse can only ever merge, never invent: 0 < defects <= confirmed.
  # Blocks are matched against `defects` (distinct defects after collapse), which
  # is bounded by the survivors of EVERY axis — a UI-audit survivor is a real
  # finding that must be allowed its own disposition block.
  local defects
  defects="$(fm_get "$rec" defects)"
  if [ -n "$defects" ]; then
    case "$defects" in *[!0-9]*) fail "record $rec: defects must be numeric"; ok=0 ;; esac
    if [ "$ok" = 1 ] && { [ "$defects" -gt "$total_confirmed" ] || { [ "$defects" -eq 0 ] && [ "$total_confirmed" -gt 0 ]; }; }; then
      fail "record $rec: defects ($defects) must be >0 and <= total confirmed across all axes ($total_confirmed) — collapsing merges findings, it never invents or drops them"; ok=0
    fi
  else
    defects="$total_confirmed"
  fi
  if [ "$ok" = 1 ] && [ "$blocks" -ne "$defects" ]; then
    fail "record $rec: $blocks finding block(s) but $defects distinct defect(s) expected (total confirmed across all axes: $total_confirmed$([ -n "$(fm_get "$rec" defects)" ] && printf ', collapsed via defects:'))"; ok=0
  fi
  # One disposition per block, each resolvable. Blocks are separated by ^###
  # headers; a disposition line is `disposition: fix_pr #N | followup <id> |
  # blocked <id>`. Count and validate per block via awk block-splitting.
  if [ "$blocks" -gt 0 ]; then
    local n=0
    while [ "$n" -lt "$blocks" ]; do
      n=$((n + 1))
      dispo="$(printf '%s\n' "$body" | awk -v want="$n" '/^### /{b++} b==want && /^disposition:[[:space:]]/{ sub(/^disposition:[[:space:]]*/,""); print }')"
      if [ "$(printf '%s\n' "$dispo" | grep -c '[^[:space:]]')" -ne 1 ]; then
        fail "record $rec: finding block $n needs exactly one disposition: line"; ok=0; continue
      fi
      case "$dispo" in
        "fix_pr #"[0-9]*) : ;;
        "followup "*|"blocked "*)
          reftype="${dispo%% *}"; ref="${dispo#* }"
          reffile="${BACKLOG_DIR}${ref}.md"
          if [ ! -f "$reffile" ]; then
            fail "record $rec: disposition references $ref but ${reffile} does not exist"; ok=0
          else
            [ "$(fm_get "$reffile" followup_of)" = "$m" ] || { fail "record $rec: $ref must carry followup_of: $m"; ok=0; }
            if [ "$reftype" = "blocked" ]; then
              [ "$(fm_get "$reffile" status)" = "blocked" ] || { fail "record $rec: $ref disposition says blocked but its status is not"; ok=0; }
            fi
            bash "$(dirname "${BASH_SOURCE[0]}")/roadmap-lint.sh" "$reffile" >/dev/null 2>&1 \
              || { fail "record $rec: $ref fails roadmap-lint"; ok=0; }
          fi
          ;;
        *) fail "record $rec: finding block $n has malformed disposition '$dispo'"; ok=0 ;;
      esac
    done
  fi

  [ "$ok" = 1 ]
}

# --- legacy (pre-format) records -------------------------------------------------
# A record is LEGACY iff it carries no `sweap_format:` key AND the commit that
# added it is already reachable from the mainline anchor. Both halves matter:
#   - no sweap_format  => it was written before the format existed (a record
#     written by a current plugin always carries the key),
#   - already on the mainline => it is water under the bridge, not something the
#     work under review is introducing. `git log <anchor> -- <path>` walks ONLY
#     commits reachable from <anchor>, so a record added by the PR under review
#     yields nothing here and is judged strictly.
# This is what makes the door close behind the migration: you can never author
# NEW legacy, only inherit it. Provenance comes from git, not from file content,
# so it cannot be forged by writing a frontmatter-less file.
# Fails CLOSED on any uncertainty (no remote, unresolvable anchor) — nothing is
# legacy, every record is judged strictly.
record_is_legacy() { # record_is_legacy <file> ; 0 = legacy
  local rec="$1" anchor add
  [ -z "$(fm_get "$rec" sweap_format)" ] || return 1
  anchor="$(git rev-parse --verify -q "${MAIN_REF}^{commit}" 2>/dev/null)" || return 1
  [ -n "$anchor" ] || return 1
  add="$(git log --diff-filter=A --format=%H "$anchor" -- "$rec" 2>/dev/null | tail -1)"
  [ -n "$add" ]
}

# --- debt set -------------------------------------------------------------------
# DEBT blocks merges. STALE is reported but never blocks — see record_is_legacy.
DEBT=""
STALE=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  in_baseline "$m" && continue
  rec="${BACKLOG_DIR}audits/$m.md"
  if [ ! -f "$rec" ]; then
    # The milestone boundary (see above). Exempt in BOTH modes, not just --check:
    # the CI job runs --files against the PR's own checkout too, where this
    # milestone reads complete and the PR touches the very item file that
    # completed it — so a --check-only exemption would still deny the merge in
    # merge mode and leave the deadlock fully intact.
    if newly_complete "$m"; then
      [ "$MODE" = "--check" ] && printf 'DEFERRED: milestone %s becomes complete in the state under review, so its audit cannot have run yet (the audit reads the MERGED default branch). Not debt here. It becomes debt the instant this lands: no backlog-advancing PR will pass the gate afterwards until %saudits/%s.md exists and validates. Run /milestone-audit for %s once this is on main.\n' "$m" "$BACKLOG_DIR" "$m" "$m"
      continue
    fi
    DEBT="$DEBT$m"$'\n'
    [ "$MODE" = "--check" ] && fail "milestone $m is complete but has no audit record ($rec) — run /milestone-audit for it"
  elif ! rec_out="$(validate_record "$m" "$rec")"; then
    if record_is_legacy "$rec"; then
      STALE="$STALE$m"$'\n'
      [ "$MODE" = "--check" ] && printf 'STALE: record %s predates the sweap_format %s record contract (written by an older sweap) — it does NOT block merges. MIGRATE IT BY TRANSCRIPTION: the audit already ran, so add the frontmatter from evidence the record and its run already contain (range, lens set, stats, workflow_run, journal_sha256 from the run journal) and give each distinct defect a disposition: line. Do NOT re-run /milestone-audit to "fix" this — that spends a full audit to produce a DIFFERENT record and discards the evidence the original triage was based on. Re-audit only if no audit ever actually ran; add %s to audit.baseline only if its evidence is genuinely unrecoverable.\n' "$rec" "$RECORD_FORMAT" "$m"
    else
      DEBT="$DEBT$m"$'\n'
      if [ "$MODE" = "--check" ]; then
        [ -n "$rec_out" ] && printf '%s\n' "$rec_out"
        fails=1
      fi
    fi
  fi
done <<COMPLETE_EOF
$COMPLETE
COMPLETE_EOF

# --- hand-off provenance: `attended` is AUTHORED, never TRANSITIONED into --------
# A hand-off item (`status: attended`) says "this was always the human's to do".
# The failure mode it creates is an agent relabelling its OWN stuck work as human
# work: the goal template stops a run when only [blocked] and [attended] items
# remain, so the flip converts an unfinished item into a legitimate termination
# condition — and unlike [blocked] it carries no failure signal. That is the
# textbook shape of a reward-hacked shortcut (2026-08-16 research memo, §3), and
# the same memo's other finding is why this is a check and not a rule: prompts
# telling a model not to take a shortcut are advisory and can even increase the
# behaviour, while a deterministic check simply holds.
#
# The rule: for every item currently `attended`, the commit that introduced
# `status: attended` must BE the commit that added the file. Authoring a hand-off
# is legal; converting existing work into one is not. Provenance comes from git,
# not from file content, so it cannot be forged by editing the item.
#
# The legitimate human move this forbids — "actually, F2.3 is mine now" — has a
# supported path: archive F2.3 with a dropped_reason: and author the hand-off as a
# new item. Both halves are visible in the diff, which is the point.
#
# Uncommitted files are skipped, not failed: /roadmap lints items in the working
# tree before they are ever committed, and an unborn item has no provenance to
# judge. CI runs this on the PR's own checkout, where the commits do exist.
if [ "$MODE" = "--check" ]; then
  for f in "${BACKLOG_DIR}"*.md; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .md)"
    case "$id" in *.*) : ;; *) continue ;; esac
    [ "$(fm_get "$f" status)" = "attended" ] || continue
    added="$(git log --diff-filter=A --format=%H -- "$f" 2>/dev/null | tail -1)"
    became="$(git log --format=%H -S'status: attended' -- "$f" 2>/dev/null | tail -1)"
    [ -n "$added" ] && [ -n "$became" ] || continue   # not committed yet — nothing to judge
    [ "$added" = "$became" ] && continue
    fail "hand-off $id: status: attended was introduced by $became but the item file was added by $added — an attended item is AUTHORED, never transitioned into (an agent must not relabel stuck work as human work; stuck work is [blocked]). If this is a deliberate re-assignment, archive $id with a dropped_reason: and author the hand-off as a new item."
  done

  # --- blocked-question aging: INFORMATIONAL, never a failure ------------------
  # A [blocked] item is a question waiting on a human. Unlike audit debt, an
  # unanswered direction call is LEGITIMATELY deferrable — the cost of waiting is
  # real but bounded, and blocking a build on someone's taste call would be
  # crying wolf. So this prints and never fails; `AGING:` joins `DEFERRED:` and
  # `STALE:` as a non-failing prefix.
  #
  # Why it lives here at all, when the board and the run summary already list
  # blocked items: those are read-only displays, and consumer A proved they change
  # nothing (2026-08-16 research memo — five of six questions survived a whole
  # milestone authoring cycle unasked). The evidence there says the intervention
  # that works is a documented pending-state AT THE TRANSITION, and this gate is
  # already what /roadmap runs as its pre-flight at exactly that moment. Riding
  # on plumbing the boundary already reads beats a fourth place to look.
  #
  # It is surfacing, not enforcement, and deliberately so: skipping the carry
  # increment buys an agent nothing it wants, so it is not the shortcut shape
  # that earns a mechanism here (contrast the hand-off provenance check above).
  for f in "${BACKLOG_DIR}"*.md; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .md)"
    case "$id" in *.*) : ;; *) continue ;; esac
    [ "$(fm_get "$f" status)" = "blocked" ] || continue
    carried="$(fm_get "$f" carried)"
    case "$carried" in ""|*[!0-9]*) carried=0 ;; esac
    # `blocked:` is usually written already-quoted (the question contains colons
    # and commas), so strip one surrounding pair before truncating — otherwise
    # the line reads ""Should the row…" with a doubled quote.
    q="$(fm_get "$f" blocked | sed 's/^"//; s/"$//' | cut -c1-100)"
    if [ "$carried" -ge 2 ]; then
      printf 'AGING: blocked %s — carried %s milestone boundaries: "%s…". At carried 2 this is ASKED, not offered: /roadmap will not start the next brainstorm until it is answered, defaulted on your explicit say-so, or dropped with a dropped_reason:. Answer it now with /unblock %s.\n' "$id" "$carried" "$q" "$id"
    else
      printf 'AGING: blocked %s — carried %s milestone boundary(ies): "%s…". Answer it with /unblock %s; at carried 2 it stops being optional.\n' "$id" "$carried" "$q" "$id"
    fi
  done

  exit "$fails"
fi

# --- merge mode (--files): roadmap-scoped denial --------------------------------
# Deny iff debt exists AND the PR touches top-level item files AND it does not
# discharge the debt (contain the audit record for a debt milestone). Follow-up
# and blocked items ride the same PR as the record, so discharge is detected at
# PATH level here.
#
# WHY PATH LEVEL IS ALL THIS MODE CAN DO: --files runs inside the pre-merge hook,
# against the LOCAL checkout, which does not contain the PR's version of the
# record — the record being discharged is by definition not merged yet. This mode
# is a ROUTING decision ("does this PR carry the record?"), never a validity
# decision. Validity is decided by --check, in a checkout that actually holds the
# content:
#   1. the audit-gate CI job (templates/.github/workflows/audit-gate.yml) runs
#      --check on the PR's own checkout, so a malformed record fails the record
#      PR itself, before it can merge. This is the primary control.
#   2. post-merge-auditcheck.sh re-runs --check on the freshly-pulled mainline
#      right after any merge, so a repo whose CI job is missing still learns
#      within ONE PR instead of drifting for days.
# The 2026-08-11 consumer A miss (F9's prose-only record merged, F10 authored on top)
# is what this note exists for: the old comment deferred to "the next --check"
# while nothing was scheduled to run one. Do not weaken (1) or (2) and leave this
# deferral standing on its own.
[ -n "$(printf '%s' "$DEBT")" ] || exit 0
touches_items=0; discharges=0
for f in "$@"; do
  # Note: case patterns are STRING matches where * also matches / (not filesystem globs)
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
