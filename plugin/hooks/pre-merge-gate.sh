#!/usr/bin/env bash
#
# pre-merge-gate.sh — mechanical enforcement of the merge-greenness gate.
#
# Wired as a PreToolUse(Bash) hook (see .claude/settings.json). It fires on EVERY
# Bash tool call and self-filters: it is a silent no-op for anything that is not a
# `gh pr merge` invocation. For a `gh pr merge`, it independently verifies the
# PR's check rollup is all-green and DENIES the merge otherwise — converting the
# playbook's instruction-level gate ("never merge until `gh pr checks` is green,
# including `review`") into a mechanical control.
#
# WHY THIS EXISTS: the gate silently failed once — a `gh pr checks <n> --watch |
# tail` pipe masked the real exit code (a pipe returns tail's 0), so a PR whose
# e2e had FAILED got merged and briefly broke `main`. This hook removes the
# human-reads-the-output link from the chain.
#
# It ALSO denies a PR whose head is BEHIND its base — green checks against an old
# base say nothing about the COMBINED state that would land.
#
# THIS IS A CORRECTNESS CONTROL, NOT CONCURRENCY MACHINERY. It used to be
# described here as guarding "the core hazard of parallel runs", which was always
# attributing a general effect to a specific cause, and became actively
# misleading once `parallel: 1` went default (2026-08-18). Measured over a consumer's
# 161 merged PRs: 42 (26%) had another PR land on `main` while they were open —
# and restricted to PRs open two hours or less, still 27 of 138 (20%), against a
# median open window of 19 minutes. One PR went stale in five minutes. A
# single-worker pipeline merges audit records, fix-PRs, follow-ups and chores
# between a branch's green and its merge, so the base rate here is INDEPENDENT of
# `parallel:` and larger than the 17% co-dispatch rate that demoted coordinator
# mode. Do not delete this check — or tests d7/d8, which are the only things that
# catch its removal — on the grounds that parallel runs are now opt-in.
#
# Freshness is enforced PROTECTION-INDEPENDENTLY: `mergeStateStatus == BEHIND` is
# a fast-path deny, but GitHub only reports BEHIND under strict
# required-status-check branch protection
# (empirically verified — a free-plan repo one commit behind its base reports
# mergeStateStatus CLEAN), so BEHIND alone is vacuous on the target repos this
# runs against. For EVERY other mergeStateStatus the hook makes the ground-truth
# call: `gh api repos/{owner}/{repo}/compare/<base>...<headOid> --jq .behind_by`
# and denies when the head is behind by >0 commits. Any uncertainty about
# freshness (missing base/head, compare error/timeout, non-numeric) denies
# recoverably. This is what makes "stale-green merges are mechanically
# impossible" true without branch protection.
#
# DESIGN INVARIANTS (this hook STRENGTHENS the gate; it must never weaken it):
#   - It only ever emits a DENY or stays silent. It NEVER emits an allow/approve,
#     so it can only ADD denials on top of the normal permission flow — it can
#     never make a command more permissive than baseline.
#   - Fail-closed for merges: on ANY error/uncertainty (gh errors, times out,
#     unparseable output) it DENIES *recoverably* — the operator re-runs once gh
#     recovers and a genuinely-green PR then passes. It never fails open (that
#     would reopen the hole) and never permanently wedges (a later retry passes).
#   - The harness may treat a non-zero hook exit as a NON-blocking (fail-open)
#     error, so this script ALWAYS exits 0 and communicates purely via stdout
#     JSON. An EXIT trap guarantees a deny is emitted even on an unexpected crash
#     while handling a merge command.
#   - Bounded: the gh query has its own internal timeout so the hook always
#     finishes well inside the harness hook timeout and never relies on it.
#   - Current repo only: gh runs in the caller's cwd (no --repo), and --repo/-R
#     /--admin on the merge command are rejected outright.
#
# PUSH GATE (same hook, second branch). The hook ALSO denies any `git push`
# whose resolved destination is the base branch (`main`/`master`, `origin/HEAD`,
# or SWEAP_BASE_BRANCH from the hook's env): `origin main`, `HEAD:main`,
# `refs/heads/main`, `--delete main`, `--all`/`--mirror`, and a bare `git push`
# while on the base or when push.default would land there. Threat model: honest
# slips on private Free-plan repos, where rulesets/branch protection are
# unavailable (403) so nothing server-side prevents a direct push. It is
# PURELY LOCAL (git symbolic-ref/rev-parse in cwd — never gh, never the network,
# each call under bounded_run) because a stalled hook does NOT block: the harness
# treats a timed-out hook as non-blocking, i.e. fail-open. Same fail-closed shape
# as the merge branch: greedy trip-wire + precise parse (lib-merge-parse.sh,
# parse_push_command) must agree, or the push is denied recoverably. Accepted
# over-blocks (re-issue the push plainly): a push wrapped in if/$()/bash -c, an
# `echo "git push …"` mention, a `-C` path with spaces, a refspec-less push after
# any `cd` but a single leading `cd /literal/absolute/dir &&` (that one, and the
# push's own `git -C /abs/dir`, are resolved IN that directory), and a
# refspec-less push sharing a command with `git checkout`/`git switch` (the
# branch the hook reads now is not the branch at push time). Prose
# the shell never runs — a PR body/title, a commit message, a heredoc body — is
# redacted before the trip-wire (lib-merge-parse.sh, _redact_prose), so talking
# about pushing is not pushing.
# Item-branch pushes — the hot path (`git push -u origin <item>`,
# `--force-with-lease` after a rebase, `--delete <item>`, tags, `main:<item>`)
# — pass untouched. Override: SWEAP_PUSH_GATE=off is honoured ONLY from the
# hook's own environment (user-level settings `env` / the launching shell) and
# is IGNORED when the project's .claude settings define it (agent-writable); an
# inline `VAR=… git push` prefix never reaches the hook's env.
#
# SELF-MODIFYING CI. A PR that touches .github/workflows/** or .github/scripts/**
# is never mergeable from a session (see verify_pr): when every other check has
# passed it is still denied, and the deny gives the human the line that merges it.
#
# Exit: always 0. Decision is the stdout JSON (deny) or empty stdout (no-op/defer).

set -uo pipefail

# Shared shell-aware `gh pr merge` + `git push` detectors/parsers (see
# lib-merge-parse.sh: parse_merge_command, parse_push_command).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib-merge-parse.sh"

# --- guaranteed decision channel ------------------------------------------------
DECISION_EMITTED=0   # set when we print a deny
IS_MERGE=0           # set once we know the command is a `gh pr merge`
IS_PUSH=0            # set once we know the command is push-related
CLEAN_ALLOW=0        # set right before a deliberate all-green (silent) allow

