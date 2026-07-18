#!/usr/bin/env bash
#
# scaffold.sh — deterministic, idempotent scaffold of sweap's project-owned
# files (CLAUDE.md config, ROADMAP, justfile, .github). Mirrors the mechanical
# half of commands/agentic-loop-init.md; that command's checklist is the human
# fill-in half and now RUNS this same script for the mechanical part, so there
# is exactly one implementation.
#
# Wired as a SessionStart hook (see plugin.json) — fires on every session
# start (startup/resume/clear/compact). SessionStart BLOCKS session start, so
# this script must stay fast: the very first thing it does after resolving
# the project dir is an idempotency fast-guard that makes every session after
# the first a near-instant no-op.
#
# Contract: NEVER overwrite an existing file. NEVER fail the session — always
# exit 0, whether we scaffolded, no-opped, or hit an unexpected error.
#
# Behavior:
#   1. Resolve the project dir from $CLAUDE_PROJECT_DIR, falling back to the
#      `.cwd` field of the JSON payload on stdin. Silent no-op if empty.
#   2. Only scaffold a real project (has a `.git`) — never a random dir.
#   3. Gitignore self-heal — runs on EVERY session start, BEFORE the
#      fast-guard: ensure `.gitignore` excludes sweap's runtime files
#      (`.claude/main-red-*.flag`, `.claude/sweap-board.md`), appending only the
#      lines that are missing (never duplicating, never overwriting), creating
#      `.gitignore` if absent. Because this precedes the fast-guard, projects
#      scaffolded before a rule existed still gain it on their next session.
#   4. Fast-guard: if CLAUDE.md exists and already has a `## sweap config`
#      block, this project is already scaffolded — exit 0 immediately, no
#      output, nothing else touched (the gitignore self-heal in step 3 has
#      already run).
#   5. Otherwise copy every file under templates/ to the same relative path,
#      skipping any destination that already exists (track what's created).
#      If CLAUDE.md already existed (so it was skipped) and lacks
#      `## sweap config`, append the template's appendable region (delimited
#      by `<!-- sweap:begin -->` / `<!-- sweap:end -->` in
#      templates/CLAUDE.md) — this carries the playbook pointer + config
#      block + standing-prefs together, so the merge can never drop the
#      playbook pointer.
#   6. Emit a SessionStart `additionalContext` JSON message (falls back to
#      plain stdout if jq is unavailable) summarizing what happened and the
#      human fill-in TODOs.

set -uo pipefail

# --- 1. Resolve project dir -------------------------------------------------

input="$(cat 2>/dev/null || true)"

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

proj="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$proj" ]; then
  if [ "$have_jq" = "1" ]; then
    proj="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
  else
    # No jq: best-effort naive extraction of "cwd":"..." from the JSON payload.
    proj="$(printf '%s' "$input" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  fi
fi

[ -n "$proj" ] || exit 0
[ -d "$proj" ] || exit 0

# --- 2. Only scaffold a real project ---------------------------------------

[ -e "$proj/.git" ] || exit 0

# --- 3. Gitignore self-heal (runs BEFORE the fast-guard) --------------------
# Ensure sweap's runtime files are excluded, never duplicated. This runs on
# EVERY session start, ahead of the already-scaffolded fast-guard below, so that
# projects scaffolded before a rule was added (e.g. the sweap-board entry) still
# gain it on their next session — a fast-guard exit would otherwise skip it. Only
# depends on $proj + the .git check above. Idempotent: grep-before-append, never
# duplicate, never overwrite. Silent (the summary in step 6 is only reached on
# the full-scaffold path; on the fast-guard path this heals quietly and exits 0).
gitignore_action="unchanged"
gi="$proj/.gitignore"
for gitignore_line in '.claude/main-red-*.flag' '.claude/sweap-board.md'; do
  if [ -f "$gi" ]; then
    if ! grep -qF "$gitignore_line" "$gi" 2>/dev/null; then
      printf '%s\n' "$gitignore_line" >> "$gi" 2>/dev/null && gitignore_action="appended"
    fi
  else
    printf '%s\n' "$gitignore_line" > "$gi" 2>/dev/null && gitignore_action="created"
  fi
done

# --- 4. Idempotency fast-guard ----------------------------------------------

if [ -f "$proj/CLAUDE.md" ] && grep -qF '## sweap config' "$proj/CLAUDE.md" 2>/dev/null; then
  exit 0
fi

# --- 5. Scaffold -------------------------------------------------------------

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
tmpl="${plugin_root%/}/templates"
[ -n "$plugin_root" ] && [ -d "$tmpl" ] || exit 0

existing_claude_md=0
[ -f "$proj/CLAUDE.md" ] && existing_claude_md=1

created=()
kept=()

while IFS= read -r -d '' f; do
  rel="${f#"$tmpl"/}"
  dest="$proj/$rel"
  if [ -e "$dest" ]; then
    kept+=("$rel")
    continue
  fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || continue
  cp "$f" "$dest" 2>/dev/null && created+=("$rel")
done < <(find "$tmpl" -type f -print0 2>/dev/null)

merged_claude_md=0
if [ "$existing_claude_md" = "1" ] && ! grep -qF '## sweap config' "$proj/CLAUDE.md" 2>/dev/null; then
  region="$(awk '/<!-- sweap:begin -->/{flag=1;next} /<!-- sweap:end -->/{flag=0} flag' "$tmpl/CLAUDE.md" 2>/dev/null)"
  if [ -n "$region" ]; then
    { printf '\n'; printf '%s\n' "$region"; } >> "$proj/CLAUDE.md" 2>/dev/null && merged_claude_md=1
  fi
fi

# --- 6. Emit summary ---------------------------------------------------------

msg="sweap: scaffolded project files on first session (auto-run by the SessionStart hook)."

if [ "${#created[@]}" -gt 0 ]; then
  msg="$msg Created: $(printf '%s, ' "${created[@]}" | sed 's/, $//')."
fi
if [ "$merged_claude_md" = "1" ]; then
  msg="$msg Merged sweap config + playbook pointer into your existing CLAUDE.md."
fi
if [ "$gitignore_action" != "unchanged" ]; then
  msg="$msg .gitignore: $gitignore_action sweap runtime ignore rules (.claude/main-red-*.flag, .claude/sweap-board.md)."
fi

msg="$msg TODO before this is a working pipeline: (1) fill in verify.typecheck / verify.lint / verify.e2e in CLAUDE.md's '## sweap config' block (verify.e2e must run the full suite — unit+integration+e2e); (2) fill in the '# <fill in for your stack>' recipe bodies in justfile (lint, typecheck, test, e2e, optionally services-up/services-down); (3) fill in the '<fill in for your stack>' steps in .github/workflows/ci.yml (toolchain setup, e2e prerequisites, e2e artifact path); (4) write the first ROADMAP milestone with /roadmap. Run /agentic-loop-init any time to re-run or repair the scaffold."

if [ "$have_jq" = "1" ]; then
  jq -n --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$msg"
else
  printf '%s\n' "$msg"
fi

exit 0
