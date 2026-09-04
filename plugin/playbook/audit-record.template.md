# Audit record format (sweap_format 1)

The canonical shape of `<backlog.dir>audits/<milestone>.md`. This file is the
ONE spec — `hooks/audit-gate.sh` validates against it, `workflows/milestone-audit.js`
emits a filled-in copy of it, and `commands/milestone-audit.md` points here
rather than restating it. If you are writing a record by hand, copy the skeleton
below; if you just ran the audit Workflow, prefer its returned `record` field,
which is this template already populated.

## Skeleton

    ---
    sweap_format: 1
    milestone: F3
    range_base: <base sha>
    range_head: <head sha>
    lens_mode: default
    lenses: [correctness, authz, data-integrity, concurrency, test-integrity, api-contract]
    raw: 14
    refuted: 9
    confirmed: 5
    finders_reporting: 6
    workflow_run: wf_...
    journal_sha256: <sha256 of the run's journal.jsonl>
    ---

    # F3 audit

    ### 1. <finding title>
    severity: high
    lens: correctness
    disposition: fix_pr #42

    ### 2. <finding title>
    severity: medium
    lens: concurrency
    disposition: followup FA.3

## Multiple audit axes (code + UI)

A UI-heavy milestone is audited on two axes — the code audit and the Tier-2 UI
audit — and they are *separate runs* with their own lens sets, stats and
journals. One stat set cannot describe both, and the UI audit's survivors are
real findings that need their own disposition blocks.

The unprefixed keys describe the PRIMARY audit. `axes:` declares additional
ones, each repeating the same seven keys under an `<axis>.` prefix:

    raw: 54
    refuted: 34
    confirmed: 20
    workflow_run: wf_a3c98a73-06e
    journal_sha256: 0c1847ee...
    axes: [ui]
    ui.raw: 11
    ui.refuted: 9
    ui.confirmed: 2
    ui.lens_mode: explicit
    ui.lenses: [visual-distinctiveness, hierarchy-density, interaction-state-coverage, design-system-consistency, a11y]
    ui.workflow_run: wf_d99e6801-a36
    ui.journal_sha256: fbfd5c41...
    defects: 15

Each axis's own `raw == refuted + confirmed` must hold, axis names are
lowercase `[a-z0-9-]`, and `defects` is bounded by the survivors of ALL axes
combined (here 20 + 2 = 22), not the primary alone.

This is purely additive — a record with no `axes:` key validates exactly as it
did before — which is why it did NOT bump `sweap_format`. An optional key that
invalidates nothing is precisely the change the version exists to make
unnecessary.

Note the UI audit's critics are deliberately anonymized, so its findings carry
no lens attribution. `ui.lenses` names the lens SET that ran, not which lens
produced which finding; do not invent per-finding attribution for a UI axis.

## Rules the gate enforces

- **Flat single-line frontmatter**, inline `[a, b]` lists, values bare. The
  format contract has NO inline comments — the gate parses values literally, so
  `raw: 14  # ...` is the value `14  # ...` and fails.
- **`sweap_format: 1`** — the format version. It is what makes a future
  tightening survivable: a record already merged WITHOUT this key is classified
  legacy and reported without blocking, while a record introduced by the work
  under review is judged strictly. Never hand-write a version the installed gate
  does not speak; the gate names the mismatch.
- **All eleven unconditional keys required.** A record missing provenance/scope
  fields is not a record. (`finders_reporting` is the twelfth, always emitted
  and conditionally enforced — see below.)
- **`range_base` / `range_head` are separate keys**, and each must be a **full
  40-character commit SHA** — never `HEAD`, a branch name or a tag. The Workflow
  returns ONE string `<base>..<head>`; split it on `..`. This is ENFORCED, in two
  places: the workflow refuses to run past its Scope stage on anything else, and
  the gate fails the record. Reason: a ref satisfies every other check on this
  list while making them all vacuous — every done-flip is an ancestor of `HEAD`,
  so the range check below becomes a no-op and the record's coverage claim cannot
  be falsified. A ref is also not durable; `--check` runs again later, against a
  moved `HEAD`, so the same record would mean two different things on two days.
- **The range must bind.** `range_base` must be an ancestor of `range_head`,
  `range_head` an ancestor of `HEAD`, and every non-follow-up done item of the
  milestone must have flipped to `status: done` within the audited range. An
  audit of a stale range fails structurally — that is the point.
- **`open_at_audit: [<id>, ...]`** — the ONE exception to the line above, and
  only for a record written EARLY, while a planned hand-off was still open (the
  playbook's order is that the audit is not due until the hand-off closes; DS.5
  audited early with DS.5.13 open, as a documented exception). Name each member
  that was still an open hand-off when the audit ran. The gate then lets that
  id's flip land after `range_head`, but only if all three hold, and the last
  two are recomputed from git, not taken from the record: the id is named here,
  its status **at `range_head`** was `attended`, and its flip commit touches
  nothing outside the backlog directory. An ordinary `todo` item does not
  qualify, and declaring one fails the record rather than exempting it. Omit the
  key entirely when no hand-off was open — which is the normal case.
