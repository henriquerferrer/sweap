# sweap Agentic-Pipeline Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package consumer A's agentic-dev loop as an installable private Claude Code plugin (marketplace + one-time init scaffold) that any of Henrique's projects can adopt.

**Architecture:** One git repo (`~/Documents/sweap`) is both a plugin marketplace and the plugin. Domain-free logic (playbook, commands, hooks, skills, agents, audit workflow) ships in the plugin and auto-updates via `git pull`; per-project files a plugin cannot author (CLAUDE.md config, ROADMAP, justfile, `.github`) are seeded once by `/agentic-loop-init`. Project specifics are declared in a fenced config block in each project's CLAUDE.md; commands read it and fall back to baked defaults.

**Tech Stack:** Claude Code plugin format (`marketplace.json`, `plugin.json`), bash hooks (`gh` + `jq`), a JS Workflow script, Markdown command/skill/agent/playbook files.

**Source of truth for all ports:** `~/Documents/consumer-a`. The design spec is `docs/superpowers/specs/2026-07-15-sweap-agentic-pipeline-plugin-design.md`.

## Global Constraints

- Plugin repo root: `~/Documents/sweap`. All plugin content lives under `plugin/`; the marketplace manifest under `.claude-plugin/`.
- Hook scripts are copied **byte-for-byte** from consumer A (they are already domain-free). Only their **wiring** changes: from `settings.json` `$CLAUDE_PROJECT_DIR/.claude/hooks/X` to `plugin.json` hooks referencing `${CLAUDE_PLUGIN_ROOT}/hooks/X`.
- "Genericizing" = copy the consumer A original, then replace each domain token (`consumer-a`, `clinic`, `patient`, `workerd`, `wsproxy`, `tenancy`/`RLS` used as *the* example, `pnpm check-types`/`pnpm test:e2e`, hardcoded `F` milestone prefix) with a **config read** or a **baked default**. Keep every mechanism; change only domain specifics.
- Config is read from a fenced block in the consuming project's `CLAUDE.md` headed `## sweap config`. Absent keys fall back to baked defaults documented in the playbook.
- Baked standing prefs that must survive every port: worktree isolation, PR-by-default, **TDD Evidence required** (implementer pastes RED + GREEN output), review-skip guards, escalate-don't-guess, never-weaken-the-gate.
- Commit after every task. Commit messages end with the Co-Authored-By trailer used in this repo.
- This repo has **no remote and no CI yet**; commits go directly to the default branch (bootstrapping). The worktree/PR discipline this plugin *ships* is for its consumer projects, not for building the plugin itself.

---

## File Structure

```
sweap/
├── .claude-plugin/
│   └── marketplace.json              # Task 1
├── plugin/
│   ├── plugin.json                   # Task 1 (hooks wired in Task 2)
│   ├── playbook/
│   │   └── agentic-loop-playbook.md  # Task 3
│   ├── hooks/
│   │   ├── lib-merge-parse.sh        # Task 2 (verbatim)
│   │   ├── pre-merge-gate.sh         # Task 2 (verbatim)
│   │   ├── pre-merge-gate.test.sh    # Task 2 (verbatim)
│   │   ├── post-merge-cleanup.sh     # Task 2 (verbatim)
│   │   └── post-merge-redcheck.sh    # Task 2 (verbatim)
│   ├── commands/
│   │   ├── init.md                   # Task 4  (/agentic-loop-init)
│   │   ├── roadmap.md                # Task 5
│   │   ├── milestone.md              # Task 5
│   │   ├── milestone-audit.md        # Task 6
│   │   └── loop-schedule.md          # Task 9
│   ├── workflows/
│   │   └── milestone-audit.js        # Task 6
│   ├── skills/
│   │   ├── milestone-cross-check/SKILL.md   # Task 7
│   │   └── ui-design/SKILL.md               # Task 7
│   ├── agents/
│   │   ├── reviewer.md               # Task 8
│   │   ├── security-reviewer.md      # Task 8
│   │   └── ui-critic.md              # Task 8
│   └── templates/                    # Task 4 (scaffolded by /agentic-loop-init)
│       ├── CLAUDE.md
│       ├── ROADMAP.md
│       ├── justfile
│       └── .github/workflows/
│           ├── ci.yml
│           └── claude-review.yml
├── README.md                         # Task 1
└── .gitignore                        # Task 1
```

