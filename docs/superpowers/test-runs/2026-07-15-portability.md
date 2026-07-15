# Task 10 — Automated integrity sweep + live-acceptance runbook

**Date:** 2026-07-15
**Scope:** Task 10's automated portion (everything that can run headlessly against
the built plugin, Tasks 1-9). Steps 1-2 of the task brief (installing into a scratch
clone of consumer A; a real throwaway repo + GitHub CI + supervised `/goal` run) require
an interactive Claude Code session, a real `gh` remote, and live `gh pr merge` calls —
they are **not** run in this pass. Section 2 below is the runbook Henrique follows to
do that live run and fill in the acceptance checklist.

---

## 1. Automated verification (Part A) — results

**Overall: 6 PASS, 1 FAIL.** The FAIL is a real bug (not fixed by this pass — see
"Finding" below); the controller decides how to handle it.

> **Closed out (2026-07-15):** commit `fcd846e` ("fix: quote frontmatter
> descriptions with colon-space across all command/skill/agent files") fixed
> `plugin/commands/roadmap.md`'s `description:` by quoting it, the same fix
> `b0e92ee` applied to `security-reviewer.md`. All 10 frontmatter files listed
> in the table below (9 shown here + the renamed `agentic-loop-init.md`) now
> parse cleanly with `yaml.safe_load`. The automated sweep in this section is
> now **fully green (7/7 PASS)** — no outstanding FAIL remains from Part A.

### 1. Manifests parse; marketplace source

```
$ jq . .claude-plugin/marketplace.json plugin/plugin.json
```
Both parsed without error. `.claude-plugin/marketplace.json` → `plugins[0].source ==
"./plugin"`. **PASS.**

### 2. Frontmatter parses (commands, skills, agents) — **FAIL**

Extracted the `---`-delimited frontmatter from every file under
`plugin/commands/*.md`, `plugin/skills/**/SKILL.md`, `plugin/agents/*.md` and ran
`yaml.safe_load` on it (PyYAML). Checked `description` present everywhere, and for
agents/skills that `name:` is present and matches the dir/file.

| File | Result |
|---|---|
| `plugin/agents/reviewer.md` | PASS — name=`reviewer` |
| `plugin/agents/security-reviewer.md` | PASS — name=`security-reviewer` |
| `plugin/agents/ui-critic.md` | PASS — name=`ui-critic` |
| `plugin/commands/agentic-loop-init.md` (named `init.md` at the time of this pass; renamed post-launch to avoid colliding with Claude Code's builtin `/init` — see the whole-branch review's Fix 1) | PASS — description present (commands have no `name:` field by Claude Code convention; the command name is the filename) |
| `plugin/commands/loop-schedule.md` | PASS |
| `plugin/commands/milestone-audit.md` | PASS |
| `plugin/commands/milestone.md` | PASS |
| **`plugin/commands/roadmap.md`** | **FAIL — invalid YAML** |
| `plugin/skills/milestone-cross-check/SKILL.md` | PASS — name=`milestone-cross-check` |
| `plugin/skills/ui-design/SKILL.md` | PASS — name=`ui-design` |

**Finding (real bug, not fixed):** `plugin/commands/roadmap.md`'s frontmatter fails
`yaml.safe_load`:

```
description: Brainstorm the next milestone into ROADMAP items (3-phase: decide → cross-check → reconcile).
```

```
$ python3 -c "import yaml; yaml.safe_load(open('plugin/commands/roadmap.md').read().split('---')[1])"
yaml.scanner.ScannerError: mapping values are not allowed here
  in "<unicode string>", line 1, column 71:
     ... tone into ROADMAP items (3-phase: decide → cross-check → reconcile).
                                         ^
```

The unquoted `description:` value contains a bare `: ` (colon-space) inside
`(3-phase: decide → ...)`, which YAML parses as a nested mapping key — invalid in a
plain scalar. This is the **exact same failure class** already caught and fixed once
in this repo: commit `b0e92ee` ("fix: quote security-reviewer.md description (invalid
YAML frontmatter)") fixed an identical issue by wrapping the description in double
quotes. That fix was never generalized/re-checked across the other command files, and
`roadmap.md` (introduced in `4960888`, "feat: generalized /roadmap and /milestone
commands") has the same defect, unfixed. `argument-hint` in the same file is
correctly quoted, which is presumably why this one was missed.

This was **not fixed** as part of this task (see task instructions: a real
integration bug found during the sweep is reported, not silently patched). The
one-line fix is to quote the description exactly as `b0e92ee` did for
`security-reviewer.md`.

**Update (2026-07-15):** fixed in commit `fcd846e`. Re-running the same
`yaml.safe_load` sweep against every frontmatter file confirms `roadmap.md`
now parses; this row is superseded — see the closing note in §1 above.

### 3. Workflow: `node --check`

```
$ node --check plugin/workflows/milestone-audit.js
```
No output, exit 0. **PASS.**

### 4. Hooks test

```
$ bash plugin/hooks/pre-merge-gate.test.sh
...
RESULT: 56 passed, 0 failed
```
All 56 sub-tests passed (branch coverage, adversarial detector-evasion, chained
multi-PR merges, inherited-flag parsing, fail-closed compound constructs, and the
`post-merge-redcheck.sh` backstop). Two `dirname: command not found` / missing
`lib-merge-parse.sh` stderr lines appear mid-run — these are the test harness
deliberately stripping `dirname` from `PATH` for cases `e5`/`e6` (parser-lib-missing,
fail-closed behavior); both associated assertions still report PASS and the run's
own tally confirms 0 failed. **PASS.**

### 5. Scaffold + idempotency

Copied `plugin/templates/.` into a fresh `mktemp -d`. All 5 files landed:
`CLAUDE.md`, `ROADMAP.md`, `justfile`, `.github/workflows/ci.yml`,
`.github/workflows/claude-review.yml`.

Second-pass idempotency: appended a marker line to two destination files
(`ROADMAP.md`, `justfile`), hashed all 5 files, re-ran a never-overwrite copy
(`rsync -a --ignore-existing` — simulating the "never overwrite existing files"
policy documented in `plugin/commands/agentic-loop-init.md`, since
`/agentic-loop-init` is an LLM-driven prompt-command, not an executable this
sweep can invoke directly), and re-hashed.
All 5 hashes were identical before/after, and both markers were still present
(`grep -c "CUSTOM MARKER"` → 1 in each file, not duplicated or clobbered).
**PASS.** (Caveat: this exercises the documented no-clobber contract via a policy
equivalent, not a literal run of the `/agentic-loop-init` slash command itself,
since that requires a live agent session.)

### 6. Domain-token sweep

```
$ grep -rniE 'consumer A|clinic|patient|workerd|wsproxy' plugin/
plugin/hooks/post-merge-redcheck.sh:119:    osascript -e "display notification \"PR #$pr merged with RED checks: $red\" with title \"consumer A: main is RED\"" >/dev/null 2>&1 || true
```
Exactly one hit, and it is the known, intentional cosmetic leak flagged in the Task 2
brief/report: the byte-for-byte ported hook string `"consumer A: main is RED"` used only
as a macOS notification title, left unchanged because the hook is a verbatim port and
"do not improve the hooks during the port" is a standing rule. No other domain-token
leak anywhere else in `plugin/`. **PASS** (one expected, already-triaged cosmetic
item; zero unexpected leaks).

### 7. Cross-file consistency

**a. Verdict string.** `plugin/agents/reviewer.md` emits `Verdict: approve` or
`Verdict: needs-work` as the mandated final line (lines 85/91, description at line 3
calls out "a required verdict line that the merge-gate CI check greps"). The gate in
`plugin/templates/.github/workflows/claude-review.yml` greps
`Verdict:[[:space:]]*approve` / `Verdict:[[:space:]]*needs-work` (lines 92/94), plus a
fail-closed `else` branch when no verdict is found (line 98). Tokens match exactly.
**PASS.**

**b. Skill references resolve.** `plugin/commands/roadmap.md` references the
`milestone-cross-check` skill; `plugin/playbook/agentic-loop-playbook.md` references
both `milestone-cross-check` (roadmap brainstorm cross-check, milestone-boundary
step) and `ui-design` (UI build/audit). Both exist:
`plugin/skills/milestone-cross-check/SKILL.md`, `plugin/skills/ui-design/SKILL.md`.
**PASS.**

**c. Config keys consistent.** Compared the playbook's "How this project is
configured" section (lines 14-43) against the `## sweap config` block in
`plugin/templates/CLAUDE.md`:

| Key | Playbook default | Template default |
|---|---|---|
| `verify.typecheck` | none (project-specific) | placeholder `<your typecheck cmd>` |
| `verify.lint` | none (project-specific) | placeholder `<your lint cmd>` |
| `verify.e2e` | none (project-specific, authoritative gate) | placeholder `<your e2e cmd>` |
| `backlog.file` | `ROADMAP.md` | `ROADMAP.md` |
| `backlog.prefix` | `F` | `F` |
| `services.up` | omit if none | commented out (`# services.up: ...`) |
| `audit.lenses` | `default` (3 modes documented) | `default` |
| `review.dimensions` | `security, ui, migration` | `security, ui, migration` |
| `notify` | `push` | `push` |
| `turns.default` | `160` | `160` |

All keys and stated defaults match. **PASS.**

**d. Audit lenses match.** `DEFAULT_LENSES` in `plugin/workflows/milestone-audit.js`
(lines 50-57): `correctness, authz, data-integrity, concurrency, test-integrity,
api-contract`. The playbook's config section (line 30-32) names the same six as the
generic default lens set. **PASS.**

**e. Playbook discoverability — assessment, not fixed.** Commands
(`/milestone`, `/roadmap`, `/milestone-audit`, `/loop-schedule`) all explicitly read
`${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md` — that resolution is
correct and unambiguous **when a slash command runs inside a session with the sweap
plugin loaded**. However `plugin/templates/CLAUDE.md` (the file a consuming project
actually keeps in its own repo, and the one a human or a plain non-plugin session is
most likely to open first) only says:

> **Read the sweap playbook before any feature work:** it defines the operating
> model...

with no literal path. `${CLAUDE_PLUGIN_ROOT}` is not meaningful outside an active
Claude Code session with the plugin installed, and the playbook is never copied into
the consuming project's own tree (only `CLAUDE.md`, `ROADMAP.md`, `justfile`,
`.github/*` are scaffolded by `/agentic-loop-init`). This matches the open question already raised
in the Task 5 report ("if a later task instead copies the playbook into the consuming
project... this path reference should be reconciled"). Net effect: a session that
opens the scaffolded `CLAUDE.md` without first invoking a sweap slash command has no
concrete pointer to where the playbook physically lives. Reporting per the brief's
instruction to assess, not fix.

---

## 2. Split: automated vs. pending human live-run

**Automated verification (this pass, done):** manifest/frontmatter/workflow syntax,
hook unit tests, scaffold+idempotency, domain-token sweep, cross-file consistency
(verdict string, skill refs, config keys, audit lenses, playbook-path assessment).

**Pending human live-run (cannot be done headlessly):** parity install into a scratch
clone of consumer A; a real throwaway repo with GitHub remote + Actions CI + a supervised
`/goal` run exercising the full per-feature loop end-to-end, including live `gh pr
merge` calls. Runbook below.

---

## 3. Live-acceptance runbook

### 3a. Parity — install into consumer A

1. Make a scratch clone: `git clone ~/Documents/consumer-a /tmp/consumer-a-parity && cd
   /tmp/consumer-a-parity`.
2. In an interactive Claude Code session in that clone, run `/plugin marketplace add
   ~/Documents/sweap` (or the appropriate local-marketplace path), then `/plugin
   install sweap`.
3. Move consumer A's own local `.claude/commands` and `.claude/hooks` aside (e.g. `mv
   .claude/commands .claude/commands.bak && mv .claude/hooks .claude/hooks.bak`) so
   only the plugin's copies are active. Do **not** delete — this is a parity check,
   not a migration.
4. Run one real `/milestone` pre-flight (no argument, so it resolves the next
   runnable milestone from consumer A's actual `ROADMAP.md`). Confirm:
   - the resolved milestone number matches what consumer A's own `/milestone` would
     produce (same `backlog.prefix`/`backlog.file` resolution logic, same next
     unblocked milestone),
   - the printed ready-to-paste `/goal` line matches consumer A's own phrasing/shape,
   - trigger the merge-gate: attempt (or simulate, per the hook's own test harness
     pattern) a `gh pr merge` on a fabricated non-green PR and confirm
     `pre-merge-gate.sh` still denies it identically to consumer A's original hook
     (byte-identical script, so this should be a formality, but confirm the
     `${CLAUDE_PLUGIN_ROOT}` wiring in `plugin.json` actually fires the hook in this
     installed context).
5. Restore consumer A's local files: `mv .claude/commands.bak .claude/commands && mv
   .claude/hooks.bak .claude/hooks`. Do not leave consumer A in the plugin-only state.

### 3b. Portability — fresh throwaway repo

1. `mkdir /tmp/sweap-portability && cd /tmp/sweap-portability && git init`.
2. `gh repo create <you>/sweap-portability --private --source=. --remote=origin`
   (or a local-only remote stub if `gh` auth/quota is a concern — but a real GitHub
   remote is needed to exercise the CI + `claude-review.yml` + `pre-merge-gate`
   PR-merge path for real).
3. In an interactive Claude Code session in that repo: `/plugin install sweap`, then
   `/agentic-loop-init` (this name is now final — the command file was briefly
   named plain `init.md`, which collided with Claude Code's own builtin
   `/init`; see the whole-branch review's Fix 1, which renamed the command
   file under `plugin/commands/` to its current, non-colliding name) to
   scaffold `CLAUDE.md`, `ROADMAP.md`, `justfile`,
   `.github/workflows/{ci,claude-review}.yml`.
4. Fill in the `## sweap config` block's `verify.*` commands with trivial,
   fast-running values for a minimal Node project: e.g. `verify.typecheck: true`
   (no-op), `verify.lint: true`, `verify.e2e: npm test` where `npm test` runs one
   real unit test plus a placeholder e2e step that always passes. Keep
   `backlog.file`/`backlog.prefix`/`audit.lenses`/`review.dimensions`/`notify`/
   `turns.default` at their scaffolded defaults.
5. Author a 2-item `ROADMAP.md` milestone: one straightforward item, one
   **deliberately ambiguous** item (missing acceptance criteria or a contradictory
   requirement) to exercise the escalate-don't-guess path.
6. Run `/milestone` to get the pre-flight + ready `/goal` line, paste it, and
   supervise the run to completion (or to the turn bound).
7. Deliberately author (or find) at least one PR in a **red** state (failing
   `verify.e2e`) and attempt `gh pr merge` on it to confirm `pre-merge-gate` blocks
   it; then get it green and merge for real to confirm the same PR is allowed once
   green. Both directions must be observed live, not just via the unit test (which
   already covers this in isolation — this is confirming the wiring end-to-end in a
   real repo).
8. **Unverified hook-schema field — assert it during this live run.**
   `plugin/plugin.json`'s `PostToolUse` entry for `post-merge-cleanup.sh` sets
   `"if": "Bash(gh pr merge:*)"` so the cleanup hook only fires on a real merge
   command, not on every `Bash` call. This `if` key's exact matching semantics
   are not independently confirmed anywhere in this repo's automated checks
   (the hook test harness stubs the script directly; it does not exercise the
   loader's own conditional-dispatch behavior). During the real merge in step 7,
   explicitly confirm: (a) `post-merge-cleanup.sh` actually runs after `gh pr
   merge` and only after it — not after unrelated `Bash` calls earlier in the
   session — and (b) it is honored by the Claude Code hook loader as gating
   dispatch, not merely present-but-ignored. If the loader does **not** honor
   `if` as a dispatch gate (e.g. it fires the hook unconditionally and relies on
   the hook script itself to no-op), then `post-merge-cleanup.sh` should be
   made to self-gate (re-derive and check the `gh pr merge` condition inside the
   script, the way `post-merge-redcheck.sh` already does via
   `parse_merge_command`) rather than relying on the untrusted `if` field.

### 3c. Acceptance checklist (spec §5)

Mark each `[automated-covered]` (already verified by this pass's static/unit checks,
no further live evidence needed) or `[needs-live-run]` (only a live interactive
session with a real PR/merge/worktree can confirm it):

- [needs-live-run] **worktree isolation** (no commits on `main`) — requires watching
  a real implementer session create/use a worktree; nothing to check statically.
- [needs-live-run] **TDD Evidence present in the implementer report** (RED + GREEN
  output) — this is a property of a specific transcript, not checkable from the repo
  at rest.
- [needs-live-run] **fresh-context review dispatched; review-skip guard holds** —
  requires observing an actual dispatch and, ideally, a deliberate attempt to skip
  review to confirm the guard fires.
- [automated-covered] **`pre-merge-gate` blocks a red PR and allows a green one** —
  the 56-case unit suite (`pre-merge-gate.test.sh`) already exercises both directions
  exhaustively with faked `gh` output, including adversarial evasion attempts. A
  live confirmation (3b step 7) is still valuable as an end-to-end wiring check but
  the gating logic itself is already proven.
- [needs-live-run] **`post-merge-cleanup` removed the worktree + branch** — requires
  a real merge event to fire the `PostToolUse` hook and observing the filesystem/
  branch state after.
- [needs-live-run] **`/milestone-audit` fired at the boundary and reported
  finder→refuter findings** — `node --check` only proves the Workflow script is
  syntactically valid; the finder/refuter majority-survives behavior is only provable
  by running it against a real merged milestone.
- [needs-live-run] **a deliberately-ambiguous item routed to `[blocked]` +
  notification, not a guess** — behavioral property of a live run against the
  ambiguous ROADMAP item authored in 3b step 5.

**Tally:** 1 of 7 checklist items is already covered by this pass's automated
evidence (the merge-gate direction, via the existing unit suite); the remaining 6
require the live sessions in 3a/3b to close out.

---

## 4. Summary

Part A: 6 PASS, 1 FAIL. The FAIL — `plugin/commands/roadmap.md` has invalid YAML
frontmatter (unquoted `description:` containing a bare `: `) — is a genuine,
previously-seen-and-fixed-elsewhere bug (see commit `b0e92ee`, which fixed the
identical issue in `security-reviewer.md` but the fix was never generalized/
re-swept across other command files). It was **not fixed** in this pass; flagged for
the controller. One additional non-blocking assessment: the plain-CLAUDE.md pointer
to the playbook has no literal path, a known open question from Task 5, not fixed
here per the brief's "assess, don't fix" instruction for this item.

Everything else that can be checked headlessly — manifests, workflow syntax, the
56-case hook test suite, scaffold+idempotency, the domain-token sweep, and all four
other cross-file consistency checks — passes cleanly.
