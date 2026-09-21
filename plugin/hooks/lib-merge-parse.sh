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
# that merely MENTIONS the words in order (an `echo`, or an unrelated `gh pr view
# … && … merge …`) is flagged merge-related and, being not a pristine simple
# merge, is DENIED-recoverable. This is deliberate: over-blocking only forces a
# plain re-issue; under-detecting would be a silent hole.
#
# The ONE mention that is NOT a false positive worth paying for is PROSE THE
# SHELL NEVER EXECUTES — a PR body, a PR title, a commit message, a heredoc body.
# Those are redacted before the greedy scan runs (see `_redact_prose` below), so
# `gh pr create --body "…this merges…"` and `git commit -m "…git push…"` are
# ordinary no-ops rather than something the operator has to reword or move into a
# file. Prose carrying a command substitution or backticks is still visible, and
# still denies.

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

# --- prose redaction (false-positive relief for the greedy scans) ----------------
# The greedy scans above are deliberately structure-agnostic, so a command that
# merely MENTIONS the trigger words is flagged and (not being a pristine merge/
# push) denied. That is the right trade for shell structure — but a PR body, a PR
# title or a commit message legitimately talks about merging and pushing, and
# `gh pr create --body "…merge…"` is a hot-path command, not an edge case. Being
# denied it forces the operator to reword prose to appease a parser.
#
# So before the greedy scans run, two REDACTIONS remove text that the shell will
# never execute:
#
#   1. HEREDOC BODIES (`gh pr create --body-file - <<'EOF' … EOF`, and the
#      `--body "$(cat <<'EOF' … EOF)"` idiom). A heredoc body is stdin data, not
#      commands. Guards, all fail-closed: the introducing line must not name a
#      shell/interpreter (`bash`, `sh`, `eval`, `xargs`, `python`… — we never
#      redact a heredoc that is fed to something that would EXECUTE it), a `<<<`
#      here-string is skipped, and an UNTERMINATED heredoc abandons redaction
#      entirely (so a stray `<<WORD` inside prose can never swallow the lines
#      that follow it).
#
#   2. VALUES OF PROSE-CARRYING FLAGS — `-m/--message`, `-b/--body`,
#      `-F/--body-file`, `-t/--title/--subject`, `--notes` and their attached
#      `--flag=value` forms — tokenised as the precise parsers tokenise, so a
#      quoted body is one token and vanishes whole. (One known difference, in the
#      DENY direction only: `_tokenise` batches through a single `xargs printf`,
#      which rejects a string ending in a lone opening quote; parse_merge_command's
#      inline `xargs -n1` accepts it. bash rejects such a command anyway unless
#      the quote sits in a trailing comment.)
#
# THE FAIL-CLOSED PROPERTY IS PRESERVED. A value token is redacted ONLY when it
# cannot become a command: it is dropped only if it contains no `$` and no
# backtick (so `--body "$(gh pr merge 5)"` stays fully visible to the scan), it is
# never dropped when it sits in command position or is a control operator, and it
# is never dropped when it is exactly one of the trigger words (`gh`/`git`/`pr`/
# `merge`/`push`) — which is what keeps the redactor from ever hiding a triple the
# PRECISE parser would still have recognised. If the string cannot be tokenised,
# redaction is abandoned and the raw greedy result stands.
#
# RESIDUAL (documented, accepted): a body containing a command substitution or
# backticks still trips the trip-wire and is denied recoverably. Pass that prose
# with `--body-file <path>` — the deny message says so.

# Remove heredoc bodies. Prints the input unchanged when anything is off.
_redact_heredocs() {
  case "$1" in *'<<'*) ;; *) printf '%s' "$1"; return 0 ;; esac
  printf '%s' "$1" | awk '
    { line[NR] = $0 }
    hd == 1 {
      t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == delim) { hd = 0 } else { drop[NR] = 1 }
      next
    }
    {
      if (index($0, "<<") == 0) next
      if ($0 ~ /<<</) next
      if ($0 ~ /(^|[^A-Za-z0-9_.\/-])(bash|sh|zsh|ksh|dash|csh|tcsh|fish|eval|source|exec|xargs|ssh|env|python|python3|perl|ruby|node|awk|sed)([^A-Za-z0-9_-]|$)/) next
      t = $0
      sub(/^.*<<-?[ \t]*/, "", t)
      if (match(t, /^[^A-Za-z0-9_]?[A-Za-z_][A-Za-z0-9_]*/) == 0) next
      delim = substr(t, 1, RLENGTH)
      sub(/^[^A-Za-z_]/, "", delim)
      hd = 1
    }
    END {
      # An unterminated heredoc means we mis-read the string: redact nothing.
      for (i = 1; i <= NR; i++) {
        if (hd == 0 && (i in drop)) continue
        print line[i]
      }
    }' 2>/dev/null || printf '%s' "$1"
}

