# sweap — SWE Agentic Pipeline: installable plugin (design)

**Date:** 2026-07-15
**Status:** approved (brainstorm) → next: implementation plan
**Author:** Henrique + Claude

## Context

`~/Documents/consumer-a` grew a mature agentic-dev loop (see its
`docs/agentic-loop-playbook.md`): a per-feature loop, a hook-enforced
merge-greenness gate, `/roadmap` `/milestone` `/milestone-audit` commands, a
deferred/blocked backlog lifecycle, and a read-only milestone-audit Workflow.
Today that machinery is copy-pasted and consumer-specific. Henrique wants it
**portable** — installable into his own future projects without re-authoring it
each time.

`sweap` ("SWE Agentic Pipeline") is the vehicle. The directory was previously a
fork of obra/superpowers; that was deleted and the repo is now blank (greenfield
as of 2026-07-15). Prior-fork lessons still apply (see Non-goals / Prior art).

## Goals

- Package consumer A's agentic loop as a **private Claude Code plugin** installable
  across Henrique's projects.
- Keep all logic **versioned and updatable** from one place; keep project
  specifics in per-project config, not forked copies.
- Preserve every control that makes unattended runs safe (merge gate, escalate-
  don't-guess, TDD evidence).
- Add a **no-paste hands-off driver** (cron) without removing the `/goal` driver.

## Non-goals

- Public distribution / polish for third parties. This is private, for
  Henrique's own use. (Revisit later if desired.)
- A new config file format. Config lives in a fenced block in each project's
  `CLAUDE.md` (see Config contract).
- Driving feature work with the Workflow tool. Workflows are reserved for the
  bounded, read-only audit phase; they are the wrong shape for serial,
  dependency-chained, escalation-prone feature work.

## Prior art (the deleted sweap fork)

The fork's pipeline-integrity fixes are the same class of control as consumer A's
gates and carry forward as **baked standing preferences**:
- **Mandatory TDD Evidence** — the implementer must paste RED (failing) and
  GREEN (passing) test output in its report.
- **Review-skip guards** — Red-Flags language that blocks the orchestrator from
  rationalizing away a code review.
- **Review-disagreement escalation** and the **escalate-don't-guess** rule.

## Locked decisions

1. **Purpose:** private plugin for Henrique's own future projects.
2. **Config model:** baked defaults + `CLAUDE.md` overrides (no separate YAML).
3. **Driver:** `/goal` as the primary, always-available driver (human types one
   line, then it runs unattended); **cron/`/loop-schedule`** as an additive
   no-paste option; the **Workflow tool** reserved for the audit phase only.
4. **v1 scope:** everything at once — core loop + audit + cross-check + UI skill
   + cron + CI templates.

## Section 1 — Distribution architecture

The `sweap` repo is **both the marketplace and the plugin**.

```
sweap/
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest → points at the plugin
└── plugin/
    ├── plugin.json               # name, version, hooks wiring (${CLAUDE_PLUGIN_ROOT})
    ├── commands/                 # roadmap, milestone, milestone-audit, init, loop-schedule
    ├── skills/                   # milestone-cross-check, ui-design, (pipeline overview)
    ├── agents/                   # reviewer, security-reviewer, ui-critic subagent defs
    ├── hooks/                    # pre-merge-gate, post-merge-cleanup, post-merge-redcheck, lib-merge-parse
    ├── workflows/                # milestone-audit.js (generic finder→refuter shape)
    ├── playbook/                 # agentic-loop-playbook.md (generic doctrine)
    └── templates/                # scaffold sources (project-owned after init)
```

**Two delivery channels:**
- **Plugin-delivered (versioned, auto-updates everywhere):** playbook, all
  commands, cron command, the three hooks *and their wiring* (plugins ship hooks
  via `${CLAUDE_PLUGIN_ROOT}`, so the safety-critical merge gate can't drift per
  project), both skills, the UI skill, the audit workflow, agent defs.
- **Scaffold-delivered (one-time, then project-owned):** the files a plugin
  *cannot* author — `CLAUDE.md` config+prefs stub, `ROADMAP.md` skeleton,
  `justfile` CI-parity recipes, `.github/workflows`.

**Install:**
1. `/plugin marketplace add <sweap repo>` — **once per machine**.
2. `/plugin install sweap` — **per project**; brings in all logic + auto-wires the three hooks.
3. `/agentic-loop-init` — **per project**; copies `templates/*` into the project; idempotent
   (detects existing files, fills only gaps); prints next steps.

**Update path:** `git -C <sweap> pull` → every project's plugin logic updates.
Scaffolded files are project-owned and never overwritten.

**Hard constraint that drives this shape:** hooks/commands/skills/agents/workflows
travel in the plugin (versioned, safe); files a plugin cannot write travel in the
`init` scaffold.

## Section 2 — Config contract

`/agentic-loop-init` seeds a fenced block into the project's `CLAUDE.md`. Every
sweap command reads it first; anything absent falls back to a baked default.

```
## sweap config (read by pipeline commands — override only what differs)
verify.typecheck: pnpm check-types      # default: auto-detect (tsc / cargo check / …)
verify.lint:      pnpm lint
verify.e2e:       pnpm test:e2e          # the authoritative gate command
backlog.file:     ROADMAP.md
backlog.prefix:   F                       # milestone id prefix (F1, F2, …)
services.up:      just services-up        # optional — omit if no local services
audit.lenses:     default + [tenancy, workerd]   # generic default set + project extras
review.dimensions: security, ui, migration
notify:           push                    # push | none
turns.default:    160
```

**Baked (plugin) vs declared (project):**

| Baked default (plugin) | Declared per project (CLAUDE.md) |
|---|---|
| Three-loops model, per-feature loop, deferred/blocked lifecycle, escalate-don't-guess | Verification commands (typecheck/lint/e2e) |
| Merge-gate + cleanup + redcheck hooks (domain-free gh parsing) | Backlog file + milestone prefix |
| Standing prefs: worktree isolation, PR-by-default, TDD-no-exceptions, **TDD-Evidence required**, **review-skip guards** | Local services bring-up (or none) |
| Audit finder→refuter Workflow *shape* + **generic default lens set** (correctness, authz/security, data-integrity, concurrency/races, test-integrity, api-contract) | Extra **domain audit lenses** (e.g. tenancy/workerd) |
| Cross-check completeness lens; command control-flow | Which **review dimensions** apply + triggers |

The generic default lens set is consumer A's lenses *generalized*, so a new project
gets useful audits day one and appends domain lenses as it grows.

## Section 3 — Components (generalized from consumer A)

### Plugin-delivered

| Component | What it is | Generalization work |
|---|---|---|
| `playbook/agentic-loop-playbook.md` | Doctrine: three loops, per-feature loop, deferred/blocked lifecycle, end-of-run hygiene, review-dimensions framework | Strip clinic/workerd/tenancy prose; replace concrete examples with config-block references. Keep every mechanism. |
| `commands/roadmap.md` | 3-phase milestone brainstorm (decide → cross-check → reconcile) | Read `backlog.prefix`; drop F-milestone hardcoding |
| `commands/milestone.md` | Pre-flight (deferred scan, audit-debt scan, env/services parity) → prints the `/goal` line | Read `verify.*`, `services.up`, `turns.default`; make the Docker/services block conditional on `services.up` |
| `commands/milestone-audit.md` + `workflows/milestone-audit.js` | Finder→refuter Workflow; majority-survives | Lenses from `audit.lenses` (default set + project extras); move the 6 hardcoded consumer A lenses into the default set |
| `commands/agentic-loop-init.md` (new) — `/agentic-loop-init` | Scaffolds `templates/*`; idempotent gap-fill | New authoring |
| `commands/loop-schedule.md` (new) — `/loop-schedule` | Creates a cron cloud agent (`/schedule`) that starts the loop hands-off | New; wraps the scheduled-agent mechanism |
| `hooks/*.sh` + `lib-merge-parse.sh` | Merge-greenness gate, worktree cleanup, red-main backstop | Already domain-free — repath to `${CLAUDE_PLUGIN_ROOT}`, wire in `plugin.json` |
| `skills/milestone-cross-check` | Completeness critic (PM write-spec lens) | Strip consumer-specific gap examples; keep the fixed lens |
| `skills/ui-design` (from `consumer-a-design`) | Render→critique→fix loop, a11y hard gate, token-reuse lint | Generalize "consumer A DS" → "the project's declared design system"; a11y/interaction gates stay universal |
| `agents/` | Fresh-context reviewer, security-reviewer, ui-critic subagent defs | Extract from playbook prose into reusable agent files |

### Scaffold-delivered (`templates/`)

| Template | Seeds |
|---|---|
| `CLAUDE.md` stub | Config block (§2) + baked standing prefs (worktree isolation, PR-default, TDD-Evidence required, review-skip guards, escalate-don't-guess) |
| `ROADMAP.md` skeleton | Section headers, status-tag legend (`[todo]/[blocked]/[deferred]/[done]`), one example item with `Depends on:` + `review-dimensions:` |
| `justfile` | CI-parity recipes (`lint`, `typecheck`, `test`, `e2e`, `ci-local`, `ci-replay`) |
| `.github/workflows/` | `ci.yml` (agent-parseable JSON status), `claude-review.yml`, the merge-gate `review` check |

## Section 4 — Driver model (selectable menu)

Three drivers, picked per run. `/goal` is always available, including for
walk-away runs.

| Driver | Who starts it | Best for | Human paste? |
|---|---|---|---|
| **`/goal`** (primary, default) | You type it once | Any run you kick off — watched or walk-away. The evaluator re-checks the condition each turn and sustains it unattended after you leave. | Yes — one line; `/milestone` prints it ready-to-paste |
| **Cron / `/loop-schedule`** (additive) | Claude creates the schedule | Recurring, PC-off, or no-human-at-all runs (nightly drain, grooming) | No — the schedule's prompt *is* the goal condition |
| **Workflow tool** (not a driver) | Claude, at a boundary | The bounded read-only audit phase inside any run | N/A |

**Resolution of the `/goal` vs `/workflows` question:** `/goal` is a built-in,
**user-only** command (Claude cannot invoke it) — that's why `/milestone` prints
a paste line. `/workflows` is just the viewer; the underlying **Workflow tool**
*is* Claude-startable but is the wrong shape for backlog drive. Hands-off runs
need neither: a **scheduled cloud agent's kickoff prompt IS the goal condition**,
supplied by the schedule, so the one manual paste disappears. `/goal` stays as
the primary driver; cron is additive; Workflow stays at the audit.

**Two things make unattended merge safe** (proven in consumer A): the
`pre-merge-gate` hook mechanically denies any non-green merge (fail-closed), and
escalate-don't-guess routes blockers to a `[blocked]` ROADMAP entry + push
notification instead of a guess.

## Section 5 — Genericizing method + verification

**Extraction method (avoids over-generalizing before first reuse):**
1. **Copy, don't rewrite.** Each component starts as a byte copy of the consumer A
   original; generalize by *diff*, replacing each domain token (clinic, workerd,
   tenancy, `pnpm test:e2e`, `F` prefix) with a config read or baked default. A
   parity checklist tracks every replacement.
2. **Consumer A is the first consumer and the ground truth.**

**Verification — two targets:**

| Target | Proves | How |
|---|---|---|
| **Parity: re-install into consumer A** | Extraction changed nothing | Install plugin into consumer A, remove the now-duplicated local `.claude/commands`+`hooks`, run one real `/milestone` session; confirm behavior matches. Regression safety net. |
| **Portability: throwaway test project** | Works with zero consumer A context | Fresh empty repo → `/plugin install sweap` → `/agentic-loop-init` → author a 2-item trivial ROADMAP → supervised `/goal` run. |

**Acceptance checklist for the portability run ("the full chain fires"):**
- worktree isolation (no commits on `main`)
- TDD Evidence present in the implementer report (RED + GREEN output)
- fresh-context review dispatched; review-skip guard holds
- `pre-merge-gate` **blocks a red PR** and **allows a green one** (test both)
- `post-merge-cleanup` removes worktree + branch
- `/milestone-audit` fires at the boundary and reports finder→refuter findings
- a deliberately-ambiguous item → `[blocked]` + notification, not a guess

**Honest scope of testing:** hooks get **ported unit tests** (consumer A already has
`pre-merge-gate.test.sh` — feed fake `gh` output, assert deny/allow); the
scaffold gets **file-assertion tests** (init creates files; re-run is
idempotent). The doctrine/skill/command layer is validated by **real agent
sessions with transcript review** — it is instruction logic, not code with a
unit-testable surface. The spec states this plainly rather than implying full
automation.

## Risks / open questions

- **Plugin hooks wiring:** confirm Claude Code plugins auto-apply `hooks`
  declared in `plugin.json` with `${CLAUDE_PLUGIN_ROOT}` paths (vs. requiring
  project `settings.json` entries). If not, the hooks move to the `init`
  scaffold instead — a fallback, not a blocker.
- **`/loop-schedule` mechanism:** confirm a scheduled cloud agent accepts a
  free-form kickoff prompt and runs it unattended to a turn/stop bound.
- **Verify-command auto-detect:** the "auto-detect" defaults are a convenience;
  if flaky, require explicit `verify.*` in every project's config.
- **UI skill generalization:** `consumer-a-design` is the most domain-coupled
  component; its generalization may be the largest single effort.
