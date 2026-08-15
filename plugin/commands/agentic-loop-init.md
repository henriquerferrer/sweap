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
3. **Audit-gate control (sweap-managed):** installs
   `.github/workflows/audit-gate.yml` plus the VENDORED gate scripts
   `.github/scripts/audit-gate.sh` and `.github/scripts/roadmap-lint.sh`, if the
   project has a `.github/workflows/` directory. Like the gitignore rules below,
   this runs BEFORE the already-scaffolded fast-guard, so a repo that adopted
   sweap before the audit gate existed gains it on its next session rather than
   never — that gap is exactly how a consumer repo ran for days with a malformed
   audit record and no check to catch it.
   Unlike every other scaffolded file these three are **kept current**, not just
   created: if the plugin's copy differs, the project's is rewritten. A consumer
   silently running an old gate is the bug this subsystem exists to fix. The
   gate is vendored (not checked out from sweap in CI) so the check needs no PAT
   and no cross-repo access — both repos being private would otherwise require a
   secret whose expiry would block every PR.
4. **Runtime gitignore rules:** ensures the project's `.gitignore` excludes both
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
   - **Decide how the audit gate is enforced — check the plan first.** Run
     `gh api repos/{owner}/{repo}/rulesets` to see which case you are in.
     - *403 "Upgrade to GitHub Pro"* (a private repo on Free — sweap's default
       assumption): rulesets and branch protection do not exist for you, and
       there is NOTHING to configure. Enforcement is `pre-merge-gate.sh`, which
       already denies any `gh pr merge` whose check rollup is not fully green,
       and `audit-gate` is now in that rollup. Tell the human plainly that a
       merge from the GitHub web UI bypasses the hook and is caught only after
       the fact by `post-merge-auditcheck.sh` — do not claim protection the
       plan cannot provide.
     - *Otherwise* (public, org, or Pro): make `audit-gate` a REQUIRED check
       pinned to the GitHub Actions app (id `15368`), never "any source". Do not
       add a required-review rule on a solo repo — you cannot approve your own
       PR and it wedges every merge.
     Either way keep the default `GITHUB_TOKEN` read-only. Path-protecting
     `.github/scripts/**` needs an org-scoped push ruleset and is not available
     to a personal repo — the scaffold's rewrite-on-drift is what covers those
     files instead.
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