# The tokeniser — parse_merge_command's four steps (join `\`-newline, newline →
# ` ; `, space-pad the operators, xargs), one token per line; returns non-zero
# when xargs cannot balance the quotes. Same tokens, but built to be CHEAP: bash
# 3.2's `${var//$'\n'/ ; }` and `xargs -n1` (one printf fork per token) measured
# 8-20 s on the 9-19 KB heredoc commits agents really issue, against a 25 s hook
# timeout — and a hook that times out does not block. awk does the joins and ONE
# printf prints every token.
_tokenise() {
  ( set -o pipefail   # a missing awk/sed must fail the tokenise even if the caller forgot pipefail
  printf '%s' "$1" | awk '
    NR > 1 { if (sub(/\\$/, "", prev)) printf "%s ", prev; else printf "%s ; ", prev }
    { prev = $0 }
    END { printf "%s", prev }' 2>/dev/null \
    | sed -E 's/(\|\||&&|;|\||&)/ \1 /g' | xargs printf '%s\n' 2>/dev/null )
}

# Drop the values of prose-carrying flags. Prints the redacted string; returns 1
# (printing nothing) when the string could not be tokenised, so callers keep the
# raw greedy result and stay fail-closed.
_redact_prose_values() {
  local out="" tok tokens
  tokens="$(_tokenise "$1")" || return 1

  local expect_cmd=1 drop=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      ";" | "&&" | "||" | "|" | "&" | "|&")
        drop=0; expect_cmd=1
        out="${out}${tok}"$'\n'; continue ;;
    esac
    if [ "$expect_cmd" = "1" ]; then
      # A command-position token is NEVER a flag value (this is what keeps a real
      # `gh`/`git` visible however the previous command ended).
      case "$tok" in
        [A-Za-z_]*=*) out="${out}${tok}"$'\n'; continue ;;                  # VAR=val prefix
        command | builtin | exec | env | sudo | nice | nohup | time | timeout)
          out="${out}${tok}"$'\n'; continue ;;                              # wrappers
      esac
      expect_cmd=0; drop=0
      out="${out}${tok}"$'\n'; continue
    fi
    if [ "$drop" = "1" ]; then
      drop=0
      case "$tok" in
        *'$'* | *'`'*) ;;                       # could still run a command — keep it
        gh | git | pr | merge | push) ;;        # a bare trigger word — keep it
        *) continue ;;                          # prose: redact
      esac
      out="${out}${tok}"$'\n'; continue
    fi
    case "$tok" in
      -m | --message | -b | --body | -F | --body-file | -t | --title | --subject | --notes | --note)
        drop=1 ;;
      --message=* | --body=* | --body-file=* | --title=* | --subject=* | --notes=* | --note=*)
        case "$tok" in
          *'$'* | *'`'*) ;;
          *) continue ;;
        esac ;;
    esac
    out="${out}${tok}"$'\n'
  done <<EOF
$tokens
EOF
  printf '%s' "$out"
}

