#!/usr/bin/env bash
# --- belt A: re-exec under a clean interpreter, BEFORE anything else runs ---------
# bash sources $BASH_ENV into a non-interactive shell before the first line of
# the script, so a scrub inside the script is too late: a BASH_ENV file that
# redefines `command` poisons tool resolution (verified: a one-prefix red
# merge). The only fix is to not run the body in this process: re-exec once
# under `env -i` (the caller's whole environment gone) and `bash -p` (which
# does not process BASH_ENV/ENV, does not import functions, and ignores
# SHELLOPTS/BASHOPTS/CDPATH/GLOBIGNORE from the environment). Only a fixed
# allowlist crosses over; the SWEAP_MERGE_* seams (and the hook knobs they
# name) only when the sentinel sits next to this file — computed with
# parameter expansion and `[ -f ]` only, no external command. Absolute
# /usr/bin/env and /bin/bash: the caller's PATH chooses nothing here.
# Residual (the spec's threat model): this FIRST process has already sourced
# BASH_ENV, so a file that shadows `exec`, `env`-via-exec, `[`, `case` or
# `set` defeats the belt — outside the honest-slip model (the gate's belt B
# refuses the launch line itself). Sourcing (SWEAP_MERGE_LIB=1) never re-execs.
if [ "${SM_REEXEC:-}" != "1" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${BASH_SOURCE[0]}" in */*) sm_reexec_dir="${BASH_SOURCE[0]%/*}" ;; *) sm_reexec_dir="." ;; esac
  set -- /bin/bash -p "${BASH_SOURCE[0]}" "$@"
  if [ -f "$sm_reexec_dir/.sweap-merge-test-seams" ]; then
    for sm_reexec_k in SWEAP_MERGE_NOW SWEAP_MERGE_SLEEP SWEAP_MERGE_MAX_ITER SWEAP_MERGE_MAX_TICKS \
        SWEAP_MERGE_GH_TIMEOUT SWEAP_MERGE_STALE SWEAP_MERGE_SESSION SWEAP_MERGE_GH \
        SWEAP_MERGE_HOOK_ENV_PASS ${SWEAP_MERGE_HOOK_ENV_PASS:-}; do
      case "$sm_reexec_k" in ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
      case "$sm_reexec_k" in PATH|BASH_ENV|ENV|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|SM_REEXEC|GIT_*) continue ;; esac
      eval "sm_reexec_v=\"\${$sm_reexec_k:-}\""
      [ -n "$sm_reexec_v" ] && set -- "$sm_reexec_k=$sm_reexec_v" "$@"
    done
  fi
  for sm_reexec_k in HOME USER LANG TMPDIR GH_TOKEN GITHUB_TOKEN CLAUDE_SESSION_ID; do
    eval "sm_reexec_v=\"\${$sm_reexec_k:-}\""
    [ -n "$sm_reexec_v" ] && set -- "$sm_reexec_k=$sm_reexec_v" "$@"
  done
  exec /usr/bin/env -i SM_REEXEC=1 PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  printf 'failed could not re-exec under a clean interpreter (/usr/bin/env or /bin/bash missing)\n'
  exit 1
fi
unset sm_reexec_dir sm_reexec_k sm_reexec_v
#
# sweap-merge.sh — the merge DRIVER (design: docs/superpowers/specs/
# 2026-08-25-sweap-merge-driver-design.md, v2).
#
# The gate (pre-merge-gate.sh) says "no" at the last instant; this script owns
# the waiting: it computes which workflows the base branch expects on a PR,
# verifies every `pull_request` run on the head SHA at the workflow-run level,
# waits under bounded ticks with GitHub-anchored deadlines, RUNS THE GATE, and
# then issues one pinned merge and the post-merge hooks.
#
#   sweap-merge.sh tick   <pr> [--budget <sec>]   one bounded tick (default 100 s)
#   sweap-merge.sh watch  <pr> [--budget <sec>]   loop ticks until a terminal state
#   sweap-merge.sh status [<pr>]                  print the state files, flag dead pollers
#   sweap-merge.sh rerun  <pr> --reason "<text>"  a HAND rerun of a failed PR's red runs:
#                                                 recorded in the state file (one per
#                                                 head SHA and workflow, ever), never automatic; a
#                                                 rerun that turns green files a flake note
#
# Stdout contract (rerun): exactly one line `<word> <reason>`, where <word> is
# `pending` (accepted and recorded; exit 0), `refused` (a precondition failed
# and NOTHING was written; exit 1), `failed` (a rerun WAS issued but not every
# one, or the record could not be written — the state file says which; exit
# 1), or `held-by:<owner>` (exit 1). Missing/blank --reason is a usage error
# (exit 2).
#
# Stdout contract (tick/watch): exactly one terminal line `<word> <reason>`,
# where <word> is a state (missing pending green merging merged failed
# superseded behind undecidable timed_out attended held-by:<owner>). `watch`
# prints one such line per transition before the terminal line. Exit 0 ONLY on
# `merged`; 1 otherwise; 2 on a usage error.
#
# Durable object = the state file <primary>/.claude/sweap-merge/<pr>.json under
# a fenced lease (<pr>.lock). Never a process. bash 3.2-safe; jq required (fail
# closed without it). Epoch seconds everywhere.
#
# Test seams (env, honoured ONLY when a sentinel file named
# `.sweap-merge-test-seams` sits next to the driver's REAL path — the test
# harness copies the driver into fixture dirs and creates it there; the plugin
# dir never has it, and a model-issued Bash call cannot create it inline, so no
# env prefix can reshape the driver's clocks, budgets or binaries):
# SWEAP_MERGE_NOW (fixed "GitHub clock"), SWEAP_MERGE_SLEEP (poll sleep,
# seconds), SWEAP_MERGE_MAX_ITER (iterations per tick), SWEAP_MERGE_MAX_TICKS
# (watch cap), SWEAP_MERGE_GH_TIMEOUT (per-call cap, default 20),
# SWEAP_MERGE_STALE (lease staleness, default 130 = 2 × (45 s sleep cap + 20 s
# call)), SWEAP_MERGE_SESSION (lease owner session id), SWEAP_MERGE_GH (stub
# gh, absolute), SWEAP_MERGE_HOOK_ENV_PASS (extra hook env). SWEAP_MERGE_LIB=1
# (source without running) is always honoured.
set -uo pipefail

# --- env scrub (D3: the gate and the hooks run with an env the model did not shape)
# GH_REPO: the driver merges only the current repo's PRs (argv contract, §3).
# The rest re-anchor or reshape the gate / audit-gate / post-merge hooks; the
# harness never lets the model set them for a hook, so neither does the driver.
unset GH_REPO SWEAP_MAIN_REF SWEAP_PUSH_GATE SWEAP_BASE_BRANCH \
      MERGE_GATE_GH_TIMEOUT MERGE_GATE_TOTAL_BUDGET SWEAP_AUDITCHECK_TIMEOUT \
      CDPATH BASH_ENV GH_HOST GH_CONFIG_DIR \
      GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
      GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_NAMESPACE GIT_PREFIX
# CDPATH: `cd hooks` would resolve elsewhere (and echo the dir into $(...)).
# BASH_ENV: sourced into every non-interactive bash, i.e. the gate. GH_HOST /
# GH_CONFIG_DIR: re-anchor gh at another host or another hosts.yml. GIT_*:
# `GIT_DIR=/forged/.git` moves <primary> — the state file, the lease and the
# gate's cwd — out of the real repo (verified), and sm_primary_check cannot see
# a consistently forged primary. Belt A already cleared all of these (env -i);
# this list is the in-script belt for a body that is run some other way.

# --- pinned PATH (nothing the driver runs may come from the caller's PATH)
# The WHOLE driver runs under this PATH from here on: a caller-PATH `jq` could
# rewrite the run evaluation and the gate's deny; a caller-PATH `env` could
# ignore `-i`; a caller-PATH `git` could forge <primary>; a caller-PATH
# `dirname` could forge the hooks dir. gh, jq, git and env are additionally
# resolved ONCE to absolute paths (sm_resolve_tools) and used as such; every
# other tool (sed, tr, grep, mktemp, ...) resolves under the pinned PATH by
# construction. The gate and the post-merge hooks run under `env -i` with this
# PATH (the resolved gh's directory first) plus an explicit passthrough
# allowlist. The mise shim dir is last: it lives under HOME, which the caller
# can also set.
SM_PINNED_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ -d "${HOME:-/nonexistent}/.local/share/mise/shims" ] && SM_PINNED_PATH="$SM_PINNED_PATH:$HOME/.local/share/mise/shims"
PATH="$SM_PINNED_PATH"; export PATH
SM_GH=""                  # absolute paths (sm_resolve_tools)
SM_GH_DIR=""
SM_JQ=""; SM_GIT=""; SM_ENV=""
SM_HOOK_ENV_PASS="HOME USER LANG TMPDIR GH_TOKEN GITHUB_TOKEN CLAUDE_SESSION_ID"

# The gate and the post-merge hooks are resolved from the driver's OWN directory
# (symlinks followed), never from CLAUDE_PLUGIN_ROOT: that variable is settable
# inline on the Bash call that launches the driver, and the harness gate does not
# see a `gh pr merge` in such a call. Residual (recorded in the spec's threat
# model): a copied driver next to a stub gate.
sm_realpath() {   # follow symlinks (bash 3.2 / macOS: no readlink -f)
  local p="$1" d l n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    l="$(readlink "$p")" || break
    case "$l" in /*) p="$l" ;; *) d="$(dirname "$p")"; p="$d/$l" ;; esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}
SM_HOOKS_DIR="$(CDPATH='' cd -P -- "$(dirname "$(sm_realpath "${BASH_SOURCE[0]}")")" && pwd -P)"

# --- test seams: sentinel-gated (see the header). Without the sentinel next to
# the driver's real path every SWEAP_MERGE_* seam is unset before it is read.
SM_SEAMS=0
[ -f "$SM_HOOKS_DIR/.sweap-merge-test-seams" ] && SM_SEAMS=1
if [ "$SM_SEAMS" != "1" ]; then
  unset SWEAP_MERGE_NOW SWEAP_MERGE_SLEEP SWEAP_MERGE_MAX_ITER SWEAP_MERGE_MAX_TICKS \
        SWEAP_MERGE_GH_TIMEOUT SWEAP_MERGE_STALE SWEAP_MERGE_SESSION \
        SWEAP_MERGE_GH SWEAP_MERGE_HOOK_ENV_PASS
fi

SM_GH_TIMEOUT="${SWEAP_MERGE_GH_TIMEOUT:-20}"
SM_STALE="${SWEAP_MERGE_STALE:-130}"
SM_MAX_ITER="${SWEAP_MERGE_MAX_ITER:-0}"
SM_APPEAR_WINDOW=300      # PR head push + 5 min
SM_COMPLETE_MIN=2400      # max(40 min, 2 × longest timeout-minutes)
SM_DEFAULT_BUDGET=100

SM_SESSION="${SWEAP_MERGE_SESSION:-${CLAUDE_SESSION_ID:-local}}"
SM_OWNER="${SM_SESSION}:$$"
SM_HOST="$(hostname 2>/dev/null || echo unknown)"

# --- globals ---------------------------------------------------------------------
SM_PRIMARY=""; SM_DIR=""; SM_PR=""; SM_FILE=""; SM_LOCK=""
SM_EPOCH=0; SM_HELD_BY=""
SM_STATE_JSON='{}'; SM_STATE="missing"; SM_REASON=""
SM_DEADLINE=0
SM_MERGE_OUT=""
SM_GH_ERR=""
BR_OUT=""; BR_ERR=""; BR_RC=0
SM_STDIN_FILE=""
SM_LAST_PRINTED=""
SM_WATCH=0
SM_INVOKE_CWD=""          # where the session launched us (the post-merge hooks' cwd)
SM_WRITE_ERR=""           # why the last fenced write failed
SM_RUNS_FILE=""           # runs on the head (JSON array file; never through argv)
SM_ALERTS=""              # post-merge hook banners folded into the terminal reason

sm_mtime() {   # epoch mtime of $1 (empty if unknown)
  stat -f %m "$1" 2>/dev/null && return 0
  stat -c %Y "$1" 2>/dev/null && return 0
  return 1
}

sm_now() { if [ -n "${SWEAP_MERGE_NOW:-}" ]; then printf '%s' "$SWEAP_MERGE_NOW"; else date +%s; fi; }
sm_real_now() { date +%s; }

sm_iso_epoch() {   # "2026-08-25T10:00:00Z" -> epoch seconds (empty on failure)
  local s="$1"
  [ -n "$s" ] || return 1
  s="${s%%.*}"; s="${s%Z}Z"
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null && return 0
  date -u -d "$s" +%s 2>/dev/null && return 0
  return 1
}

sm_oneline() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ //; s/ $//'; }

sm_usage() {
  printf 'usage: sweap-merge.sh tick|watch <pr> [--budget <sec>] | status [<pr>] | rerun <pr> --reason "<text>"\n' >&2
  printf '  rerun prints one line: pending (recorded, exit 0) | refused (nothing written, exit 1) | failed (issued but not all/not recorded, exit 1); usage errors exit 2\n' >&2
  exit 2
}

# sm_bounded <timeout> <cmd...>: run <cmd> under its own watchdog (copied from
# pre-merge-gate.sh, plus stderr capture). Sets BR_OUT/BR_ERR/BR_RC. Returns 1
# only on an infra failure (no temp file). The watcher never inherits stdout —
# an orphaned sleep holding the pipe would charge every call its full timeout.
sm_bounded() {
  local timeout="$1"; shift
  local tmp err brpid watcher infile
  [ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
  tmp="$(mktemp 2>/dev/null)" || { BR_OUT=""; BR_ERR="mktemp failed"; BR_RC=1; return 1; }
  err="$(mktemp 2>/dev/null)" || { rm -f "$tmp"; BR_OUT=""; BR_ERR="mktemp failed"; BR_RC=1; return 1; }
  infile="${SM_STDIN_FILE:-/dev/null}"
  "$@" >"$tmp" 2>"$err" <"$infile" &
  brpid=$!
  ( sleep "$timeout"; kill -TERM "$brpid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  watcher=$!
  wait "$brpid" 2>/dev/null
  BR_RC=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  BR_OUT="$(cat "$tmp" 2>/dev/null)"
  BR_ERR="$(cat "$err" 2>/dev/null)"
  rm -f "$tmp" "$err"
  return 0
}

# sm_gh <args...>: one gh call under ≤20 s, charged against the tick budget.
# Returns 0 iff gh exited 0 within its cap; SM_GH_ERR carries the reason.
sm_gh() {
  local t="$SM_GH_TIMEOUT" remaining
  if [ "$SM_DEADLINE" -gt 0 ]; then
    remaining=$(( SM_DEADLINE - $(sm_real_now) ))
    [ "$remaining" -lt "$t" ] && t="$remaining"
  fi
  if [ "$t" -lt 1 ]; then SM_GH_ERR="budget exhausted before gh $1 $2"; BR_OUT=""; BR_RC=124; return 1; fi
  # heartbeat before every call: a slow API under a long --budget must not let a
  # live poller be declared stale (and a lost lease stops the call — never a
  # merge from a stale holder)
  if [ "$SM_EPOCH" -gt 0 ] && ! sm_lease_renew; then SM_GH_ERR="$SM_REASON"; BR_OUT=""; BR_RC=1; return 1; fi
  if [ -z "$SM_GH" ]; then SM_GH_ERR="gh not resolved (fail closed)"; BR_OUT=""; BR_RC=1; return 1; fi
  sm_bounded "$t" "$SM_GH" "$@" || { SM_GH_ERR="gh $1 $2: $BR_ERR"; return 1; }
  if [ "$BR_RC" != "0" ]; then
    SM_GH_ERR="gh $1 $2 failed (rc=$BR_RC): $(sm_oneline "${BR_ERR:-no output}")"
    return 1
  fi
  SM_GH_ERR=""
  return 0
}

# sm_resolve_tools: gh, jq, git and env as absolute paths found under
# SM_PINNED_PATH (never the caller's PATH), once, at startup; fail closed with
# the missing tool's name in SM_TOOL_ERR. SWEAP_MERGE_GH=<abs path> is a test
# seam (stub gh), sentinel-gated — it was unset above otherwise.
SM_TOOL_ERR=""
sm_resolve_tools() {
  local g="" t v
  SM_TOOL_ERR=""
  for t in jq git env; do
    v="$(PATH="$SM_PINNED_PATH" command -v "$t" 2>/dev/null)" || v=""
    case "$v" in /*) [ -x "$v" ] || v="" ;; *) v="" ;; esac
    if [ -z "$v" ]; then SM_TOOL_ERR="$t is required: not found under pinned PATH ($SM_PINNED_PATH; fail closed)"; return 1; fi
    case "$t" in jq) SM_JQ="$v" ;; git) SM_GIT="$v" ;; env) SM_ENV="$v" ;; esac
  done
  if [ -n "${SWEAP_MERGE_GH:-}" ]; then
    case "$SWEAP_MERGE_GH" in /*) g="$SWEAP_MERGE_GH" ;; *) g="" ;; esac
  else
    g="$(PATH="$SM_PINNED_PATH" command -v gh 2>/dev/null)" || g=""
  fi
  if [ -z "$g" ] || [ ! -x "$g" ]; then SM_TOOL_ERR="gh not found under pinned PATH ($SM_PINNED_PATH; fail closed)"; return 1; fi
  SM_GH="$g"
  SM_GH_DIR="$(dirname "$g")"
  return 0
}

# sm_run_hook <timeout> <cwd> <script>: run a hook under env -i — pinned PATH
# (the resolved gh's dir first, so the gate's own `gh` is the same binary),
# then only the allowlisted names that are set. Under the test seams,
# SWEAP_MERGE_HOOK_ENV_PASS names extra variables to pass (fixture knobs).
sm_run_hook() {
  local timeout="$1" cwd="$2" script="$3" k
  set -- "PATH=$SM_GH_DIR:$SM_PINNED_PATH"
  for k in $SM_HOOK_ENV_PASS ${SWEAP_MERGE_HOOK_ENV_PASS:-}; do
    printf '%s' "$k" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    case "$k" in PATH|CDPATH|BASH_ENV|GH_HOST|GH_CONFIG_DIR|GH_REPO) continue ;; esac
    if [ -n "$(eval "printf '%s' \"\${$k:-}\"")" ]; then set -- "$@" "$k=$(eval "printf '%s' \"\$$k\"")"; fi
  done
  sm_bounded "$timeout" "$SM_ENV" -i "$@" /bin/sh -c 'cd "$1" && exec bash "$2"' sh "$cwd" "$script"
}

# --- primary + state dir -----------------------------------------------------------
sm_resolve_primary() {
  local gitdir top
  gitdir="$("$SM_GIT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  SM_PRIMARY="$(CDPATH='' cd -P -- "$(dirname "$gitdir")" 2>/dev/null && pwd -P)" || return 1
  [ -n "$SM_PRIMARY" ] || return 1
  # <primary> must BE a checkout: its own `.git` (dir or worktree file) exists
  # and git, entered there, names it as the toplevel. A common-dir that points
  # somewhere else (a bare repo, a forged git dir whose parent is not a repo)
  # is refused rather than turned into a state dir.
  [ -e "$SM_PRIMARY/.git" ] || return 1
  top="$("$SM_GIT" -C "$SM_PRIMARY" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$top" = "$SM_PRIMARY" ] || return 1
  SM_DIR="$SM_PRIMARY/.claude/sweap-merge"
  mkdir -p "$SM_DIR" 2>/dev/null || return 1
  return 0
}

sm_bind_pr() {
  SM_PR="$1"
  SM_FILE="$SM_DIR/$SM_PR.json"
  SM_LOCK="$SM_DIR/$SM_PR.lock"
}

# --- lease (§4) ----------------------------------------------------------------------
sm_lock_read() {   # [dir] -> LK_OWNER LK_EPOCH LK_PID LK_HOST LK_HB LK_PRIMARY (default dir: SM_LOCK)
  local line d="${1:-$SM_LOCK}"
  LK_OWNER=""; LK_EPOCH=0; LK_PID=""; LK_HOST=""; LK_HB=0; LK_PRIMARY=""
  [ -f "$d/info" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      owner=*) LK_OWNER="${line#owner=}" ;;
      epoch=*) LK_EPOCH="${line#epoch=}" ;;
      pid=*) LK_PID="${line#pid=}" ;;
      host=*) LK_HOST="${line#host=}" ;;
      heartbeat=*) LK_HB="${line#heartbeat=}" ;;
      primary=*) LK_PRIMARY="${line#primary=}" ;;
    esac
  done <"$d/info"
  printf '%s' "$LK_EPOCH" | grep -qE '^[0-9]+$' || LK_EPOCH=0
  printf '%s' "$LK_HB" | grep -qE '^[0-9]+$' || LK_HB=0
  return 0
}

sm_lock_write() {   # [dir]: rewrite info atomically for the current owner/epoch
  local d="${1:-$SM_LOCK}" tmp
  tmp="$d/info.$$"
  printf 'owner=%s\nepoch=%s\npid=%s\nhost=%s\nheartbeat=%s\nprimary=%s\n' \
    "$SM_OWNER" "$SM_EPOCH" "$$" "$SM_HOST" "$(sm_now)" "$SM_PRIMARY" >"$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$d/info" 2>/dev/null || return 1
  return 0
}

# sm_lock_floor_epoch: the highest epoch any <pr>.lock.stale.* dir carries — a
# takeover in flight (or one that crashed) took the lock's epoch with it; a
# fresh claim must never restart below it.
sm_lock_floor_epoch() {
  local d e max=0
  for d in "$SM_LOCK".stale.*; do
    [ -d "$d" ] || continue
    e="$(sed -n 's/^epoch=\([0-9][0-9]*\)$/\1/p' "$d/info" 2>/dev/null | head -1)"
    [ -n "$e" ] && [ "$e" -gt "$max" ] && max="$e"
  done
  printf '%s' "$max"
}

# sm_lease_lost_to: name whoever holds the lock now (for a held-by verdict),
# after a losing race — the WINNER, not the stale owner we read before it.
sm_lease_lost_to() {
  local i=0
  SM_HELD_BY="${1:-?}"
  while [ "$i" -lt 5 ]; do   # the winner's rename-back is a few ms away at most
    sleep 0.1 2>/dev/null || sleep 1
    if sm_lock_read; then SM_HELD_BY="$LK_OWNER"; break; fi
    i=$((i + 1))
  done
  return 1
}

# sm_takeover_recover: a takeover mutex older than SM_STALE belongs to a
# claimant that died mid-takeover. Put its renamed lock back (it is just a stale
# lock again, epoch intact) and drop the mutex.
sm_takeover_recover() {
  local mx="$SM_LOCK.takeover" mt d
  [ -d "$mx" ] || return 0
  mt="$(sm_mtime "$mx")"
  [ -n "$mt" ] && [ $(( $(sm_real_now) - mt )) -gt "$SM_STALE" ] || return 0
  for d in "$SM_LOCK".stale.*; do
    [ -d "$d" ] || continue
    mv "$d" "$SM_LOCK" 2>/dev/null || rm -rf "$d" 2>/dev/null
  done
  rmdir "$mx" 2>/dev/null
  return 0
}

sm_pid_alive() {   # $1 pid on this host
  printf '%s' "$1" | grep -qE '^[0-9]+$' || return 1
  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1
}

# sm_lease_claim. Fresh claim = mkdir (atomic). Stale takeover = under a
# takeover mutex (<pr>.lock.takeover, mkdir-atomic): re-verify the lock is
# exactly the owner/epoch judged stale, rename it aside, verify again, write the
# new info INTO the renamed dir, rename it back onto the lock path. Every
# claimant that loses a step reports held-by whoever holds the lock NOW. A
# fresh claimant that lands in the takeover's rename gap backs out (the mutex
# says the path is spoken for), and a fresh epoch never restarts below an
# epoch a renamed dir still carries.
sm_lease_claim() {
  local prev_epoch alive stale now mt mx judged_owner judged_epoch floor n nested
  prev_epoch="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.lease.epoch // 0' 2>/dev/null)"
  printf '%s' "$prev_epoch" | grep -qE '^[0-9]+$' || prev_epoch=0
  mx="$SM_LOCK.takeover"
  sm_takeover_recover
  if mkdir "$SM_LOCK" 2>/dev/null; then
    if [ -d "$mx" ]; then     # a takeover is between its rename-away and rename-back
      rmdir "$SM_LOCK" 2>/dev/null
      sm_lease_lost_to "?"; return 1
    fi
    SM_EPOCH="$prev_epoch"
    floor="$(sm_lock_floor_epoch)"
    [ "$floor" -gt "$SM_EPOCH" ] && SM_EPOCH="$floor"
    SM_EPOCH=$((SM_EPOCH + 1))
    sm_lock_write || { SM_HELD_BY="?"; return 1; }
    return 0
  fi
  if ! sm_lock_read; then
    # A lock dir without `info` is a claimant between its mkdir and its first
    # write (a few ms) — or a crashed one. It is LIVE unless the dir itself is
    # older than SM_STALE; treating it as stale would let two ticks launched in
    # the same instant both claim (the second would then lose its fenced write).
    sleep 0.1 2>/dev/null || sleep 1
    if ! sm_lock_read; then
      mt="$(sm_mtime "$SM_LOCK")"
      if [ -z "$mt" ] || [ $(( $(sm_real_now) - mt )) -le "$SM_STALE" ]; then
        SM_HELD_BY="?"
        return 1
      fi
      LK_OWNER="?"; LK_EPOCH="$prev_epoch"; LK_PID=""; LK_HOST=""; LK_HB=0
    fi
  fi
  if [ "$LK_OWNER" = "$SM_OWNER" ] && [ "$LK_HOST" = "$SM_HOST" ]; then
    SM_EPOCH="$LK_EPOCH"          # re-entrant: same session, same pid
    sm_lock_write || { SM_HELD_BY="?"; return 1; }
    return 0
  fi
  alive=1
  now="$(sm_now)"
  if [ "$LK_HOST" = "$SM_HOST" ] && [ -n "$LK_PID" ]; then sm_pid_alive "$LK_PID" || alive=0; fi
  if [ $(( now - LK_HB )) -gt "$SM_STALE" ]; then alive=0; fi
  if [ "$alive" = "1" ]; then
    SM_HELD_BY="$LK_OWNER"
    return 1
  fi
  # Stale takeover (see the function comment). Epoch strictly increases.
  judged_owner="$LK_OWNER"; judged_epoch="$LK_EPOCH"
  mkdir "$mx" 2>/dev/null || { sm_lease_lost_to "$judged_owner"; return 1; }
  # under the mutex: the lock must still be the one we judged (another
  # claimant may have replaced it between our read and our mkdir)
  if ! sm_lock_read || [ "$LK_OWNER" != "$judged_owner" ] || [ "$LK_EPOCH" != "$judged_epoch" ]; then
    rmdir "$mx" 2>/dev/null; sm_lease_lost_to "$judged_owner"; return 1
  fi
  stale="$SM_LOCK.stale.$$"
  [ -e "$stale" ] && rm -rf "$stale" 2>/dev/null   # a pid-reuse leftover would swallow the rename
  if ! mv "$SM_LOCK" "$stale" 2>/dev/null; then
    rmdir "$mx" 2>/dev/null; sm_lease_lost_to "$judged_owner"; return 1
  fi
  if ! sm_lock_read "$stale" || [ "$LK_OWNER" != "$judged_owner" ] || [ "$LK_EPOCH" != "$judged_epoch" ]; then
    mv "$stale" "$SM_LOCK" 2>/dev/null || rm -rf "$stale" 2>/dev/null
    rmdir "$mx" 2>/dev/null; sm_lease_lost_to "$judged_owner"; return 1
  fi
  SM_EPOCH="$judged_epoch"
  [ "$prev_epoch" -gt "$SM_EPOCH" ] && SM_EPOCH="$prev_epoch"
  SM_EPOCH=$((SM_EPOCH + 1))
  if ! sm_lock_write "$stale"; then
    mv "$stale" "$SM_LOCK" 2>/dev/null || rm -rf "$stale" 2>/dev/null
    rmdir "$mx" 2>/dev/null; SM_HELD_BY="$judged_owner"; return 1
  fi
  # rename back onto the lock path. `mv` onto an EXISTING dir moves us inside
  # it (a fresh claimant's empty dir, about to back out): pull ours out, drop
  # the empty dir, retry — bounded.
  n=0
  nested="$SM_LOCK/$(basename "$stale")"
  while :; do
    mv "$stale" "$SM_LOCK" 2>/dev/null
    if sm_lock_read && [ "$LK_OWNER" = "$SM_OWNER" ] && [ "$LK_EPOCH" = "$SM_EPOCH" ]; then
      rmdir "$mx" 2>/dev/null
      return 0
    fi
    [ -d "$nested" ] && mv "$nested" "$stale" 2>/dev/null
    rmdir "$SM_LOCK" 2>/dev/null
    n=$((n + 1))
    if [ "$n" -ge 40 ] || [ ! -d "$stale" ]; then
      rm -rf "$stale" 2>/dev/null
      rmdir "$mx" 2>/dev/null; sm_lease_lost_to "?"; return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
}

# sm_lease_renew: fenced heartbeat. The lock must still carry OUR owner+epoch;
# a taken-over holder must never write its (older) epoch back and steal the
# lock. On mismatch: SM_STATE=failed, SM_REASON says who holds it, return 1.
sm_lease_renew() {
  if ! sm_lock_read; then
    SM_STATE="failed"; SM_REASON="lease lost (lock gone or unreadable; epoch $SM_EPOCH)"; return 1
  fi
  if [ "$LK_OWNER" != "$SM_OWNER" ] || [ "$LK_EPOCH" != "$SM_EPOCH" ]; then
    SM_STATE="failed"; SM_REASON="lease lost to $LK_OWNER (epoch $LK_EPOCH; ours $SM_EPOCH)"; return 1
  fi
  sm_lock_write
}

sm_lease_release() {
  [ -n "$SM_LOCK" ] && [ -d "$SM_LOCK" ] || return 0
  sm_lock_read || return 0
  if [ "$LK_OWNER" = "$SM_OWNER" ] && [ "$LK_EPOCH" = "$SM_EPOCH" ]; then
    rm -rf "$SM_LOCK" 2>/dev/null
  fi
  return 0
}

# sm_primary_check: the state file and the lock both record the <primary> they
# were written under. A tick that derives a DIFFERENT primary for the same PR
# (a forged git, a moved checkout, a copied state dir) must not run: it would
# split the durable object across two directories, and the gate would verify
# a checkout other than the one the merge is issued from.
sm_primary_check() {
  local p
  p="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.primary // ""' 2>/dev/null)"
  if [ -n "$p" ] && [ "$p" != "$SM_PRIMARY" ]; then
    SM_REASON="state split: PR #$SM_PR's state file was written under $p but this tick derived <primary> $SM_PRIMARY; refusing (fail closed)"
    return 1
  fi
  if [ -d "$SM_LOCK" ] && sm_lock_read && [ -n "$LK_PRIMARY" ] && [ "$LK_PRIMARY" != "$SM_PRIMARY" ]; then
    SM_REASON="state split: PR #$SM_PR's lease was taken under $LK_PRIMARY but this tick derived <primary> $SM_PRIMARY; refusing (fail closed)"
    return 1
  fi
  return 0
}

# --- state file (fenced writes) ------------------------------------------------------
sm_state_read() {
  SM_STATE_JSON='{}'; SM_STATE="missing"
  if [ -f "$SM_FILE" ]; then
    SM_STATE_JSON="$("$SM_JQ" -c . "$SM_FILE" 2>/dev/null)" || SM_STATE_JSON='{}'
    SM_STATE="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.state // "missing"' 2>/dev/null)"
    [ -n "$SM_STATE" ] || SM_STATE="missing"
  fi
  return 0
}

# sm_set <jq filter> [jq args...]: update SM_STATE_JSON in memory.
sm_set() {
  local f="$1"; shift
  local out
  out="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c "$@" "$f" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  SM_STATE_JSON="$out"
  return 0
}

# sm_state_write: the fenced write (§4). The lock must still carry OUR epoch
# (else a takeover happened and we are the stale holder), then the next version
# is claimed with `ln` (fails if a newer version exists) and moved over the file.
sm_state_write() {
  local seq tmp ver cur_seq v mt now
  SM_WRITE_ERR=""
  sm_lock_read || { SM_WRITE_ERR="fenced write lost the lease (lock gone; epoch $SM_EPOCH)"; return 1; }
  [ "$LK_OWNER" = "$SM_OWNER" ] && [ "$LK_EPOCH" = "$SM_EPOCH" ] || { SM_WRITE_ERR="fenced write lost the lease to $LK_OWNER (epoch $LK_EPOCH; ours $SM_EPOCH)"; return 1; }
  cur_seq=0
  [ -f "$SM_FILE" ] && cur_seq="$("$SM_JQ" -r '.seq // 0' "$SM_FILE" 2>/dev/null)"
  printf '%s' "$cur_seq" | grep -qE '^[0-9]+$' || cur_seq=0
  seq=$((cur_seq + 1))
  sm_set '.seq = ($s|tonumber) | .primary = $p | .lease = {owner:$o, epoch:($e|tonumber), heartbeat_at:($h|tonumber), primary:$p}' \
    --arg s "$seq" --arg o "$SM_OWNER" --arg e "$SM_EPOCH" --arg h "$(sm_now)" --arg p "$SM_PRIMARY" || { SM_WRITE_ERR="state update failed (jq)"; return 1; }
  tmp="$SM_DIR/.$SM_PR.tmp.$$"
  ver="$SM_FILE.v$seq"
  # A version file left by a writer killed between its ln and mv would block
  # every later write forever: sweep any older than SM_STALE (a live writer
  # holds one for microseconds), and name a fresh one instead of blaming the lease.
  now="$(sm_real_now)"
  for v in "$SM_FILE".v*; do
    [ -e "$v" ] || continue
    mt="$(sm_mtime "$v")"
    [ -n "$mt" ] && [ $(( now - mt )) -gt "$SM_STALE" ] && rm -f "$v" 2>/dev/null
  done
  if [ -e "$ver" ]; then
    SM_WRITE_ERR="version file $ver already exists (crashed writer?); it is swept once older than ${SM_STALE}s, or remove it by hand"
    return 1
  fi
  printf '%s\n' "$SM_STATE_JSON" >"$tmp" 2>/dev/null || { SM_WRITE_ERR="cannot write $tmp"; return 1; }
  if ! ln "$tmp" "$ver" 2>/dev/null; then
    rm -f "$tmp"
    SM_WRITE_ERR="version file $ver already exists (crashed writer?); it is swept once older than ${SM_STALE}s, or remove it by hand"
    return 1
  fi
  rm -f "$tmp"
  mv -f "$ver" "$SM_FILE" 2>/dev/null || { rm -f "$ver"; SM_WRITE_ERR="cannot move $ver over $SM_FILE"; return 1; }
  return 0
}

# sm_transition <to> <why>: append history, set state, write (fenced).
sm_transition() {
  local to="$1" why="$2" from
  from="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.state // "missing"' 2>/dev/null)"
  [ -n "$from" ] || from="missing"
  if [ "$from" != "$to" ]; then
    sm_set '.state = $to | .history = ((.history // []) + [{at:($at|tonumber), from:$from, to:$to, why:$why}])' \
      --arg to "$to" --arg from "$from" --arg why "$why" --arg at "$(sm_now)"
  fi
  SM_STATE="$to"; SM_REASON="$why"
  sm_state_write || { SM_STATE="failed"; SM_REASON="$SM_WRITE_ERR"; return 1; }
  if [ "$SM_WATCH" = "1" ] && [ "$from" != "$to" ]; then
    printf '%s %s\n' "$to" "$(sm_oneline "$why")"
    SM_LAST_PRINTED="$to"
  fi
  return 0
}

# sm_disarm: clear the clocks so the tick's "re-arm after superseded" branch
# computes fresh deadlines on its next pass. The ONE way a state file is
# re-armed: the superseded branch of sm_tick and a hand `rerun` both go through
# here, so the arming logic (appear anchored on the later of commit and arm
# time, complete on the newest run start) lives in exactly one place.
sm_disarm() {
  sm_set '.arm_at = null | .appear_deadline = null | .complete_deadline = null | .observed = {} | .verdict = null'
}

# sm_checkpoint: the ARM-TIME write. A fenced write of the state as it already
# is — no transition, no history row, no gh call. Until this existed the state
# file was first created by the tick's first sm_transition, i.e. only AFTER an
# evaluation succeeded: a tick that claimed the lease and then died inside its
# FIRST gh call (budget exhausted, a hung API, a lost lease) left the lock
# heartbeat behind but NO state file, so `status` listed nothing for a PR whose
# watch was armed and the durable object lagged the lease. One write right after
# the claim publishes .pr / .state / .primary / .lease.{owner,epoch,heartbeat_at}
# so the file exists from the instant the lease does. `.state` is carried over
# untouched (a file that does not exist yet arms as `missing`, which is what the
# next tick would read anyway), so no state is invented and no history row is
# appended — the tick's real first transition still records from=<what it was>.
# Cost: one extra .seq bump per tick.
sm_checkpoint() {
  sm_set '.pr = ($pr|tonumber) | .state = (.state // $st)' --arg pr "$SM_PR" --arg st "$SM_STATE" \
    || { SM_WRITE_ERR="arm-time checkpoint update failed (jq)"; return 1; }
  sm_state_write
}

# --- §5 workflow reader ---------------------------------------------------------------
# sm_classify_workflow <file> <base>: CW_RESULT = member|excluded|undecidable,
# CW_WHY, CW_TIMEOUT (max timeout-minutes seen). One bash line reader (E10).
sm_flow_items() {   # "[a, 'b', c]" -> one bare token per line
  printf '%s' "$1" | tr '[],' '   ' | tr -s ' \t' '\n\n' | sed -e "s/^['\"]//; s/['\"]\$//" | sed '/^$/d'
}

sm_classify_workflow() {
  local f="$1" base="$2"
  local raw line content ind ind_str t val tok
  local in_on=0 key_ind=-1 in_pr=0 sub_ind=-1 in_branches=0 found_pr=0 has_branches=0 br_match=0 decided=0
  local in_types=0 has_types=0 ty_opened=0 ty_sync=0
  CW_RESULT=excluded; CW_WHY=""; CW_TIMEOUT=0

  sm_cw_type_item() {   # $1 = one types: entry
    local t="$1"
    t="${t#\"}"; t="${t%\"}"; t="${t#\'}"; t="${t%\'}"
    case "$t" in opened) ty_opened=1 ;; synchronize) ty_sync=1 ;; esac
    return 0
  }

  sm_cw_branch_item() {   # $1 = one branches: entry
    local b="$1"
    b="${b#\"}"; b="${b%\"}"; b="${b#\'}"; b="${b%\'}"
    [ -n "$b" ] || return 0
    case "$b" in
      *'*'*|*'?'*|*'['*|*'!'*|*'+'*) CW_RESULT=undecidable; CW_WHY="glob in branches: $b"; decided=1 ;;
    esac
    [ "$b" = "$base" ] && br_match=1
    return 0
  }

  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    case "$line" in
      *timeout-minutes:*)
        t="$(printf '%s' "$line" | sed -n 's/.*timeout-minutes:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
        [ -n "$t" ] && [ "$t" -gt "$CW_TIMEOUT" ] && CW_TIMEOUT="$t" ;;
    esac
    [ "$decided" = "1" ] && continue
    # strip comments (a `#` at line start or after whitespace)
    case "$line" in
      \#*) line="" ;;
      *" #"*) line="${line%% #*}" ;;
      *"	#"*) line="${line%%	#*}" ;;
    esac
    [ -n "${line//[[:space:]]/}" ] || continue
    ind_str="${line%%[! ]*}"; ind="${#ind_str}"
    content="${line#"$ind_str"}"
    content="${content%"${content##*[![:space:]]}"}"

    if [ "$in_on" = "0" ]; then
      [ "$ind" = "0" ] || continue
      case "$content" in
        on:*|\"on\":*|\'on\':*|true:*) ;;
        *) continue ;;
      esac
      val="${content#*:}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [ -z "$val" ]; then in_on=1; continue; fi
      case "$val" in
        *"{"*) CW_RESULT=undecidable; CW_WHY="flow-style on: mapping"; decided=1; continue ;;
      esac
      # scalar or flow list
      for tok in $(sm_flow_items "$val"); do
        case "$tok" in
          pull_request_target) CW_RESULT=undecidable; CW_WHY="pull_request_target"; decided=1 ;;
          pull_request) found_pr=1 ;;
        esac
      done
      decided=1
      continue
    fi

    # inside the on: block
    if [ "$ind" = "0" ]; then in_on=0; decided=1; continue; fi
    [ "$key_ind" = "-1" ] && key_ind="$ind"
    if [ "$ind" -le "$key_ind" ]; then
      in_pr=0; in_branches=0; sub_ind=-1
      tok="$content"; tok="${tok#- }"; tok="${tok#-}"
      tok="${tok#"${tok%%[![:space:]]*}"}"
      val=""
      case "$tok" in *:*) val="${tok#*:}"; tok="${tok%%:*}" ;; esac
      val="${val#"${val%%[![:space:]]*}"}"
      tok="${tok#\"}"; tok="${tok%\"}"; tok="${tok#\'}"; tok="${tok%\'}"
      case "$tok" in
        pull_request_target) CW_RESULT=undecidable; CW_WHY="pull_request_target"; decided=1 ;;
        pull_request)
          found_pr=1; in_pr=1
          case "$val" in
            ""|"~"|null) ;;
            *) CW_RESULT=undecidable; CW_WHY="flow-style pull_request: value"; decided=1 ;;
          esac ;;
      esac
      continue
    fi
    [ "$in_pr" = "1" ] || continue
    [ "$sub_ind" = "-1" ] && sub_ind="$ind"
    if [ "$ind" -le "$sub_ind" ]; then
      in_branches=0; in_types=0
      tok="$content"; val=""
      case "$tok" in *:*) val="${tok#*:}"; tok="${tok%%:*}" ;; esac
      val="${val#"${val%%[![:space:]]*}"}"
      case "$tok" in
        branches-ignore) CW_RESULT=undecidable; CW_WHY="branches-ignore"; decided=1 ;;
        paths) CW_RESULT=undecidable; CW_WHY="paths"; decided=1 ;;
        paths-ignore) CW_RESULT=undecidable; CW_WHY="paths-ignore"; decided=1 ;;
        branches)
          has_branches=1; in_branches=1
          if [ -n "$val" ]; then
            for tok in $(sm_flow_items "$val"); do sm_cw_branch_item "$tok"; done
          fi ;;
        types)
          has_types=1; in_types=1
          if [ -n "$val" ]; then
            for tok in $(sm_flow_items "$val"); do sm_cw_type_item "$tok"; done
          fi ;;
      esac
      continue
    fi
    if [ "$in_branches" = "1" ] || [ "$in_types" = "1" ]; then
      tok="$content"; tok="${tok#- }"; tok="${tok#-}"
      tok="${tok#"${tok%%[![:space:]]*}"}"
      if [ "$in_branches" = "1" ]; then sm_cw_branch_item "$tok"; else sm_cw_type_item "$tok"; fi
    fi
  done <"$f"

  if [ "$CW_RESULT" = "undecidable" ]; then return 0; fi
  if [ "$found_pr" = "1" ]; then
    if [ "$has_branches" = "1" ] && [ "$br_match" = "0" ]; then
      CW_RESULT=excluded; CW_WHY="branches: does not name $base"
    elif [ "$has_types" = "1" ] && { [ "$ty_opened" = "0" ] || [ "$ty_sync" = "0" ]; }; then
      # a workflow that does not run on opened+synchronize never has a run on a
      # fresh head: it would sit at `missing` forever, so say so up front
      CW_RESULT=undecidable; CW_WHY="types: without opened+synchronize"
    else
      CW_RESULT=member; CW_WHY=""
    fi
  else
    CW_RESULT=excluded; CW_WHY="no pull_request trigger"
  fi
  return 0
}

# sm_compute_expected <base> <base_sha>: E_PATHS (newline list), E_TIMEOUT
# (max minutes), E_ERR ("" or the undecidable reason). Return 1 on gh failure.
sm_compute_expected() {
  local base="$1" base_sha="$2" wf_states paths p tmp st
  E_PATHS=""; E_TIMEOUT=0; E_ERR=""
  sm_gh api "repos/{owner}/{repo}/actions/workflows?per_page=100" || return 1
  wf_states="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '(.workflows // [])[] | "\(.path)\t\(.state)"' 2>/dev/null)" || { SM_GH_ERR="unparseable workflows list"; return 1; }
  # no .github/workflows on the base at all => E empty => undecidable (§5.3),
  # not an API error to retry forever
  if sm_gh api "repos/{owner}/{repo}/contents/.github/workflows?ref=$base_sha"; then
    paths="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '(if type=="array" then . else [] end)[] | select(.type=="file") | .path' 2>/dev/null)" || paths=""
  elif printf '%s' "$SM_GH_ERR" | grep -qE 'HTTP 404|Not Found'; then
    E_ERR="no .github/workflows directory on $base@${base_sha}"; return 0
  else
    return 1
  fi
  tmp="$(mktemp 2>/dev/null)" || { SM_GH_ERR="mktemp failed"; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *.yml|*.yaml) ;; *) continue ;; esac
    sm_gh api -H 'Accept: application/vnd.github.raw+json' "repos/{owner}/{repo}/contents/$p?ref=$base_sha" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$BR_OUT" >"$tmp"
    sm_classify_workflow "$tmp" "$base"
    case "$CW_RESULT" in
      undecidable) E_ERR="$p: $CW_WHY"; rm -f "$tmp"; return 0 ;;
      member)
        st="$(printf '%s\n' "$wf_states" | awk -F'\t' -v p="$p" '$1==p {print $2; exit}')"
        if [ "$st" != "active" ]; then E_ERR="$p: workflow ${st:-not registered}"; rm -f "$tmp"; return 0; fi
        E_PATHS="${E_PATHS}${E_PATHS:+$'\n'}$p"
        [ "$CW_TIMEOUT" -gt "$E_TIMEOUT" ] && E_TIMEOUT="$CW_TIMEOUT" ;;
    esac
  done <<EOF_PATHS
$paths
EOF_PATHS
  rm -f "$tmp"
  [ -n "$E_PATHS" ] || E_ERR="no pull_request workflow on $base@${base_sha}"
  return 0
}

# --- §6 evaluation -----------------------------------------------------------------------
# sm_fetch_runs <head>: SM_RUNS_FILE = a JSON array (one document) of every run on
# the head (paginated), each projected to the fields §6 reads. Run objects are
# ~13 KB each, so the array never travels through argv (ARG_MAX): pages are
# appended to a file and slurped.
sm_fetch_runs() {
  local head="$1" page=1 total got n pages
  [ -n "$SM_RUNS_FILE" ] || SM_RUNS_FILE="$(mktemp 2>/dev/null)" || { SM_GH_ERR="mktemp failed"; return 1; }
  pages="$SM_RUNS_FILE.pages"
  : >"$pages"
  while :; do
    sm_gh api "repos/{owner}/{repo}/actions/runs?head_sha=$head&per_page=100&page=$page" || { rm -f "$pages"; return 1; }
    n="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '(.workflow_runs // []) | length' 2>/dev/null)"
    printf '%s' "$n" | grep -qE '^[0-9]+$' || { SM_GH_ERR="unparseable runs page $page"; rm -f "$pages"; return 1; }
    [ "$page" = "1" ] && total="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.total_count // 0' 2>/dev/null)"
    printf '%s' "$BR_OUT" | "$SM_JQ" -c '(.workflow_runs // []) | map({id, name, path, event, status, conclusion, run_attempt, created_at, run_started_at, pull_requests})' >>"$pages" 2>/dev/null \
      || { SM_GH_ERR="unparseable runs page $page"; rm -f "$pages"; return 1; }
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
    [ "$page" -gt 10 ] && break
  done
  "$SM_JQ" -s 'add // []' "$pages" >"$SM_RUNS_FILE" 2>/dev/null || { SM_GH_ERR="runs merge failed"; rm -f "$pages"; return 1; }
  rm -f "$pages"
  got="$("$SM_JQ" 'length' "$SM_RUNS_FILE" 2>/dev/null)"
  printf '%s' "$got" | grep -qE '^[0-9]+$' || { SM_GH_ERR="runs merge failed"; return 1; }
  RUNS_TOTAL="${total:-0}"; RUNS_GOT="$got"
  return 0
}

SM_JQ_EVAL='
def prfilter:
  select((.event // "") == "pull_request")
  | select((((.pull_requests // []) | length) == 0) or any((.pull_requests // [])[]; (.number|tostring) == $pr));
def classify:
  if .status == "completed" and .conclusion == "success" then {s:"green", r:"success"}
  elif .status == "queued" or .status == "in_progress" or .status == "pending" or .status == "requested"
       then {s:"pending", r:"\(.status)"}
  elif .status == "waiting" or .status == "action_required"
       or (.status == "completed" and .conclusion == "action_required") then {s:"attended", r:"needs approval"}
  elif .conclusion == "startup_failure" then {s:"failed", r:"startup_failure"}
  elif .status == "completed" and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out"
       or .conclusion == "skipped" or .conclusion == "neutral" or .conclusion == "stale") then {s:"failed", r:"\(.conclusion)"}
  else {s:"failed", r:"unknown \(.status)/\(.conclusion)"} end;
($runs | map(prfilter)) as $all
| ($all | group_by(.path) | map(sort_by(.created_at, (.run_attempt // 1)) | last)) as $newest
| ($newest | map({key: .path, value: {run_id: .id, attempt: (.run_attempt // 1), status: .status, conclusion: .conclusion,
     created_at: (.created_at // ""), run_started_at: (.run_started_at // "")}}) | from_entries) as $observed
| ([ $runs[] | select(.conclusion == "startup_failure") | {s:"failed", r:"\(.path // .name // "?") startup_failure (\(.event // "?") event)"} ]
   + [ $expected[] as $p
       | if ($headfiles | index($p)) == null then {s:"failed", r:"\($p) removed on head"}
         elif $observed[$p] == null then
           (if ($now|tonumber) < ($appear|tonumber) then {s:"missing", r:"\($p) has no run yet"} else {s:"failed", r:"missing \($p)"} end)
         else ($observed[$p] | classify) as $c
           | ($observed[$p]) as $o
           | ([ $stale[] | select(.run_id == $o.run_id and ($o.attempt // 1) <= (.attempt // 1)) ] | first) as $st
           | if $c.s == "failed" and $o.status == "completed" and $o.conclusion == "failure" and $st != null then
               # the listing still reports the attempt that was RERUN by hand:
               # a stale observation, not a verdict, until the attempt advances
               # or the appear deadline says the rerun never materialised
               (if ($now|tonumber) < ($appear|tonumber)
                then {s:"pending", r:"\($p) rerun of run \($o.run_id) not yet visible (attempt \($o.attempt // 1) still reported)"}
                else {s:"failed", r:"\($p) rerun of run \($o.run_id) never appeared (attempt \($o.attempt // 1) still reported after appear_deadline)"} end)
             elif $c.s == "green" then $c else {s:$c.s, r:"\($p) \($c.r)"} end
         end ]
   + [ $newest[] | .path as $p | select(($expected | index($p)) == null) | (classify) as $c
       | if $c.s == "green" then $c
         elif $c.s == "pending" then {s:"pending", r:"\(.path) \($c.r) (not on base)"}
         else {s:"failed", r:"\(.path) \($c.r) (not on base)"} end ]) as $rows
| (["failed","attended","pending","missing"] | map(. as $s | ($rows | map(select(.s == $s)) | first) // empty) | first) as $top
| {state: ($top.s // "green"), reason: ($top.r // "all expected runs succeeded"),
   observed: $observed,
   newest_started: ([ $newest[] | .path as $p | select(($expected | index($p)) != null) | .run_started_at // empty ] | max // "")}
'

# sm_evaluate <expected-json-array> <headfiles-json-array> <appear_deadline>:
# EV_STATE, EV_REASON, EV_OBSERVED (json), EV_NEWEST_STARTED (iso or empty).
# $stale = the runs every hand `rerun` ISSUED on the current head ({path,
# run_id, attempt} as they were when rerun; one entry per verb call, so all
# entries for the head are unioned): a listing that still shows that attempt as
# completed/failure is not a verdict (see the filter), or the workflow's one
# rerun on this head would be consumed by the tick that saw the pre-rerun state.
sm_evaluate() {
  local out stale
  [ -n "$SM_RUNS_FILE" ] && [ -f "$SM_RUNS_FILE" ] || return 1
  stale="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c '.head as $h
            | [ (.reruns // [])[] | select(.head == $h) | . as $e
                | ($e.runs // [])[] | select(.run_id as $id | ($e.issued // []) | index($id) != null) ]' 2>/dev/null)" || stale='[]'
  [ -n "$stale" ] || stale='[]'
  out="$("$SM_JQ" -cn --slurpfile r "$SM_RUNS_FILE" --argjson expected "$1" --argjson headfiles "$2" --argjson stale "$stale" \
          --arg pr "$SM_PR" --arg now "$(sm_now)" --arg appear "$3" '($r[0] // []) as $runs | '"$SM_JQ_EVAL" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  EV_STATE="$(printf '%s' "$out" | "$SM_JQ" -r .state)"
  EV_REASON="$(printf '%s' "$out" | "$SM_JQ" -r .reason)"
  EV_OBSERVED="$(printf '%s' "$out" | "$SM_JQ" -c .observed)"
  EV_NEWEST_STARTED="$(printf '%s' "$out" | "$SM_JQ" -r .newest_started)"
  return 0
}

# --- output --------------------------------------------------------------------------
sm_is_terminal() {   # states `watch` stops on
  case "$1" in merged|failed|undecidable|timed_out|attended|behind|held-by:*) return 0 ;; esac
  return 1
}

sm_finish() {   # print the terminal line and exit (0 only on merged)
  local word="$1" reason="$2"
  if [ "$SM_WATCH" = "1" ]; then
    # watch prints transitions as they happen; the tick's closing word is
    # printed only when it is terminal and was not already a transition line.
    if sm_is_terminal "$word" && [ "$SM_LAST_PRINTED" != "$word" ]; then
      printf '%s %s\n' "$word" "$(sm_oneline "$reason")"
    fi
    [ -n "${SM_RESULT_FILE:-}" ] && printf '%s %s\n' "$word" "$(sm_oneline "$reason")" >"$SM_RESULT_FILE"
  else
    printf '%s %s\n' "$word" "$(sm_oneline "$reason")"
  fi
  sm_lease_release
  [ -n "$SM_RUNS_FILE" ] && rm -f "$SM_RUNS_FILE" "$SM_RUNS_FILE.pages" 2>/dev/null
  [ "$word" = "merged" ] && exit 0
  exit 1
}

sm_sleep() {   # poll sleep: 30 s ± U(0,15); test-overridable; stops at the budget
  local s remaining
  if [ -n "${SWEAP_MERGE_SLEEP:-}" ]; then s="$SWEAP_MERGE_SLEEP"; else s=$((30 + RANDOM % 16)); fi
  [ "$1" = "backoff" ] && s=$((s * 2))
  remaining=$(( SM_DEADLINE - $(sm_real_now) ))
  [ "$s" -gt "$remaining" ] && return 1
  [ "$s" -gt 0 ] && sleep "$s"
  return 0
}

# --- the merge step (D3 + D4 + E2) ------------------------------------------------------
sm_run_gate() {   # returns 0 on allow; on deny/absent/timeout/unparseable sets GATE_REASON and returns 1
  local gate="$SM_HOOKS_DIR/pre-merge-gate.sh" payload tmp decision
  GATE_REASON=""
  [ -f "$gate" ] || { GATE_REASON="pre-merge-gate.sh not found at $gate (fail closed)"; return 1; }
  payload="$("$SM_JQ" -cn --arg c "gh pr merge $SM_PR --squash" --arg cwd "$SM_PRIMARY" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')"
  tmp="$(mktemp 2>/dev/null)" || { GATE_REASON="mktemp failed"; return 1; }
  printf '%s\n' "$payload" >"$tmp"
  SM_STDIN_FILE="$tmp"
  sm_run_hook 25 "$SM_PRIMARY" "$gate"
  SM_STDIN_FILE=""
  rm -f "$tmp"
  if [ "$BR_RC" != "0" ]; then GATE_REASON="gate did not complete (rc=$BR_RC, fail closed)"; return 1; fi
  # Silence is the only allow. Anything else must parse, entirely, to decision
  # objects — a stray line before the JSON is not "no decision", it is a gate
  # the driver cannot read, and an unreadable gate is a closed one.
  if [ -z "$(printf '%s' "$BR_OUT" | tr -d '[:space:]')" ]; then return 0; fi
  decision="$(printf '%s' "$BR_OUT" | "$SM_JQ" -rs '
      if length > 0 and all(.[]; type == "object" and ((.hookSpecificOutput.permissionDecision | type) == "string"))
      then (map(.hookSpecificOutput.permissionDecision) | if index("deny") != null then "deny" else .[0] end)
      else error("unparseable") end' 2>/dev/null)" || decision=""
  if [ -z "$decision" ]; then GATE_REASON="gate output unparseable (fail closed): $(sm_oneline "$BR_OUT" | cut -c1-160)"; return 1; fi
  if [ "$decision" = "deny" ]; then
    GATE_REASON="$(printf '%s' "$BR_OUT" | "$SM_JQ" -rs 'map(select(.hookSpecificOutput.permissionDecision == "deny")) | first | .hookSpecificOutput.permissionDecisionReason // "denied"' 2>/dev/null)"
    return 1
  fi
  if [ "$decision" != "allow" ]; then GATE_REASON="gate returned '$decision' (fail closed)"; return 1; fi
  return 0
}

# sm_post_merge: E2, the three post-merge hooks, once, with a synthetic
# PostToolUse payload. They run with the SESSION's cwd (where the driver was
# launched), not <primary>: post-merge-cleanup.sh skips the worktree the caller
# stands in, and each hook derives <primary> itself. Their alarms are the
# harness's out-of-band channel (stderr + exit 2 = "AUDIT DEBT"/"AUDIT DUE";
# cleanup's additionalContext on stdout): forwarded to our stderr prefixed by
# the hook name, recorded in the state file, and an exit-2 banner is folded into
# the terminal reason so the session sees "merged BUT ...".
sm_post_merge() {
  local payload tmp s line banner ctx
  payload="$("$SM_JQ" -cn --arg c "gh pr merge $SM_PR --squash" --arg cwd "$SM_INVOKE_CWD" --arg out "$SM_MERGE_OUT" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$out, stderr:"", interrupted:false}, cwd:$cwd}')"
  tmp="$(mktemp 2>/dev/null)" || return 0
  printf '%s\n' "$payload" >"$tmp"
  for s in post-merge-cleanup.sh post-merge-auditcheck.sh; do
    [ -f "$SM_HOOKS_DIR/$s" ] || continue
    SM_STDIN_FILE="$tmp"
    sm_run_hook 30 "$SM_INVOKE_CWD" "$SM_HOOKS_DIR/$s" || true
    SM_STDIN_FILE=""
    if [ -n "$BR_ERR" ]; then
      printf '%s\n' "$BR_ERR" | while IFS= read -r line; do printf '[%s] %s\n' "$s" "$line"; done >&2
    fi
    ctx="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r 'select(type=="object") | .hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    if [ -n "$ctx" ]; then
      printf '%s\n' "$ctx" | while IFS= read -r line; do printf '[%s] %s\n' "$s" "$line"; done >&2
      sm_set '.post_merge_alerts = ((.post_merge_alerts // []) + [{hook:$h, rc:($rc|tonumber), context:$c}])' \
        --arg h "$s" --arg rc "$BR_RC" --arg c "$ctx"
    fi
    if [ "$BR_RC" = "2" ]; then
      # the hooks' banners are `## <text>` lines between `####…` rules
      banner="$(printf '%s\n' "$BR_ERR" | sed -n 's/^## *\([^# ].*\)$/\1/p' | head -1)"
      [ -n "$banner" ] || banner="$(printf '%s\n' "$BR_ERR" | grep -v '^ *$' | head -1)"
      [ -n "$banner" ] || banner="exited 2 without a message"
      sm_set '.post_merge_alerts = ((.post_merge_alerts // []) + [{hook:$h, rc:2, banner:$b}])' --arg h "$s" --arg b "$banner"
      SM_ALERTS="${SM_ALERTS} | ${s%.sh}: $(sm_oneline "$banner")"
    fi
  done
  rm -f "$tmp"
  sm_set '.post_merge_done = true'
  sm_state_write || true
  [ -n "$SM_ALERTS" ] && SM_REASON="${SM_REASON}${SM_ALERTS}"
  return 0
}

sm_after_merged() {   # run the post-merge hooks exactly once per merged state file
  # a flake note deferred at green for budget (sm_flake_note) is filed here,
  # on the merge or on any re-entry; the entry's mark makes it idempotent
  sm_flake_note
  if [ "$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.post_merge_done // false')" = "true" ]; then
    # re-entry: the alarms recorded by the run that did the hooks still matter
    SM_ALERTS="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '(.post_merge_alerts // []) | map(select(.rc == 2)) | map(" | \(.hook | sub("\\.sh$"; "")): \(.banner)") | join("")' 2>/dev/null)"
    [ -n "$SM_ALERTS" ] && SM_REASON="${SM_REASON}${SM_ALERTS}"
    return 0
  fi
  [ -n "$SM_MERGE_OUT" ] || SM_MERGE_OUT="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '(.history // []) | map(select(.to=="merged")) | last | .why // "merged"')"
  sm_post_merge
}

# sm_reconcile: read-only (D4). Never issues a merge. Sets SM_STATE via transition.
sm_reconcile() {
  local st mc head stored attempts
  if ! sm_gh pr view "$SM_PR" --json state,mergeCommit,headRefOid; then
    SM_STATE="merging"; SM_REASON="reconcile unavailable: $SM_GH_ERR (re-tick to reconcile; no merge will be issued)"
    return 1
  fi
  st="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.state // ""')"
  mc="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.mergeCommit.oid // ""')"
  head="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.headRefOid // ""')"
  stored="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.head // ""')"
  attempts="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.merge_attempts // 0')"
  printf '%s' "$attempts" | grep -qE '^[0-9]+$' || attempts=0
  case "$st" in
    MERGED) SM_MERGE_OUT="${SM_MERGE_OUT:-reconciled: PR #$SM_PR merged as ${mc:-?}}"; sm_transition merged "reconciled: merged as ${mc:-?}"; return 0 ;;
    OPEN)
      if [ -n "$head" ] && [ "$head" != "$stored" ]; then
        sm_set '.head = $h | .merge_attempts = 0' --arg h "$head"
        sm_transition superseded "head moved $stored -> $head during merge; re-arm next tick"; return 0
      fi
      # Same head, still open: the merge was refused for a reason a re-evaluation
      # cannot change (token scope, archived repo, a rule, a 5xx). One re-try via
      # pending; a second refusal is a finding, not a loop (D5: no auto-retry).
      if [ "$attempts" -ge 2 ]; then
        sm_transition failed "merge ${SM_RECONCILE_WHY:-refused} after $attempts attempts on $stored; not retrying"; return 0
      fi
      sm_transition pending "merge did not land on $stored (${SM_RECONCILE_WHY:-unknown}); re-evaluating (attempt $attempts of 2)"; return 0 ;;
    *) sm_transition failed "merge ${SM_RECONCILE_WHY:-failed}; PR is ${st:-unknown}"; return 0 ;;
  esac
}

sm_merge_step() {   # from green: verdict → gate → merging → pinned merge → merged | reconcile
  local head base_sha
  head="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.head')"
  base_sha="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.base_sha')"
  sm_set '.verdict = {head:$h, base_sha:$b, epoch:($e|tonumber), at:($at|tonumber), expected:.expected}' \
    --arg h "$head" --arg b "$base_sha" --arg e "$SM_EPOCH" --arg at "$(sm_now)"
  sm_state_write || { SM_STATE="failed"; SM_REASON="$SM_WRITE_ERR"; return 0; }
  if ! sm_run_gate; then
    sm_transition failed "gate: $GATE_REASON"
    return 0
  fi
  sm_set '.merge_attempts = ((.merge_attempts // 0) + 1)'
  sm_transition merging "gate allowed; merging $head pinned" || return 0
  if sm_gh pr merge "$SM_PR" --squash --match-head-commit "$head"; then
    SM_MERGE_OUT="$BR_OUT"
    if sm_transition merged "$(sm_oneline "${BR_OUT:-merged}")"; then
      sm_after_merged
    else
      # the merge landed; only our record of it lost the fence. Say `merging`
      # (the next tick reconciles to merged), never `failed`.
      SM_STATE="merging"; SM_REASON="merged on GitHub but the state write failed ($SM_WRITE_ERR); re-tick to reconcile"
    fi
    return 0
  fi
  SM_RECONCILE_WHY="$SM_GH_ERR"
  sm_reconcile
  [ "$SM_STATE" = "merged" ] && sm_after_merged
  return 0
}

# --- tick ---------------------------------------------------------------------------------
sm_tick() {
  local budget="$1" iter=0
  local head base base_sha behind stored_head stored_base_sha commit_date arm_at appear complete window
  local expected_json headfiles run_started
  SM_DEADLINE=$(( $(sm_real_now) + budget ))
  sm_state_read
  sm_primary_check || sm_finish failed "$SM_REASON"
  if ! sm_lease_claim; then sm_finish "held-by:$SM_HELD_BY" "lease on PR #$SM_PR is held by a live poller"; fi
  trap sm_lease_release EXIT

  case "$SM_STATE" in
    merging)
      # D4: a `merging` file (ours or hand-edited) is only ever reconciled, never re-merged.
      sm_reconcile || sm_finish merging "$SM_REASON"
      # open on the same head => pending: this tick ends there, so a merging
      # file is never a warrant to merge; the next tick re-evaluates from pending.
      case "$SM_STATE" in superseded|failed|pending) sm_finish "$SM_STATE" "$SM_REASON" ;; esac
      ;;
    superseded)
      sm_disarm   # re-arm on the new head with fresh deadlines
      ;;
  esac
  if [ "$SM_STATE" = "merged" ]; then
    sm_after_merged
    sm_finish merged "${SM_REASON:-PR #$SM_PR is merged}"
  fi
  # Arm-time checkpoint (see sm_checkpoint). HERE, not right after the claim:
  # the `merging` branch above reconciles from a file that already exists (and
  # always finishes), the `merged` branch likewise, and the `superseded` branch
  # has just cleared the deadlines in memory — so this is the first point at
  # which the shape of the durable object for THIS tick is settled and nothing
  # after it is anything but gh-driven. Everything below can die in a gh call;
  # the state file and its heartbeat are already on disk.
  if ! sm_checkpoint; then
    SM_STATE="failed"
    sm_finish failed "${SM_WRITE_ERR:-arm-time checkpoint failed}"
  fi

  while :; do
    iter=$((iter + 1))
    if [ $(( SM_DEADLINE - $(sm_real_now) )) -lt 1 ]; then break; fi

    # 1. resolve head / base / PR state
    if ! sm_gh pr view "$SM_PR" --json headRefOid,baseRefName,state,mergeCommit,commits; then
      SM_REASON="$SM_GH_ERR"
      sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    head="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.headRefOid // ""')"
    base="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.baseRefName // ""')"
    case "$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.state // ""')" in
      MERGED)
        SM_MERGE_OUT="PR #$SM_PR was merged outside the driver ($(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.mergeCommit.oid // "?"'))"
        sm_set '.pr = ($pr|tonumber) | .head = (if .head == null or .head == "" then $h else .head end)' --arg h "$head" --arg pr "$SM_PR"
        sm_transition merged "$SM_MERGE_OUT"
        sm_after_merged
        sm_finish merged "$SM_MERGE_OUT" ;;
      CLOSED) sm_transition failed "PR #$SM_PR is closed"; sm_finish failed "$SM_REASON" ;;
    esac
    if [ -z "$head" ] || [ -z "$base" ]; then
      SM_REASON="gh pr view returned no head/base"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    commit_date="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '(.commits // []) | last | .committedDate // ""')"

    stored_head="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.head // ""')"
    if [ -n "$stored_head" ] && [ "$stored_head" != "$head" ]; then
      sm_set '.head = $h | .pr = ($pr|tonumber) | .merge_attempts = 0' --arg h "$head" --arg pr "$SM_PR"
      sm_transition superseded "head moved $stored_head -> $head; re-arm next tick"
      sm_finish superseded "$SM_REASON"
    fi
    # appear_deadline (E8): committedDate is the COMMIT time, not the push — a
    # commit tested locally for an hour and pushed now has no run yet for a few
    # seconds, and that is `missing`, not `failed`. Anchor on the later of the
    # commit and the arm time, then + 5 min.
    if [ -z "$stored_head" ]; then
      arm_at="$(sm_now)"
      appear=""
      if [ -n "$commit_date" ]; then appear="$(sm_iso_epoch "$commit_date")" || appear=""; fi
      [ -n "$appear" ] && [ "$appear" -gt "$arm_at" ] || appear="$arm_at"
      appear=$((appear + SM_APPEAR_WINDOW))
      sm_set '.pr = ($pr|tonumber) | .head = $h | .base = $b | .arm_at = ($a|tonumber) | .appear_deadline = ($ap|tonumber)
              | .observed = {} | .verdict = null | .post_merge_done = false | .merge_attempts = 0' \
        --arg pr "$SM_PR" --arg h "$head" --arg b "$base" --arg a "$arm_at" --arg ap "$appear"
    fi
    if [ "$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.arm_at // ""')" = "" ]; then   # re-arm after superseded
      arm_at="$(sm_now)"
      appear=""
      if [ -n "$commit_date" ]; then appear="$(sm_iso_epoch "$commit_date")" || appear=""; fi
      [ -n "$appear" ] && [ "$appear" -gt "$arm_at" ] || appear="$arm_at"
      appear=$((appear + SM_APPEAR_WINDOW))
      sm_set '.base = $b | .arm_at = ($a|tonumber) | .appear_deadline = ($ap|tonumber) | .post_merge_done = false | .merge_attempts = 0' \
        --arg b "$base" --arg a "$arm_at" --arg ap "$appear"
    fi

    # 2. freshness against base (also yields base_sha)
    if ! sm_gh api "repos/{owner}/{repo}/compare/$base...$head"; then
      SM_REASON="$SM_GH_ERR"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    behind="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.behind_by // ""')"
    base_sha="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.base_commit.sha // ""')"
    if ! printf '%s' "$behind" | grep -qE '^[0-9]+$' || [ -z "$base_sha" ]; then
      SM_REASON="compare returned no behind_by/base_commit"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    if [ "$behind" -gt 0 ]; then
      sm_set '.base_sha = $s' --arg s "$base_sha"
      sm_transition behind "head is behind $base by $behind commit(s); rebase"
      sm_finish behind "$SM_REASON"
    fi

    # 3. expected set (recomputed when base_sha moves)
    stored_base_sha="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.expected_from // ""')"
    if [ "$stored_base_sha" != "$base_sha" ] || [ "$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '(.expected // []) | length')" = "0" ]; then
      if ! sm_compute_expected "$base" "$base_sha"; then
        SM_REASON="$SM_GH_ERR"; sm_lease_renew
        if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
        sm_sleep backoff || break
        continue
      fi
      if [ -n "$E_ERR" ]; then
        sm_set '.base_sha = $s | .expected = [] | .expected_from = $s' --arg s "$base_sha"
        sm_transition undecidable "expected set: $E_ERR"
        sm_finish undecidable "$SM_REASON"
      fi
      expected_json="$(printf '%s\n' "$E_PATHS" | "$SM_JQ" -R . | "$SM_JQ" -cs .)"
      sm_set '.base_sha = $s | .expected = $e | .expected_from = $s | .expected_timeout_min = ($t|tonumber)' \
        --arg s "$base_sha" --argjson e "$expected_json" --arg t "$E_TIMEOUT"
    fi
    expected_json="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c '.expected')"
    window="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '(.expected_timeout_min // 0) * 120')"
    [ "$window" -lt "$SM_COMPLETE_MIN" ] && window="$SM_COMPLETE_MIN"

    # 4. head's workflow files + runs. A 404 means the directory is gone on the
    #    head (every expected path is then "removed on head"); any other failure
    #    is an API error and retries — never a verdict.
    if sm_gh api "repos/{owner}/{repo}/contents/.github/workflows?ref=$head"; then
      headfiles="$(printf '%s' "$BR_OUT" | "$SM_JQ" -c '(if type=="array" then . else [] end) | map(select(.type=="file") | .path)' 2>/dev/null)" || headfiles='[]'
    elif printf '%s' "$SM_GH_ERR" | grep -qE 'HTTP 404|Not Found'; then
      headfiles='[]'
    else
      SM_REASON="$SM_GH_ERR"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    if ! sm_fetch_runs "$head"; then
      SM_REASON="$SM_GH_ERR"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    if ! printf '%s' "$RUNS_TOTAL" | grep -qE '^[0-9]+$'; then
      sm_transition undecidable "runs for $head: total_count '$RUNS_TOTAL' is not a number"
      sm_finish undecidable "$SM_REASON"
    fi
    if [ "$RUNS_TOTAL" -gt "$RUNS_GOT" ]; then
      sm_transition undecidable "runs for $head: total_count $RUNS_TOTAL > $RUNS_GOT returned after pagination"
      sm_finish undecidable "$SM_REASON"
    fi

    # 5. evaluate §6
    appear="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.appear_deadline // 0')"
    if ! sm_evaluate "$expected_json" "$headfiles" "$appear"; then
      SM_REASON="evaluation failed (jq)"; sm_lease_renew || sm_finish failed "$SM_REASON"
      if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
      sm_sleep backoff || break
      continue
    fi
    arm_at="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.arm_at // 0')"
    run_started=""
    [ -n "$EV_NEWEST_STARTED" ] && run_started="$(sm_iso_epoch "$EV_NEWEST_STARTED")" || run_started=""
    if [ -n "$run_started" ]; then complete=$((run_started + window)); else complete=$((arm_at + window)); fi
    sm_set '.observed = $o | .complete_deadline = ($c|tonumber)' --argjson o "$EV_OBSERVED" --arg c "$complete"
    if [ "$EV_STATE" = "pending" ] && [ "$(sm_now)" -ge "$complete" ]; then
      EV_STATE="timed_out"; EV_REASON="complete_deadline $complete passed: $EV_REASON"
    fi
    sm_transition "$EV_STATE" "$EV_REASON" || sm_finish failed "$SM_REASON"
    case "$EV_STATE" in
      green) sm_flake_note; sm_merge_step; break ;;
      failed|undecidable|attended|timed_out) sm_finish "$EV_STATE" "$SM_REASON" ;;
    esac
    if [ "$SM_MAX_ITER" -gt 0 ] && [ "$iter" -ge "$SM_MAX_ITER" ]; then break; fi
    sm_sleep normal || break
  done
  sm_finish "$SM_STATE" "$SM_REASON"
}

# --- watch --------------------------------------------------------------------------------
sm_watch() {   # loop ticks (each in a subshell, output streamed) until a terminal state
  local budget="$1" word ticks=0 rf
  rf="$(mktemp 2>/dev/null)" || { printf 'failed mktemp failed\n'; exit 1; }
  SM_RESULT_FILE="$rf"
  SM_WATCH=1
  while :; do
    : >"$rf"
    ( sm_tick "$budget" )
    word="$(cut -d' ' -f1 "$rf" 2>/dev/null)"
    if [ -z "$word" ]; then rm -f "$rf"; printf 'failed tick produced no result\n'; exit 1; fi
    if sm_is_terminal "$word"; then
      rm -f "$rf"
      [ "$word" = "merged" ] && exit 0
      exit 1
    fi
    ticks=$((ticks + 1))
    if [ "${SWEAP_MERGE_MAX_TICKS:-0}" -gt 0 ] && [ "$ticks" -ge "$SWEAP_MERGE_MAX_TICKS" ]; then
      rm -f "$rf"; printf '%s watch stopped after %s tick(s)\n' "$word" "$ticks"; exit 1
    fi
  done
}

# --- status --------------------------------------------------------------------------------
sm_status() {
  local f pr st head owner hb age dead lk now wpid
  now="$(sm_now)"
  for f in "$SM_DIR"/*.json; do
    [ -f "$f" ] || continue
    pr="$(basename "$f" .json)"
    [ -n "${1:-}" ] && [ "$pr" != "$1" ] && continue
    st="$("$SM_JQ" -r '.state // "?"' "$f" 2>/dev/null)"
    head="$("$SM_JQ" -r '.head // "" | .[0:12]' "$f" 2>/dev/null)"
    owner="$("$SM_JQ" -r '.lease.owner // "-"' "$f" 2>/dev/null)"
    hb="$("$SM_JQ" -r '.lease.heartbeat_at // 0' "$f" 2>/dev/null)"
    # A hand-edited or half-written state file must not take the whole command
    # down: `age=$(( now - "2026-09-02T10:00:00Z" ))` is a fatal shell error, and
    # it kills sm_status MID-LOOP, so every PR after this one is never printed —
    # silence again, in the command whose whole job is not to be silent. The lock
    # parser has validated its own numeric fields since it was written; this one
    # had not.
    case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
    age=$(( now - hb ))
    dead=""
    lk="$SM_DIR/$pr.lock"
    if [ -d "$lk" ]; then
      SM_LOCK="$lk"
      if sm_lock_read; then
        if [ "$LK_HOST" = "$SM_HOST" ] && ! sm_pid_alive "$LK_PID"; then dead="dead poller (pid $LK_PID gone)"
        elif [ $(( now - LK_HB )) -gt "$SM_STALE" ]; then dead="dead poller (heartbeat ${LK_HB} stale)"
        else dead="live poller $LK_OWNER"; fi
      else
        dead="lock without info"
      fi
    else
      # NO LOCK IS THE QUESTION THIS COMMAND EXISTS TO ANSWER, and until now it
      # said nothing at all. A watcher holds the lease only DURING a tick —
      # sm_tick runs in a subshell whose EXIT trap releases it — and bash runs an
      # EXIT trap on SIGTERM too, so a KILLED watcher also leaves no lock. Claude
      # Code kills a session's background shells under memory pressure (see the
      # playbook), which is how consumer A #237 sat green and unmerged for 26 minutes:
      # `status` showed a 29s-old heartbeat and no annotation, and that was read as
      # "someone is on it". Say which of the two it is, or say that it cannot be
      # told — never let silence read as health.
      case "$st" in
        merged|failed|attended|undecidable|timed_out|behind) : ;;
        *)
          # DECIDE, do not hedge. An earlier draft answered "a watcher between
          # ticks and one just killed look identical here" — that is wrong, and
          # the wrongness mattered: a tick holds the lock for its ENTIRE budget
          # including every sleep inside it, so "no lock" is the millisecond gap
          # between one tick's subshell and the next, not a 130 s window of doubt.
          # The deciding fact is already on disk: the lease records its holder as
          # <session>:<pid>, and that pid is the watcher's, so ask it with the same
          # sm_pid_alive the lock branch uses four lines up. The heartbeat stays as
          # the second opinion, for the one thing a pid cannot answer — a recycled
          # pid that now belongs to something unrelated.
          wpid="${owner##*:}"
          if [ -z "$owner" ] || [ "$owner" = "-" ]; then
            dead="NO WATCHER — no lease was ever recorded for this PR; nothing is waiting on it. Arm one: sweap-merge watch $pr"
          elif ! sm_pid_alive "$wpid"; then
            dead="NO WATCHER — the watcher that held this PR (pid $wpid) is gone. Arm one: sweap-merge watch $pr"
          elif [ "$age" -lt 0 ]; then
            dead="pid $wpid is alive but its heartbeat ($hb) is ahead of now ($now) — the clock moved backwards, so age says nothing; re-run 'sweap-merge watch $pr' to settle it"
          elif [ "$age" -gt "$SM_STALE" ]; then
            dead="pid $wpid is alive but has not ticked for ${age}s, past the ${SM_STALE}s bound — a stalled watcher or a reused pid, not evidence of one waiting; re-run 'sweap-merge watch $pr'"
          else
            dead="watcher pid $wpid alive, last tick ${age}s ago"
          fi ;;
      esac
    fi
    printf '#%s %s head=%s owner=%s heartbeat=%ss-ago%s\n' "$pr" "$st" "$head" "$owner" "$age" "${dead:+ [$dead]}"
  done
  return 0
}

# --- rerun (a HAND verb; the driver never reruns on its own) ------------------------------
# The 2026-08-25 memo's item 1: every production queue ships without auto-retry,
# and a rerun issued outside the driver leaves no record. This verb is the ONE
# accepted path for a rerun: it refuses unless the PR's state is `failed` with a
# completed `failure` run in the expected set, refuses when the same workflow is
# also red on the base's tip (a flaky main stalls every PR; rerunning the PR is
# then pointless), and refuses when a rerun was ever recorded for this head SHA
# AND workflow path (one per head+workflow, ever — a second red of the same
# workflow on the same head is a finding; a different workflow's first red on
# the same head is not, see consumer A #319). It carries
# its reason, records `reruns[]` in the state file, and re-arms through
# sm_disarm so the next tick waits with fresh deadlines. Nothing is written on
# a refusal.
sm_refuse() {   # print `refused <why>` and exit 1 (nothing written)
  printf 'refused %s\n' "$(sm_oneline "$1")"
  sm_lease_release
  exit 1
}

# sm_rerun_judge: the checks that decide whether THIS state file admits a
# rerun, against SM_STATE_JSON as currently loaded. Run twice: once on the
# pre-claim snapshot (cheap refusals take no lease) and again on a fresh read
# under the lease — a tick that released between our first read and our
# mkdir has rewritten history/observed/deadlines, and the write at the end
# must be built from THAT file, never from the snapshot. Sets RJ_HEAD and
# RJ_FAILED (json array of {path, run_id, attempt}); refuses otherwise.
sm_rerun_judge() {
  local n
  [ "$SM_STATE" = "failed" ] || sm_refuse "PR #$SM_PR is '$SM_STATE', not failed; a rerun only answers a red run"
  RJ_HEAD="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.head // ""')"
  [ -n "$RJ_HEAD" ] || sm_refuse "PR #$SM_PR's state file records no head"
  # the red runs: expected paths whose newest observed run COMPLETED with
  # conclusion `failure`. A missing run, a startup_failure, a cancelled or an
  # in-flight one is not rerunnable (GitHub refuses reruns of unfinished runs,
  # and the others are not flakes to begin with).
  # The cap is per (head, workflow path), not per head: consumer A #319 went red
  # on ci.yml, was rerun, then went red on claude-review.yml on the SAME head
  # — a different workflow's first flake, not the same one's second. A path
  # already in reruns[].runs[] for this head is spent; what is left is the
  # rerunnable set, and only an EMPTY remainder refuses.
  RJ_FAILED="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c --arg h "$RJ_HEAD" '
    ([ (.reruns // [])[] | select(.head == $h) | (.runs // [])[] | .path ]) as $spent
    | [ (.expected // [])[] as $p | (.observed // {})[$p] // empty
        | select(.status == "completed" and .conclusion == "failure")
        | select(($spent | index($p)) == null)
        | {path: $p, run_id: .run_id, attempt: (.attempt // 1)} ]' 2>/dev/null)" || RJ_FAILED='[]'
  n="$(printf '%s' "$RJ_FAILED" | "$SM_JQ" 'length' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" = 0 ]; then
    if [ "$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r --arg h "$RJ_HEAD" '
          ([ (.reruns // [])[] | select(.head == $h) | (.runs // [])[] | .path ]) as $spent
          | [ (.expected // [])[] as $p | (.observed // {})[$p] // empty
              | select(.status == "completed" and .conclusion == "failure") | $p ]
          | any(. as $p | ($spent | index($p)) != null)')" = "true" ]; then
      sm_refuse "every red run on head $RJ_HEAD was already rerun once ($(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r --arg h "$RJ_HEAD" '(.reruns // []) | map(select(.head == $h)) | map("\((.runs // []) | map(.path) | join(" ")) at \(.at), reason: \(.reason)") | join("; ")')); one rerun per head and workflow, ever — a second red of the same workflow on the same head is a finding, not a flake"
    fi
    sm_refuse "PR #$SM_PR failed without a completed 'failure' run in the expected set ($(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '(.history // []) | last | .why // "no reason recorded"')); nothing to rerun"
  fi
  return 0
}

sm_rerun() {
  local reason="$1" stored_head head base pr_state failed_json n i run_id path ids paths issued="" bad="" red_json red_c red_id red_s
  SM_DEADLINE=$(( $(sm_real_now) + SM_DEFAULT_BUDGET ))
  sm_state_read
  [ -f "$SM_FILE" ] || sm_refuse "no state file for PR #$SM_PR under $SM_DIR (nothing was ever watched); arm a watch first: sweap-merge watch $SM_PR"
  sm_primary_check || sm_refuse "$SM_REASON"
  sm_rerun_judge                     # pre-claim snapshot: cheap refusals, no lease
  stored_head="$RJ_HEAD"
  if ! sm_lease_claim; then sm_finish "held-by:$SM_HELD_BY" "lease on PR #$SM_PR is held by a live poller; a rerun needs the state file"; fi
  trap sm_lease_release EXIT
  # the head must still be the one that went red: a rerun reuses GITHUB_SHA, so
  # after a push it would test the wrong commit (and the new head gets its own runs)
  sm_gh pr view "$SM_PR" --json headRefOid,baseRefName,state || sm_refuse "$SM_GH_ERR"
  head="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.headRefOid // ""')"
  base="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.baseRefName // ""')"
  pr_state="$(printf '%s' "$BR_OUT" | "$SM_JQ" -r '.state // ""')"
  case "$pr_state" in
    OPEN) ;;
    "") sm_refuse "gh pr view returned no state for PR #$SM_PR (fail closed)" ;;
    *) sm_refuse "PR #$SM_PR is $pr_state; nothing to rerun" ;;
  esac
  [ -n "$head" ] || sm_refuse "gh pr view returned no head for PR #$SM_PR (fail closed)"
  # AUTHORITATIVE read, under the lease: everything judged so far was a
  # snapshot from before the claim. Re-judge the file as it is now, and refuse
  # if the head it records is no longer the one we judged.
  sm_state_read
  sm_primary_check || sm_refuse "$SM_REASON"
  sm_rerun_judge
  [ "$RJ_HEAD" = "$stored_head" ] || sm_refuse "state file changed under us: it recorded head $stored_head before the claim and $RJ_HEAD after; re-run the verb"
  failed_json="$RJ_FAILED"
  n="$(printf '%s' "$failed_json" | "$SM_JQ" 'length')"
  [ -n "$base" ] || base="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.base // "main"')"
  if [ "$head" != "$stored_head" ]; then
    sm_refuse "head moved $stored_head -> $head since the red run; the rerun would test the old commit — re-arm the watch instead: sweap-merge watch $SM_PR"
  fi
  # a red base tip: the newest run of the same workflow on the base branch
  i=0
  while [ "$i" -lt "$n" ]; do
    path="$(printf '%s' "$failed_json" | "$SM_JQ" -r ".[$i].path")"
    sm_gh run list --branch "$base" --workflow "$(basename "$path")" --limit 1 --json status,conclusion,headSha,databaseId \
      || sm_refuse "cannot read $base's tip for $path: $SM_GH_ERR (a rerun needs to know the base is green)"
    red_json="$(printf '%s' "$BR_OUT" | "$SM_JQ" -c '(if type=="array" then . else [] end) | first // {}' 2>/dev/null)" || red_json='{}'
    red_s="$(printf '%s' "$red_json" | "$SM_JQ" -r '.status // ""')"
    red_c="$(printf '%s' "$red_json" | "$SM_JQ" -r '.conclusion // ""')"
    red_id="$(printf '%s' "$red_json" | "$SM_JQ" -r '.databaseId // "?"')"
    if [ "$red_s" = "completed" ]; then
      case "$red_c" in
        failure|timed_out|startup_failure)
          sm_refuse "$path is also red on $base's tip (run $red_id: $red_c); rerunning PR #$SM_PR is pointless — fix or rerun $base first" ;;
      esac
    fi
    i=$((i + 1))
  done
  # act: one `gh run rerun --failed` per red expected run. Past this point the
  # record is written whatever happens — a rerun that was issued must count
  # against this head even if a later call fails.
  ids=""; paths=""
  i=0
  while [ "$i" -lt "$n" ]; do
    run_id="$(printf '%s' "$failed_json" | "$SM_JQ" -r ".[$i].run_id")"
    path="$(printf '%s' "$failed_json" | "$SM_JQ" -r ".[$i].path")"
    if sm_gh run rerun --failed "$run_id"; then
      issued="${issued}${issued:+ }$run_id"
    else
      bad="${bad}${bad:+; }run $run_id ($path): $SM_GH_ERR"
    fi
    ids="${ids}${ids:+,}$run_id"; paths="${paths}${paths:+ }$path"
    i=$((i + 1))
  done
  if [ -z "$issued" ]; then
    sm_refuse "no rerun was issued: $bad"
  fi
  # the record is built from the JSON read UNDER the lease (the second
  # sm_state_read above), so nothing a released tick wrote is clobbered
  sm_set '.reruns = ((.reruns // []) + [{head:$h, run_ids:($ids | split(",") | map(tonumber)), runs:$runs, reason:$r, at:($at|tonumber), by:$by, issued:($iss | split(" ") | map(tonumber))}])' \
    --arg h "$stored_head" --arg ids "$ids" --argjson runs "$failed_json" --arg r "$reason" --arg at "$(sm_now)" \
    --arg by "${USER:-unknown}@$SM_HOST session $SM_SESSION" --arg iss "$issued" \
    || sm_refuse "state update failed (jq); the rerun of $issued WAS issued but could not be recorded"
  sm_disarm
  if ! sm_transition pending "manual rerun ($reason)"; then
    printf 'failed rerun of %s was issued but the record could not be written: %s\n' "$issued" "$(sm_oneline "$SM_REASON")"
    exit 1
  fi
  if [ -n "$bad" ]; then
    printf 'failed rerun issued for %s but not all: %s; recorded on head %s\n' "$issued" "$(sm_oneline "$bad")" "$stored_head"
    exit 1
  fi
  printf 'pending manual rerun (%s): gh run rerun --failed %s (%s) on head %s, recorded; re-arm the watch: sweap-merge watch %s\n' \
    "$(sm_oneline "$reason")" "$(printf '%s' "$issued" | tr ' ' ',')" "$paths" "$stored_head" "$SM_PR"
  exit 0
}

# --- the flake note --------------------------------------------------------------------
# A PR that went red, was rerun BY HAND through `rerun`, and then reaches green
# on the same head is a flake by definition (same commit, different verdict).
# That is a finding the pipeline would otherwise lose: it is filed as ONE
# discovered note (kind gap) per workflow path through the plugin's own note
# writer, and a later flake of the same workflow APPENDS one line to that note
# instead of opening a second — the only edit a discovered note ever receives.
# Never a merge blocker: every failure here is a stderr line, nothing more.
sm_backlog_dir() {   # the consumer's backlog.dir (CLAUDE.md `## sweap config`), default roadmap/
  local d=""
  [ -f "$SM_PRIMARY/CLAUDE.md" ] && d="$(sed -n 's/^backlog\.dir:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$SM_PRIMARY/CLAUDE.md" 2>/dev/null | head -1)"
  [ -n "$d" ] || d="roadmap/"
  case "$d" in */) ;; *) d="$d/" ;; esac
  printf '%s' "$d"
}