emit_deny() {
  # $1 = human-readable reason. Emits the PreToolUse deny JSON and marks done.
  local reason="$1"
  DECISION_EMITTED=1
  # jq builds valid JSON regardless of characters in the reason.
  jq -cn --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

# Fail-closed backstop: if we are handling a merge command and somehow reach exit
# WITHOUT having emitted a decision (unexpected crash / unbound var / etc.), deny
# recoverably. Always force exit 0 so the harness parses our stdout JSON rather
# than treating a non-zero exit as a fail-open non-blocking error.
# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT`
handle_exit() {
  if [ "$DECISION_EMITTED" != "1" ] && [ "$CLEAN_ALLOW" != "1" ]; then
    if [ "$IS_MERGE" = "1" ]; then
      emit_deny "merge-gate hook could not complete its greenness check (internal error). Denying to stay fail-closed — re-run the merge once resolved."
    elif [ "$IS_PUSH" = "1" ]; then
      emit_deny "push-gate hook could not complete (internal error). Denying to stay fail-closed — re-issue the push."
    fi
  fi
  exit 0
}
trap handle_exit EXIT

# --- read hook input ------------------------------------------------------------
input="$(cat)"

# jq parses the tool call. If it is somehow missing we cannot parse the JSON, so
# fall back to a RAW grep of the whole input: if it looks like a `gh pr merge`,
# FAIL CLOSED (deny-recoverable) rather than silently letting an unverifiable
# merge through; otherwise no-op. (jq is a hard repo dependency and is always
# present — this is pure defence-in-depth so the jq-missing path is never a hole.)
if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
    IS_MERGE=1
    DECISION_EMITTED=1
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"merge-gate: jq is unavailable so checks cannot be verified. Denying (recoverable) — install jq and re-run the merge."}}'
  elif printf '%s' "$input" | grep -Eq 'git[[:space:]]+push'; then
    IS_PUSH=1
    DECISION_EMITTED=1
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"push-gate: jq is unavailable so the push destination cannot be resolved. Denying (recoverable) — install jq and re-issue the push."}}'
  fi
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"

# Only Bash tool calls carry a shell command.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# --- merge-driver launch hygiene (belt B) ------------------------------------------
# The driver (sweap-merge.sh) re-execs itself under `env -i` + `bash -p` (belt
# A), but its FIRST process has already sourced $BASH_ENV by then, so a file that
# shadows `exec`/`env` there defeats belt A. This rule refuses the launch LINE:
# any command that names the driver AND carries an environment override —
# an interpreter knob (BASH_ENV, ENV, SHELLOPTS, BASHOPTS), a lookup knob (PATH,
# CDPATH, HOME), a repo re-anchor (GIT_DIR, GIT_WORK_TREE, GIT_CONFIG_GLOBAL),
# a loader hook (LD_PRELOAD, DYLD_INSERT_LIBRARIES), a SWEAP_MERGE_* test seam,
# or an `env` wrapper. Pure text scan, no git, no gh; greedy on purpose — a
# comment or `echo` that mentions the driver next to `PATH=` is over-denied
# (re-issue without the mention). Independent of the parser lib (runs before
# it is needed) and of the merge/push branches (a deny here is final).
#
# "Names the driver" is TWO spellings, because the model's launch line is now
# the bare command from the plugin's bin/ (`sweap-merge watch <n>`) and only a
# maintainer types the script path. The second pattern matches `sweap-merge` as
# a whole token — end of word — so the driver's own test suite
# (`sweap-merge.test.sh`) and its state dir (`.claude/sweap-merge/`) do not trip
# it, while an explicit path to the wrapper (`plugin/bin/sweap-merge`) does. A
# rename that reached only the first spelling would have left the new primary
# launch line unguarded.
ml_named=0
case "$cmd" in *sweap-merge.sh*) ml_named=1 ;; esac
if [ "$ml_named" = "0" ] && printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_-])[^[:space:]]*sweap-merge([[:space:]]|$)'; then
  ml_named=1
fi
case "$ml_named" in
  1)
    ml_hit=""
    for ml_v in BASH_ENV ENV SHELLOPTS BASHOPTS PATH CDPATH HOME GIT_DIR GIT_WORK_TREE GIT_CONFIG_GLOBAL LD_PRELOAD DYLD_INSERT_LIBRARIES; do
      if printf '%s' "$cmd" | grep -Eq "(^|[^A-Za-z0-9_])${ml_v}="; then ml_hit="$ml_v"; break; fi
    done
    if [ -z "$ml_hit" ] && printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_])SWEAP_MERGE_[A-Za-z0-9_]*='; then ml_hit="SWEAP_MERGE_*"; fi
    if [ -z "$ml_hit" ] && printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_.-])env[[:space:]]'; then ml_hit="env wrapper"; fi
    if [ -n "$ml_hit" ]; then
      emit_deny "merge-driver: refusing to launch the sweap-merge driver with an environment override ($ml_hit). Run it plainly: sweap-merge watch <n>"
      exit 0
    fi
    ;;
esac

# --- rerun redirect -----------------------------------------------------------------
# The 2026-08-25 sweap-merge research memo (item 1, "Open risks") names the one
# risk of a MANUAL rerun verb: "agents route around the verb via bare `gh run
# rerun` — needs the PreToolUse redirect". This is that redirect. A bare
# `gh run rerun` leaves nothing in the PR's state file — no record of who
# rerun what and why, no per-head+workflow cap, no base-red refusal, and no
# flake note when the rerun turns green — so it is denied and pointed at
# `sweap-merge rerun <pr> --reason "<why>"`, which issues the very same
# `gh run rerun --failed <id>` and records it. Pure text scan, greedy on
# purpose (a --reason that quotes the words is over-denied; rephrase it).
# Calling context: this hook sees only Bash TOOL calls. The driver's own
# `gh run rerun` (sweap-merge.sh, sm_rerun) is a direct child process of the
# driver, never a tool call, so it never reaches this hook — and the driver
# runs THIS gate only for its synthetic `gh pr merge` payload (sm_run_gate).
# `sweap-merge rerun …` itself does not contain the denied words. Nothing to
# allow-list; the belt-B token match above stays untouched.
if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_./-])gh[[:space:]]+run[[:space:]]+rerun([[:space:]]|$)'; then
  emit_deny "rerun-redirect: a bare 'gh run rerun' is not the recorded path. Use: sweap-merge rerun <pr> --reason \"<why this red is believed to be a flake>\" — it issues the same 'gh run rerun --failed <id>' but only for a completed failure, refuses when the same workflow is red on the base's tip, allows one rerun per head AND workflow (a second red of the same workflow on the same head is a finding, not a flake), records who/what/why in the PR's state file, and files a flaky: discovered note if the rerun turns green. The driver never reruns on its own; this verb is how a human does it on record."
  exit 0
fi