# The string the greedy scans actually read: heredoc bodies and prose flag values
# removed. Returns 1 (printing nothing) when redaction could not be done safely.
_redact_prose() {
  local hd
  hd="$(_redact_heredocs "$1")"
  _redact_prose_values "$hd"
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
  # It IS present — but it may be present only in prose the shell never executes
  # (a PR body, a commit message, a heredoc). Re-scan with those redacted; the
  # redaction is skipped when it cannot be done safely, and never when the greedy
  # counter itself was unavailable (the 999999 sentinel must keep failing closed).
  if [ "$MC_MERGE_RELATED" = "1" ] && [ "$MC_RELATED_COUNT" != "999999" ]; then
    local _mc_red
    if _mc_red="$(_redact_prose "$raw")" && [ -n "$_mc_red" ]; then
      MC_MERGE_RELATED=0
      MC_RELATED_COUNT=0
      _mc_related_scan "$_mc_red"
    fi
  fi
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
#   PC_PARSE_ERR    — 1 if the command carries a `git … push` and could not be
#                     safely tokenised (see WHEN THE RAW STRING … below).
#   PC_HAS_CD       — 1 if a `cd`/`pushd`/`popd` command appears anywhere, or a
#                     `git -C <path>` was consumed (the hook's cwd is not
#                     necessarily where the push runs).
#   PC_CD_WORDS     — greedy count of the WORDS `cd`/`pushd`/`popd` anywhere in
#                     the raw string, structure-agnostic (999999 = uncountable).
#   PC_CD_DIR       — the argument of a LEADING `cd <dir>`: set only when `cd` is
#                     the command's very first token (no wrapper, nothing before
#                     it) and `<dir>` is followed directly by `&&` or `;`. Empty
#                     otherwise. The gate resolves a refspec-less push in it only
#                     when PC_CD_WORDS is exactly 1 — so a second cd the walker
#                     cannot see (`if …; then cd …`, `{ cd …; }`, a heredoc or
#                     comment line) keeps denying — and vets the path itself.
#   PC_GIT_REDIRECT — 1 if the raw string mentions GIT_DIR/GIT_WORK_TREE or
#                     --git-dir/--work-tree: the repository a push reads is then
#                     not the one in its directory, so nothing can be resolved.
#   PC_HAS_SWITCH   — 1 if a `git checkout`/`git switch` appears (in command
#                     position, or to the same greedy scan that counts pushes):
#                     the branch at push time is then not the branch the hook
#                     can read now.
#   PC_C_PATHS      — newline-separated list of `-C` values seen.
#   PC_PUSHES       — one record per push, newline-separated:
#                     `<flags>\x1f<remote>\x1f<refspec1> <refspec2>…\x1f<-C path>`
#                     (US-separated, since tab is IFS whitespace and an empty
#                     flags column would collapse) where flags is a comma-joined
#                     subset of {all,mirror,branches,delete,tags,prune,dryrun}
#                     (dry-run is informational only — still gated) and the last
#                     column is THAT push's own `-C` value (the last one wins, as
#                     in git), empty when it has none.
#
# WHEN THE RAW STRING CANNOT BE TOKENISED (an apostrophe in a heredoc body, a
# `\"` inside a double-quoted message — xargs knows neither), the parse is retried
# ONCE on the text with heredoc bodies removed (`_redact_heredocs` — the text the
# greedy scan already trusts; a heredoc fed to an interpreter is never removed)
# and `\\` / `\"` neutralised. A command that tokenises raw never takes this
# path, so it behaves exactly as it always has. The retry is accepted only if the
# removed bodies carried no `git … push` (greedy count AND the looser per-line
# scan both unchanged) — a script written by heredoc and then run stays denied.
# If the retry fails too, the command is push-related only when one of those two
# scans sees a `git … push`: the bare word `push` (JS `.push(`, prose) is not one.
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
          else if ($0=="checkout" || $0=="switch") k++
          s=0; skip=0
        } }
      END { print c+0, k+0 }' 2>/dev/null)"
  fi
  if printf '%s' "$n" | grep -qE '^[0-9]+ [0-9]+$'; then
    PC_RELATED_COUNT="${n% *}"
    PC_SWITCH_COUNT="${n#* }"
  elif printf '%s' "$1" | grep -Eq 'git.*push'; then
    # Greedy counter unavailable (missing tr/awk) — do NOT fail open. Sentinel
    # count can never equal PC_PUSH_COUNT, so the gate denies (recoverable).
    PC_RELATED_COUNT=999999
  fi
}

