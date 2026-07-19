---
description: Scaffold sweap's project-owned files (CLAUDE.md config, ROADMAP index + roadmap/ items dir, justfile, .github) into this repo. Idempotent.
---

This project is normally auto-scaffolded on first session by the sweap plugin's
`SessionStart` hook (`hooks/scaffold.sh`) — you're running this command as the
explicit repair/re-run path (e.g. the hook didn't fire, files got deleted, or
you want to re-check for drift). It shares the exact same scaffold logic as the
hook, so there is only one implementation to keep correct.

Run the scaffold now:

```bash
"${CLAUDE_PLUGIN_ROOT}"/hooks/scaffold.sh <<< "$(printf '{"cwd":"%s","source":"init-command"}' "$PWD")"
```

This mechanically, idempotently:

1. **Never overwrites.** For each template file under
   `${CLAUDE_PLUGIN_ROOT}/templates/`, if the destination already exists in
   this project, it's skipped. Only missing files are created.
2. **CLAUDE.md merge:** if the project already has a `CLAUDE.md` but it lacks a
   `## sweap config` block, appends the template's `<!-- sweap:begin -->` …
   `<!-- sweap:end -->` region (playbook pointer + config block + standing-prefs,
   together, so the playbook pointer can never be dropped by the merge). If a
   `## sweap config` block already exists, leaves it — idempotent.
3. **Runtime gitignore rules:** ensures the project's `.gitignore` excludes both
   sweap runtime files — `post-merge-redcheck.sh`'s marker file
   (`.claude/main-red-*.flag`) and the coordinator's parallel-runs board
   (`.claude/sweap-board.md`) — appending each line only if missing, creating
   `.gitignore` if absent, never duplicated. The scaffold self-heals these on
   every session start (the gitignore step runs before the already-scaffolded
   fast-guard), so an existing project gains a newly-added rule on its next
   session; this command is the manual repair path.

Report back to the human exactly what the script's summary said it created,
kept, or merged. Then walk through this checklist regardless of what the
script reported (these are the fill-ins the script cannot do for you):
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
   - Write the first milestone with `/roadmap` (one file per item under
     `roadmap/`; the `ROADMAP.md` index lists milestones only).

Do not commit — leave the scaffolded files staged-or-unstaged for the human to
review, since CI and verify commands are stack-specific and must be filled in
first.
