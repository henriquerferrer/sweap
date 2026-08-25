#!/usr/bin/env bash
#
# lib-merge-parse.sh — shared detector/parser for `gh pr merge`, greedy-detect +
# fail-closed.
#
# Sourced by pre-merge-gate.sh (the control) and post-merge-redcheck.sh (the
# backstop) so both use IDENTICAL logic.
#
# WHY THIS SHAPE. Trying to precisely tokenise every shell form is whack-a-mole
# (operators, then inherited flags between subcommand words, then `if`/`while`/
# `for`/subshells/`$()`/backticks …). Each missed construct that flips detection
# to "not a merge" is a silent fail-OPEN. So we INVERT: a deliberately
# over-approximate GREEDY scan decides "is this merge-related at all?", a PRECISE
# parser decides "is it a pristine, simple, extractable merge?", and the gate
# ALLOWs only when both agree — otherwise it fails CLOSED. A newly-missed shell
# construct now denies (recoverable: re-issue plainly), it can never silently pass.
#
# `parse_merge_command "<raw command string>"` sets these globals:
#   MC_MERGE_RELATED — 1 iff the word tokens `gh`, `pr`, `merge` appear IN THAT
#                      ORDER anywhere in the raw command, ignoring ALL shell
#                      structure (operators, keywords, grouping, quoting). This is
#                      the greedy trip-wire; it does NOT use command-position logic.
#   MC_RELATED_COUNT — number of non-overlapping in-order `gh…pr…merge` triples the
#                      greedy scan found (used to check the precise parse accounts
#                      for every one).
#   MC_IS_MERGE   — 1 iff the PRECISE parser recognised a `gh pr merge` running in
#                   command position (positional `pr merge` path).
#   MC_MERGE_COUNT— number of merges the precise parser recognised.
#   MC_BAD_FLAG   — "admin" | "repo" | "" — `--admin`/`--repo`/`-R` seen anywhere
#                   inside a recognised merge invocation (inherited flags may
#                   precede the subcommand).
#   MC_PRS        — space-separated PR numbers, one per merge that parsed to
#                   exactly one clean numeric/URL PR. Callers verify EVERY entry.
#   MC_UNPARSED   — count of recognised merges that did NOT cleanly yield a single
#                   numeric PR (missing / branch-name / extra positional).
#   MC_PARSE_ERR  — 1 if the command could not be safely tokenised (unbalanced
#                   quotes).
#
# The GATE's ALLOW condition (see pre-merge-gate.sh) is the conjunction: merge-
# related AND precise recognised exactly the same number of merges the greedy scan
# saw (MC_MERGE_COUNT == MC_RELATED_COUNT) AND none unparsed AND no bad flag AND no
# tokenise error AND every extracted PR is green. Any other merge-related command
# is DENY-recoverable.
#
# RESIDUAL (documented, accepted): deliberate token-HIDING that prevents the
# literal `gh`/`pr`/`merge` word tokens from appearing at all — `eval "$(printf …)"`,
# `bash -c`, string-assembled commands — is out of the honest-mistake threat model.
# The greedy scan cannot see tokens that are not literally present; nothing can,
# short of executing the command. This gate defends against honest slips (the
# masked-pipe incident, a retry wrapped in `if`), not an agent obfuscating its own
# merge to defeat its own safety control.
#
# ACCEPTED FALSE-POSITIVES: because the greedy scan ignores structure, a command
# that merely MENTIONS the words in order (a commit message, an `echo`, or an
# unrelated `gh pr view … && … merge …`) is flagged merge-related and, being not a
# pristine simple merge, is DENIED-recoverable. This is deliberate: over-blocking
# only forces a plain re-issue; under-detecting would be a silent hole.

# shellcheck shell=bash
# shellcheck disable=SC2034  # MC_* / _mc_* are the output contract + walker state, read across functions

# --- greedy trip-wire -----------------------------------------------------------
# Split the raw string into word tokens (maximal [A-Za-z0-9_] runs — so shell
# structure, quotes and punctuation all vanish and `mygh`/`graphql` are single
# tokens that never equal `gh`), then count in-order gh->pr->merge triples.
_mc_related_scan() {
  local n=""
  if command -v awk >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '\n' | awk '
      { if (s==0)      { if ($0=="gh") s=1 }
        else if (s==1) { if ($0=="pr") s=2; else if ($0=="gh") s=1 }
        else if (s==2) { if ($0=="merge") { c++; s=0 } else if ($0=="gh") s=1 } }
      END { print c+0 }' 2>/dev/null)"
  fi
  if printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    MC_RELATED_COUNT="$n"
    [ "$MC_RELATED_COUNT" -gt 0 ] && MC_MERGE_RELATED=1
  elif printf '%s' "$1" | grep -Eq 'gh.*pr.*merge'; then
    # The greedy counter could not run (missing tr/awk) or returned garbage. Do
    # NOT silently treat this as "not a merge" — that would fail OPEN. If the
    # command even loosely looks merge-ish, flag it related with a sentinel count
    # that can never equal the precise MC_MERGE_COUNT, so the gate fails CLOSED.
    MC_MERGE_RELATED=1
    MC_RELATED_COUNT=999999
  fi
}