sm_epoch_iso() {   # epoch -> 2026-08-25T10:00:00Z (bash 3.2 / macOS date, then GNU)
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  printf '%s' "$1"
}

sm_flake_note() {
  local head base_sha inbox node mjs todo n i j m entry path run_id attempt green_attempt reason at ts title body existing noted bound
  head="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.head // ""')"
  todo="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c --arg h "$head" \
    '[(.reruns // []) | to_entries[] | select(.value.head == $h and ((.value.flake_noted // false) | not)) | .key]' 2>/dev/null)" || todo='[]'
  n="$(printf '%s' "$todo" | "$SM_JQ" 'length' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*|0) return 0 ;; esac
  base_sha="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r '.base_sha // "?"')"
  inbox="$SM_PRIMARY/$(sm_backlog_dir)discovered"
  mjs="$SM_HOOKS_DIR/../tools/sweap-note.mjs"
  node="$(PATH="$SM_PINNED_PATH" command -v node 2>/dev/null)" || node=""
  # the note writer is charged against the tick's budget like a gh call: a
  # slow node start must never eat the budget the merge step needs (and one
  # of its two attempts). Below the margin the note is DEFERRED — the entry
  # stays un-noted and the merged re-entry path files it on a later pass.
  bound=$(( SM_DEADLINE - $(sm_real_now) - 10 ))
  if [ "$SM_DEADLINE" -gt 0 ] && [ "$bound" -lt 5 ]; then
    printf '[sweap-merge] flake note deferred: %ss of budget left is too little to start the note writer; it is filed on the next pass\n' "$(( SM_DEADLINE - $(sm_real_now) ))" >&2
    return 0
  fi
  [ "$bound" -gt 20 ] && bound=20
  noted='"skipped"'
  if [ ! -d "$inbox" ]; then
    printf '[sweap-merge] flake note skipped: no discovered inbox at %s (backlog.dir); the rerun stays recorded in the state file\n' "$inbox" >&2
  elif [ ! -f "$mjs" ]; then
    printf '[sweap-merge] flake note skipped: sweap-note.mjs not found at %s (the rerun stays recorded in the state file)\n' "$mjs" >&2
  elif [ -z "$node" ]; then
    printf '[sweap-merge] flake note skipped: node not found under the pinned PATH (the rerun stays recorded in the state file)\n' >&2
  else
    noted='true'
    at="$(sm_now)"; ts="$(sm_epoch_iso "$at")"
    i=0
    while [ "$i" -lt "$n" ]; do
      j="$(printf '%s' "$todo" | "$SM_JQ" -r ".[$i]")"
      entry="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -c ".reruns[$j]")"
      reason="$(printf '%s' "$entry" | "$SM_JQ" -r '.reason // ""')"
      m="$(printf '%s' "$entry" | "$SM_JQ" -r '(.runs // []) | length')"
      case "$m" in ''|*[!0-9]*) m=0 ;; esac
      j=0
      while [ "$j" -lt "$m" ]; do
        path="$(printf '%s' "$entry" | "$SM_JQ" -r ".runs[$j].path")"
        run_id="$(printf '%s' "$entry" | "$SM_JQ" -r ".runs[$j].run_id")"
        attempt="$(printf '%s' "$entry" | "$SM_JQ" -r ".runs[$j].attempt // 1")"
        green_attempt="$(printf '%s' "$SM_STATE_JSON" | "$SM_JQ" -r --arg p "$path" '(.observed[$p].attempt // "?")')"
        existing="$(grep -l -- "^title: flaky: $path " "$inbox"/*.md 2>/dev/null | head -1)"
        if [ -n "$existing" ]; then
          # append-only: the one edit a discovered note ever receives
          if printf -- '- PR #%s head %s run %s at %s\n' "$SM_PR" "$head" "$run_id" "$ts" >>"$existing" 2>/dev/null; then
            printf '[sweap-merge] flake: %s red then green on rerun again; appended to %s\n' "$path" "${existing#"$SM_PRIMARY"/}" >&2
          else
            printf '[sweap-merge] flake note append FAILED for %s (cannot write %s)\n' "$path" "$existing" >&2
          fi
        else
          title="flaky: $path went red then green on rerun for PR #$SM_PR ($reason)"
          body="$(printf '%s failed on PR #%s at head %s (run %s attempt %s, base %s), was rerun by hand (reason: %s) and went green on attempt %s of the same run with no change to the commit. Same code, two verdicts: a flake. Find the nondeterminism (test, runner, fixture) and fix or quarantine it; each further occurrence is appended below by sweap-merge.\n\n- PR #%s head %s run %s at %s' \
            "$path" "$SM_PR" "$head" "$run_id" "$attempt" "$base_sha" "$reason" "$green_attempt" "$SM_PR" "$head" "$run_id" "$ts")"
          sm_bounded "$bound" /bin/sh -c 'cd "$1" && exec "$2" "$3" discovered "$4" gap "$5" "$6" "$7"' sh \
            "$SM_PRIMARY" "$node" "$mjs" "$title" "PR #$SM_PR" "$body" "sweap-merge rerun"
          if [ "$BR_RC" = "0" ] && [ -n "$BR_OUT" ]; then
            printf '[sweap-merge] flake: %s red then green on rerun; filed %s\n' "$path" "$(sm_oneline "$BR_OUT")" >&2
          else
            printf '[sweap-merge] flake note FAILED for %s (rc=%s): %s\n' "$path" "$BR_RC" "$(sm_oneline "${BR_ERR:-$BR_OUT}")" >&2
          fi
        fi
        j=$((j + 1))
      done
      i=$((i + 1))
    done
  fi
  # mark every entry for this head so a second pass through green (a gate deny
  # and a later re-evaluation) never files or appends twice
  sm_set '.reruns = [ .reruns[] | if .head == $h and ((.flake_noted // false) | not) then .flake_noted = $v else . end ]' \
    --arg h "$head" --argjson v "$noted" || true
  sm_state_write || true
  return 0
}

