---
description: Prepare and kick off an autonomous milestone run (pre-flight + ready-to-paste goal).
argument-hint: "[milestone] [turns] — defaults: next unstarted milestone, turns.default"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
`ROADMAP.md` (`backlog.file`) first.

Resolve the run:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) — this is the milestone-tag prefix used below.
- **Milestone `M`** = the first argument if given (e.g. `F2` using the
  configured prefix); otherwise the lowest-numbered milestone in ROADMAP.md that
  has `[todo]` items whose dependencies are all `[done]` (the next runnable
  milestone).
- **Audit debt `D`** = the outstanding audit follow-ups from the audit-debt scan
  below.
- **Turns** = the second argument if given; otherwise `turns.default` from the
  `## sweap config` block (default `160`).

Then pick the run shape:
- **`M` exists** → scope = `D` then `M` (debt-first): drain every item in `D`,
  then run `M`'s items.
- **No runnable `M` but `D` is non-empty** → **debt-only run**: scope = `D`. Do
  NOT run a milestone-audit for a debt-only run — you don't audit a debt-drain.
- **Neither** → nothing to run; say so and stop.

Deferred-item backstop (see the playbook's "Deferred items" section). Before
resolving the milestone, scan ROADMAP.md for newly-unblocked **`[deferred]`**
items — these may have unblocked outside an autonomous run (e.g. a hand-merged
dependency) and the end-of-run scan never fired. Match only ROADMAP **item
headers** (lines beginning with `### ` that carry a status tag) — never the
status-tag legend/explainer line or a prose mention of `[deferred]`, both of
which are false positives for a naive substring match. An item counts as unblocked when
either: (a) every **item-level** `Depends on:` (a taggable ID like `F4.3` using
the configured prefix) is `[done]`; or (b) a **milestone-level** `Depends on:`
(a bare `F#`) has *completed* — that milestone's section exists and every item
in it is `[done]` (this pre-flight is the designated surfacing point for
milestone-level deps, which the item scan cannot catch). For each unblocked
item, apply the lifecycle: if its `Premise:` is machine-checkable and verifiably
holds, promote it to `[todo]` (it may then be this run's work); otherwise list
it for the human to re-decide (re-spec or drop) — do not promote on a stale or
uncheckable premise. Report any you found. The scan is stateless (just re-reads
current statuses), so running it here every time is safe and idempotent.

Audit-debt scan (see the playbook's "Milestone audit" section). Collect the
debt set `D`: every `### …` item under a `## <backlog.prefix># audit follow-ups`
section that is `[todo]` AND unblocked (all `Depends on:` items are `[done]`;
`[blocked]` and `[deferred]` items are excluded — same rule as the
top-of-backlog picker). As with the deferred scan, match only ROADMAP item
headers (`### …` lines carrying a status tag), never the status-tag
legend/explainer line or a prose mention of a tag. These are auto-folded into this run's scope **ahead of**
the named milestone's items (debt-first). Report the list of items in `D`. Like
the deferred scan, this is stateless — it just re-reads current statuses — so
running it here every time is safe and idempotent. (An item in `D` that turns
out to need a direction call on pickup escalates to `[blocked]` and is left for
the human, exactly like any other item — the "Stop when only [blocked] items
remain" clause below still lets the run finish.)

Environment pre-flight (parity — see the playbook's "Environment parity"
section). Do this **yourself** — the user should never bring up services by
hand. Check whether `services.up` is declared in the `## sweap config` block in
`CLAUDE.md`:

- **If `services.up` is declared:**
  1. Run `docker info` quietly.
  2. **If it succeeds** → run the `services.up` command and continue (local
     fast-path).
  3. **If it fails but the `docker` CLI exists and this is macOS** → the daemon
     is just not started. Run `open -a Docker`, then poll `docker info` every 3s
     for up to ~90s. Once it succeeds, run the `services.up` command. (Tell the
     user you're waiting on Docker Desktop to boot.)
  4. **If Docker has no CLI, or never comes up within the timeout** (e.g. Claude
     Code web, or Docker not installed) → skip local services and drop to
     **CI-gated mode** (below).
- **If `services.up` is not declared** → there are no local services to bring
  up; go straight to **CI-gated mode**.

**CI-gated mode:** CI runs the identical services as containers on every PR and
the merge gate requires CI e2e green, so CI is the authoritative test gate. Say
which mode you ended up in. Never block the run on Docker, or on the absence of
`services.up` — the loop is identical either way.

Then **print** the exact goal line, filled in, for the user to paste — do NOT
try to set `/goal` yourself (only the user can invoke it). Pick the template by
run shape from "Resolve the run" above.

**Milestone + debt** (an `M` was resolved):

```
/goal First, every outstanding audit follow-up item in ROADMAP.md is [done];
then every unblocked <MILESTONE> item is [done] per its definition of done, and
the <MILESTONE> milestone-audit has run and been triaged. Stop when only
[blocked] items remain, or after <TURNS> turns.
```

**Debt-only** (no runnable `M`, but `D` is non-empty):

```
/goal Every outstanding audit follow-up item in ROADMAP.md is [done] per its
definition of done. Stop when only [blocked] items remain, or after <TURNS> turns.
```

Everything else (TDD, the review dimensions, end-of-run hygiene, escalation, and
the audit auto-launch/triage) is inherited from CLAUDE.md and the playbook, which
the run reads at start — the goal only states the end condition.

The whole ritual for the user is just: `claude --permission-mode auto` →
`/milestone` → paste the printed goal. If `services.up` is declared, services
come up automatically above — the user never runs it themselves.