# Looser than the greedy scan, and only consulted where the precise walker cannot
# be: prints how many LINES carry the word `git` and, later on that line, the
# word `push`. Words are [A-Za-z0-9_] runs, so the quoted `-C "/dir with space"`
# that blinds the greedy scan is seen here. Prints nothing if awk is missing
# — callers compare against "0" / each other, so that fails closed.
_pc_loose_scan() {
  printf '%s' "$1" | awk '
    function scan(l,   n, w, i, g) {
      gsub(/[^A-Za-z0-9_]+/, " ", l); n = split(l, w, " "); g = 0
      for (i = 1; i <= n; i++) { if (w[i] == "git") g = 1; else if (g && w[i] == "push") { c++; break } }
    }
    { if (sub(/\\$/, " ")) { buf = buf $0; next } scan(buf $0); buf = "" }   # `\`-newline joins
    END { if (buf != "") scan(buf); print c+0 }' 2>/dev/null
}

# The same word scan over the WHOLE string, line breaks ignored: prints 1 when the
# word `git` is followed ANYWHERE later by the word `push`, else 0. For the one
# place nothing else can vouch for the command (it would not tokenise, twice). A
# per-line scan is not enough there: a newline inside a quoted option value, or a
# python list split across lines, puts `git` and `push` on different lines while
# the greedy scan is blinded by the same quoted value — and that was a real
# `git push origin main` the old gate denied. Prints nothing if awk is missing;
# the caller compares against "0", so that fails closed.
_pc_anywhere_scan() {
  printf '%s' "$1" | awk '
    { gsub(/[^A-Za-z0-9_]+/, " "); n = split($0, w, " ")
      for (i = 1; i <= n; i++) { if (w[i] == "git") g = 1; else if (g && w[i] == "push") c = 1 } }
    END { print c+0 }' 2>/dev/null
}

# Flush the push invocation being walked (state in _pc_*).
_pc_record() {
  [ "$_pc_in_push" = "1" ] || return 0
  PC_PUSH_COUNT=$((PC_PUSH_COUNT + 1))
  PC_PUSHES="${PC_PUSHES}${PC_PUSHES:+$'\n'}${_pc_flags}"$'\x1f'"${_pc_remote}"$'\x1f'"${_pc_refspecs}"$'\x1f'"${_pc_cdir}"
}

_pc_reset() {
  _pc_in_git=0; _pc_in_push=0; _pc_git_skip=0; _pc_git_c=0; _pc_push_skip=0
  _pc_dashdash=0; _pc_flags=""; _pc_remote=""; _pc_refspecs=""; _pc_npos=0; _pc_cdir=""
}