- **`unscored: <n>`** — findings that NO refuter ever scored, i.e. the panel did
  not run for them. Distinct from `unverified:`, which also counts the honest
  case of a finding reading could not settle. The Workflow emits it only when
  non-zero, and the gate REFUSES a record carrying `unscored > 0` unless you
  either resume the run named in `workflow_run:` and regenerate, or state in
  **`unscored_accepted: <why>`** that you are closing the milestone over a panel
  that did not run. Reason: consumer A's DS.5 run lost 115 of 330 agents to usage
  limits and emitted `confirmed: 31, unverified: 26` — 26 findings nothing had
  checked — and it passed every arithmetic check here, because nothing read the
  number. Writing the gap down was free and it passed.
- **`raw == refuted + confirmed`**, all numeric.
- **`finders_reporting: <n>`** — how many finder lenses actually returned a
  result. The Workflow emits it on every record; the gate DEMANDS it, `>= 1`,
  whenever `raw` is 0. Reason: a `0 / 0 / 0` record passes every other check on
  this list, and it is also exactly what a run whose finders all died produces
  (consumer A's F11 lost eleven finder agents to an unresolvable agent type). The
  property being enforced is *this audit ran*, which is a different claim from
  *this audit was clean*. Records written before the key existed still validate
  unless they claim zero findings — purely additive, no `sweap_format` bump.
  It is scoped to the primary axis: a `ui.raw: 0` comes from a different
  workflow, which does not emit this key.
- **One `### <n>. <title>` block per DISTINCT DEFECT.** By default that is one
  per confirmed finding. When several lenses converge on the same underlying
  defect — the normal outcome of a multi-lens ensemble, and usually the
  strongest signal an audit produces — collapse them into one block and declare
  the collapsed count with an optional **`defects: <n>`** key; the gate then
  matches blocks against `defects` instead. A collapse may only merge, never
  invent or drop: `0 < defects <= confirmed`. Do not un-collapse converged
  findings just to satisfy the block count — that destroys the analysis.
- **Exactly one `disposition:` line per block**, resolvable:
  `fix_pr #NN` | `followup <id>` | `blocked <id>`. A `followup`/`blocked` ref
  must name an item file that exists, carries `followup_of: <milestone>`, passes
  roadmap-lint, and (for `blocked`) is actually `status: blocked`.

## Migrating a `STALE:` record — transcribe, do not re-audit

A `STALE:` line means the record predates this format, i.e. it was written by an
older sweap. **The audit itself already ran.** Its findings were already
triaged, and fix-PRs and follow-up items were already opened off the back of
them. Re-running `/milestone-audit` to "fix" the record is the wrong instinct on
every axis: it spends a full adversarial audit to produce a *different* result
set, and the record you land then documents a run that nothing in the backlog
came from — the fix-PRs and follow-up items still trace to the original run.
That is strictly worse evidence than what you started with.

Migrate by transcription instead. Everything the format needs is normally
recoverable from the record and the run that produced it:

| key | where it comes from |
|---|---|
| `range_base` / `range_head` | the range the old record states, split on `..` |
| `lens_mode` / `lenses` | `audit.lenses` in CLAUDE.md as it was for that run |
| `raw` / `refuted` / `confirmed` | the stats the old record already quotes |
| `workflow_run` | the `wf_*` transcript dir for that run |
| `journal_sha256` | `shasum -a 256 <that dir>/journal.jsonl` |
| `###` blocks + `disposition:` | the dispositions the old record already records in prose — the fix-PR numbers and `followup_of:` items it produced |

Then re-run `--check`. Only if the run's evidence is genuinely unrecoverable
(the transcript is gone AND the old record does not state its stats) does
`audit.baseline` become the right home — and add it with a comment saying why,
because baseline is an acknowledgement, not a dodge. Re-audit only when no
audit ever actually ran.

## Verifying it

    bash "${CLAUDE_PLUGIN_ROOT}"/hooks/audit-gate.sh --check

Run it before opening the record PR. But understand what that run is and is not:
it is a **pre-flight for your own benefit**, and a session quoting its output is
a self-report — precisely the kind of evidence the playbook says not to trust.
The BINDING verification is the `audit-gate` required check in CI
(`.github/workflows/audit-gate.yml`), which re-runs the same script against the
PR's own checkout where no session can vouch for it. If that job is missing from
a repo, the record is unverified no matter what any transcript claims — install
it with `/agentic-loop-init` and make it required.
