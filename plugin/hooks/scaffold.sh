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
#      (`.claude/main-red-*.flag`, `.claude/sweap-board.md`, `.claude/audit-debt-*.flag`), appending only the
#      lines that are missing (never duplicating, never overwriting), creating
#      `.gitignore` if absent. Because this precedes the fast-guard, projects
#      scaffolded before a rule existed still gain it on their next session.
#   3b. Required-workflow self-heal — also runs BEFORE the fast-guard, for the
#      same reason: install `.github/workflows/audit-gate.yml` into a repo that
#      already has `.github/workflows/` but predates that control. Never
#      overwrites, never creates the directory. Announces itself (a new required
#      check nobody knows about is not a control).
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
for gitignore_line in '.claude/main-red-*.flag' '.claude/sweap-board.md' '.claude/audit-debt-*.flag'; do
  if [ -f "$gi" ]; then
    if ! grep -qF "$gitignore_line" "$gi" 2>/dev/null; then
      printf '%s\n' "$gitignore_line" >> "$gi" 2>/dev/null && gitignore_action="appended"
    fi
  else
    printf '%s\n' "$gitignore_line" > "$gi" 2>/dev/null && gitignore_action="created"
  fi
done

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
tmpl="${plugin_root%/}/templates"

# --- 3b. Required-workflow self-heal (also BEFORE the fast-guard) ------------
# Same reasoning as the gitignore self-heal: a repo that adopted sweap before a
# control existed would otherwise never receive it, because the fast-guard below
# short-circuits every session after the first. That is exactly how a consumer
# repo ran for days with no audit-gate CI job while the playbook documented one
# (2026-08-11) — doctrine that ships as prose and not as scaffold is doctrine
# that does not run.
# Conservative: only heals a repo that ALREADY has .github/workflows/ (i.e. it
# uses GitHub Actions), never creates the directory, never overwrites.
#
# These files are SWEAP-MANAGED, not project-owned, so unlike everything else
# the scaffold touches they are kept CURRENT rather than merely created: if the
# plugin's copy differs, the project's copy is rewritten. That is the whole
# point — a control the consumer repo silently keeps an old copy of is the bug
# this whole subsystem exists to fix. Every rewrite is an ordinary working-tree
# change: visible in `git status`, diffable, and reviewed in the next PR.
# Customize via repo variables, never by editing these files.
#
# The gate is VENDORED (rather than checked out from sweap in CI) because both
# repos are private: a cross-repo checkout would need a PAT in every consumer
# repo, and a required check that dies on token expiry blocks every PR.
# roadmap-lint.sh travels with it — audit-gate.sh shells out to it when
# validating a disposition's follow-up item.
healed_workflows=()
sync_managed() { # sync_managed <src> <dest-rel> ; keeps dest byte-identical to src
  local src="$1" rel="$2" dest="$proj/$2" tmp
  [ -f "$src" ] || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  # Banner goes AFTER the shebang so the script stays directly executable.
  if IFS= read -r first < "$src" && case "$first" in '#!'*) true ;; *) false ;; esac; then
    { printf '%s\n' "$first"
      printf '# VENDORED BY SWEAP — do not edit. Kept byte-identical to the plugin\n'
      printf '# copy on every session start; local edits are overwritten.\n'
      tail -n +2 "$src"
    } > "$tmp" 2>/dev/null
  else
    cat "$src" > "$tmp" 2>/dev/null
  fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || { rm -f "$tmp"; return 0; }
  if cp "$tmp" "$dest" 2>/dev/null; then
    chmod +x "$dest" 2>/dev/null
    healed_workflows+=("$rel")
  fi
  rm -f "$tmp"
}
# Only for a repo that already uses GitHub Actions — never create .github itself.
if [ -d "$proj/.github/workflows" ] && [ -n "$plugin_root" ] && [ -d "$tmpl" ]; then
  sync_managed "$tmpl/.github/workflows/audit-gate.yml" ".github/workflows/audit-gate.yml"
  sync_managed "${plugin_root%/}/hooks/audit-gate.sh"   ".github/scripts/audit-gate.sh"
  sync_managed "${plugin_root%/}/hooks/roadmap-lint.sh" ".github/scripts/roadmap-lint.sh"
fi

# --- 4. Idempotency fast-guard ----------------------------------------------

if [ -f "$proj/CLAUDE.md" ] && grep -qF '## sweap config' "$proj/CLAUDE.md" 2>/dev/null; then
  # Already scaffolded. Stay silent UNLESS a self-heal above added something —
  # a new required check appearing unannounced is worse than no check at all,
  # because nobody knows to make it required in the ruleset.
  if [ "${#healed_workflows[@]}" -gt 0 ]; then
    heal_msg="sweap: installed/updated the audit-gate control in this repo — $(printf '%s, ' "${healed_workflows[@]}" | sed 's/, $//'). These are sweap-managed (vendored so CI needs no cross-repo access) and are kept byte-identical to the plugin's copies, so this fires both on first install and whenever the plugin's version changes. ACTION NEEDED: review the diff and commit it. Enforcement then depends on your GitHub plan: on a PRIVATE FREE repo, rulesets/branch protection are unavailable (the API 403s), and the enforcement is pre-merge-gate.sh, which already refuses any 'gh pr merge' whose check rollup is not fully green — audit-gate included — so no further setup is possible or needed; note a merge from the GitHub web UI bypasses that hook and is caught only after the fact by post-merge-auditcheck.sh. On a public/org/Pro repo, additionally make 'audit-gate' a REQUIRED check pinned to the GitHub Actions app (id 15368), never 'any source'. See the playbook's 'Enforcing the audit gate in CI' section."
    if [ "$have_jq" = "1" ]; then
      jq -n --arg ctx "$heal_msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$heal_msg"
    else
      printf '%s\n' "$heal_msg"
    fi
  fi
  exit 0
fi

# --- 5. Scaffold -------------------------------------------------------------

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

if [ "${#healed_workflows[@]}" -gt 0 ]; then
  msg="$msg Added missing required workflow(s): $(printf '%s, ' "${healed_workflows[@]}" | sed 's/, $//')."
fi

msg="$msg TODO before this is a working pipeline: (0) decide how the audit gate is ENFORCED: on a private Free repo rulesets are unavailable, so pre-merge-gate.sh (which requires an all-green check rollup) is the enforcement and there is nothing to configure; on a public/org/Pro repo make 'audit-gate' a REQUIRED check pinned to the GitHub Actions app (id 15368), never 'any source'; (1) fill in verify.typecheck / verify.lint / verify.e2e in CLAUDE.md's '## sweap config' block (verify.e2e must run the full suite — unit+integration+e2e); (2) fill in the '# <fill in for your stack>' recipe bodies in justfile (lint, typecheck, test, e2e, optionally services-up/services-down); (3) fill in the '<fill in for your stack>' steps in .github/workflows/ci.yml (toolchain setup, e2e prerequisites, e2e artifact path); (4) write the first milestone with /roadmap (one file per item under roadmap/ — see the playbook's 'Backlog format' section). Run /agentic-loop-init any time to re-run or repair the scaffold."

if [ "$have_jq" = "1" ]; then
  jq -n --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null || printf '%s\n' "$msg"
else
  printf '%s\n' "$msg"
fi

exit 0