# If the shared parser failed to load (lib missing/deleted, a syntax error, or a
# missing tool like `dirname` broke the `.` source line), do NOT proceed to an
# undefined `parse_merge_command` — that would abort under `set -u` before we mark
# IS_MERGE and fail OPEN. Fail CLOSED on anything merge-ish instead.
if ! declare -F parse_merge_command >/dev/null 2>&1 || ! declare -F parse_push_command >/dev/null 2>&1; then
  if printf '%s' "$cmd" | grep -Eq 'gh.*pr.*merge'; then
    IS_MERGE=1
    emit_deny "merge-gate: the gate's parser could not load, so this merge cannot be verified. Denying (recoverable) — retry once the environment is healthy."
  elif printf '%s' "$cmd" | grep -Eq 'git.*push'; then
    IS_PUSH=1
    emit_deny "push-gate: the gate's parser could not load, so this push's destination cannot be resolved. Denying (recoverable) — retry once the environment is healthy."
  fi
  exit 0
fi

# --- greedy-detect + fail-closed ------------------------------------------------
# parse_merge_command sets MC_MERGE_RELATED (a structure-agnostic greedy trip-wire:
# do the words gh->pr->merge appear in order anywhere?) plus a PRECISE parse of the
# pristine simple form. parse_push_command does the same for `git push`. A command
# can be neither (silent no-op), either, or both (push branch runs first; a push
# deny wins, otherwise merge verification proceeds unchanged). Merge-related but
# NOT a pristine simple merge (wrapped in if/while/for/subshell/$()/backticks,
# extra or missing args, a bad flag, untokenisable, or the precise parse didn't
# account for every greedy occurrence) → fail CLOSED. Only a pristine, all-green
# merge ALLOWs.
parse_merge_command "$cmd"
parse_push_command "$cmd"
if [ "$MC_MERGE_RELATED" != "1" ] && [ "${PC_PUSH_RELATED:-0}" != "1" ]; then
  exit 0   # neither merge- nor push-related — silent no-op
fi
[ "$MC_MERGE_RELATED" = "1" ] && IS_MERGE=1
[ "${PC_PUSH_RELATED:-0}" = "1" ] && IS_PUSH=1

# --- run in the caller's cwd so gh/git resolve the CURRENT repo -----------------
if [ -n "$cwd" ]; then
  cd "$cwd" 2>/dev/null || {
    emit_deny "merge/push-gate: could not enter the working directory to verify the command. Denying (recoverable) — re-run it."
    exit 0
  }
fi