# Record the gh invocation whose positionals were collected into _mc_p0/1/2
# (_mc_npos = how many, _mc_bad = worst flag seen in it).
_mc_record() {
  [ "$_mc_p0" = "pr" ] && [ "$_mc_p1" = "merge" ] || return 0   # not a merge
  MC_IS_MERGE=1
  MC_MERGE_COUNT=$((MC_MERGE_COUNT + 1))
  [ -n "$_mc_bad" ] && MC_BAD_FLAG="$_mc_bad"
  if [ "$_mc_npos" = "3" ]; then
    case "$_mc_p2" in
      *pull/[0-9]*)
        _mc_n="$(printf '%s' "$_mc_p2" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' | head -1)"
        if [ -n "$_mc_n" ]; then MC_PRS="${MC_PRS}${MC_PRS:+ }$_mc_n"; else MC_UNPARSED=$((MC_UNPARSED + 1)); fi ;;
      '' | *[!0-9]*) MC_UNPARSED=$((MC_UNPARSED + 1)) ;;   # missing / non-numeric
      *) MC_PRS="${MC_PRS}${MC_PRS:+ }$_mc_p2" ;;          # a plain integer
    esac
  else
    MC_UNPARSED=$((MC_UNPARSED + 1))   # no PR, or an extra/ambiguous positional
  fi
}

parse_merge_command() {
  MC_MERGE_RELATED=0
  MC_RELATED_COUNT=0
  MC_IS_MERGE=0
  MC_MERGE_COUNT=0
  MC_BAD_FLAG=""
  MC_PRS=""
  MC_UNPARSED=0
  MC_PARSE_ERR=0

  local raw="$1"
  [ -n "$raw" ] || return 0

  # GREEDY first, on the untouched raw string (structure-agnostic). If the
  # gh->pr->merge word sequence isn't even present, it cannot be a merge → no-op.
  _mc_related_scan "$raw"
  [ "$MC_MERGE_RELATED" = "1" ] || return 0

  # --- PRECISE parse (only to recognise the pristine simple form) ---------------
  # 1) Join backslash-newline continuations; 2) newlines -> separators.
  raw="${raw//\\$'\n'/ }"
  raw="${raw//$'\n'/ ; }"
  # 3) Space-pad shell control operators so they tokenise as standalone words
  #    (operators inside quotes stay grouped in their token — never mis-split).
  raw="$(printf '%s' "$raw" | sed -E 's/(\|\||&&|;|\||&)/ \1 /g')"
  # 4) Tokenise honouring quoting/escapes WITHOUT executing. Unbalanced quotes →
  #    parse error; MC_MERGE_RELATED is already 1 so the gate fails closed.
  local tokens
  if ! tokens="$(printf '%s' "$raw" | xargs -n1 printf '%s\n' 2>/dev/null)"; then
    MC_PARSE_ERR=1
    return 0
  fi

  local expect_cmd=1     # next token begins a command (start / post-operator)
  local in_gh=0          # inside a `gh ...` invocation
  local skip_val=0       # previous token was a value-taking flag; skip its value
  local tok
  _mc_p0=""; _mc_p1=""; _mc_p2=""; _mc_npos=0; _mc_bad=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue

    case "$tok" in
      ";" | "&&" | "||" | "|" | "&" | "|&")
        [ "$in_gh" = "1" ] && _mc_record
        expect_cmd=1; in_gh=0; skip_val=0
        _mc_p0=""; _mc_p1=""; _mc_p2=""; _mc_npos=0; _mc_bad=""
        continue ;;
    esac

    if [ "$in_gh" = "1" ]; then
      case "$tok" in
        --admin) _mc_bad="admin" ;;
        --repo | --repo=* | -R | -R?*) _mc_bad="repo" ;;
      esac
      if [ "$skip_val" = "1" ]; then skip_val=0; continue; fi
      case "$tok" in
        -R | --repo | -b | --body | -F | --body-file | -t | --subject | --match-head-commit | --author-email)
          skip_val=1; continue ;;   # value-taking flags consume the next token
        -*) continue ;;             # boolean/other flag (incl. attached --repo=x/-Rx)
      esac
      _mc_npos=$((_mc_npos + 1))
      case "$_mc_npos" in
        1) _mc_p0="$tok" ;;
        2) _mc_p1="$tok" ;;
        3) _mc_p2="$tok" ;;
      esac
      continue
    fi

    if [ "$expect_cmd" = "1" ]; then
      case "$tok" in
        [A-Za-z_]*=*) continue ;;                                   # VAR=val prefix
        command | builtin | exec | env | sudo | nice | nohup | time)
          continue ;;                                               # command wrappers
      esac
      expect_cmd=0
      [ "$tok" = "gh" ] && in_gh=1
      continue
    fi
    # Argument of a non-gh command → ignore.
  done <<EOF