---

### Task 1: Repo skeleton + plugin/marketplace manifests

**Files:**
- Create: `.claude-plugin/marketplace.json`
- Create: `plugin/plugin.json`
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- Produces: a loadable plugin named `sweap`. Later tasks add `commands/`, `skills/`, `hooks/`, `workflows/`, `agents/`, `playbook/`, `templates/` under `plugin/`.

- [ ] **Step 1: Write `.claude-plugin/marketplace.json`**

```json
{
  "name": "sweap",
  "owner": { "name": "Henrique" },
  "metadata": { "description": "SWE Agentic Pipeline — consumer A's agentic-dev loop, installable." },
  "plugins": [
    {
      "name": "sweap",
      "source": "./plugin",
      "description": "Agentic-dev pipeline: per-feature loop, merge gate, roadmap/milestone/audit commands, cron driver."
    }
  ]
}
```

- [ ] **Step 2: Write `plugin/plugin.json`** (hooks array is filled in Task 2; start with an empty object so the manifest is valid now)

```json
{
  "name": "sweap",
  "version": "0.1.0",
  "description": "SWE Agentic Pipeline — per-feature loop, merge-greenness gate, roadmap/milestone/audit, cron driver.",
  "author": { "name": "Henrique" }
}
```

- [ ] **Step 3: Write `.gitignore`**

```
node_modules/
.DS_Store
*.log
.claude/main-red-*.flag
```

- [ ] **Step 4: Write `README.md`** with install instructions (once-per-machine marketplace add, per-project install + init) copied from the spec's Section 1 "Install" list. Keep it to ~20 lines.

- [ ] **Step 5: Verify the plugin loads**