# bounded_run <timeout> <cmd...>: run <cmd> under its own watchdog so it always
# finishes within <timeout> seconds (never relying on the harness hook timeout),
# capturing its stdout to BR_OUT and its exit status to BR_RC. Returns non-zero
# ONLY on an infra failure (could not allocate the temp file); on a normal or
# timed-out run it returns 0 and the caller inspects BR_RC/BR_OUT. Factored so the
# rollup-view call and the compare call share ONE watchdog implementation instead
# of duplicating the block (both must stay bounded — see verify_pr's budget).
BR_OUT=""
BR_RC=0
bounded_run() {
  local timeout="$1"; shift
  local tmp brpid watcher
  [ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
  tmp="$(mktemp 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then
    BR_OUT=""; BR_RC=1
    return 1
  fi
  "$@" >"$tmp" 2>/dev/null </dev/null &
  brpid=$!
  # The watcher (and the `sleep` it may orphan when killed) must NOT inherit our
  # stdout: the harness reads the hook's stdout to EOF, and an orphaned sleep
  # holding the pipe would make every bounded call cost its FULL timeout even
  # when the command finished instantly (measured: 3 s per git call, 5-10 s per
  # gh call — the reason the test suite used to take minutes).
  ( sleep "$timeout"; kill -TERM "$brpid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  watcher=$!
  wait "$brpid" 2>/dev/null
  BR_RC=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  BR_OUT="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  return 0
}

# --- push gate ------------------------------------------------------------------
# base_set: the union of every name the base branch could go by. Over-approximate
# on purpose (only ever ADDED to; every lookup failure is ignored) — a false
# "main" costs one plain re-issue, a missed one is a direct push to the base.
PG_BASES=""
_pg_add_base() { [ -n "$1" ] && PG_BASES="${PG_BASES}${PG_BASES:+ }$1"; }
_pg_in_bases() {
  local b
  for b in $PG_BASES; do [ "$1" = "$b" ] && return 0; done
  return 1
}
# _pg_origin_head <dir>: append the branch origin/HEAD points at in <dir>.
_pg_origin_head() {
  bounded_run 3 git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD
  if [ "$BR_RC" = "0" ] && [ -n "$BR_OUT" ]; then _pg_add_base "${BR_OUT#origin/}"; fi
}
# _pg_strip_remote <ref> [<dir>]: `refs/remotes/<remote>/<branch>` or
# `<remote>/<branch>` → `<branch>`, using the actual remote names of the repo in
# <dir> (so a branch containing `/` is not mangled). Sets PG_DST.
_pg_strip_remote() {
  local ref="${1#refs/remotes/}" r
  PG_DST="$ref"
  bounded_run 3 git -C "${2:-.}" remote
  [ "$BR_RC" = "0" ] || return 0
  for r in $BR_OUT; do
    case "$ref" in "$r"/*) PG_DST="${ref#"$r"/}"; return 0 ;; esac
  done
  # No remote matched: fall back to dropping the first path component.
  case "$ref" in */*) PG_DST="${ref#*/}" ;; esac
}
# _pg_current_dest <mode> [<push's own -C>]: resolve where a refspec-less push
# (mode=push, respects push.default) or an explicit HEAD refspec (mode=head) would
# land. Sets PG_DST; returns 1 (PG_ERR = why) when it cannot be trusted → deny
# recoverable.
#
# The branch is read in the directory the push will RUN in. Without cd/-C that is
# the hook's cwd. With them it is resolved, not refused, in exactly three shapes
# (lib-merge-parse.sh: PC_CD_DIR / PC_CD_WORDS); every other shape denies as before:
#   - the push carries its own `-C <dir>`            → <dir> (cd is irrelevant to it);
#   - no `cd` word anywhere (the -C sat on ANOTHER git call) → the hook's cwd;
#   - one leading `cd <dir> &&|;` and no other cd word       → <dir>.
# <dir> must be a literal absolute path that exists — no expansion of any kind, no
# `..` — or the shell's idea of it and ours could differ.
_pg_current_dest() {
  PG_DST=""; PG_ERR=""
  local pg_dir="."
  if [ "${PC_HAS_SWITCH:-0}" = "1" ]; then
    PG_ERR="the command also runs 'git checkout'/'git switch', so the branch at push time is not the branch the gate can read now — name the branch: git push origin <branch>"
    return 1
  fi
  if [ "${PC_GIT_REDIRECT:-0}" = "1" ]; then
    PG_ERR="GIT_DIR/GIT_WORK_TREE/--git-dir/--work-tree point git at another repository — name the branch: git push origin <branch>"
    return 1
  fi
  if [ "${PC_HAS_CD:-0}" = "1" ]; then
    if [ -n "${2:-}" ]; then
      case "$2" in /*) pg_dir="$2" ;; *) pg_dir="" ;; esac
    elif [ "${PC_CD_WORDS:-1}" = "0" ]; then pg_dir="."
    elif [ "${PC_CD_WORDS:-0}" = "1" ]; then pg_dir="${PC_CD_DIR:-}"
    else pg_dir=""
    fi
    case "$pg_dir" in
      .) ;;
      *'$'* | *'`'* | *'*'* | *'?'* | *'['* | *'{'* | *'~'* | *..*) pg_dir="" ;;
      /*) [ -d "$pg_dir" ] && [ -x "$pg_dir" ] || pg_dir="" ;;
      *) pg_dir="" ;;
    esac
    if [ -z "$pg_dir" ]; then
      PG_ERR="cwd cannot be trusted after this cd/-C — only a single leading 'cd /literal/absolute/dir &&' (or the push's own 'git -C /literal/absolute/dir') is followed. Name the branch: git push origin <branch>"
      return 1
    fi
  fi
  if [ "$1" = "push" ]; then
    bounded_run 3 git -C "$pg_dir" config --get push.default
    if [ "$BR_OUT" = "matching" ]; then
      PG_ERR="push.default=matching pushes EVERY matching branch, including the base — name the branch: git push origin <branch>"
      return 1
    fi
    bounded_run 3 git -C "$pg_dir" rev-parse --symbolic-full-name '@{push}'
    if [ "$BR_RC" = "0" ] && [ -n "$BR_OUT" ]; then
      _pg_strip_remote "$BR_OUT" "$pg_dir"
      return 0
    fi
  fi
  bounded_run 3 git -C "$pg_dir" rev-parse --abbrev-ref HEAD
  if [ "$BR_RC" != "0" ] || [ -z "$BR_OUT" ] || [ "$BR_OUT" = "HEAD" ]; then
    PG_ERR="HEAD is detached or unreadable, so the destination cannot be resolved — name the branch explicitly: git push origin <branch>"
    return 1
  fi
  PG_DST="$BR_OUT"
  return 0
}
PG_DENY_TAIL="On a Free-plan private repo nothing server-side prevents this, so this hook is the control. Land the change through a PR: gh pr create → green checks → gh pr merge. If this is a deliberate maintainer chore, run it in your own terminal outside Claude Code (or set SWEAP_PUSH_GATE=off in USER settings env / the launching shell — never in the project's .claude settings, never inline)."
_pg_deny_base() {  # $1=base name, $2=what resolved to it
  emit_deny "push-gate: refusing 'git push' whose destination resolves to base branch '$1' ($2). $PG_DENY_TAIL${PG_OVERRIDE_NOTE:-}"
  exit 0
}
_pg_deny_recoverable() {
  emit_deny "push-gate: cannot resolve where this push would land — $1. Denying (recoverable)."
  exit 0
}

if [ "$IS_PUSH" = "1" ]; then
  # Override channel: only the hook's OWN environment (user settings `env` or the
  # launching shell). A project-level settings file that defines the variable is
  # agent-writable, so its presence there VOIDS the override (deny proceeds,
  # with a note). An inline `SWEAP_PUSH_GATE=off git push` never reaches us.
  PG_OVERRIDE_NOTE=""
  if [ "${SWEAP_PUSH_GATE:-}" = "off" ]; then
    pg_top=""
    bounded_run 3 git rev-parse --show-toplevel
    [ "$BR_RC" = "0" ] && pg_top="$BR_OUT"
    [ -n "$pg_top" ] || pg_top="${CLAUDE_PROJECT_DIR:-}"
    pg_project_defines=0
    for pg_f in "$pg_top/.claude/settings.json" "$pg_top/.claude/settings.local.json"; do
      [ -n "$pg_top" ] && [ -f "$pg_f" ] || continue
      if jq -e '.env.SWEAP_PUSH_GATE != null' "$pg_f" >/dev/null 2>&1; then pg_project_defines=1; fi
    done
    if [ "$pg_project_defines" = "1" ]; then
      PG_OVERRIDE_NOTE=" SWEAP_PUSH_GATE is set in the project's .claude settings, which the agent can write — the override is honoured only from user settings or the launching shell."
    else
      IS_PUSH=0   # the push branch stands down; the merge branch is unaffected
      if [ "$IS_MERGE" != "1" ]; then CLEAN_ALLOW=1; exit 0; fi
    fi
  fi
fi

if [ "$IS_PUSH" = "1" ]; then
  if [ "${PC_PARSE_ERR:-0}" = "1" ]; then
    # Its own message: the generic one below blames prose carrying $(…), which is
    # not what happened here and sent operators rewording text that was never the
    # cause (84 false denials : 1 true refusal, 2026-08-25..09-20).
    emit_deny "push-gate: this command carries a 'git … push' but could not be tokenised, so the gate cannot tell where the push would land. The usual cause is an unbalanced quote as the gate's tokeniser sees it — an apostrophe in a comment, in a heredoc fed to an interpreter (python/bash/node <<EOF) or in a \$'…' string — or a heredoc body that itself contains a 'git … push'. Failing CLOSED — re-issue the push on its own, as a separate command."
    exit 0
  fi
  if [ "${PC_PUSH_COUNT:-0}" != "${PC_RELATED_COUNT:-0}" ] \
     || [ "${PC_PUSH_COUNT:-0}" = "0" ]; then
    emit_deny "push-gate: this command is push-related but is not a plain 'git push <remote> <refspec>' the gate can resolve (wrapped in if/while/\$()/backticks, or the words appear elsewhere). Failing CLOSED — re-issue each push plainly on its own line. If the words are only PROSE: values of --body/-b, --body-file/-F, --title/-t, --subject, -m/--message and heredoc bodies are already exempt, so what tripped this is prose carrying \$(…) or backticks — put that text in a file and pass it with --body-file/-F."
    exit 0
  fi

  # Base set B.
  _pg_add_base "${SWEAP_BASE_BRANCH:-}"
  _pg_add_base main
  _pg_add_base master
  _pg_origin_head .
  case "${PC_CD_DIR:-}" in /*) [ -d "$PC_CD_DIR" ] && _pg_origin_head "$PC_CD_DIR" ;; esac
  if [ -n "${PC_C_PATHS:-}" ]; then
    while IFS= read -r pg_p; do [ -n "$pg_p" ] && _pg_origin_head "$pg_p"; done <<EOF_PATHS
$PC_C_PATHS
EOF_PATHS
  fi

  # shellcheck disable=SC2034  # pg_remote is positional filler (the record's remote column)
  while IFS=$'\x1f' read -r pg_flags pg_remote pg_refspecs pg_cdir; do
    case ",$pg_flags," in
      *,all,*) _pg_deny_base "${PG_BASES%% *}" "--all/--mirror/--branches pushes every branch, including the base" ;;
    esac
    if [ -z "$pg_refspecs" ]; then
      # Bare `git push` / `git push origin` / `git push --force-with-lease`.
      _pg_current_dest push "$pg_cdir" || _pg_deny_recoverable "$PG_ERR"
      _pg_in_bases "$PG_DST" && _pg_deny_base "$PG_DST" "current branch's push destination"
      continue
    fi
    for pg_rs in $pg_refspecs; do
      pg_rs="${pg_rs#+}"
      case ",$pg_flags," in
        *,delete,*) pg_dst="$pg_rs" ;;
        *) case "$pg_rs" in *:*) pg_dst="${pg_rs##*:}" ;; *) pg_dst="$pg_rs" ;; esac ;;
      esac
      case "$pg_dst" in
        HEAD | @)
          _pg_current_dest head "$pg_cdir" || _pg_deny_recoverable "$PG_ERR"
          pg_dst="$PG_DST" ;;
      esac
      pg_dst="${pg_dst#refs/heads/}"
      case "$pg_dst" in
        *"*"*) _pg_deny_recoverable "refspec '$pg_rs' contains a wildcard — push one branch at a time" ;;
        refs/*) continue ;;   # tags/notes/refs/for/refs/sweap — not a branch
        '') continue ;;
      esac
      _pg_in_bases "$pg_dst" && _pg_deny_base "$pg_dst" "refspec '$pg_rs'"
    done
  done <<EOF_PUSHES
$PC_PUSHES
EOF_PUSHES

  # Every push resolved to a non-base destination. If the command is ALSO a
  # merge, fall through to the merge verification; otherwise stay silent.
  if [ "$IS_MERGE" != "1" ]; then
    CLEAN_ALLOW=1
    exit 0
  fi
fi

# --- merge gate -----------------------------------------------------------------
# Specific, actionable denials first (bad flags anywhere in a recognised merge).
if [ "$MC_BAD_FLAG" = "admin" ]; then
  emit_deny "Refusing 'gh pr merge --admin': force-merging past required checks is never self-authorized (standing policy). Merge only via a green gate."
  exit 0
fi
if [ "$MC_BAD_FLAG" = "repo" ]; then
  emit_deny "Refusing 'gh pr merge --repo/-R': the agent merges only the CURRENT repo's PRs (standing policy). Drop the --repo/-R flag."
  exit 0
fi

# Fail CLOSED unless this is a PRISTINE simple merge the parser fully accounts for:
#   - tokenised cleanly (no unbalanced quotes),
#   - precise parser recognised a command-position `gh pr merge`,
#   - it recognised EXACTLY as many merges as the greedy scan saw (nothing hidden
#     in an `if`/subshell/`$()` alongside),
#   - every merge yielded one clean numeric/URL PR (nothing unparsed),
#   - at least one PR to check.
if [ "${MC_PARSE_ERR:-0}" = "1" ] \
   || [ "$MC_IS_MERGE" != "1" ] \
   || [ "${MC_UNPARSED:-0}" -gt 0 ] \
   || [ "${MC_MERGE_COUNT:-0}" != "${MC_RELATED_COUNT:-0}" ] \
   || [ -z "$MC_PRS" ]; then
  emit_deny "merge-gate: this command is merge-related but is NOT a pristine 'gh pr merge <n>' the gate can verify — it is wrapped (if/while/for/subshell/\$()/backticks), has extra/missing/ambiguous arguments, or could not be cleanly tokenised. Failing CLOSED. Re-issue each merge plainly on its own line: 'gh pr merge <n> --squash'. If the words are only PROSE: values of --body/-b, --body-file/-F, --title/-t, --subject, -m/--message and heredoc bodies are already exempt, so what tripped this is prose carrying \$(…) or backticks — put that text in a file and pass it with --body-file/-F."
  exit 0
fi

# verify_pr <n>: query one PR's rollup (bounded by an internal timeout) and, if it
# is not green or greenness can't be determined, emit a deny and return 1. Green
# ⇒ return 0 silently. A PR touching .github/workflows/** or .github/scripts/**
# is denied even when everything else passes (self-modifying CI), and that deny
# comes last, so it is only ever reached by a PR that is otherwise mergeable.
# A CheckRun is green only when COMPLETED with conclusion SUCCESS. SKIPPED/NEUTRAL
# are non-blocking for checks the pipeline does not know (a legitimately skipped
# optional check must not permanently wedge a merge), with two exceptions for
# the checks that ARE the gate — the job names the CI template fixes as its
# contract (lint, typecheck, test, e2e, review, audit-gate, ci-status):
#   - `e2e` SKIPPED is green ONLY when hooks/ci-lane.sh classifies the PR's own
#     file list as `roadmap-only` — the roadmap-only fast lane (the CI template
#     skips e2e for a backlog/docs-only change; see the playbook). The gate
#     re-derives the lane from the files rather than trusting the skip, so a
#     mis-globbed workflow can never make "e2e skipped" mean "e2e passed" on a
#     PR that touches code. A PR with no file list is not roadmap-only.
#   - any OTHER contract check SKIPPED is never green: nothing in the pipeline
#     may skip lint, typecheck, test, the review verdict or the audit gate, so a
#     skip there is a misconfiguration (a job-level `if:` reports SUCCESS and
#     satisfies a required check — audit-gate.yml's first hard rule).
# A StatusContext is green only when state==SUCCESS. Everything else (PENDING /
# QUEUED / IN_PROGRESS / FAILURE / ERROR / CANCELLED / TIMED_OUT / ACTION_REQUIRED)
# is not-green.
verify_pr() {
  local pr="$1"
  # Per-call budget ($2) so a MULTI-PR batch's TOTAL verification time stays
  # bounded (see the loop) — otherwise N × per-PR-timeout could exceed the harness
  # hook timeout, which would kill the hook and (the harness treating a killed hook
  # as non-blocking) fail OPEN. Falls back to the per-PR default for single-PR use.
  # The budget covers BOTH bounded calls this PR may make (rollup view, then the
  # compare check): the view runs first, the compare gets whatever remains.
  local budget="${2:-${MERGE_GATE_GH_TIMEOUT:-10}}"
  local json count offenders mstate base head behind remaining deadline
  [ "$budget" -ge 1 ] 2>/dev/null || budget=1
  deadline=$(( $(date +%s) + budget ))

  if ! bounded_run "$budget" gh pr view "$pr" --json statusCheckRollup,mergeStateStatus,baseRefName,headRefOid,files; then
    emit_deny "merge-gate: could not allocate a temp file to verify checks. Denying (recoverable) — re-run the merge."
    return 1
  fi
  json="$BR_OUT"

  if [ "$BR_RC" != "0" ] || [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    emit_deny "merge-gate: could not verify PR #$pr's checks (gh errored or timed out). The gate fails CLOSED — it does not know the checks are green. Re-run the merge once gh recovers; a genuinely-green PR will pass."
    return 1
  fi
  count="$(printf '%s' "$json" | jq '(.statusCheckRollup // []) | length' 2>/dev/null)"
  if ! printf '%s' "$count" | grep -qE '^[0-9]+$'; then
    emit_deny "merge-gate: could not read PR #$pr's check rollup. Denying (recoverable) — re-run the merge."
    return 1
  fi
  if [ "$count" = "0" ]; then
    emit_deny "merge-gate: PR #$pr has no checks reported yet — CI has not registered. The gate fails CLOSED (can't confirm green). Re-run once the checks appear and pass."
    return 1
  fi
  offenders="$(printf '%s' "$json" | jq -r '
    def norm:
      if (.__typename // "") == "CheckRun"
      then (if (.status // "") != "COMPLETED" then (.status // "PENDING") else (.conclusion // "PENDING") end)
      else (.state // "PENDING") end;
    (.statusCheckRollup // [])
    | map({name: (.name // .context // "unknown"), s: (norm | ascii_upcase)})
    | map(select(.s as $s | ($s == "SUCCESS" or $s == "SKIPPED" or $s == "NEUTRAL") | not))
    | map("\(.name)=\(.s)")
    | join(", ")
  ' 2>/dev/null)"
  if [ -n "$offenders" ]; then
    emit_deny "merge-gate: PR #$pr is NOT green — refusing to merge. Not-green checks: $offenders. Wait for them to pass (or fix a failure) and re-run; the gate is the control, not a prompt."
    return 1
  fi
  # Skipped CONTRACT checks (see the note above verify_pr). e2e skipped is
  # decided later, against the PR's file list; anything else skipped is a deny.
  local skipped_hard skipped_e2e=0
  skipped_hard="$(printf '%s' "$json" | jq -r '
    def norm:
      if (.__typename // "") == "CheckRun"
      then (if (.status // "") != "COMPLETED" then (.status // "PENDING") else (.conclusion // "PENDING") end)
      else (.state // "PENDING") end;
    (.statusCheckRollup // [])
    | map(select((norm | ascii_upcase) == "SKIPPED") | (.name // .context // ""))
    | map(select(. == "lint" or . == "typecheck" or . == "test" or . == "review" or . == "audit-gate" or . == "ci-status"))
    | unique | join(", ")
  ' 2>/dev/null)"
  if [ -n "$skipped_hard" ]; then
    emit_deny "merge-gate: PR #$pr has gate check(s) SKIPPED: $skipped_hard. Only e2e may skip (roadmap-only lane); a skipped lint/typecheck/test/review/audit-gate means the workflow is misconfigured (a job skipped by an if: reports success). Fix the workflow so the check runs, then re-run the merge."
    return 1
  fi
  # ci-status PRESENCE (2026-08-24). The aggregator job (`needs:` every gate)
  # is the one check whose presence proves the CI workflow actually ran on this
  # head. Required only when the repo's own workflows declare a `ci-status` job
  # (the CI template's contract) — a repo without the template is unaffected,
  # and a repo with no checks at all is already denied above. Why presence and
  # not just greenness: a ci.yml that never triggers (path filter, workflow
  # parse error, bot-token push) reports NOTHING for its jobs, and audit-gate +
  # review alone would read all-green — every check that exists passed, but the
  # check set is not the expected one. The workflow files are read from the
  # merging session's checkout; a PR that deletes the ci-status job is a
  # CI-weakening PR (standing policy forbids it, and .github/ edits always run
  # the code lane) — accepted residual. Greenness needs no extra check here:
  # a present ci-status that is not SUCCESS was already denied as an offender
  # or as a skipped contract check.
  # The workflow files are read from the REPOSITORY ROOT, not from the cwd the
  # session happens to be in: from a subdirectory the relative glob matched
  # nothing and both presence checks silently did not apply (2026-09-23 review).
  local wf_root
  wf_root="$(git rev-parse --show-toplevel 2>/dev/null)" || wf_root="."
  if grep -qsE '^[[:space:]]{2}ci-status:' "$wf_root"/.github/workflows/*.yml "$wf_root"/.github/workflows/*.yaml 2>/dev/null; then
    if ! printf '%s' "$json" | jq -e '
      any((.statusCheckRollup // [])[]; (.name // .context // "") == "ci-status")
    ' >/dev/null 2>&1; then
      emit_deny "merge-gate: PR #$pr has no 'ci-status' check on its head, but this repo's CI declares one. A check that has not been reported is not a passing check — the gate needs every expected check PRESENT and succeeded, never merely 'nothing pending'. Wait for CI to register on this head (or re-run the CI workflow), then re-run the merge."
      return 1
    fi
  fi
  # audit-gate PRESENCE (2026-09-23), the same shape and the same reasoning.
  # The skipped-check rule above catches an audit-gate check that reported
  # SKIPPED, but an audit-gate.yml that never triggered on this head reports
  # nothing at all, and the rollup then reads all-green with the one check that
  # validates the audit state simply absent — at which point merge mode's local
  # validation (a routing decision over the BASE's state, by its own header)
  # was the only validator left. Found while pricing that local step. Required
  # only when the repo's own workflows declare an `audit-gate:` job (the managed
  # template does); a repo without it is unaffected.
  if grep -qsE '^[[:space:]]{2}audit-gate:' "$wf_root"/.github/workflows/*.yml "$wf_root"/.github/workflows/*.yaml 2>/dev/null; then
    if ! printf '%s' "$json" | jq -e '
      any((.statusCheckRollup // [])[]; (.name // .context // "") == "audit-gate")
    ' >/dev/null 2>&1; then
      emit_deny "merge-gate: PR #$pr has no 'audit-gate' check on its head, but this repo's CI declares one. The audit gate is the check that validates the audit records on the PR's own tree; a head it never reported on is not verified, whatever the other checks say. Wait for CI to register on this head (or re-run the audit-gate workflow), then re-run the merge."
      return 1
    fi
  fi
  printf '%s' "$json" | jq -e '
    def norm:
      if (.__typename // "") == "CheckRun"
      then (if (.status // "") != "COMPLETED" then (.status // "PENDING") else (.conclusion // "PENDING") end)
      else (.state // "PENDING") end;
    any((.statusCheckRollup // [])[]; (.name // .context // "") == "e2e" and (norm | ascii_upcase) == "SKIPPED")
  ' >/dev/null 2>&1 && skipped_e2e=1
  # Base-freshness gate: green checks that ran against an OLD base are not
  # evidence about the COMBINED state that would actually land (a "real conflict"
  # is invisible per-branch). Enforced PROTECTION-INDEPENDENTLY:
  #   - mergeStateStatus == BEHIND ⇒ deny immediately (no compare needed). This is
  #     the fast path, but GitHub only reports BEHIND under strict required-check
  #     branch protection, so on a free-plan repo it is effectively never seen.
  #   - EVERY other state (CLEAN/BLOCKED/UNSTABLE/DIRTY/missing/UNKNOWN/anything)
  #     ⇒ ask the ground truth: how many commits is the head behind its base?
  #     `gh api repos/{owner}/{repo}/compare/<base>...<headOid> --jq .behind_by`
  #     (gh resolves {owner}/{repo} from cwd). behind_by > 0 ⇒ deny with the rebase
  #     recipe against the ACTUAL base branch; == 0 ⇒ fresh, fall through to allow.
  # Any uncertainty (missing base/head, compare error/timeout, non-numeric result)
  # denies recoverably — uncertainty is never an allow.
  mstate="$(printf '%s' "$json" | jq -r '(.mergeStateStatus // "") | ascii_upcase' 2>/dev/null)"
  if [ "$mstate" = "BEHIND" ]; then
    emit_deny "merge-gate: PR #$pr is BEHIND the base branch (mergeStateStatus) — its green checks ran against an old base, so the combined state is unverified. Rebase (git fetch origin && git rebase origin/main && git push --force-with-lease), wait for CI to go green on the rebased head, then re-run the merge."
    return 1
  fi

  base="$(printf '%s' "$json" | jq -r '.baseRefName // empty' 2>/dev/null)"
  head="$(printf '%s' "$json" | jq -r '.headRefOid // empty' 2>/dev/null)"
  if [ -z "$base" ] || [ -z "$head" ]; then
    emit_deny "merge-gate: could not read PR #$pr's base branch / head commit to verify freshness against the base. The gate fails CLOSED — re-run the merge once gh reports them."
    return 1
  fi

  remaining=$(( deadline - $(date +%s) ))
  if [ "$remaining" -lt 1 ]; then
    emit_deny "merge-gate: ran out of the time budget before the base-freshness (compare) check for PR #$pr. The gate fails CLOSED on this uncertainty — re-run the merge (merge one PR at a time so each has budget for both checks)."
    return 1
  fi

  # Same bounded watchdog as the view call; compare gets the remaining budget.
  bounded_run "$remaining" gh api "repos/{owner}/{repo}/compare/${base}...${head}" --jq .behind_by
  behind="$BR_OUT"
  if [ "$BR_RC" != "0" ] || ! printf '%s' "$behind" | grep -qE '^[0-9]+$'; then
    emit_deny "merge-gate: could not determine PR #$pr's freshness against base '$base' (the compare API errored, timed out, or returned a non-numeric result). The gate fails CLOSED — re-run the merge once gh recovers."
    return 1
  fi
  if [ "$behind" -gt 0 ]; then
    emit_deny "merge-gate: PR #$pr is BEHIND base '$base' by $behind commit(s) — its green checks ran against an old base, so the combined state that would land is unverified (branch protection does not report this on free-plan repos; the compare API is the ground truth). Rebase (git fetch origin && git rebase origin/$base && git push --force-with-lease), wait for CI to go green on the rebased head, then re-run the merge."
    return 1
  fi

  # --- audit gate (roadmap-scoped denial; logic lives in audit-gate.sh) ---------
  # Deterministic and local: uses the SAME view payload (files ride the query),
  # so this adds no gh calls. It is NOT free, though — audit-gate's per-done-item
  # `git log -S` pickaxe scales with roadmap size × history, so it is routed
  # through the SAME bounded watchdog as the view/compare calls above, charged
  # against this PR's remaining per-PR deadline: a slow/hung audit-gate must
  # never be able to run past the harness hook timeout and get killed (the
  # harness treats a killed hook as non-blocking, i.e. fail OPEN).
  local fcount
  fcount="$(printf '%s' "$json" | jq -r '(.files // []) | length' 2>/dev/null)"
  if ! printf '%s' "$fcount" | grep -qE '^[0-9]+$'; then
    emit_deny "merge-gate: could not read PR #$pr's changed-file list for the audit gate. Denying (recoverable) — re-run the merge."
    return 1
  fi
  if [ "$fcount" -ge 100 ]; then
    emit_deny "merge-gate: PR #$pr reports $fcount changed files — gh may truncate the list at 100, so the audit gate cannot classify this PR. Failing CLOSED. Split the PR (or land the audit record first)."
    return 1
  fi
  if [ "$skipped_e2e" = 1 ] && [ "$fcount" -eq 0 ]; then
    emit_deny "merge-gate: PR #$pr's e2e check was SKIPPED but the PR reports no changed files, so the roadmap-only lane cannot be confirmed. Failing CLOSED — re-run once gh reports the file list, or re-run CI so e2e executes."
    return 1
  fi
  if [ "$fcount" -gt 0 ]; then
    # NUL-delimited extraction: a newline-delimited read would let a crafted
    # filename containing a literal newline (e.g. "notes\nroadmap/audits/F1.md")
    # split into two array entries and fabricate a discharge path. Paths cannot
    # contain NUL, so NUL-delimiting is unambiguous.
    local -a fpaths=()
    while IFS= read -r -d '' fp; do [ -n "$fp" ] && fpaths+=("$fp"); done \
      < <(printf '%s' "$json" | jq -j '(.files // [])[] | .path + "\u0000"' 2>/dev/null)
    if [ "${#fpaths[@]}" -eq 0 ]; then
      emit_deny "merge-gate: could not extract PR #$pr's changed-file paths for the audit gate. Denying (recoverable) — re-run the merge."
      return 1
    fi

    # Self-modifying CI. A `pull_request` workflow runs from the PR's MERGE
    # commit, so a PR that edits .github/workflows/ executed its OWN copy of
    # every check — its green rollup was produced by the thing it changed, and
    # the review workflow explicitly withholds its verdict on such PRs. The
    # vendored gate scripts under .github/scripts/ are the same surface (they
    # run with CI's token). GitHub's control for this (CODEOWNERS + required
    # code-owner review) is branch protection, which a private Free repo cannot
    # have, so this hook is the only enforcement point: such PRs are never
    # mergeable from a session. A human merges them outside the harness — that
    # bypass is the intended exit, not a hole. No env override, by design.
    # "Outside the harness" includes a line the human types at the session prompt
    # starting with `!`: Claude Code runs it in their shell and fires neither
    # PreToolUse nor PostToolUse for it (not documented; probed on 2.1.322 with
    # logging hooks, a model Bash call as the control). The deny names that line
    # because it is the one exit that does not make the human leave the session.
    # The paths are collected here (pure string matching on data already in
    # hand); the deny itself is emitted after the lane check and the audit gate.
    # Root-anchored prefix, exactly as gh reports paths (no leading ./);
    # `*` in a case pattern also matches `/`, so nested paths match; any file
    # type and deletions count; docs/.github/workflows/x does NOT match.
    local protected="" fp
    for fp in "${fpaths[@]}"; do
      case "$fp" in
        .github/workflows/*|.github/scripts/*) protected="${protected:+$protected, }$fp" ;;
      esac
    done

    # Roadmap-only lane: a SKIPPED e2e is accepted only if the gate's OWN
    # classification of the PR's files says nothing under test changed. Same
    # script the CI template runs (vendored as .github/scripts/ci-lane.sh), so
    # the two cannot disagree about what the lane is; the plugin's copy is used
    # here because the hook runs from the plugin, not the repo.
    if [ "$skipped_e2e" = 1 ]; then
      local lane
      lane="$(bash "$(dirname "${BASH_SOURCE[0]}")/ci-lane.sh" --files "${fpaths[@]}" 2>/dev/null)"
      if [ "$lane" != "roadmap-only" ]; then
        emit_deny "merge-gate: PR #$pr's e2e check was SKIPPED but the PR is not roadmap-only (it touches code, config or .github/), so the skip is not a pass. Re-run CI so e2e executes (or split the backlog files into their own PR), then re-run the merge."
        return 1
      fi
    fi

    remaining=$(( deadline - $(date +%s) ))
    [ "$remaining" -lt 1 ] && remaining=1
    bounded_run "$remaining" bash "$(dirname "${BASH_SOURCE[0]}")/audit-gate.sh" --files "${fpaths[@]}"
    if [ "$BR_RC" != "0" ]; then
      # An empty BR_OUT with a non-zero rc is the watchdog, not a FAIL line: say
      # how much of the budget the audit step was given, because "timed out" with
      # the number hidden sent a session hunting for audit debt that did not exist.
      emit_deny "merge-gate: audit gate refused PR #$pr: ${BR_OUT:-audit-gate timed out or errored after the gh calls left it ${remaining}s of the ${budget}s per-PR budget (rc=$BR_RC) — fails CLOSED; re-run the merge, and if the Mac is loaded by CI wait for it or raise MERGE_GATE_GH_TIMEOUT} (see plugin/hooks/audit-gate.sh; run 'audit-gate.sh --check' for the full debt state)"
      return 1
    fi

    # The self-modifying-CI deny is LAST on purpose. Its message hands the human
    # the one line that merges this PR past every hook, so reaching it has to
    # mean every other check passed: a red, stale, e2e-skipped or audit-refused
    # PR gets that deny instead and is never offered the line. (It used to fire
    # before the lane check and the audit gate, which was harmless while the
    # message only said "a human merges it".)
    if [ -n "$protected" ]; then
      emit_deny "merge-gate: PR #$pr edits the CI controls themselves ($protected). A PR that changes .github/workflows/ or the vendored gate scripts in .github/scripts/ runs its OWN copy of every pull_request workflow, so its green checks were produced by the thing it changed (the review job skips its verdict on exactly these PRs). This PR is never mergeable from a session: a HUMAN reviews the CI diff and merges it (GitHub web UI, their own terminal, or by typing '! gh pr merge $pr --squash --match-head-commit $head' at this session's prompt: a line the human starts with ! runs in their shell and never reaches this hook). Every other check this gate makes has passed for that head (green, fresh against the base, lane, audit gate), so the human merge is the only thing left. Do not retry, do not use --admin, do not move the edit into another PR — that PR is denied the same way. In a /sweap:handoff or /sweap:unblock walk the human is at the prompt: say what the CI diff changes and give them that exact ! line; no hook fires on a ! line, so once it lands run 'sweap-merge watch $pr' again, which sees the merge and runs the post-merge cleanup and audit check. Anywhere else, record it as a question: set the item to 'status: blocked' with 'blocked: PR #$pr changes CI controls ($protected) and needs a human merge — merge it as-is, or say what to change?', notify, and continue with other work."
      return 1
    fi
  fi

  return 0
}

# Verify EVERY batched PR; deny on the first that is not green. A GLOBAL wall-clock
# budget bounds the whole batch well under the harness hook timeout (60 s in
# hooks.json, and the same 60 s where sweap-merge runs this gate itself) so a
# slow-gh batch can never run long enough to be killed and fail open — if the
# budget runs out mid-batch we deny (recoverable): merge one PR per call. Each
# PR gets min(per-PR cap, remaining budget).
#
# Why 50/40 and not the 18/10 they were until 0.31.1. A single PR's verification
# is two gh calls (the rollup view, the compare) and then the local audit gate,
# each charged against the SAME per-PR deadline in that order. Measured on
# a consumer, 2026-09-23: 1.9 s end to end on an idle Mac — and two denials in a row
# on PR #388 with the Mac at load 13 (the two self-hosted CI runners plus an e2e
# run), when the gh calls took ~9 s of the 10 and the audit gate was handed the
# 1-second remainder and killed. The audit step is deterministic and offline
# but NOT small for a PR that touches item files: 7.4 s idle on a consumer repo
# (2026-09-23, 264 done items, five audit records), the same as a full
# --check, because merge mode validates every record on the primary checkout
# — on that repo 91 roadmap-lint runs over the follow-ups the records declare
# plus a path-limited pickaxe and a merge-base per done item they cover (~51
# each). It grows with every audited milestone's follow-ups, not with history
# depth (one pickaxe is ~30 ms). A code-only PR exits in 4 ms. So the cap must
# hold ~3x the idle figure plus two loaded gh calls; the only thing a small
# cap buys is a false deny on a loaded machine, which is the normal state of
# a box that also hosts its own CI. The hook's fast path (any command that is
# not a merge or a push) never reaches this, so the larger timeout costs an
# ordinary Bash call nothing. 0.32.0 trimmed the step where semantics allow
# (one rev-list per record instead of a merge-base per done item; each
# follow-up judged once) after a validity cache AND a batched pickaxe were both
# refuted as fail-open — docs/research/2026-09-23-audit-gate-merge-mode-cost.md;
# the remaining lever is a maintainer decision recorded there.
GATE_TOTAL_BUDGET="${MERGE_GATE_TOTAL_BUDGET:-50}"
GATE_PER_PR_CAP="${MERGE_GATE_GH_TIMEOUT:-40}"
gate_deadline=$(( $(date +%s) + GATE_TOTAL_BUDGET ))
# shellcheck disable=SC2086  # MC_PRS is a space-separated list of bare integers
for pr in $MC_PRS; do
  remaining=$(( gate_deadline - $(date +%s) ))
  if [ "$remaining" -lt 1 ]; then
    emit_deny "merge-gate: ran out of the time budget while verifying a batch of merges (gh is slow) before checking PR #$pr. Failing CLOSED. Merge PRs one at a time so each is verified within budget."
    exit 0
  fi
  budget="$GATE_PER_PR_CAP"
  [ "$remaining" -lt "$budget" ] && budget="$remaining"
  verify_pr "$pr" "$budget" || exit 0
done

# Every PR green → stay silent (no decision). The command is on the gh allowlist
# and proceeds under the normal permission flow. The hook never auto-approves.
# CLEAN_ALLOW tells the EXIT trap this was a deliberate green pass, not a crash.
CLEAN_ALLOW=1
exit 0