$tokens
EOF
  [ "$in_gh" = "1" ] && _mc_record
  return 0
}

# ==============================================================================
# `git push` detector/parser — same greedy-detect + fail-closed doctrine.
#
# Sourced by pre-merge-gate.sh for its push branch (deny a push whose resolved
# destination is the base branch). Lives in this lib so the two detectors share
# ONE tokeniser and one set of accepted false-positives.
#
# `parse_push_command "<raw command string>"` sets these globals:
#   PC_PUSH_RELATED — 1 iff PC_RELATED_COUNT>0 OR PC_PUSH_COUNT>0. Never a
#                     no-op just because the greedy scan missed a quoted -C path.
#   PC_RELATED_COUNT— greedy count: `push` seen as the FIRST non-option word after
#                     a `git` token (skipping dash-tokens and the values of
#                     -C/-c/--git-dir/--work-tree/--namespace/--exec-path/
#                     --super-prefix), structure-agnostic (quotes/operators
#                     vanish). Deliberately NARROWER than the merge scan so
#                     `git stash push`, `git commit -m "push notifications"` and
#                     `git log --grep push` do not trip, while `echo "git push"`,
#                     `bash -c "git push origin main"`, `if …; then git push …; fi`
#                     and `$(git push …)` still do (fail closed).
#   PC_PUSH_COUNT   — precise count of command-position `git push` invocations.
#   PC_PARSE_ERR    — 1 if the command could not be safely tokenised.
#   PC_HAS_CD       — 1 if a `cd`/`pushd`/`popd` command appears anywhere, or a
#                     `git -C <path>` was consumed (cwd cannot be trusted).
#   PC_C_PATHS      — newline-separated list of `-C` values seen.
#   PC_PUSHES       — one record per push, newline-separated:
#                     `<flags>\x1f<remote>\x1f<refspec1> <refspec2>…` (US-separated,
#                     since tab is IFS whitespace and an empty flags column would
#                     collapse) where flags is a comma-joined subset of {all,mirror,branches,delete,tags,
#                     prune,dryrun} (dry-run is informational only — still gated).
#
# Value-taking push flags (separate token) are ONLY -o/--push-option,
# --receive-pack, --exec, --repo. `--force-with-lease`, `--signed`,
# `--force-if-includes`, -f/-u/-n/-q/-v/-4/-6 and every other `-*` are booleans
# (the attached `--force-with-lease=…`/`--repo=…`/`--signed=…` forms are single
# tokens, ignored). Getting this wrong fails OPEN: treating a bare
# `--force-with-lease` as value-taking would eat `origin` in
# `git push --force-with-lease origin main`, make `main` the remote, and resolve
# the CURRENT branch instead.
#
# RESIDUAL / ACCEPTED FALSE-POSITIVES: identical to the merge parser above —
# token-hiding (eval/string assembly) is out of the threat model; a mention of
# `git push` in structure the precise parser cannot see denies recoverably.

_pc_related_scan() {
  local n=""
  if command -v awk >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.=/~:@+-' '\n' | awk '
      NF==0 { next }
      { if ($0=="git") { s=1; next }
        if (s==1) {
          if (skip==1) { skip=0; next }
          if (substr($0,1,1)=="-") {
            if ($0=="-C" || $0=="-c" || $0=="--git-dir" || $0=="--work-tree" || $0=="--namespace" || $0=="--exec-path" || $0=="--super-prefix") skip=1
            next
          }
          if ($0=="push") c++
          s=0; skip=0
        } }
      END { print c+0 }' 2>/dev/null)"
  fi
  if printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    PC_RELATED_COUNT="$n"
  elif printf '%s' "$1" | grep -Eq 'git.*push'; then
    # Greedy counter unavailable (missing tr/awk) — do NOT fail open. Sentinel
    # count can never equal PC_PUSH_COUNT, so the gate denies (recoverable).
    PC_RELATED_COUNT=999999
  fi
}

# Flush the push invocation being walked (state in _pc_*).
_pc_record() {
  [ "$_pc_in_push" = "1" ] || return 0
  PC_PUSH_COUNT=$((PC_PUSH_COUNT + 1))
  PC_PUSHES="${PC_PUSHES}${PC_PUSHES:+$'\n'}${_pc_flags}"$'\x1f'"${_pc_remote}"$'\x1f'"${_pc_refspecs}"
}

