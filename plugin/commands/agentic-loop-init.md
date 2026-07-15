---
description: Scaffold sweap's project-owned files (CLAUDE.md config, ROADMAP, justfile, .github) into this repo. Idempotent.
---

Copy each file under `${CLAUDE_PLUGIN_ROOT}/templates/` into the current project
at the same relative path, with these rules:

1. **Never overwrite.** For each template file, if the destination already
   exists, skip it and report "kept existing <path>". Only create missing files.
2. **CLAUDE.md merge:** if the project already has a `CLAUDE.md` but it lacks a
   `## sweap config` block, append the config block + standing-prefs section from
   the template rather than skipping the whole file. If a `## sweap config` block
   already exists, leave it.
3. **Red-flag gitignore rule:** `post-merge-redcheck.sh` writes a marker file at
   `.claude/main-red-<sha>.flag` and documents it as gitignored, so ensure the
   project's `.gitignore` actually excludes it:
   - If `.gitignore` exists and does not already contain the line
     `.claude/main-red-*.flag`, append it (on its own line).
   - If `.gitignore` exists and already contains that line, leave it unchanged
     (idempotent — never duplicate the line on re-run).
   - If no `.gitignore` exists, create one containing just that line.
4. After copying, print a checklist for the human:
   - Fill in the `verify.typecheck` / `verify.lint` / `verify.e2e` commands in
     the `## sweap config` block (`verify.e2e` must run the full automated test
     suite — unit + integration + e2e — it is the authoritative merge gate).
   - Fill in every `# <fill in for your stack>` stub in `justfile` (recipe
     bodies for `lint`, `typecheck`, `test`, `e2e`, and optionally
     `services-up`/`services-down`).
   - Fill in every `<fill in for your stack>` step in
     `.github/workflows/ci.yml` (toolchain setup, e2e prerequisites, optional
     `services:` blocks, the e2e artifact path).
   - Write `.github/scripts/ci-status.sh` and `.github/scripts/ci-summary.sh`
     to emit the JSON status-block convention documented in CLAUDE.md's CI
     section (or generate them via the `agentic-ci` skill).
   - Generate a `CLAUDE_CODE_OAUTH_TOKEN` repo secret (`claude setup-token`,
     then `gh secret set`) so `.github/workflows/claude-review.yml` runs.
   - Write the first ROADMAP milestone with `/roadmap`.
5. Report exactly which files were created, which were kept, and the fill-in
   TODOs above.

Do not commit — leave the scaffolded files staged-or-unstaged for the human to
review, since CI and verify commands are stack-specific and must be filled in
first.