parse_push_command() {
  PC_PUSH_RELATED=0
  PC_RELATED_COUNT=0
  PC_PUSH_COUNT=0
  PC_PARSE_ERR=0
  PC_HAS_CD=0
  PC_CD_WORDS=0
  PC_CD_DIR=""
  PC_GIT_REDIRECT=0
  PC_HAS_SWITCH=0
  PC_SWITCH_COUNT=0
  PC_C_PATHS=""
  PC_PUSHES=""

  local raw="$1"
  [ -n "$raw" ] || return 0

  _pc_related_scan "$raw"
  local _pc_red _pc_n_raw="$PC_RELATED_COUNT"   # raw count, before any redaction — the fallback's yardstick
  # Same prose re-scan as parse_merge_command (see _redact_prose): a commit
  # message or PR body that talks about pushing is not a push.
  if [ "${PC_RELATED_COUNT:-0}" != "0" ] && [ "${PC_RELATED_COUNT:-0}" != "999999" ]; then
    if _pc_red="$(_redact_prose "$raw")" && [ -n "$_pc_red" ]; then
      PC_RELATED_COUNT=0
      _pc_related_scan "$_pc_red"
    fi
  fi

  # Cheap pre-filter: if the literal word `push` is nowhere in the string the
  # precise walker cannot find one either (it only recognises the token `push`).
  # Keeps the hot path (every Bash call) to one grep + one awk.
  if [ "$PC_RELATED_COUNT" = "0" ] && ! printf '%s' "$raw" | grep -qw 'push'; then
    return 0
  fi

  # Precise parse — same pipeline as parse_merge_command, on the RAW string first.
  local tokens
  if ! tokens="$(_tokenise "$raw")"; then
    # Untokenisable. Retry once with heredoc bodies removed and `\\` / `\"`
    # neutralised (sed scans left to right, so `\\"` is a backslash pair and then
    # a real quote — xargs has no escapes inside "…", bash does). See the header.
    local _pc_hd _pc_t2
    _pc_hd="$(_redact_heredocs "$raw")"
    _pc_t2="$(printf '%s' "$_pc_hd" | sed -E 's/\\[\\"]/_/g')"
    if tokens="$(_tokenise "$_pc_t2")" && _pc_red="$(_redact_prose_values "$_pc_t2")" && [ -n "$_pc_red" ]; then
      # The walker is about to read text with the heredoc bodies gone. If a body
      # carried a `git … push` (a script being written, then run) that would hide
      # it — keep failing closed.
      _pc_related_scan "$_pc_hd"
      if [ "$PC_RELATED_COUNT" != "$_pc_n_raw" ] || [ "$(_pc_loose_scan "$_pc_hd")" != "$(_pc_loose_scan "$raw")" ]; then
        PC_PARSE_ERR=1
        PC_PUSH_RELATED=1
        return 0
      fi
      PC_RELATED_COUNT=0
      _pc_related_scan "$_pc_red"
    else
      # Still untokenisable, so there is no precise parse to agree with. The bare
      # word `push` that got us past the pre-filter is not a git push (JS
      # `.push(`, prose); a `git` with a `push` ANYWHERE after it is, whatever
      # the line breaks between them say.
      if [ "$_pc_n_raw" = "0" ] && [ "$(_pc_anywhere_scan "$raw")" = "0" ]; then
        return 0
      fi
      PC_PARSE_ERR=1
      PC_PUSH_RELATED=1
      return 0
    fi
  fi
  [ "${PC_SWITCH_COUNT:-0}" != "0" ] && PC_HAS_SWITCH=1
  case "$raw" in
    *GIT_DIR* | *GIT_WORK_TREE* | *--git-dir* | *--work-tree*) PC_GIT_REDIRECT=1 ;;
  esac
  PC_CD_WORDS="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_' '\n' | grep -cxE 'cd|pushd|popd')"
  printf '%s' "$PC_CD_WORDS" | grep -qE '^[0-9]+$' || PC_CD_WORDS=999999

  local expect_cmd=1 tok _pc_tokn=0 _pc_in_cd=0 _pc_cd_arg=""
  _pc_reset
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _pc_tokn=$((_pc_tokn + 1))

    case "$tok" in
      ";" | "&&" | "||" | "|" | "&" | "|&")
        # The leading `cd <dir>` is kept only when `&&` / `;` follows <dir> directly.
        if [ "$_pc_in_cd" = "2" ]; then
          case "$tok" in "&&" | ";") PC_CD_DIR="$_pc_cd_arg" ;; esac
        fi
        _pc_in_cd=0
        _pc_record
        _pc_reset
        expect_cmd=1
        continue ;;
    esac

    if [ "$_pc_in_cd" != "0" ]; then
      # 1 = expecting <dir>; 2 = have it; 3 = extra args / a redirection — not kept.
      if [ "$_pc_in_cd" = "1" ]; then _pc_cd_arg="$tok"; _pc_in_cd=2; else _pc_in_cd=3; fi
      continue
    fi

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
        _pc_git_c=0; PC_HAS_CD=1; _pc_cdir="$tok"
        PC_C_PATHS="${PC_C_PATHS}${PC_C_PATHS:+$'\n'}$tok"
        continue
      fi
      if [ "$_pc_git_skip" = "1" ]; then _pc_git_skip=0; continue; fi
      case "$tok" in
        -C) _pc_git_c=1; continue ;;
        -C?*) PC_HAS_CD=1; _pc_cdir="${tok#-C}"; PC_C_PATHS="${PC_C_PATHS}${PC_C_PATHS:+$'\n'}${tok#-C}"; continue ;;
        -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix) _pc_git_skip=1; continue ;;
        -*) continue ;;
      esac
      case "$tok" in
        push) _pc_in_push=1 ;;
        checkout | switch) PC_HAS_SWITCH=1; _pc_in_git=0 ;;
        *) _pc_in_git=0 ;;
      esac
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
        cd | pushd | popd)
          PC_HAS_CD=1
          [ "$tok" = "cd" ] && [ "$_pc_tokn" = "1" ] && _pc_in_cd=1 ;;
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
