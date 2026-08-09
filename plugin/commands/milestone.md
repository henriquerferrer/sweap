---
description: Prepare and kick off an autonomous milestone run (pre-flight + ready-to-paste goal).
argument-hint: "[milestone] [turns] — defaults: next unstarted milestone, turns.default"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and
the backlog first — `backlog.file` (the index) plus the item files under
`backlog.dir` (playbook: "Backlog format (file-per-item)").
**Legacy pre-flight:** if `backlog.file` still contains item headers
(`### … [todo]`-style), run the one-time migration defined there (one PR
through the gate) before anything below.

Resolve the run:
- Read `backlog.prefix` from the `## sweap config` block in `CLAUDE.md` (default
  `F`) as a comma-separated LIST of one or more milestone-tag prefixes (e.g. `F`
  or `F, DS`) — these are the prefixes used below.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the repo
  root. Any `FAIL:` output means **audit debt**: a completed milestone lacks a
  valid audit record. The ONLY permitted work while debt exists is discharging
  it (run `/milestone-audit` for the named milestone; land its record PR) —
  do not resolve a new milestone past unaudited work. This **record-debt** is
  distinct from the outstanding `followup_of:` items ("Audit debt `D`"
  below): draining `D` never clears the gate — only landing the audit record
  PR does — and while record-debt exists that record PR is the only
  backlog-advancing merge the gate allows, so resolve it before picking any
  run shape.
- **Milestone `M`** = the first argument if given (e.g. `F2` or `DS3`, using
  any configured prefix); otherwise the next runnable milestone —
  across ALL configured prefixes, in the index's milestone order — that has
  `status: todo` item files whose dependencies are all satisfied (the next
  runnable milestone). A milestone is a milestone regardless of prefix: a
  `DS3` run gets the same audit-inclusive goal as an `F2` run.
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
resolving the milestone, scan `backlog.dir` for newly-unblocked
**`status: deferred`** item files — these may have unblocked outside an
autonomous run (e.g. a hand-merged dependency) and the end-of-run scan never
fired. (A frontmatter scan — no header matching needed.) An item counts as unblocked when
either: (a) every **item-level** `depends_on` entry (a dotted ID like `F4.3`
or `DS3.4`, any configured prefix) has its file at `status: done`; or (b) a
**milestone-level** entry (a bare tag like `F#` or `DS#`) has *completed* —
item files for that milestone exist and every one is `status: done` (this
pre-flight is the designated surfacing point for milestone-level deps, which
the item scan cannot catch). For each unblocked
item, apply the lifecycle: if its `premise:` is machine-checkable and verifiably
holds, promote it to `status: todo` (it may then be this run's work); otherwise list
it for the human to re-decide (re-spec or drop) — do not promote on a stale or
uncheckable premise. Report any you found. The scan is stateless (just re-reads
current statuses), so running it here every time is safe and idempotent.

Audit-debt scan (see the playbook's "Milestone audit" section). Collect the
debt set `D`: every item file with `followup_of:` set — for ANY configured
prefix — that is `status: todo` AND unblocked (all `depends_on` satisfied;
blocked and deferred items are excluded — same rule as the frontier picker).
A frontmatter scan; no header matching. These are auto-folded into this run's scope **ahead of**
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

Parallel width (coordinator mode). Read `parallel:` from the `## sweap
config` block (default 2; clamp values above 4 to 4 and say so). If it is 2
or more, say the run will operate in **coordinator mode** per the playbook's
"Parallel runs (coordinator mode)" section — frontier scheduling,
worktree-isolated workers, the FIFO always-verify merge queue, and the
`.claude/sweap-board.md` board file. The printed goal line is IDENTICAL to
the serial form — the mode changes how the run executes, not its definition
of done.

Before any dispatch (either mode, serial included), run the spec gate on the
item: `bash ${CLAUDE_PLUGIN_ROOT}/hooks/roadmap-lint.sh <backlog.dir>/<ID>.md`
— a failing todo item is not runnable (fix mechanically or escalate), per the
playbook's "Backlog format (file-per-item)" section.

Then **print** the exact goal line, filled in, for the user to paste — do NOT
try to set `/goal` yourself (only the user can invoke it). Pick the template by
run shape from "Resolve the run" above.

**Non-negotiable for any milestone run (regardless of prefix):** the goal line
MUST carry the "…and the `<MILESTONE>` milestone-audit has run and been
triaged" clause. A milestone is not complete until its audit has run — a run
that drains every item but stops before the audit has stopped early. This
holds whether the goal is printed here or hand-written: if a milestone `/goal`
is ever hand-written rather than printed by `/milestone` (or the user pastes
one), the audit-and-triage clause is part of the definition of done, not
optional. For a UI-heavy milestone (its `review.dimensions` tags include `ui`)
the audit clause covers **both** the `/milestone-audit` code pass **and** the
Tier-2 UI audit (see the playbook's "Milestone audit" section and the
`ui-design` skill §7). The only run shape without an audit is the **debt-only**
run below (you don't audit a debt-drain).

**Milestone + debt** (an `M` was resolved):

```
/goal First, every outstanding audit follow-up item in the backlog is [done];
then every unblocked <MILESTONE> item is [done] per its definition of done, and
the <MILESTONE> milestone-audit (plus the Tier-2 UI audit for a UI-heavy
milestone) has run and been triaged. Stop when only [blocked] items remain, or
after <TURNS> turns.
```

**Debt-only** (no runnable `M`, but `D` is non-empty):

```
/goal Every outstanding audit follow-up item in the backlog is [done] per its
definition of done. Stop when only [blocked] items remain, or after <TURNS> turns.
```

Everything else (TDD, the review dimensions, end-of-run hygiene, escalation, and
the audit auto-launch/triage) is inherited from CLAUDE.md and the playbook, which
the run reads at start — the goal only states the end condition.

The whole ritual for the user is just: `claude --permission-mode auto` →
`/milestone` → paste the printed goal. If `services.up` is declared, services
come up automatically above — the user never runs it themselves.