# --- main -----------------------------------------------------------------------------------
sm_main() {
  local verb="${1:-}" pr="" budget="$SM_DEFAULT_BUDGET" a reason=""
  [ -n "$verb" ] || sm_usage
  shift
  case "$verb" in tick|watch|status|rerun) ;; *) sm_usage ;; esac
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --budget) [ "$verb" != "rerun" ] && [ $# -gt 0 ] || sm_usage; budget="$1"; shift
        printf '%s' "$budget" | grep -qE '^[0-9]+$' && [ "$budget" -ge 1 ] || sm_usage ;;
      --budget=*) [ "$verb" != "rerun" ] || sm_usage; budget="${a#--budget=}"; printf '%s' "$budget" | grep -qE '^[0-9]+$' && [ "$budget" -ge 1 ] || sm_usage ;;
      --reason) [ "$verb" = "rerun" ] && [ $# -gt 0 ] || sm_usage; reason="$1"; shift ;;
      --reason=*) [ "$verb" = "rerun" ] || sm_usage; reason="${a#--reason=}" ;;
      -*) sm_usage ;;   # no --repo/-R/--admin or anything else
      *) [ -z "$pr" ] || sm_usage; pr="$a" ;;
    esac
  done
  if [ "$verb" = "rerun" ]; then
    # a hand rerun carries its reason (the memo's rule); an empty one is a usage error
    reason="$(sm_oneline "$reason")"
    [ -n "$reason" ] || { printf 'usage: sweap-merge.sh rerun <pr> --reason "<why this red is believed to be a flake>"\n' >&2; exit 2; }
  fi
  if [ "$verb" != "status" ]; then
    printf '%s' "$pr" | grep -qE '^[0-9]+$' || sm_usage
  elif [ -n "$pr" ]; then
    printf '%s' "$pr" | grep -qE '^[0-9]+$' || sm_usage
  fi
  if ! sm_resolve_tools; then
    printf 'failed %s\n' "$SM_TOOL_ERR"; exit 1
  fi
  # the session's cwd, captured before anything resolves <primary>: the
  # post-merge hooks run here so cleanup's self-skip protects the live worktree
  SM_INVOKE_CWD="$(pwd -P 2>/dev/null)" || SM_INVOKE_CWD="$PWD"
  if ! sm_resolve_primary; then
    printf 'failed not inside a git repository (cannot resolve <primary>)\n'; exit 1
  fi
  case "$verb" in
    status) sm_status "$pr"; exit 0 ;;
    tick) sm_bind_pr "$pr"; sm_tick "$budget" ;;
    watch) sm_bind_pr "$pr"; sm_watch "$budget" ;;
    rerun) sm_bind_pr "$pr"; sm_rerun "$reason" ;;
  esac
}

if [ "${SWEAP_MERGE_LIB:-0}" != "1" ]; then
  sm_main "$@"
else
  sm_resolve_tools || true   # library callers get the pinned absolutes too (sm_main re-resolves)
fi