_pc_reset() {
  _pc_in_git=0; _pc_in_push=0; _pc_git_skip=0; _pc_git_c=0; _pc_push_skip=0
  _pc_dashdash=0; _pc_flags=""; _pc_remote=""; _pc_refspecs=""; _pc_npos=0
}

parse_push_command() {
  PC_PUSH_RELATED=0
  PC_RELATED_COUNT=0
  PC_PUSH_COUNT=0
  PC_PARSE_ERR=0
  PC_HAS_CD=0
  PC_C_PATHS=""
  PC_PUSHES=""

  local raw="$1"
  [ -n "$raw" ] || return 0

  _pc_related_scan "$raw"

  # Cheap pre-filter: if the literal word `push` is nowhere in the string the
  # precise walker cannot find one either (it only recognises the token `push`).
  # Keeps the hot path (every Bash call) to one grep + one awk.
  if [ "$PC_RELATED_COUNT" = "0" ] && ! printf '%s' "$raw" | grep -qw 'push'; then
    return 0
  fi

  # Precise parse — same pipeline as parse_merge_command.
  raw="${raw//\\$'\n'/ }"
  raw="${raw//$'\n'/ ; }"
  raw="$(printf '%s' "$raw" | sed -E 's/(\|\||&&|;|\||&)/ \1 /g')"
  local tokens
  if ! tokens="$(printf '%s' "$raw" | xargs -n1 printf '%s\n' 2>/dev/null)"; then
    PC_PARSE_ERR=1
    PC_PUSH_RELATED=1
    return 0
  fi

  local expect_cmd=1 tok
  _pc_reset
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue

    case "$tok" in
      ";" | "&&" | "||" | "|" | "&" | "|&")
        _pc_record
        _pc_reset
        expect_cmd=1
        continue ;;
    esac

    if [ "$_pc_in_push" = "1" ]; then
      case "$tok" in *">"* | *"<"*) continue ;; esac     # redirections
      if [ "$_pc_push_skip" = "1" ]; then _pc_push_skip=0; continue; fi
      if [ "$_pc_dashdash" = "0" ]; then
        case "$tok" in
          --) _pc_dashdash=1; continue ;;
          -o | --push-option | --receive-pack | --exec | --repo) _pc_push_skip=1; continue ;;
          --all | --mirror | --branches) _pc_flags="${_pc_flags}${_pc_flags:+,}all"; continue ;;
          -d | --delete) _pc_flags="${_pc_flags}${_pc_flags:+,}delete"; continue ;;
          --tags) _pc_flags="${_pc_flags}${_pc_flags:+,}tags"; continue ;;
          --prune) _pc_flags="${_pc_flags}${_pc_flags:+,}prune"; continue ;;
          -n | --dry-run) _pc_flags="${_pc_flags}${_pc_flags:+,}dryrun"; continue ;;
          -*) continue ;;   # every other flag is boolean (incl. attached =value forms)
        esac
      fi
      _pc_npos=$((_pc_npos + 1))
      if [ "$_pc_npos" = "1" ]; then _pc_remote="$tok"
      else _pc_refspecs="${_pc_refspecs}${_pc_refspecs:+ }$tok"; fi
      continue
    fi

    if [ "$_pc_in_git" = "1" ]; then
      # git global options before the subcommand.
      if [ "$_pc_git_c" = "1" ]; then
        _pc_git_c=0; PC_HAS_CD=1
        PC_C_PATHS="${PC_C_PATHS}${PC_C_PATHS:+$'\n'}$tok"
        continue
      fi
      if [ "$_pc_git_skip" = "1" ]; then _pc_git_skip=0; continue; fi
      case "$tok" in
        -C) _pc_git_c=1; continue ;;
        -C?*) PC_HAS_CD=1; PC_C_PATHS="${PC_C_PATHS}${PC_C_PATHS:+$'\n'}${tok#-C}"; continue ;;
        -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix) _pc_git_skip=1; continue ;;
        -*) continue ;;
      esac
      if [ "$tok" = "push" ]; then _pc_in_push=1; else _pc_in_git=0; fi
      continue
    fi

    if [ "$expect_cmd" = "1" ]; then
      case "$tok" in
        [A-Za-z_]*=*) continue ;;                                   # VAR=val prefix
        command | builtin | exec | env | sudo | nice | nohup | time | timeout)
          continue ;;                                               # command wrappers
      esac
      expect_cmd=0
      case "$tok" in
        git) _pc_in_git=1 ;;
        cd | pushd | popd) PC_HAS_CD=1 ;;
      esac
      continue
    fi
    # Argument of a non-git command → ignore.
  done <<EOF2
$tokens
EOF2
  _pc_record

  if [ "${PC_RELATED_COUNT:-0}" -gt 0 ] || [ "${PC_PUSH_COUNT:-0}" -gt 0 ]; then
    PC_PUSH_RELATED=1
  fi
  return 0
}