Run: `claude` → `/plugin marketplace add ~/Documents/sweap` → `/plugin install sweap` → `/plugin`
Expected: `sweap` appears in the installed-plugins list with no manifest error. (If run headless, instead validate JSON: `jq . .claude-plugin/marketplace.json plugin/plugin.json` exits 0.)

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin plugin/plugin.json README.md .gitignore
git commit -m "feat: plugin + marketplace skeleton"
```

---

### Task 2: Port the merge-gate hooks (verbatim) + wire via plugin.json

**Files:**
- Create (byte copy from consumer A): `plugin/hooks/lib-merge-parse.sh`, `plugin/hooks/pre-merge-gate.sh`, `plugin/hooks/post-merge-cleanup.sh`, `plugin/hooks/post-merge-redcheck.sh`
- Create (byte copy): `plugin/hooks/pre-merge-gate.test.sh`
- Modify: `plugin/plugin.json` (add `hooks`)

**Interfaces:**
- Consumes: nothing (hooks self-source `lib-merge-parse.sh` via `$(dirname "${BASH_SOURCE[0]}")`, which is location-independent — no repathing needed inside the scripts).
- Produces: a `PreToolUse(Bash)` deny on non-green / `--admin` / `--repo` `gh pr merge`; `PostToolUse(Bash)` cleanup + red-main backstop.

- [ ] **Step 1: Copy the five hook files verbatim**

```bash
cp ~/Documents/consumer-a/.claude/hooks/lib-merge-parse.sh      plugin/hooks/
cp ~/Documents/consumer-a/.claude/hooks/pre-merge-gate.sh       plugin/hooks/
cp ~/Documents/consumer-a/.claude/hooks/pre-merge-gate.test.sh  plugin/hooks/
cp ~/Documents/consumer-a/.claude/hooks/post-merge-cleanup.sh   plugin/hooks/
cp ~/Documents/consumer-a/.claude/hooks/post-merge-redcheck.sh  plugin/hooks/
chmod +x plugin/hooks/*.sh
```

- [ ] **Step 2: Confirm the scripts contain no project-path assumptions**

Run: `grep -n 'CLAUDE_PROJECT_DIR\|/Documents/consumer-a\|\.claude/hooks' plugin/hooks/*.sh`
Expected: no matches. (The sourcing line uses `BASH_SOURCE`, not `CLAUDE_PROJECT_DIR`.) If `post-merge-cleanup.sh` or `post-merge-redcheck.sh` reference `.claude/` paths for the red-flag marker, that is a *project*-relative runtime path (correct — the flag lands in the consumer repo), leave it.

- [ ] **Step 3: Run the ported hook test to verify it still passes**

Run: `bash plugin/hooks/pre-merge-gate.test.sh`
Expected: all assertions pass (same output as in consumer A). This is the TDD anchor for the port — a byte-identical script under an unchanged test must stay green.

- [ ] **Step 4: Wire the hooks into `plugin/plugin.json`** using `${CLAUDE_PLUGIN_ROOT}` (mirrors consumer A `settings.json`, repathed for the plugin)

```json
{
  "name": "sweap",
  "version": "0.1.0",
  "description": "SWE Agentic Pipeline — per-feature loop, merge-greenness gate, roadmap/milestone/audit, cron driver.",
  "author": { "name": "Henrique" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-merge-gate.sh", "timeout": 25 }
      ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "if": "Bash(gh pr merge:*)", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-merge-cleanup.sh 2>/dev/null || true", "timeout": 30 },
        { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-merge-redcheck.sh", "timeout": 25 }
      ] }
    ]
  }
}
```

- [ ] **Step 5: Verify hook wiring is honored by the plugin loader**

Run: install the plugin (as Task 1 Step 5) into a scratch repo, then attempt a fake merge: `gh pr merge 999999 --admin` (a non-existent PR with a banned flag).
Expected: the command is **denied** with the `--admin` refusal message — proving the PreToolUse hook fires from the plugin.
**If plugins do NOT auto-apply `plugin.json` hooks** (the spec's flagged risk): fall back to emitting the same hook block into the consumer's `.claude/settings.json` from `/agentic-loop-init` (Task 4), pointing at `${CLAUDE_PLUGIN_ROOT}`. Record which path was used in the README.

- [ ] **Step 6: Commit**

```bash
git add plugin/hooks plugin/plugin.json
git commit -m "feat: port merge-gate hooks (verbatim) + plugin hook wiring"
```

---

### Task 3: Generalize the playbook

**Files:**
- Create: `plugin/playbook/agentic-loop-playbook.md` (copy of consumer A's, genericized)

**Interfaces:**
- Produces: the doctrine every command/skill references. Defines the baked defaults and the `## sweap config` key names Tasks 4–6 read.

- [ ] **Step 1: Copy the source**

```bash
cp ~/Documents/consumer-a/docs/agentic-loop-playbook.md plugin/playbook/agentic-loop-playbook.md
```

- [ ] **Step 2: Apply the genericize transform.** Edit `plugin/playbook/agentic-loop-playbook.md`:
  - Replace the "Project state" section with a generic **"How this project is configured"** section that points at the `## sweap config` block in CLAUDE.md and lists each key with its baked default (verify.typecheck/lint/e2e, backlog.file/prefix, services.up, audit.lenses, review.dimensions, notify, turns.default).
  - In "Environment parity", replace `just services-up`/Docker-specific prose with: "if `services.up` is declared, `/milestone` runs it (starting the daemon if the command is Docker-based); otherwise it runs in CI-gated mode." Keep the CI-is-authoritative principle verbatim.
  - In "Review dimensions", keep `security` / `ui` / `migration` as the shipped set but strip the consumer-specific `consumer-a-design`/DS.1 references → "the project's declared design system (see the ui-design skill)".
  - In "Milestone audit", replace the six hardcoded consumer A lenses with a pointer to the **generic default lens set** (correctness, authz/security, data-integrity, concurrency/races, test-integrity, api-contract) defined in the audit workflow, plus "projects append domain lenses via `audit.lenses`".
  - Replace every remaining literal `consumer-a`, `clinic`, `patient`, `workerd`, `wsproxy`, `F0/F1…` example with a neutral placeholder (`<project>`, `<the milestone prefix>`, a generic feature example).
  - Keep verbatim: the three-loops model, per-feature loop, deferred/blocked lifecycle, end-of-run hygiene (the full worktree cleanup sequence), the merge-gate section, standing preferences, hard rules.

- [ ] **Step 3: Verify no domain tokens leaked**

Run: `grep -niE 'consumer A|clinic|patient|workerd|wsproxy' plugin/playbook/agentic-loop-playbook.md`
Expected: no matches (or only inside an explicit "e.g. a clinic app" illustrative aside you deliberately kept — if so, none at all is preferred).

- [ ] **Step 4: Read-through parity check.** Read the generalized playbook end to end; confirm every *mechanism* present in the consumer A original is still present (checklist against the consumer A file's section headers).

- [ ] **Step 5: Commit**

```bash
git add plugin/playbook/agentic-loop-playbook.md
git commit -m "feat: generalized agentic-loop playbook"
```

---

### Task 4: `/agentic-loop-init` command + scaffold templates

**Files:**
- Create: `plugin/commands/agentic-loop-init.md` (final shipped name; drafted below under its original working filename `init.md`, renamed post-launch to avoid colliding with Claude Code's builtin `/init`)
- Create: `plugin/templates/CLAUDE.md`
- Create: `plugin/templates/ROADMAP.md`
- Create: `plugin/templates/justfile`
- Create: `plugin/templates/.github/workflows/ci.yml`
- Create: `plugin/templates/.github/workflows/claude-review.yml`

**Interfaces:**
- Consumes: the `## sweap config` key names and baked defaults from the playbook (Task 3).
- Produces: `/agentic-loop-init`, which copies `templates/*` into the consuming project, idempotently.

- [ ] **Step 1: Write `plugin/templates/CLAUDE.md`** — the config block + baked standing prefs stub:

````markdown
# <project> — agent instructions

**Read the sweap playbook before any feature work:** it defines the operating
model, autonomy rules, and how to resume interrupted work. Specs live in
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Backlog: `ROADMAP.md`.

## sweap config (read by pipeline commands — override only what differs)
```
verify.typecheck: <your typecheck cmd>     # e.g. pnpm check-types / tsc --noEmit / cargo check
verify.lint:      <your lint cmd>
verify.e2e:       <your e2e cmd>           # the authoritative gate command
backlog.file:     ROADMAP.md
backlog.prefix:   F
# services.up:    just services-up          # uncomment only if you have local test services
audit.lenses:     default
review.dimensions: security, ui, migration
notify:           push
turns.default:    160
```

## Standing preferences — treat as already answered, do not re-ask
- Always work in an isolated worktree/branch; never implement on `main`.
- Finishing a branch: open a PR by default. Never discard work autonomously.
- Merging an unblocked PR whose gate is green is pre-authorized — do not ask.
  Never pass `--admin`/`--repo`/`-R`; never disable or weaken the gate.
- Plan execution: subagent-driven-development (continuous, no check-ins).
- TDD, no exceptions in product code. The implementer's report MUST include TDD
  Evidence: the RED (failing) output and the GREEN (passing) output, pasted.
  Never modify a test to make it pass; never skip/quarantine silently.
- Do not rationalize skipping a code review ("nothing to review", "trivial
  adapter"). Every task gets its fresh-context review.
- When blocked or ambiguous in an unattended run: escalate, don't guess —
  record the question on the item in ROADMAP.md, notify, move to the next item.
- Honor each ROADMAP item's `review-dimensions` tags.
- At the end of an autonomous run: notify with merged-PRs + blocked-items summary.
````

- [ ] **Step 2: Write `plugin/templates/ROADMAP.md`** — skeleton with the legend and one example item:

```markdown
# ROADMAP

Status tags: `[todo]` `[blocked]` `[deferred]` `[done]`. The loop always picks
the top **unblocked** `[todo]` item (all `Depends on:` are `[done]`).

## F1 — <first milestone>

### F1.1 — <feature> [todo]
- **Depends on:** —
- **review-dimensions:** []
- **Acceptance (e2e):** <observable behavior a test asserts>

## Later milestones (sketch, not yet specced)
- F2 — <...>

## Archived / dropped
```

- [ ] **Step 3: Create the `justfile` and CI templates by copy-generalize from consumer A.**

```bash
cp ~/Documents/consumer-a/justfile plugin/templates/justfile
cp ~/Documents/consumer-a/.github/workflows/ci.yml plugin/templates/.github/workflows/ci.yml
cp ~/Documents/consumer-a/.github/workflows/claude-review.yml plugin/templates/.github/workflows/claude-review.yml
```
Then edit each: replace consumer-specific recipe bodies (pnpm/turbo/wsproxy/postgres service containers) with clearly-marked `# <fill in for your stack>` recipe stubs that keep the **recipe names** (`lint`, `typecheck`, `test`, `e2e`, `ci-local`, `ci-replay`) and the agent-parseable JSON status-block convention (documented in CLAUDE.md's CI section, which you also copy-generalize into the template CLAUDE.md). The names are the contract commands depend on; the bodies are project-specific. (These stubs are the one deliberate exception to "no placeholders" — a scaffold template is meant to be filled per project — and each is explicitly marked as fill-in.)

- [ ] **Step 4: Write `plugin/commands/agentic-loop-init.md`** — the scaffold command:

````markdown
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
3. After copying, print a checklist for the human: fill in `verify.*` commands in
   the config block, fill the `justfile` recipe bodies and CI workflow steps for
   the stack, and write the first ROADMAP milestone with `/roadmap`.
4. Report exactly which files were created, which were kept, and the fill-in TODOs.

Do not commit — leave the scaffolded files staged-or-unstaged for the human to
review, since CI and verify commands are stack-specific and must be filled first.
````

- [ ] **Step 5: Test the scaffold in a throwaway dir**

Run:
```bash
d=$(mktemp -d); cd "$d"; git init -q
# simulate the command's copy logic:
cp -R ~/Documents/sweap/plugin/templates/. .
ls -R . | head -40
# idempotency: a second copy with "never overwrite" must change nothing
```
Expected: `CLAUDE.md`, `ROADMAP.md`, `justfile`, `.github/workflows/{ci,claude-review}.yml` present. Re-running the guarded copy reports all "kept existing", modifies nothing.

- [ ] **Step 6: Commit**

```bash
git add plugin/commands/agentic-loop-init.md plugin/templates
git commit -m "feat: /agentic-loop-init command + scaffold templates"
```

---

### Task 5: `/roadmap` + `/milestone` commands

**Files:**
- Create: `plugin/commands/roadmap.md` (copy + generalize from consumer A)
- Create: `plugin/commands/milestone.md` (copy + generalize from consumer A)

**Interfaces:**
- Consumes: `## sweap config` (`backlog.*`, `verify.*`, `services.up`, `turns.default`) and the playbook (Task 3).
- Produces: `/roadmap` (3-phase milestone brainstorm) and `/milestone` (pre-flight + printed `/goal` line).

- [ ] **Step 1: Copy both sources**

```bash
cp ~/Documents/consumer-a/.claude/commands/roadmap.md   plugin/commands/roadmap.md
cp ~/Documents/consumer-a/.claude/commands/milestone.md plugin/commands/milestone.md
```

- [ ] **Step 2: Generalize `roadmap.md`** — replace the hardcoded `F` milestone resolution with "read `backlog.prefix` from the `## sweap config` block (default `F`)"; keep the decide → cross-check → reconcile three phases and the `milestone-cross-check` skill reference intact; replace any consumer A example with a neutral one.

- [ ] **Step 3: Generalize `milestone.md`** —
  - Milestone/turn resolution reads `backlog.prefix` and `turns.default` from config.
  - The environment pre-flight becomes **conditional**: only run the Docker/services block if `services.up` is declared in config; otherwise state CI-gated mode. Replace `just services-up` with the value of `services.up`.
  - The printed `/goal` templates stay, with `<MILESTONE>`/`<TURNS>` filled from the resolved values. Keep the "print, don't invoke — only the user can call `/goal`" instruction verbatim.
  - Keep the deferred-item and audit-debt pre-flight scans verbatim (they are config-agnostic ROADMAP scans).

- [ ] **Step 4: Verify** by reading each command: no literal `consumer-a`/`pnpm`/`F0`; every project-specific value comes from a named config key with a stated default.

Run: `grep -niE 'consumer A|pnpm|\bF0\b|workerd' plugin/commands/roadmap.md plugin/commands/milestone.md`
Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/roadmap.md plugin/commands/milestone.md
git commit -m "feat: generalized /roadmap and /milestone commands"
```

---

### Task 6: `/milestone-audit` command + Workflow + default lens set

**Files:**
- Create: `plugin/commands/milestone-audit.md` (copy + generalize)
- Create: `plugin/workflows/milestone-audit.js` (copy + generalize; add the generic default lens set)

**Interfaces:**
- Consumes: `audit.lenses` from config; the finder→refuter shape from the consumer A workflow.
- Produces: `/milestone-audit` and the `milestone-audit` Workflow (read-only; finder → 2× refuter → majority-survives).

- [ ] **Step 1: Copy both sources**

```bash
cp ~/Documents/consumer-a/.claude/commands/milestone-audit.md plugin/commands/milestone-audit.md 2>/dev/null || true
cp ~/Documents/consumer-a/.claude/workflows/milestone-audit.js plugin/workflows/milestone-audit.js
```
(If consumer A has no separate `milestone-audit.md` command file, author one whose body is: "Run the saved `milestone-audit` workflow over `{range}` (infer from ROADMAP if absent); triage confirmed findings into the three buckets per the playbook.")

- [ ] **Step 2: Replace the six consumer A lenses with a config-driven set** in `milestone-audit.js`. Define a baked `DEFAULT_LENSES` array and merge project extras:

```js
// Generic, domain-free default lenses. Projects extend via `audit.lenses` in
// the CLAUDE.md config block (e.g. "default + [tenancy, workerd]").
const DEFAULT_LENSES = [
  { key: 'correctness',   prompt: 'Audit the merged milestone for logic errors: off-by-one, wrong conditionals, unhandled return values, contract mismatches between callers and callees across the milestone surface.' },
  { key: 'authz',         prompt: 'Audit authorization at every server entry point: writes gated by the project permission model; checks that gate the UI but not the server call; roles reaching data they should not.' },
  { key: 'data-integrity',prompt: 'Audit data lifecycle as one system: create/update/archive/delete interactions with search, pagination, and references; uniqueness under concurrent writes; orphaned rows after delete.' },
  { key: 'concurrency',   prompt: 'Audit races and ordering: last-response-wins / stale-write races on the client, non-idempotent handlers, unguarded read-modify-write, request N breaking state set by request N-1.' },
  { key: 'test-integrity',prompt: 'Audit the tests themselves: assertions weakened to pass, tests that never exercise the claimed behavior, skipped/quarantined tests, e2e that asserts nothing observable.' },
  { key: 'api-contract',  prompt: 'Audit public contracts: response shape changes, breaking param changes, error mapping, backward-compat of anything the milestone touched that other features consume.' },
];
```
Wire the Scope stage to read `audit.lenses` from the project CLAUDE.md config: `default` → `DEFAULT_LENSES`; `default + [x, y]` → `DEFAULT_LENSES` plus project-authored lens stubs the run infers from the milestone surface; an explicit list → only those. Keep the `FINDINGS`/`VERDICT` schemas, the finder→refuter phases, and majority-survives logic verbatim.

- [ ] **Step 3: Verify the workflow script parses**

Run: `node --check plugin/workflows/milestone-audit.js`
Expected: no syntax error. (`--check` only parses; it does not run the Workflow runtime.)

- [ ] **Step 4: Verify no domain lenses remain baked**

Run: `grep -niE 'tenancy|workerd|withTenant|organizationId|clinic' plugin/workflows/milestone-audit.js`
Expected: no matches (those move to per-project `audit.lenses`).

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/milestone-audit.md plugin/workflows/milestone-audit.js
git commit -m "feat: generalized milestone-audit workflow + default lens set"
```

---

### Task 7: Skills — milestone-cross-check + ui-design

**Files:**
- Create: `plugin/skills/milestone-cross-check/SKILL.md` (copy + generalize)
- Create: `plugin/skills/ui-design/SKILL.md` (from consumer-a-design, generalized)

**Interfaces:**
- Produces: the `milestone-cross-check` completeness-critic skill (used by `/roadmap` phase 2) and the `ui-design` skill (used for `ui` review-dimension items).

- [ ] **Step 1: Copy milestone-cross-check**

```bash
cp ~/Documents/consumer-a/.claude/skills/milestone-cross-check/SKILL.md plugin/skills/milestone-cross-check/SKILL.md
```

- [ ] **Step 2: Generalize milestone-cross-check** — keep the fixed completeness lens (non-goals, role/persona coverage, locale/timezone, data-lifecycle & cross-feature interaction, edge-case policies, AC testability, scope tiering, success signal) and the "flags gaps, never rewrites/expands scope" contract. Strip consumer-specific example gaps (the F2 timezone / same-patient-overlap anecdotes) → one neutral example. Update the `description:` frontmatter to drop "consumer-a".

- [ ] **Step 3: Copy consumer-a-design → ui-design**

```bash
cp ~/Documents/consumer-a/.claude/skills/consumer-a-design/SKILL.md plugin/skills/ui-design/SKILL.md
```

- [ ] **Step 4: Generalize ui-design** — rename the skill to `ui-design`; replace "consumer A design system / DS.1 / tokens+primitives" with "the project's declared design system"; keep universal parts verbatim: the render→critique→fix bounded loop, the **hard a11y gate** (axe, keyboard/focus, required empty/loading/error states), the "no arbitrary values / token-reuse lint" (framed as "if the project declares a design system"), and the advisory-ratchet aesthetic verdict (address-or-justify, never auto-block). Keep browser control (claude-in-chrome / webapp-testing) exploratory, never a CI gate.

- [ ] **Step 5: Verify** frontmatter names and no residual domain tokens

Run: `grep -rniE 'consumer A|clinic|patient' plugin/skills/`
Expected: no matches. Confirm each `SKILL.md` has valid `name:`/`description:` frontmatter (`name: milestone-cross-check`, `name: ui-design`).

- [ ] **Step 6: Commit**

```bash
git add plugin/skills
git commit -m "feat: generalized milestone-cross-check + ui-design skills"
```

---

### Task 8: Agent definitions

**Files:**
- Create: `plugin/agents/reviewer.md`
- Create: `plugin/agents/security-reviewer.md`
- Create: `plugin/agents/ui-critic.md`

**Interfaces:**
- Consumes: the review-dimensions framework (playbook, Task 3).
- Produces: reusable subagent definitions the per-feature loop and audits dispatch, so the review behavior lives in one place instead of inline prose.

- [ ] **Step 1: Write `plugin/agents/reviewer.md`** — a fresh-context code reviewer that sees only the diff + the plan, reports confirmed findings with a `Verdict: approved|needs-work` line (matching the merge-gate `review` check the CI template greps). Include: reads nothing but the diff and the item's plan/spec; does not implement fixes; flags review-skip rationalizations as a finding.

- [ ] **Step 2: Write `plugin/agents/security-reviewer.md`** — runs the built-in `security-review` skill against the branch diff for items tagged `review-dimensions: security`; attention to authz bypass and any tenant/isolation model the project declares; confirmed findings block.

- [ ] **Step 3: Write `plugin/agents/ui-critic.md`** — the anonymized aesthetic/a11y critic used by the ui-design skill and UI audits: comparative/pairwise judging against the project exemplar, independent refutation, a11y findings carry gate weight, aesthetic findings are advisory-ratchet.

- [ ] **Step 4: Verify** each file has valid agent frontmatter (`name`, `description`, `tools` as appropriate) and no domain tokens.

Run: `grep -rniE 'consumer A|clinic|patient' plugin/agents/`
Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add plugin/agents
git commit -m "feat: reviewer, security-reviewer, ui-critic agent defs"
```

---

### Task 9: `/loop-schedule` cron driver command

**Files:**
- Create: `plugin/commands/loop-schedule.md`

**Interfaces:**
- Consumes: `backlog.*`, `turns.default` from config; the playbook's autonomy rules.
- Produces: `/loop-schedule [milestone] [cadence]`, which creates a scheduled cloud agent whose kickoff prompt is the goal condition — the no-paste hands-off driver.

- [ ] **Step 1: Write `plugin/commands/loop-schedule.md`**

````markdown
---
description: Schedule a hands-off pipeline run as a cron cloud agent (no /goal paste needed).
argument-hint: "[milestone] [cadence] — e.g. F2 nightly"
---

Read `CLAUDE.md` (incl. the `## sweap config` block), the sweap playbook, and
`ROADMAP.md` first. Resolve the milestone and turn bound exactly as `/milestone`
does (respecting `backlog.prefix` and `turns.default`).

Then create a **scheduled cloud agent** (the `/schedule` mechanism) whose cron
cadence is the second argument (`nightly` → a daily cron; accept explicit cron
too). The agent's **kickoff prompt IS the goal condition** — no human paste:

> Drain the top unblocked ROADMAP items per the sweap playbook. For each: work in
> an isolated worktree, TDD (include RED+GREEN evidence), dispatch a fresh-context
> review, open a PR, and merge only when the gate is green (the pre-merge-gate
> hook enforces this). Escalate any blocker to a `[blocked]` ROADMAP entry + a
> notification instead of guessing. When the last <MILESTONE> item merges, run
> `/milestone-audit` for that range and triage. Stop when only `[blocked]` items
> remain, or after <TURNS> turns. Notify with a merged-PRs + blocked-items summary.

Confirm the created schedule back to the user (cadence, milestone, turn bound) and
note they can cancel it with the schedule manager. Do NOT invoke `/goal` (only a
human can); the schedule supplies the goal via this prompt instead.
````

- [ ] **Step 2: Verify** the command references only config keys + the `/schedule` mechanism; no consumer A tokens.

Run: `grep -niE 'consumer A|pnpm|workerd' plugin/commands/loop-schedule.md`
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add plugin/commands/loop-schedule.md
git commit -m "feat: /loop-schedule cron driver command"
```

---

### Task 10: Verification — parity (consumer A) + portability (throwaway)

**Files:** none created — this task exercises the installed plugin end-to-end. It is validated by real agent sessions with transcript review (the doctrine/command layer has no unit-test surface), plus the deterministic hook/scaffold checks from Tasks 2 and 4.

**Interfaces:**
- Consumes: everything above.
- Produces: sign-off that the plugin reproduces consumer A's behavior (parity) and works with zero consumer A context (portability).

- [ ] **Step 1: Parity — install into consumer A.** In a scratch clone of consumer A: `/plugin install sweap`, then temporarily move consumer A's local `.claude/commands` + `.claude/hooks` aside. Run one real `/milestone` pre-flight and confirm: same milestone resolution, same printed `/goal` line, the merge-gate hook still denies a fabricated non-green `gh pr merge`. Restore consumer A's local files afterward (parity test only — do not delete consumer A's working setup).

- [ ] **Step 2: Portability — fresh throwaway repo.** `mkdir /tmp/sweap-portability && cd` it, `git init`, `gh repo create` (or a local-only remote stub). `/plugin install sweap` → `/agentic-loop-init` → fill the `verify.*` config with trivial commands (e.g. a Node project with one unit test + a placeholder e2e) → author a 2-item ROADMAP → run a supervised `/goal`.

- [ ] **Step 3: Walk the acceptance checklist** (from the spec §5). Confirm each, capturing evidence from the session transcript:
  - [ ] worktree isolation (no commits on `main`)
  - [ ] TDD Evidence present in the implementer report (RED + GREEN output)
  - [ ] fresh-context review dispatched; review-skip guard held
  - [ ] `pre-merge-gate` **blocked a red PR** and **allowed a green one** (test both)
  - [ ] `post-merge-cleanup` removed the worktree + branch
  - [ ] `/milestone-audit` fired at the boundary and reported finder→refuter findings
  - [ ] a deliberately-ambiguous item routed to `[blocked]` + notification, not a guess

- [ ] **Step 4: Record results** in `docs/superpowers/test-runs/2026-07-15-portability.md` (session id, which checklist items passed/failed, any gaps). File gaps as follow-up `[todo]` items in this repo's own ROADMAP (create it if absent).

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/test-runs
git commit -m "test: parity + portability verification run"
```

---

## Notes for the executor

- **Ports before authoring.** Tasks 3, 5, 6, 7 start from a byte copy of a consumer A file — always diff your generalized version against the original so you can see (and justify) every change. The mechanisms must survive; only domain specifics change.
- **The hooks are the safety core.** Task 2's byte-identical copy under an unchanged test is deliberate — do not "improve" the hooks during the port. Any change there needs its own spec.
- **Placeholder exception.** The only intentional fill-in-later content is in `templates/` (justfile recipe bodies, CI steps, `verify.*` values) — these are scaffold stubs a consuming project completes, each explicitly marked. Everywhere else, no placeholders.
