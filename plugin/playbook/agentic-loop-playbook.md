# Agentic Loop Playbook

Handoff document for any Claude Code agent (or the human partner) picking up a
project that runs this pipeline. **Read the Run core below — it ends at the
`run-core:end` marker — and stop there.** Everything after it is reference, read
by heading when its situation arrives; `docs/superpowers/plans/` and
`docs/superpowers/specs/` hold per-feature history. This is doctrine: the
mechanisms below are project-independent; everything project-specific is declared
in the `## sweap config` block of the project's `CLAUDE.md` (see **How this
project is configured**).

## Run core (read this; the rest is reference)

**Who reads what.** Whoever drives an item reads THIS section, in full, and
nothing else up front — a run session, and equally any agent it delegates a
range of items to (hand that agent this section; never rewrite it for it). Every
other section is reference: read it when its situation arrives, by heading —
`sed -n '/^## Blocked items/,/^## /p' <this file>` — using the table that closes
this section. Commands (`/milestone-audit`, `/unblock`, `/handoff`,
`/walkthrough`) name the sections they need.

### Hard rules

- Tests are the spec: never edit a failing test to pass; never skip or
  quarantine a test without flagging it.
- Never touch production or real user data; no irreversible action without
  explicit human approval. Never discard work without the human's typed
  confirmation.
- Every merge requires CI's verify gates green plus a fresh-context review with
  confirmed findings addressed. Merging a green, reviewed PR is pre-authorized —
  never ask, and never weaken or bypass a gate to get there.
- The merge path is `sweap-merge watch <n>`. Never `gh pr merge`, never
  `--admin`, never a bare `gh run rerun`.
- Never commit in the primary checkout and never push to the default branch:
  work happens in the item's worktree and reaches it only through the item's PR.
- A PR that touches `.github/` is a human's to merge (the driver refuses it).
  If the work needs one, escalate; do not route around it.
- When blocked: write the question down, notify, move on. A stalled item must
  never stall the loop; a guess must never resolve ambiguity.
- Work you discover is filed, not built — as a discovered note, never an item
  file on your branch, never an index edit.
- Never create an `[attended]` item and never transition one into it: work an
  agent cannot finish is `[blocked]` with the question.
- Never spawn a background CPU load generator (the marker-and-verify recipe is
  under "Hard rules for unattended runs").
- Report honestly: failing output verbatim, skipped steps named.

### Start, or resume

1. `.claude/sweap-run.md` — the run's goal and scope. A `stalled:` line means the
   orchestrator's turn died on an API error: the run is NOT over; verify the
   in-flight item from git and `sweap-merge status`, then continue.
2. `git worktree list`, open PRs, and `docs/superpowers/plans/` for a plan with
   unchecked steps — an interrupted item is resumed before anything new starts.
3. The default branch's CI: a red tip is fixed first (`sweap-merge rerun`
   refuses a PR while the same workflow is red on the base).

**What to pick.** Only `status: todo` items whose every `depends_on` entry is
satisfied (a named item is `done`; a named milestone has every non-follow-up
item `done`). Order: follow-ups first (`followup_of:` set), then milestone order
as the index lists it, then numeric item order (F1.9 before F1.10). `attended`
is the human's, `blocked` waits on an answer, `deferred` is parked — an agent
never picks, promotes or drops any of the three. Run `sweap-roadmap-lint <file>`
on an item before dispatching it; a failing item is not runnable.

### The per-item loop

1. **Plan.** Pin the data model, access boundaries and permissions, and the
   acceptance criteria — each naming the layer that asserts it. Spec to
   `docs/superpowers/specs/`, plan to `docs/superpowers/plans/`. Check the item's
   premises against the code first: a stale premise is common, and building on
   one is the expensive mistake.
2. **Implement with TDD.** Write the acceptance tests first, each at the layer
   its criterion named; never modify a test to make it pass. **Verify locally
   with typecheck, lint, the formatter, and the tests and specs the change
   touched — not the full `verify.e2e` suite.** CI runs that on the PR, and CI is
   the gate. A local full run is for a sweep, a refactor, a test-harness change or
   a flake fix, and only while no CI job is running on this machine.
3. **Adversarial review.** A fresh-context reviewer sees only the diff and the
   plan. A re-review is a NEW dispatch with the new diff, never a message to the
   reviewer still alive. Reviewers read the local worktree, so **keep fixes local
   until every reviewer has approved, then push once** — each push to an open PR
   cancels and restarts a full e2e run. Under `/sweap:run` the script
   dispatches the reviewers and awaits them; the implementer never does.
4. **Conditional dimensions**, from the item's `review-dimensions:` —
   `security`: a dedicated security reviewer whose confirmed findings block the
   PR; `ui`: the implementer runs the ui-design skill and its hard gates must
   pass; `migration`: see "Review dimensions". All before the PR merges.
5. **Merge** with `sweap-merge watch <n>` (below), verify, clean up, next item.

**Who holds the loop.** A run session drives items with the `sweap:run`
workflow, launched from the goal's own driver sentence
(`Workflow({name: "sweap:run", args: {...}})`, args as an object): `ids` is
the batch in the kickoff's drain order, `milestone` makes the run go on to
that milestone's items — and the follow-ups of other milestones — once the
batch is drained, `max_items` bounds it, and nothing at all drains the whole
frontier in pick order (the frontier is backlog-wide, so a bare launch for an
F13 run drains F14's runnable items too). The workflow holds the loop in a
script: before every item it recomputes the frontier (`sweap-frontier`),
dispatches ONE fresh implementer that exits when its branch is committed,
reviews it with fresh reviewers (a fixer per finding), publishes it, hands the CI
wait to the small `merge-watcher` agent, and dispatches a fresh fixer per red
with every earlier round in hand. Nothing waits on CI while holding
implementation context. Never hold the loop in a long-lived agent instead: the
a consumer's F13 run's hand-written "lane runner" agents grew to 806k of context
waiting in 600-second Bash calls, and their expired caches were half the run's
cost. A dead runner fleet stops the run (`sweap-fleet`, asked at Resume and
by the watcher on a queued timeout) instead of opening PRs nobody can test.
While the workflow runs, end the turn and wait for its result; never
poll it. When it returns, the session records the run (below), runs
`/milestone-audit` if a milestone completed, and after a stop it clears the
cause if it can (a red default branch: rerun its failed job once) and
relaunches the workflow FRESH with the same args — the frontier is live, so
merged items are not picked again, and the Resume stage must run live to see
what the stop left behind.

**Discovered work.** Anything you notice that is not the item: file it and go
back. `sweap-note discovered "<title>" gap|direction "<item id or PR #n>"
"<what is wrong, and what done looks like>" "$(git branch --show-current)"`.
`gap` = the spec promised it; `direction` = it never did (when unsure,
`direction`). File everything you see and do not argue its importance — the next
`/milestone` triages gaps against the harm bar, `/roadmap` decides directions.
A status flip travels only in its own item's PR; the index changes only at
`/roadmap`.

### Merge and wait

Run `sweap-merge watch <n>` with Bash `run_in_background: true`. It ends the turn
while it waits; its ONE terminal word is the result. Inside an agent — the
`merge-watcher`, or any agent a session delegates to — there is no turn to end:
run `sweap-merge tick <PR> --budget 540` (the PR's own number — there is no default, and `tick 1` answers for PR #1) in the FOREGROUND with the Bash
timeout at `600000`, one bounded call at a time, until its closing word is
terminal (a `pending`/`green`/`merging` closing word just means call it
again). `tick` always prints its closing line; a foreground `watch` re-ticks
until terminal and can outlive the Bash timeout with nothing printed. A run GitHub reports as `pending` or `requested` — queued behind a
`concurrency:` group or a busy self-hosted fleet — is `pending`, never
`attended` (0.31.0; before that every `attended` a consumer ever saw was this):

| word | what you do |
|---|---|
| `merged` | verify and clean up (below) |
| `failed` | a red check, a gate deny or a refused merge — a FINDING first, not a retry |
| `superseded` | the head moved — re-arm `watch` |
| `behind` | the base moved — rebase the branch, push, re-arm |
| `timed_out` | a finding: say which check never finished |
| `undecidable` / `attended` | escalate: a human decides |
| `held-by:<owner>` | another live watcher owns this PR — do not start a second |

- If you believe a red is a flake: `sweap-merge rerun <n> --reason "<why>"`,
  ONCE per head and workflow. It refuses a run that is not a completed
  `failure` (so not a cancelled one) and refuses while the same workflow is red
  on the base. A second red on the same head is a finding.
- A notice that the background command "was stopped" is not a verdict: re-run
  `sweap-merge watch <n>`.
- After `merged`: confirm the item file on the default branch reads
  `status: done` (self-reported state is not trusted; a missed flip is fixed
  through the next gated PR, never by committing to main), then `git worktree
  list` / `git branch` / `git branch -r` — the cleanup hook removes merged
  worktrees and branches, you verify none linger. It never removes the worktree
  you ran the merge from: leave it, then `git worktree remove <path>` and `git
  branch -D <branch>` from the primary (its origin branch is already gone).
- Before opening any PR, sweep both inboxes into it: an untracked file under
  `roadmap/ideas/` or `roadmap/discovered/` dies with its worktree.
  `sweap-stranded` lists backlog files sitting on branches nothing will land.

**Escalating.** Set the item `status: blocked`, put the question verbatim in
`blocked:`, notify, take the next item. Never `attended`, never a guess.

### The worker brief

Hand this to every implementer you dispatch, by reference — "read the playbook
between `worker-brief:begin` and `worker-brief:end`" — then append the item file
in full, the worktree and branch, the project's verify and format commands, its
skills, and who opens the PR. Add below it; never delete a line of it.

<!-- worker-brief:begin -->
- Work only in the worktree and branch you were given. Never commit in the
  primary checkout, never push to the default branch, never edit `.github/`.
- Check the item's premises against the code before building on them; report a
  stale one instead of working around it.
- TDD: acceptance tests first, each at the layer its criterion names. Never edit
  a test to make it pass. Paste the RED and the GREEN output in your report.
- Verify with typecheck, lint, the formatter, and the tests and specs you
  touched. Do NOT run the full e2e suite: CI runs it on the PR and CI is the
  gate; a local full run shares this machine with the CI runners and makes both
  slower and flakier. The exceptions are a sweep, a refactor, a test-harness
  change or a flake fix — and then only while no CI job is running.
- Flip the item's `status:` in its own file, on this branch.
- Anything you notice that is not this item: `sweap-note discovered …`, then go
  back to the item. Never build it, never write an item file for it.
- Stop at ambiguity: report the question; do not guess.
- Report: what changed, RED/GREEN, what you verified and what you did not, notes
  filed, anything you are unsure of.
- Premises: grep every file the item names and COUNT every number it states
  before building on it (every item in one consumer run had a stale one). Build
  what the item is FOR and record the discrepancy under its `## Notes`.
- Run the unit tests your change touches BY NAME: a project's e2e command may
  not run them (a consumer's does not), so "e2e green" is not "tests green".
- Before committing, scan your added lines for `every|all|only|never|both|<a
  number>` and cut each claim you cannot check — the one defect class behind
  nine of ten blocking review findings.
- Under `/sweap:run` you do not review, push or open the PR: commit and
  return; the run dispatches the reviewer and a fixer per finding. Never
  dispatch an agent or start a review skill yourself, and leave nothing
  running in the background — it outlives your return. Driven by hand,
  reviewers run one at a time against a worktree, never two in parallel (they
  mutate the tree to verify findings and revert each other); two review
  rounds, then cut claims rather than open a third.
- Driven by hand (never under `/sweap:run`): commit in one call; push in its
  own call, plainly (`git push -u origin
  <branch>`), nothing else in it — the push gate denies a compound command and
  the denial eats the commit too.
- Before escalating a symptom, grep the backlog's `discovered/` inbox: a note on
  it may already refute your diagnosis.
<!-- worker-brief:end -->

A range of items is driven by `/sweap:run` ("Who holds the loop", above), never
by one long-lived agent given the list. Never run gates in a worktree whose
implementer is still working: two test runs in one worktree share a database
and one's teardown drops the other's mid-flight.

### Ending the run

When the goal ends — met, stopped, or out of turns — append to
`.claude/sweap-run.md`, as flat keys and inline lists, nothing else:

```
ended: <ISO-8601 UTC>
reason: frontier-empty | awaiting-human | turns-exhausted | goal-met
needs: [<ids a human must act on — only when reason is awaiting-human>]
why_not_agent: [<id>=identity|money|terms|taste|authority, ...]
```

`needs:` is ids, never prose; `why_not_agent:` says why a person is required
rather than another turn — if you cannot name why, do it yourself. Do not write
the commands the human should run; the board derives them. Then notify (when
`notify: push`): merged PRs, each blocked item with `/unblock <id>`, each open
hand-off with `/handoff <id>`. Delete the run file on `goal-met`,
`frontier-empty` or `turns-exhausted`; keep it on `awaiting-human`. When the run
finished a milestone (every item under it done), end your report to the human
with one reminder line, never a question: `<M> is done: /sweap:walkthrough <M>
to walk it with me, or /sweap:demo <M> to film what it delivered.`

### When this happens, read that

| situation | section |
|---|---|
| an item carries `review-dimensions:` | Review dimensions |
| a question only a human can answer | Blocked items |
| an `attended` item, or work only a human can do | Attended items |
| a `deferred` item | Deferred items |
| the milestone's last item merged | `/milestone-audit` runs it; Milestone audit → Findings triage, Audit evidence and the audit record |
| a follow-up carries `followup_of: <this milestone>` | it is the NEXT run's debt, not this run's work |
| a PR changes only backlog files or docs | Roadmap-only CI lane |
| no local services | Environment parity |
| why a merge or cleanup rule exists, the allowlist | End-of-run hygiene |
| the backlog's file format, the four statuses | Backlog format (file-per-item) |
<!-- run-core:end -->

## How this project is configured

The pipeline is one set of mechanisms parameterized per project. Every command and
skill reads the `## sweap config` block in the project's `CLAUDE.md`; a project
overrides only the keys that differ from the baked defaults. The keys:

- **`verify.typecheck`** — the typecheck command (project-specific; no default —
  e.g. `just typecheck`).
- **`verify.lint`** — the lint command (project-specific; e.g. `just lint`).
- **`verify.e2e`** — the end-to-end test command (project-specific; e.g.
  `just e2e`). **CI runs it in full on every PR, and that run is the
  authoritative merge gate** — the project's whole automated suite (unit +
  integration + e2e); there is no separate unit-test key. **Locally you run the
  part of it your change touches**, never the whole suite: on a consumer repo a local
  full run cost a median 23 min per item (43% of an implementer's time) and,
  sharing one machine with the CI runners, made CI's own e2e slower and flakier.
- **`backlog.file`** — the backlog **index** file (milestone list + the
  later-milestones sketch; never per-item status). Default **`ROADMAP.md`**.
- **`backlog.dir`** — the per-item backlog directory, one file per item — see
  **Backlog format (file-per-item)**. Default **`roadmap/`**.
- **`backlog.prefix`** — the milestone-tag prefix(es), as one or more
  comma-separated values (e.g. `F` or `F, DS`). Default **`F`** (so milestones
  read `F1`, `F2`, … and items `F1.1`, `F1.2`, …). Ids may be multi-segment: a
  milestone can itself carry a dot (`DS.2`) with items one level deeper
  (`DS.2.1`) — a milestone id is any item id minus its last dotted segment, and
  dependency resolution is dot-depth-agnostic (see **Backlog format**). When
  more than one prefix is configured, `/milestone` resolves the next runnable
  milestone across ALL of them, in the index's listed order — a milestone is a
  milestone regardless of prefix.
  Referred to below as *the milestone prefix*.
- **`services.up`** — optional command that brings up local test services. **Omit
  it entirely if the project has no local services** — the pipeline then runs in
  CI-gated mode (see Environment parity).
- **`audit.lenses`** — the milestone-audit finder lenses. Three modes: **`default`**
  uses the generic default lens set defined in the audit workflow (correctness,
  authz/security, data-integrity, concurrency/races, test-integrity, api-contract);
  **`default + [x, y]`** keeps that default set and appends project domain lenses
  `x, y` — the preferred, common case; an **explicit list with no `default`** uses
  only those lenses for the run, replacing the defaults entirely. CAUTION: a fully
  explicit list drops the generic default coverage, so use it deliberately, only
  when you truly want a custom set.
- **`audit.baseline`** — inline list of milestones grandfathered before audit
  enforcement shipped (e.g. `[F1, F2]`). Milestones listed here are exempt
  from the audit-gate's debt computation. Set once at adoption; never grow it
  to dodge an audit — that is the bypass the gate exists to make visible.
- **`review.dimensions`** — the conditional review dimensions a roadmap item may
  tag. Default: **`security`, `ui`, `migration`**.
- **`notify`** — end-of-run notification channel: **`push`** or **`none`**.
  Default **`push`**.
- **`turns.default`** — the default turn budget for an autonomous run. Default
  **`160`**. A turn is a session turn (a workflow launch, its return, a
  check-in), not an item — the items run inside the workflow — so the bound is
  a backstop against a session relaunching a stopped workflow forever, not a
  measure of work.
- **`test.url`** / **`test.seed`** — optional, read only by `/walkthrough`: the
  URL the acceptance pass opens (never production) and the ONE command allowed
  to create test data. Undeclared, `/walkthrough` opens nothing and seeds
  nothing by itself — the human drives.

References to `ROADMAP.md`, the milestone prefix `F`, and `just …` recipe names
below are the baked defaults; a project that overrides them reads its own values
through this block. When a project's config declares a value, that value wins.

## Backlog format (file-per-item)

The backlog is two layers, split by state lifetime. Evidence (2026-07-19
roadmap-substrate spec): every verified lab system coordinates parallel agents
through per-task files — a single mutable backlog file is the one pattern the
evidence rules out, and shared-file mutation (not markdown itself) is the
hazard.

- **`ROADMAP.md`** (`backlog.file`) — the human-facing **index**: the
  milestone list in priority order plus the "Later milestones" sketch.
  Direction-level only; it never carries per-item status, so it changes only
  at milestone boundaries (human-in-the-loop moments) and is never a
  concurrent-write hotspot.
- **`roadmap/`** (`backlog.dir`) — **one file per item**: `roadmap/<ID>.md`
  (e.g. `roadmap/F1.2.md`), the single source of truth for that item's
  status, dependencies, and spec. Parallel workers touch disjoint item files
  by construction.
- **`roadmap/archive/`** — dropped items move here (`status: dropped` plus a
  `dropped_reason:` key): a reversible soft-delete, visible in git history.
- **`roadmap/ideas/`** — the **idea inbox**: free-form idea files (frontmatter
  `title:` + `created:` only — no id, no status) captured from the sweap-board
  page's Ideas form or the `/idea` command. Invisible to lint, dep resolution,
  and the frontier (like `archive/`). `/roadmap`'s decide phase surfaces them
  as read-only context; reconcile moves triaged ones to
  `roadmap/ideas/archive/`. **Idea files are committed, not scratch** — see the
  sweep rule under End-of-run hygiene. They were untracked-until-triaged until
  2026-08-19, which lost the difference between "captured" and "still on one
  disk": a consumer carried three uncommitted ideas for up to three days while
  sessions, following their own judgment, committed untriaged ones into
  unrelated PRs anyway (2 of the 3 times an idea ever reached git). A rule the
  agents override two thirds of the time is the defect.
- **`roadmap/discovered/`** — the **discovered inbox**: work an agent noticed
  while on something else, written at the moment of discovery as a *note* —
  no id, no status, no spec; frontmatter `title:`, `kind:`, `discovered_from:`,
  `discovered_by:`, `milestone_hint:`, `created:`; body = *why*, written so a
  fresh session can act on it after the branch it was found on is gone.
  `kind: gap` = the spec promised it (a bug, a race, infra the spec assumed):
  agent work, TRIAGED by the next `/milestone` against the harm bar — promoted
  into a `followup_of:` item when the fix removes a class of harm, parked
  otherwise. `kind: direction` = not in the spec: a human's call,
  surfaced by `/roadmap` like an idea. Invisible to lint, dep resolution and
  the frontier until promoted; triage moves the note to
  `roadmap/discovered/archive/` with `promoted_to:` (or `declined:`, which for
  a park reads `declined: parked: <reason>`) appended, the only edit a note
  ever receives. Gate-exempt by path, like `ideas/`
  (`audit-gate.sh`'s "other subdirs" arm), which is what makes it safe to
  carry on any PR during audit debt. Filenames carry a hash suffix so two
  sessions capturing the same title from two branches never collide. **The one
  thing a discovered note is not is an item file on a feature branch** — see
  "Discovered work" under the per-feature loop for why.
- **`.claude/sweap-run.md`** (gitignored) is the other ephemeral file: which
  milestone `/milestone` resolved for THIS run, and the shape it resolved to.
  It exists because that resolution is the one fact no item file records —
  "debt-first", "debt-only", "hand-offs outstanding" and the deferred hand-offs
  behind them are decisions made at kickoff, and before this they were spoken
  once into a printed goal line and then lost. `/milestone` writes it (see that
  command); End-of-run hygiene deletes it. Nothing in the loop READS it to
  decide anything — status truth is still the item files — so a stale or
  missing one degrades a display, never a control. The board viewer is its only
  consumer today, for the running-milestone card.

Item file schema. Frontmatter keys are single-line and `depends_on` is an
inline `[a, b]` list — keep it flat so `roadmap-lint.sh` and plain greps stay
trivial (this flatness is a format contract, not a style preference):

    ---
    id: F1.2                 # must equal the filename (F1.2.md)
    title: <short feature name>
    status: todo             # todo | attended | blocked | deferred | done (dropped: archive only)
    depends_on: []           # item IDs (F1.1) and/or bare milestone tags (F2)
    review-dimensions: []    # from the review.dimensions config set
    followup_of:             # optional milestone tag — marks an audit-debt item
    harm:                    # optional — security | data-loss | wrong-data | outage: why a follow-up outranks features (owes a ## Harm section)
    premise:                 # REQUIRED when deferred — why it is parked, what would un-park it
    blocked:                 # REQUIRED when blocked — the question awaiting "> ANSWER:"
    carried:                 # optional int — milestone boundaries this question has survived
    handoff:                 # REQUIRED when attended — the task the HUMAN performs
    ---

    # F1.2 — <title>

    ## Spec
    - **Surface:** <files/modules this item is expected to touch>
    - **Interfaces:** <contracts produced/consumed — exact names/signatures wherever two concurrent items share one>
    - **Out of scope:** <what this item deliberately does not do>

    ## Acceptance
    - <observable behavior a test asserts, and the LAYER that asserts it>

    ## Notes
    <optional: "> ANSWER:" threads, CARRIED annotations, links>

**Authoring `## Acceptance` — each criterion names its LAYER.** The heading is
`## Acceptance`; `roadmap-lint.sh` matches it as a prefix, so
`## Acceptance (e2e)` and `## Acceptance (vitest + e2e)` are equally valid and
no existing item has to be rewritten. What changed is the default reading: the
bare `(e2e)` used to be the only spelling, and an acceptance heading is a strong
nudge — so a pure rule check that a cheap route-level test asserts perfectly well
got written as a browser spec because the heading said `e2e`.

The line to draw is what the criterion is ABOUT, not where the code lives:

- **A rule** — a permission, a tenancy scope, a 404-vs-403, a state machine's
  legal transitions, a pure function's contract — is asserted at the layer that
  owns the rule: a test against the route handler or lib function. It is no less
  authoritative for being cheap; it is usually *more* precise, because it can put
  the system in states a browser cannot reach.
- **A journey, an a11y/axe scan, a focus or geometry assertion, or a
  request-ordering race** is asserted in the browser. These are claims about what
  a person encounters, and only a real page can settle them.

`verify.e2e` **in CI** remains the authoritative gate and that is unchanged — it
runs the project's FULL automated suite (unit + integration + e2e), so a criterion
written as a route test is gated exactly as hard as one written as a browser
spec. Naming the layer is about writing the cheapest test that can actually fail
for its own subject, never about which tests the gate runs.

**The four states, and who owns each.** Status is the ownership axis, which is
why these are mutually exclusive values rather than flags: `todo` means
*agent-dispatchable*, by construction, and everything downstream (the frontier,
dependency resolution, the board's queues, milestone completeness) keys off
exactly that.

| status | whose it is | waiting on | required key | on the frontier? | needs-me-now? |
|---|---|---|---|---|---|
| `todo` | agent | nothing | — | yes, when unblocked | no |
| `attended` | **human** | the human doing it | `handoff:` | never | yes — *a planned hand-off* |
| `blocked` | agent, **stuck** | a human's answer | `blocked:` | never | yes — *a failure signal* |
| `deferred` | nobody | a human's decision to un-park it | `premise:` | never | no |

The line between the two that page the human: **`blocked:` holds a QUESTION,
`handoff:` holds a TASK.** If the human's next move is to answer, the item is
blocked. If their next move is to *do something*, it is attended. See
**Attended items** and **Blocked items** below.

Both queues have a command that *drains* them — `/unblock <id>` for a question,
`/handoff <id>` for a task. A queue that is only displayed is not worked: sweap
listed blocked items in three read-only places for months and a consumer still
carried five questions through whole milestones unasked
(`docs/research/2026-08-16-blocked-question-queue.md`).

**Spec gate (mechanical, one gate, two call sites).** An item is runnable
only if `roadmap-lint.sh` passes on its file. For a `todo` item that is the
full spec: valid frontmatter, every `depends_on` entry resolves (to an item
file, or to a milestone that has item files), `## Spec` (all three bullets) +
`## Acceptance` present, and no unfilled `<…>` placeholders. An `attended`
item is picked up by a *human* rather than dispatched, so it needs its own
self-contained instructions instead — `handoff:` plus a `## Hand-off` section,
both lint-enforced (same principle, different reader). `blocked`,
`deferred`, and `done` items are **records** — they need only valid
frontmatter (plus `blocked:`/`premise:` where the status requires it), NOT a
`## Spec`/`## Acceptance`; a deferred or blocked item earns its full spec when
it is promoted to `todo`. `/roadmap` runs it on every new/changed item
file before the milestone PR opens; the dispatching session runs it again
before dispatch. A todo item failing lint is not
runnable: fix it if the fix is mechanical, else escalate (status: blocked
with the question). Evidence: vague delegation is the dominant
parallel-dispatch failure mode; a self-contained spec naming surface,
interfaces, and out-of-scope is the lab-converged prerequisite — and when two
concurrent items share a contract, the **Interfaces** bullet is where it gets
pre-declared.

**Frontier order** (replaces the old "top-of-file order"): debt first (items
with `followup_of:` set), then milestone order as listed in the index, then
numeric item order within a milestone (numeric segment compare: F1.9 before
F1.10). An item is *unblocked* when every `depends_on` entry is satisfied — an
entry that names an **item** (an item file exists for it) is satisfied when
that item is `status: done`; an entry that names a **milestone** (no item file
of its own, but it has item files under it) is satisfied when every item in it
is done. Classification is by which files exist, not by counting dots, so
multi-segment ids (a `DS.2` milestone whose items are `DS.2.1`, `DS.2.2`)
resolve correctly alongside `F1`/`F1.1`.

**Legacy migration (one-time, agentic).** A project whose `backlog.file`
still contains item headers (`### … [todo]`-style) migrates before its next
`/roadmap` or `/milestone` proceeds: one PR through the gate that moves every
item into a `backlog.dir` file (parsed fields → frontmatter; `Depends on:` →
`depends_on`; `Premise:` → `premise:`; items under `## <milestone> audit
follow-ups` sections → `followup_of: <milestone>`), rewrites the index, and
deletes the legacy sections. Because the spec gate is todo-only, **done /
blocked / deferred items migrate as plain records** — frontmatter plus their
existing prose preserved under `## Notes`, no `## Spec`/`## Acceptance`
required. Only the `todo` items need a synthesized `## Spec` (Surface /
Interfaces / Out of scope) + `## Acceptance`. The session performs the
split (a purpose-built parser for the project's specific legacy format is
fine) and lints every produced file; multi-segment ids (a `DS.2` milestone
with `DS.2.1` items) are supported.

## Operating model — the per-feature loop

One feature = one session. Target 10–25 turns per feature; consistently >30 means
the item is scoped too big — split it. **The five steps are in the Run core**
(plan → implement with TDD → adversarial review → conditional dimensions →
merge); this section holds the reasons behind them.

- **Step 2, local verification.** The verify gates must be green before a PR
  merges, and it is CI that proves it: locally you run typecheck, lint, the
  formatter and what you touched. Where the project's services are not
  available at all, CI on the PR is the only verification (see Environment
  parity).
- **Step 3, a re-review is a NEW dispatch** with the new diff, never a message
  to the reviewer that is still alive: a re-messaged reviewer's context drifts
  and every round finds a new class of remark (a consumer's DV.9, 2026-09-07: one
  reviewer re-messaged five times, seven rounds, the last three about comment
  wording, ~600k tokens; the CI reviewer then approved the PR on its first
  pass). Non-blocking remarks belong under the reviewer's `Advisory` section and
  never flip the verdict.
- **Step 3, fixes stay local until every reviewer approves.** A consumer, last 40
  PRs: 13 of the 20 cancelled CI runs came from review fixes pushed to an
  already-open PR, each restarting a ~16-minute e2e run (398 runner-minutes),
  and on a single-machine runner fleet the overlap also slowed the run that
  finally counted (21.4 min vs 15.4).

**Discovered work — the three-lane rule.** Work you notice mid-item that is
*not* the item goes in exactly one of three places, chosen by what kind of
change it is. Nothing else is sanctioned:

1. **A new item → a discovered note.** Write it the moment you notice it, then
   go back to the item. Never build it; never author an item file for it:

   ```bash
   sweap-note discovered "<title>" gap|direction \
     "<item id you are on, or PR #n>" \
     "<why: what is wrong or missing, and what done looks like>" \
     "$(git branch --show-current)"
   ```

   (`sweap-note` is on your PATH whenever the sweap plugin is enabled — the
   plugin's `bin/` is added to the Bash tool's PATH. Run it from the repo or
   worktree root; it prints the file it created. Never write the file by hand:
   the writer owns the slug, the hash suffix that lets the same title be
   captured on two branches, and the create-only guarantee.)

   `kind` is the one judgment you make, on the line the milestone audit's
   triage already draws: failed-the-spec (a bug, a race, infra the spec
   assumed) is a `gap`; not-in-the-spec (the feature *should* do something it
   never promised) is `direction`. When unsure, `direction` — a human
   un-deciding a gap costs a minute, an agent deciding direction costs a
   milestone. Commit the note on the branch you are on and carry on: the sweep
   rule (End-of-run hygiene) lands it with the PR you are opening anyway, the
   next `/milestone` triages every `gap` against the harm bar (promoted ones
   drain debt-first, as `followup_of:` items with a real spec; the rest are
   parked), and `/roadmap` triages every `direction`. File everything you see
   and do not argue its importance — capture stays exhaustive precisely because
   a separate pass does the filtering.
2. **A status flip → the item's own PR.** Unchanged: the `status:` line in
   `roadmap/<ID>.md` travels with *that* item's PR — conflict-free by
   construction — never with someone else's.
3. **An index or direction edit — a retitle, a milestone reorder, a new
   milestone — → `/roadmap`, never mid-run.** The index is a direction-level
   document; it changes at milestone boundaries with the human present.

**Why a note and not an item file.** An item file authored mid-run on a feature
branch is backlog-advancing for the audit gate, mints its id against a branch
(two sessions can collide), and dies with an abandoned branch; a note is
gate-exempt by path, has no id, and one rescue PR can carry it. The sanctioned
path is also the cheap one — the roadmap-only CI lane (next section) — because
agents route around an expensive rule.

## Roadmap-only CI lane (why landing a backlog file is cheap)

A PR that changes only backlog files (`<backlog.dir>**`), `docs/**` and
markdown cannot change what e2e tests, so the scaffolded `ci.yml` skips its
`e2e` job for it: a `changes` job classifies the diff with the VENDORED
`.github/scripts/ci-lane.sh` — an allowlist; an empty or uncomputable diff is
`code`; `.github/**` is always code — and `e2e` runs unless the lane is
`roadmap-only`. `lint`, `typecheck`, `test`, `audit-gate` and the review never
skip: a job skipped by an `if:` reports SUCCESS and satisfies a required check,
which is exactly why `audit-gate.yml` forbids it for the gate.

The merge hook does not trust the skip. `pre-merge-gate.sh` accepts an `e2e`
check in state SKIPPED only when the plugin's own copy of `ci-lane.sh`, run on
the PR's file list, also says `roadmap-only`; a PR whose `e2e` was skipped but
which touches code, or reports no files, is denied, and any *other* gate check
in state SKIPPED is denied outright as a misconfiguration. One script, two
readers: the lane CI took and the lane the gate accepts cannot disagree.

Why this is load-bearing rather than an optimisation: on a consumer repo every extra PR
cost TWO e2e runs (the PR, then the `push` to main) on a runner that shares the
agents' CPU — a docs-only PR measured 24.8 minutes — and that price is what
pushed agents to bundle backlog files onto unrelated feature branches. The
discovered-note rule above holds only while the sanctioned path is the cheap
one; this lane is what makes it so. A consumer that adopted sweap before the
lane existed gets `ci-lane.sh` vendored by the scaffold's self-heal and adds
the `changes` job from the template by hand — the scaffold never overwrites a
project-owned `ci.yml`.

## Environment parity (local machine vs. Claude Code web / cloud)

The loop runs identically in any environment because **CI is the authoritative
test gate, not the local machine.** CI runs the verify gates (including
`verify.e2e`) against the same services on every PR, and the merge gate requires
every CI check green — so an item **cannot** reach `status: done` without e2e
passing in CI, regardless of where it was written.

- **Local (services available):** if `services.up` is declared, `/milestone` runs
  it (starting the daemon if the command is daemon/Docker-based), then the local
  gates are a fast pre-check before pushing — typecheck, lint, and the specs and
  tests the change touched: seconds of feedback instead of waiting on CI, never
  the full suite (CI runs that). If `services.up` is *not* declared, the loop runs in CI-gated
  mode: the gates that need no services run locally and everything else is
  verified by CI on the PR.
- **Web / cloud (no local services):** skip local services entirely. Run the
  no-service gates (`verify.lint` + `verify.typecheck`) locally, push the PR, and
  let CI run test + e2e + review. Merge on green. Slower per item (CI minutes vs.
  local seconds) but the exact same gate and the same result.

`/milestone` detects the environment and picks the path automatically. Do not
treat "e2e ran locally" as a merge requirement — "CI e2e green on the PR" is the
requirement, and it holds in both environments.

## Kickoff commands

- **`/roadmap [milestone]`** — brainstorm the next milestone into item files
  under `roadmap/` plus the index (the 3-phase decide → cross-check →
  reconcile). Defaults to the next unspecced milestone. Interactive.
- **`/milestone [milestone] [turns]`** — if `services.up` is declared, brings up
  local test services itself (starting the daemon if needed; falls back to
  CI-gated mode when services are unavailable), then prints the ready-to-paste
  `/goal` for an autonomous run — one line, and the goal names the driver, so
  that one paste is the whole kickoff. Defaults to the next runnable milestone
  and `turns.default` turns. You never run `services.up` by hand; the paste
  step exists only because a human must invoke `/goal`. Ritual:
  `claude --permission-mode auto` → `/milestone` → paste. When the run's scope
  contains unblocked hand-offs, the pre-flight asks whether to do them first and
  prints `/handoff` commands instead — see **Attended items**.
- **`/handoff [id]`** — walk one `status: attended` item with the human: do
  every part an agent legitimately can, check its *Done when* condition, and on
  their explicit confirmation flip it to `done` through a gated PR. Interactive
  only; never invoked by an unattended run.
- **`/unblock [id]`** — walk one `status: blocked` item with the human: brief the
  question, prepare the fork (options, a recommended default, what each answer
  produces), take their answer, and close it through a gated PR — to `todo` with
  a spec authored, or to `done` when the answer produces no work. Prepares
  everything; answers nothing. Interactive only; never invoked by an unattended
  run. `/roadmap`'s step 0 does the same for the whole queue at a milestone
  boundary — see **Blocked items**.

## Review dimensions (tagged per backlog item)

Each item file carries `review-dimensions: [...]` frontmatter, drawn from the project's
`review.dimensions` set (default `security`, `ui`, `migration`). Rules:

- **`security`** — required for any item touching auth, permissions,
  access-control rules, new data tables with access rules, or session handling.
  Dispatch a dedicated reviewer agent that runs the built-in `security-review`
  skill against the branch diff, with explicit attention to authorization
  boundaries and permission bypasses. Confirmed findings block the PR.
- **`ui`** — required for any product-visible surface. The implementer MUST run
  the **ui-design** skill, which orchestrates the project's UI process and
  composes the aesthetic-craft sub-skills. Two things carry teeth:
  - **Hard gate (blocks the PR):** the deterministic checks — axe a11y, keyboard/
    focus + required empty/loading/error states, the "no arbitrary values"
    token/primitive-reuse lint (raw hex / arbitrary utility values fail), and the
    **surface-contract structural checks**. The
    token-reuse lint **activates once the project's design system has shipped** —
    once the design system exists, new UI that bypasses it cannot merge; UI
    already in flight before the design system landed is not retroactively blocked
    (a11y/interaction checks still apply).
  - **Advisory ratchet (mandatory to run):** the bounded render→critique→fix loop
    and its multi-dimensional aesthetic verdict. Findings are address-or-justify →
    roadmap follow-up, never an auto-block (the VLM judge is ~69.5% human-aligned
    and can mode-collapse). Browser control (claude-in-chrome / webapp-testing) is
    the loop's hands and stays exploratory — never a CI gate; whatever should stay
    fixed becomes a deterministic Playwright/axe test.
  For net-new or redesign/composition UI work the implementer MUST consult Mobbin
  when available and record the archetype + reference app(s) (or a `Mobbin
  unavailable: <reason>` note) in the PR. A behavior-preserving retrofit is
  exempt **only when the composition it inherits was itself ever approved** — a
  recorded brief or the designated exemplar, pointed at in the PR. Retrofitting
  onto scaffolded composition inherits nothing; the exemption is evidence-gated
  rather than self-classified, because the exempt path is the cheap path and an
  exemption an agent grants itself becomes the default route.
  All product-visible UI builds on the project's declared design system (tokens +
  primitives) **and on its surface contract** — the committed cross-screen
  invariants (page shell, width system, control-height scale, sticky regions,
  overlay-vs-route navigation model, breakpoints). Tokens make a screen correct;
  they do not make two screens match, and every other UI control judges one
  screen at a time, so without the contract a token-clean app still drifts
  screen by screen (`docs/research/2026-08-19-cross-screen-consistency.md`). The
  contract's deterministic clauses are enforced by checks that **enumerate the
  route inventory, not the diff** — a diff-scoped lint only ever sees the screens
  someone touched. The contract is authored in `/roadmap`'s decide phase, never
  by an implementer mid-item; the human remains the spot-check on
  visual polish, authored as an `attended` hand-off (see the ui-design skill).
- **`migration`** — any schema change beyond a new table: reviewer checks
  reversibility, data backfill, and access-control continuity.

Untagged items get the standard fresh-context review only. The orchestrator
may ADD dimensions it judges necessary; it may not remove tagged ones.

## End-of-run hygiene (mandatory)

- **Sweep both inboxes into whatever PR you are already opening.** Before
  committing, `git status` the `<backlog.dir>ideas/` and
  `<backlog.dir>discovered/` directories; any untracked idea file or discovered
  note rides along in this PR. It costs one line in the diff and it is the
  only mechanism that covers ideas captured from the board's Ideas form, which
  writes over HTTP with no session behind it and can never open a PR itself. Do
  not open a separate PR for them mid-feature, and do not hold them back for
  `/roadmap` — an idea sitting untracked is one `git clean` from gone, and the
  human wrote it. (`/idea` flushes both inboxes itself when nothing is in
  flight; this rule is what catches everything else. An inbox-only PR is never
  backlog-advancing — `audit-gate.sh` classifies `<backlog.dir>ideas/` and
  `<backlog.dir>discovered/` as non-item subdirs — so it lands even during
  audit debt, and it rides the roadmap-only CI lane, so it is cheap.)
- **Before you abandon a branch, or stop on one, check it is not carrying
  backlog files.** Run `sweap-stranded`:
  one line per not-merged branch whose `<backlog.dir>` differs from main, with
  its PR state. `open` is a rider and fine; `closed` or `none` is **stranded**
  — invisible to the frontier, the board's backlog, the gate and `/roadmap`,
  with nothing scheduled to ever land it. Rescue inbox files (`discovered/`,
  `ideas/`) with a docs-only PR: `git checkout -b roadmap/rescue-<6hex>
  origin/main && git checkout <branch> -- <paths>`, commit, open the PR (it
  rides the roadmap-only lane). Stranded top-level item files or index edits
  are listed for the human, not relayed blindly — they need `/roadmap`
  judgement and may be gate-denied. The `post-merge-cleanup` hook runs the same
  scan after every merge and reports stranded branches to the session, and the
  board shows them, so a stranded file cannot go quietly — but the scan is a
  detector; the rescue is yours to do. Then delete the dead branch so it stops
  firing.
- **Record how the run ended, before deleting anything.** Append `ended:`,
  `reason:` and (for `awaiting-human`) `needs:` to `.claude/sweap-run.md` — see
  `/milestone`, "Record the end of the run". A run that stops without recording
  why is indistinguishable from one that died, and "I asked the human in chat"
  is not a record: no tool can read it.
- **Delete `.claude/sweap-run.md`** when the run ended with reason `goal-met`,
  `frontier-empty` or `turns-exhausted` — it describes THIS run and, left
  behind, makes the board's card claim a run that is over. **Do not delete it
  when the reason is `awaiting-human`**: it is then the board's only record of
  whose answer the run is waiting on (`needs:`/`why_not_agent:`); the next
  `/milestone` kickoff overwrites it (one run at a time). Gitignored, so
  deletion is a plain `rm -f`, never a commit. (The card ignores a run file
  whose milestone has no unfinished items, so a missed delete after `goal-met`
  only stales the shape line — a run stopped mid-milestone is exactly the case
  that backstop cannot detect.)
- **Never commit to the local `main` checkout — not even docs.** Every commit
  happens in a worktree and reaches `main` only through a PR. (This keeps the
  primary checkout from diverging; auto-mode cannot hard-reset it later.)
- After each PR merges, run the full cleanup — **unconditionally, no judgment
  call.** Nothing needs a merged branch or worktree afterward: `main` has the
  squashed result and GitHub keeps the PR (and a "Restore branch" button), so the
  branch/worktree are pure clutter. **Do not rely on `gh pr merge --delete-branch`
  to remove the branch in this repo.** In a worktree-per-PR flow the branch is
  always checked out in its worktree, so gh's post-merge local-branch delete aborts
  (`cannot delete branch '…' used by worktree …`, or `'main' is already used by
  worktree …`) and it never reaches the remote delete — `--delete-branch` silently
  leaves the branch on **both** the local repo and origin. Running from the primary
  checkout does **not** fix this (verified: the branch is still checked out in its
  worktree either way). The reliable sequence, in order:
  1. **Merge:** `sweap-merge watch <n>` — the merge driver (see "The merge
     path" below); it waits, runs the gate, merges, and runs the post-merge hooks.
     The driver ENDS THE TURN while it waits, so read its terminal word as the
     result. (Its inner merge omits `--delete-branch`, the no-op footgun here.)
  2. **Fast-forward the primary** (`git -C <primary-checkout> pull --ff-only`) so
     `main` never drifts (`--ff-only` no-ops on local changes).
  3. **`git worktree remove <path>`** — this frees the branch from its worktree.
  4. **`git branch -D <branch>`** — now succeeds (force `-D`: squash-merged branches
     aren't ancestors of `main`, so `-d` refuses them; safe, the PR is merged).
  5. **`git push origin --delete <branch>`** — the ONLY reliable remote delete; a
     pure remote op unaffected by worktree/checkout state.
  6. **Verify none linger:** `git worktree list`, `git branch`, `git branch -r`.
- In practice the plugin's `post-merge-cleanup` hook does steps 3–5
  **automatically**, so you usually just merge (1), let the hook clean up, and
  verify (6). The hook (shipped by the plugin and wired via `hooks/hooks.json`) fires
  after any `gh pr merge`, fast-forwards the primary, prunes stale
  remote-tracking refs, and for any worktree whose branch has a **merged** PR
  removes the worktree, deletes the local branch, **and `git push origin
  --delete`s its origin branch** (the reliable remote delete `--delete-branch`
  fails to do here). It only ever touches merged-PR branches, never
  `--force`-removes (so a dirty in-flight worktree is safe), and **skips the
  worktree the caller is standing in** — it will not delete the live session's cwd
  out from under it, so that worktree and its local branch are left for the
  explicit manual step (or the next hook pass once the session has moved on). Its
  origin branch is deleted all the same, as long as origin still holds the merged
  PR's head (a branch name reused for new commits is kept). A worktree removed by
  hand before the hook saw its PR merged is invisible to every later pass: delete
  that origin branch yourself (step 5). The hook is belt-and-suspenders: still
  run/verify the cleanup yourself.
- Item status updates (the `status:` flip in the item's `roadmap/<ID>.md`) are
  part of the item's PR, not separate commits — conflict-free by construction
  (disjoint files). Verified, not trusted (agent-self-reported task state is
  unreliable — Anthropic's own agent-teams docs): after a merge lands, confirm
  the merged item file on `main` reads `status: done`; a missed flip is a
  worker error, fixed through the next gated PR (e.g. folded into the next
  queued item's branch), never by committing to `main`.
- At goal end (met or stopped): if `notify` is `push`, send a push notification
  summarizing merged PRs, blocked items (each with `/unblock <id>` and its
  `carried:` count, so the summary is actionable rather than a list), and **open
  hand-offs** (`status: attended`, with what each one gates — the human's own
  queue is part of "what now?", not a detail); list any leftover worktrees/branches
  in the final message; the primary checkout is already current (see above), so
  `git pull --ff-only` is a no-op for the human.
- **Merge gate (substitute for branch protection, unavailable on the free
  GitHub plan):** never `gh pr merge` until `gh pr checks <n>` shows every
  check green — including the `review` check. The `review` check now **enforces
  the verdict**: its final job resolves the reviewer's verdict line and fails
  closed on "Verdict: needs-work" or on no verdict at all, so a green `review`
  check structurally means the reviewer approved. Read the reviewer's inline
  comments and address every one before pushing the fix; a "needs-work" verdict
  is the GitLab-style "resolve the threads before you can merge" — you clear it
  by fixing and re-pushing, which re-runs the review. (The gate is skipped only
  on PRs that edit the reviewer workflow itself, which self-skip the action.)
  - **Where the verdict is read from, and what counts.** Three surfaces are
    scanned — issue comments (the `gh pr comment` form the prompt prescribes),
    PR review bodies (what the inline-comment tool submits), and inline review
    comments — because the reviewer does not reliably use the prescribed one.
    Two rules keep that width from weakening the gate: the verdict must be the
    **last non-empty line** of a comment (a substring match anywhere let a
    *quoted* "Verdict: approve" outrank a real trailing needs-work), and the
    comment must be **newer than the head commit** (otherwise an approve from a
    previous push satisfies a run whose reviewer errored out and posted
    nothing). A run that posts no verdict anywhere still fails closed — that is
    the reviewer failing to do its job, not the gate misreading it.
  - **The greenness check is HOOK-ENFORCED.** A `PreToolUse` hook
    (`pre-merge-gate`, shipped by the plugin and wired via `hooks/hooks.json`) fires on
    every `gh pr merge`, independently queries the PR's `statusCheckRollup`, and
    **denies the merge** unless every check is green — plus it denies
    `--admin`/`--repo`/`-R` outright. On any uncertainty (gh errors/times out) it
    denies *recoverably* (fail-closed, never fail-open, never a permanent wedge);
    a later retry passes once checks are green. A `PostToolUse` backstop
    (`post-merge-redcheck`) re-checks after a session-issued `gh pr merge` and, if
    `main` somehow landed red, prints a loud banner so the run opens a remediation
    PR (it never commits to `main`; `sweap-merge` does not need it — its gate runs
    in the driver's own loop). **Why it
    exists:** the instruction-level gate silently failed once — a `gh pr checks
    <n> --watch | tail` pipe masked the real exit code (a pipe returns `tail`'s
    `0`), so a PR whose `e2e` had FAILED got merged and briefly broke `main`. The
    hook removes the human-reads-the-output link. This *strengthens* the gate and
    never weakens it — the hook only ever denies, never auto-approves.
  - **The push gate.** The same hook denies any `git push` whose destination
    resolves to the base branch (`main`/`master`, `origin/HEAD`, or
    `SWEAP_BASE_BRANCH` from the hook's env) — `origin main`, `HEAD:main`,
    `refs/heads/main`, `--delete main`, `--all`/`--mirror`, and a bare
    `git push` while on the base or when `push.default` would land there.
    Item-branch pushes, `--force-with-lease` to item branches, `--delete <item>`,
    tags and `main:<item>` pass. It is local-only (no `gh`) because a stalled
    hook fails open. Over-blocks are recoverable: re-issue the push plainly.
    Override `SWEAP_PUSH_GATE=off` is honoured only from user-level settings
    `env` or the shell that launched Claude Code; the hook ignores it when the
    project's `.claude` settings define it, and an inline `VAR= git push`
    prefix never reaches the hook.
  - **Self-modifying CI is never session-mergeable.** The same hook denies any
    `gh pr merge` whose PR touches `.github/workflows/**` or
    `.github/scripts/**`, whatever its check state (the PR ran its own copy of
    every check); a human merges those from the web UI or their own shell, and
    the run records the PR as a `status: blocked` question.
- **Waiting discipline (upstream of the gate).** These four rules are what
  `sweap-merge.sh` implements (next bullet); a session should not hand-roll
  them. They stay here as documentation of what the driver does. The gate
  decides at merge time; the waiting before it is where runs have burned the
  most time. Four rules, each bought by a documented incident (a consumer
  2026-08-21/22, one run):
  **(1) Absence is not a pass.** A check that has not been reported is not
  green: wait on the expected set being *present and succeeded*, never on
  "nothing is pending" — an empty rollup satisfies `all(…)`-style predicates
  vacuously, and a just-pushed head has no checks at all for a window.
  **(2) Pin to the head SHA.** Re-resolve the PR's head each poll; a force-push
  silently retargets a branch-pinned waiter onto history.
  **(3) Own your liveness signal.** Wait on a PID or run-id you own, never a
  `pgrep -f` pattern — it matches the waiting loop's own command line.
  **(4) Retry discipline lives INSIDE the loop.** Only re-run a workflow run
  whose status is `completed` (GitHub refuses otherwise, and a refusal with
  discarded stderr inside a sleep-loop is a livelock — #189 went to attempt 41);
  re-run ONCE as diagnosis, never retry-until-green; stop if the same check is
  red on the base branch. One watcher per PR, owned by the session that merges.
  **(5) The waiter is a background shell, and the harness may kill it.** Claude
  Code kills a session's background Bash tasks on a macOS memory-pressure event
  once the user has been away ~30 min with the model idle and no subagent
  running — by process GROUP, so everything the task started dies with it. It
  arrives as `Background command "…" was stopped`. consumer PR #237 went green at
  19:31 and merged at 19:57, by hand, because of exactly that (2026-09-02).
  sweap's scaffold now writes `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`
  into the project's `.claude/settings.json` `env` block, which turns the reaper
  off — but it is read when a task is BACKGROUNDED, not when it is killed, so it
  protects sessions started after it lands, never the one that added it. Commit
  it. Treat the rest of this rule as live regardless: it is an internal flag
  reached through a documented mechanism, and if it is ever renamed, prevention
  lapses silently.
- **After a "was stopped" notice, re-run `sweap-merge watch <n>`. Do not reason
  about whether the watcher survived.** Re-running is cheap and idempotent: it
  takes over a dead watcher and reports `held-by` against a live one. Do not
  reason from a heartbeat: a killed watcher's EXIT trap releases its lease, so a
  recent heartbeat with no lock is what a DEAD watcher looks like, and reading it
  as "someone is on it" is what turned a lost notification into a 26-minute
  stall. `sweap-merge status <n>` now decides it for you instead of leaving it to
  be inferred — the lease records its holder as `<session>:<pid>`, so status asks
  that pid and answers `NO WATCHER — … (pid N) is gone` or `watcher pid N alive`,
  naming the command to arm one either way. And never substitute a hand-rolled `until …; do sleep 60; done` for the
  driver: the same incident lost 26 more minutes to one waiting on the wrong
  event (the PR leaving `OPEN`, which nothing was going to produce once its
  merger was dead).
- **The merge path is `sweap-merge watch <n>`** — a bare command, and it is how
  a PR lands. **Not `${CLAUDE_PLUGIN_ROOT}`:** that variable is exported for
  HOOK execution only and is UNSET in a model-issued Bash call (verified —
  `echo "[${CLAUDE_PLUGIN_ROOT:-UNSET}]"` prints `UNSET`), so 0.13.0's
  advertised `bash "${CLAUDE_PLUGIN_ROOT}/hooks/sweap-merge.sh" watch <n>`
  expanded to `bash /hooks/sweap-merge.sh` and could not run: the driver
  appeared ZERO times in a consumer's first run that had it. What makes the bare
  name work is that Claude Code adds **`<plugin-root>/bin` to the Bash tool's
  PATH for every enabled plugin** (measured: enabled plugins with no `bin/` on
  disk still contribute their bin path to `$PATH`), so the plugin ships
  `bin/sweap-merge`, a wrapper that resolves the plugin root from its own real
  path and execs `hooks/sweap-merge.sh`. Nothing is written per session and
  nothing is copied out of the plugin. `sweap-merge status [<n>]` reports what
  the driver is doing; `just merge <n>` / `just merge-status` are terminal
  conveniences that call the same command.
  Run it with Bash `run_in_background: true` (Monitor optional) — **it ends
  the turn while it waits**, and its terminal word, not the tool call, is the
  result. It waits, verifies
  conclusiveness from the base branch's workflows (expected set present and
  succeeded on the current head), runs the merge gate itself, merges pinned to
  that head, and runs the post-merge hooks. One terminal word: `merged`;
  `failed` (red check / gate deny / merge refused — a finding, not a retry);
  `superseded` (head moved — re-arm); `behind` (base moved — rebase, re-arm);
  `undecidable` (expected set not computable, e.g. `paths:` — escalate);
  `timed_out` (deadline passed — a finding); `attended` (a check needs a human);
  `held-by:<owner>` (another live watcher owns the PR — don't start a second).
  On `failed`: a red run is a finding first. If you believe it is a flake,
  re-run it ONCE, by hand, through the driver — `sweap-merge rerun <n>
  --reason "<why>"` — never with a bare `gh run rerun`. The verb issues the
  same `gh run rerun --failed <run-id>`, but it refuses unless the run is
  `completed` with conclusion `failure`, refuses if the same workflow is red on
  the base's tip (a red main makes rerunning the PR pointless), and unless no
  rerun was ever recorded for that head SHA *and workflow* — one per head and
  workflow, ever; a second red of the same workflow on the same head is a
  finding, not a flake (a different workflow going red on the same head gets
  its own one rerun — consumer PR #319's shape). A bare `gh run rerun` from a
  session is denied by the merge gate and redirected here, so every rerun is
  on record. On accept it records `reruns[]`
  (head, run ids, reason, who, when) in the PR's state file, re-arms the
  deadlines, and the next `sweap-merge watch <n>` waits as usual. If that head
  then reaches green, the driver files ONE discovered note (`flaky: <workflow>
  went red then green on rerun for PR #<n> (<reason>)`, kind gap) and appends
  a line to it for each later flake of the same workflow — so the flake rate
  is on record instead of in someone's memory. The driver still never reruns
  on its own. Consumers must allowlist it in project `.claude/settings.json`:
  **`Bash(sweap-merge:*)`** — the `:*` suffix is the documented equivalent of a
  trailing ` *`, so it matches `sweap-merge watch 12` and bare `sweap-merge`,
  and the space it implies keeps it from matching some other `sweap-merge…`
  program. That rule is writable only because the name is stable: a prefix
  pattern against the script's own path is not, since the plugin cache path
  carries a commit sha and changes on every version bump. The driver is
  deliberately **not vendored** into `.github/scripts/` the way `audit-gate.sh`
  is: it resolves the merge gate (`pre-merge-gate.sh`) and the post-merge hooks
  from its own directory, so it must run from the plugin dir beside its
  siblings. A copy in the consumer repo would find neither — `bin/` gives it a
  stable name *without* moving the script out of the plugin dir.
- **Merge from the consumer's own session.** The gate is a plugin hook scoped
  to the project the session was started in; `cd <other-repo> && gh pr merge`
  from a different project's session runs with no gate at all. Open the repo,
  then merge.
- **Merging an unblocked item's PR is pre-authorized — do not ask.** You do not
  wait for `gh pr checks <n>` to be green first; the driver's whole job is that
  wait (and it fails closed on anything else). It is a
  standing authorization: `sweap-merge watch <n>` with no confirmation prompt — the
  driver does its own waiting and gating, and ends the turn while it waits.
  The *gate* is the control, not a human click; pausing to ask "may I merge?" is
  a judgment the gate already answered. (This is why some earlier runs prompted
  and some didn't — the confirm was a per-run judgment call, not a rule. Stating
  the authorization here removes the ambiguity.) The one thing never
  self-authorized: **weakening the gate to get a merge** — editing
  `.github/workflows`, `gh workflow disable`, changing required checks, setting
  `SWEAP_PUSH_GATE`, editing any settings `env`, or pushing to the base branch. A run
  must never be able to turn off the verification that makes its own autonomy
  safe; if the gate is in the way, escalate, don't disable it.
- **Allowlist scope and its limit (`.claude/settings.json`).** The `gh` allowlist
  is scoped to the verbs the loop uses — reads plus the two intentional writes
  `gh pr create` and `gh pr merge` — so `gh pr close`, `gh issue close`,
  `gh run delete`, etc. still prompt. **`Bash(sweap-merge:*)` belongs in that
  list too** (plus `Bash(sweap-roadmap-lint:*)`, `Bash(sweap-stranded:*)` and
  `Bash(sweap-note:*)` if those are to run unprompted): an allowlist that
  names `Bash(gh pr merge:*)` and nothing for the driver makes the raw merge
  the frictionless path and the driver the one that prompts — which is half of
  why a consumer's first run with the driver available never used it. An advertised
  preference loses to an allowlisted idiom every time. Be aware it scopes *verbs, not flags*:
  `Bash(gh pr merge:*)` also matches `gh pr merge --admin` (force-merge past
  checks) and `--repo <other>` (act on a different repo). Two things keep this
  from being a hole: **(1)** on the free plan there is *no branch protection*, so
  nothing GitHub-side enforces gate-greenness regardless of flags — the agent
  reading `gh pr checks` before merging is the actual, and only possible, control
  (see above), and `--admin` therefore changes nothing today. **(2)** Standing
  instruction: the agent merges **only the current repo's** green PRs and never
  passes `--admin`, `--repo`, or its short alias `-R` to `gh pr merge` /
  `gh pr create`. **For `gh pr merge` this is no longer instruction-only:** the
  `pre-merge-gate` `PreToolUse` hook mechanically denies `--admin`/`--repo`/`-R`
  on merges (and enforces greenness — see the Merge-gate section). The standing
  instruction still governs `gh pr create` (not hooked). `git rebase` and
  `git push --force-with-lease` on an item's own branch are routine loop verbs
  (a BEHIND branch is updated that way).

## Attended items (planned human hand-offs)

An `[attended]` item is work that **was always the human's to do** — a step
needing credentials, an account, hardware, a legal identity, a third-party
approval, or a taste decision. Nothing failed; the work simply is not an
agent's. It is not `[todo]` (that means agent-dispatchable), and it is not
`[blocked]` (nothing is stuck and there is no question to answer).

**Why it must be an item at all.** The alternative is what happens without this
status: authoring scopes the human part out of an item — usually into an
`- **Out of scope:**` bullet — and it lands nowhere. That is a *deletion, not a
hand-off*: invisible to the index, to lint, to the frontier, to the board, and
to milestone completeness, so the milestone reports itself complete with the
human's part never done. The prior art is unanimous here: every workflow engine
that ever coordinated people and machines gave human work its own node type
(BPMN's *user task* vs *service task*), and the current agent frameworks are
re-deriving the same primitive as first-class human-in-the-loop state. See
`docs/research/2026-08-16-planned-human-handoffs.md`.

**Everything else already does the right thing.** Because `attended` is a
status value and not a flag, the frontier (`status: todo` only), dependency
resolution (satisfied only by `done`), the blocked queue, and the audit gate's
milestone-completeness computation all behave correctly with no special cases.

**Authoring (the only way one is created).** Hand-offs are declared during
`/roadmap`'s decide phase, with the human present — the brainstorm asks
outright what in the milestone is not an agent's to do, and
`milestone-cross-check`'s human-dependency lens catches what it missed. Two
authoring rules carry weight:

- **Write the `## Hand-off` section for a reader who is not you** — why it's
  theirs, the concrete steps, and a *Done when* condition that can be checked.
  `/handoff` walks exactly this.
- **Give a hand-off as few dependencies as possible.** A hand-off buried
  mid-chain serializes the whole run on one person, and wait time — not
  execution time — is the dominant cost. Authored dependency-free, it is
  startable on day one and runs *concurrently* with the agents' drain.

**Surfacing (day one, not day nine).** `/milestone`'s pre-flight lists every
unblocked hand-off in the run's scope **before** printing the goal, with what
each one gates, and offers to walk them then and there. Skipping is a legitimate
choice with a stated cost, and it changes the run shape (see `/milestone`'s
hand-offs-outstanding goal template). The end-of-run summary lists open
hand-offs alongside blocked items; the board gives them their own column,
`🙋 Yours`, deliberately separate from `⛔ Blocked` — a needs-me-now list that
mixes *an agent failed* with *this was always yours* is one the human stops
reading.

**Completion.** `/handoff <id>` walks the item, does every part it legitimately
can, checks the *Done when* condition, and — only on the human's explicit
confirmation — flips `status: done` through a normal gated PR. An unattended run
never flips it. A hand-off that is started but cannot finish yet (waiting on a
third party) stays `attended` with a `> **STARTED (YYYY-MM-DD):** <what's
pending>` note under `## Notes`. One that stops mattering is archived with a
`dropped_reason:` like any other item.

**An open hand-off keeps its milestone incomplete**, so the milestone-audit is
not due until it is closed. No merges are blocked and no audit debt accrues —
the audit is simply not owed yet. That is the leverage that makes a hand-off
impossible to ignore, and the accepted cost is that audit timing depends on a
person.

**If you audit early anyway, declare it.** Auditing a milestone while one of its
hand-offs is still open is a documented exception, not the order above — and it
has a price the exception used to hide: the record's `range_head` predates the
hand-off's flip, so flipping it later fails the gate's range binding and NO PR
can satisfy it (a consumer's DS.5.13, 2026-09-03). Pay the price at audit time instead
of discovering it at flip time: put every still-open member in the record's
**`open_at_audit: [<id>, ...]`** list. It is a coverage claim in the record's own
diff — these members were not covered by this audit — and the gate verifies it
from git rather than believing it: the id must have been `attended` at
`range_head`, and its flip must touch nothing outside the backlog directory. The
flip then lands in one ordinary PR alongside the declaration.

**Never an escape hatch (mechanically, not just by rule).** An agent must never
relabel its own stuck work as human work — escalate-don't-guess is unchanged:
stuck work goes to `[blocked]` with the question, full stop. Because `attended`
is a legitimate stop condition for a run, that relabel would be a genuine
shortcut, so it is enforced rather than requested: `audit-gate.sh --check` fails
if any item's `status: attended` was introduced by a commit other than the one
that *added* the file. **A hand-off is authored, never transitioned into.** For
a deliberate re-assignment ("actually, F2.3 is mine"), archive the item with a
`dropped_reason:` and author the hand-off as a new one — both halves visible in
the diff. Why a check and not a rule: instructions are advisory and, per the
reward-hacking literature, telling a model not to take a shortcut can even
increase the behaviour; every other tempting shortcut in this pipeline
(`--admin`, merging red, skipping the audit) is denied by a mechanism, and this
one is no different.

## Blocked items (a question awaiting an answer)

A `[blocked]` item is **active work that is stuck** because a human has to decide
something. Writing one is correct behaviour — escalate-don't-guess — and the
authoring rules are unchanged: the question goes in `blocked:` verbatim, the
human is notified, and the run moves to the next item.

What was missing, until 2026-08-16, was the other half: **nothing drained the
queue.** Blocked items appeared in the end-of-run summary, on the board, and in
the loop's stop condition — three read-only displays — while the questions
survived milestone after milestone (a consumer: five of six questions outlived a full
authoring-and-draining cycle; one outlived two). The fix is a **closing event at
the boundary**, not a fourth place to look.

**Working one.** `/unblock [id]` walks a single question: brief, prepare, take
the answer, close it through a gated PR. `/roadmap`'s **step 0** works the whole
queue at the milestone boundary before the brainstorm starts. Both use the same
classification, and both are bound by the rule below.

**The agent prepares; the agent does not answer.** For any question, the agent
may restate the fork, list the options, recommend a **default with its
rationale**, and simulate what the resulting item file looks like under each
answer. It may propose closing a question only in two evidenced cases: the
premise has been *invalidated by shipped code* (attach the diff), or the
double-turn simulation shows *both answers produce the same item file*, so the
fork was never a direction call. Everything else — taste, scope, policy,
cross-milestone information architecture — is the human's, and stays theirs.

Why this is written as a hard rule rather than left to judgement: having the repo
in context makes it *easier*, not harder, to talk yourself out of asking. The
2026-08-16 research memo (§4) cites the finding directly — retrieved context
makes models less likely to ask a clarifying question and more likely to assume
an interpretation. A step that says "check whether these are answerable" is that
condition exactly, which is why it ends in a classification instead of an answer.

**Aging, and the deadline.** `carried: N` counts the milestone boundaries a
question has survived unanswered. `/roadmap`'s step 0 is its only writer; it
increments on each boundary the item is not resolved at and records
`> **CARRIED (YYYY-MM-DD):** unanswered through <milestone>.` under `## Notes`,
adding `> **RECOMMENDATION (YYYY-MM-DD):** <default> — <rationale>` if the item
has none. `audit-gate.sh --check` prints a non-failing `AGING:` line per open
question, so the boundary's own pre-flight reports what is pending.

At **`carried: ≥2` the question is asked, not offered**: the next `/roadmap` does
not start its brainstorm until the item is answered, defaulted on the human's
explicit say-so (recorded as an answer marked `(default taken)`), or dropped with
a `dropped_reason:`. Below that it stays a soft gate — surfaced, offered, and the
skip recorded with its cost. An unanswered direction call is legitimately
deferrable in a way audit debt never is; `carried:` is what bounds the deferral.

**Closing one.** On the human's answer, append `> **ANSWER (YYYY-MM-DD):**` under
`## Notes`, keep `blocked:` and `carried:` as the record of what was asked and how
long it waited, and then either:

- **the answer produces work** → `status: todo`, *with `## Spec` and
  `## Acceptance` authored from the answer* (a blocked item is a record without a
  spec, and `roadmap-lint.sh` requires both for `todo` — the flip is real work,
  not a status edit); the item then rejoins the frontier like any other, which is
  how an answered question gets built in the next run; or
- **the answer produces no work** → `status: done` with the answer as the record.
  The decision *is* the outcome. Keep the file in place rather than archiving it:
  it stays findable as the reason the behaviour is what it is, and `done` keeps
  milestone-completeness arithmetic correct.

**Never**: relabel a blocked item `attended` to get a run-stop — a hand-off is
authored, never transitioned into, and `audit-gate.sh --check` enforces it.

## Deferred items (parked)

A `[deferred]` item is parked: nobody is working on it and nothing is stuck.

- `[blocked]` = active work is **stuck** and needs a human answer to continue
  *now*. It sits on the "needs-me-now" queue and pings the human.
- `[attended]` = a **planned hand-off**: the human's own work, waiting on them
  to do it (see **Attended items**).
- `[deferred]` = **parked**. It never pulls the human's attention and an agent
  never picks it, never promotes it and never drops it.

Every deferred item carries a `premise:` — one line saying why it is parked and
what would un-park it (*"parked 2026-09-20 — no harm class"*, *"waits on F4's
billing surface; re-decide when F4 lands"*). Two things park an item: the harm
bar (`/milestone`'s triage step, and the one parked-findings item an audit
files), and a human at `/roadmap` setting aside a good idea whose time has not
come. Work that merely waits on a dependency does not need this status — a
`todo` item with an unsatisfied `depends_on` is already off the frontier.

**Only a human un-parks**, at `/roadmap`, which lists the deferred items next to
the inboxes: flip it to `todo` (it then needs a real spec — the lint gate is
todo-only), re-spec it, or drop it to `roadmap/archive/` with a
`dropped_reason:`. One exception to the drop: a follow-up an audit record names
is never archived — the gate fails a record whose file is gone.

## Milestone brainstorm (before a milestone starts)

Authoring a milestone's item files is direction-loop work —
interactive-only, done with the human. It runs in three phases; the pair of a
decisive pass and an independent completeness critic is the same finder/refuter
shape as the audit.

1. **Decide** (interactive) — `/roadmap`'s decide phase, with the human.
   Socratic, one question at a time; it *locks* the core decisions and produces
   draft items in the item-file format (frontmatter + Spec/Acceptance body —
   see **Backlog format (file-per-item)**). This is where the human's
   decisions get extracted.
2. **Cross-check** (automated) — dispatch a fresh-context critic using the
   `milestone-cross-check` skill. It reviews the draft against a fixed lens
   (non-goals, role coverage, locale/timezone, data-lifecycle & cross-feature
   interaction, edge-case policies, AC testability, scope tiering, success signal)
   and surfaces *only the net-new forks the brainstorm missed*, each with a
   recommended default. It flags; it never rewrites or expands scope. (Distilled
   from the product-management `write-spec` lens so we own it with no plugin
   dependency.)
   For a **UI-heavy milestone**, the **surface contract** — the cross-screen
   invariants every screen will share (`ui-design` §2) — is locked with the human
   in the *decide* phase above, not here; this phase only flags contract forks
   the brainstorm missed, like any other fork. It belongs in the direction loop
   and nowhere else: a contract settled item-by-item is not a contract, because
   whichever item merges first silently becomes the standard.
   Cut the work by that contract too — **one item per invariant applied across
   the whole inventory**, not one item per screen. Per-screen items re-apply the
   very unit that let the screens drift apart, and yield N individually-plausible
   screens that still disagree; "responsive" and "feels high-end" are dimensions,
   never screens.
3. **Reconcile** (brief, interactive) — the human answers the net-new forks;
   writing, linting and merging the items is `/roadmap` steps 3–4, which is the
   source.

Rationale: a single decisive pass is fast but blind-spotted. The A/B that
motivated this: a decisive pass locked a milestone's core but missed timezone
handling and a cross-record overlap case; an independent breadth pass caught both.
Phase 2 makes that second lens a standard, cheap step instead of luck.

## Milestone audit (after a milestone completes)

When the last item of a milestone merges, run the saved audit workflow via
`/milestone-audit`, always passing the milestone id being audited —
`{milestone: "<id>"}`, optionally with `{range: "<base>..<head>"}` too when
known. Passing the milestone id is what lets the workflow refuse to run if it
resolves a different one (see "Audit evidence" below) — omitting it disables
that guard. It audits the merged whole with the finder lenses declared in
`audit.lenses` — by default **the generic default lens set defined in the audit
workflow** (correctness, authz/security, data-integrity, concurrency/races,
test-integrity, api-contract), optionally extended with **domain lenses the
project appends via `audit.lenses`** (the preferred `default + [...]` form), or
replaced entirely by an explicit list when the project deliberately wants a
custom set — and adversarially refutes every finding — only majority-surviving
findings are reported. It exists to catch what per-PR review structurally
cannot: cross-feature interactions, systemic patterns, and plan-level mistakes.

**A panel that stopped answering is resumed, not written up.** The audit is a
Workflow, and a Workflow run is resumable by its run id: `Workflow({scriptPath,
resumeFromRunId})` replays the completed prefix from cache and re-runs only what
failed, so a resume costs the dead dispatches and nothing else. The run itself
will NOT stop when the panel dies, and that is deliberate: an in-run circuit
breaker was built and removed, because from inside the script a dead panel and a
slow one are not distinguishable in time — the failure reason never reaches it,
and "consecutive empty dispatches" over a concurrent fan-out aborted a healthy
run at 9% loss while catching the real outage under a third of the time. The
detection is at the GATE instead, on the finished record, where `unscored` is a
fact rather than an inference. Resume when capacity is back, BEFORE triaging
anything: a finding no
refuter scored is not an adversarially-confirmed finding, and the record's
`unscored:` count is what the gate refuses. A consumer's DS.5 run lost 115 of 330
agents this way, recovered 65 on a resume and never recovered 50, and the record
still read as a finished audit — a resume does not self-complete either, which is
why the count is checked rather than assumed. If you genuinely mean to close a
milestone over a panel that did not run, say so in `unscored_accepted:` and own
it; do not let "documented the gap" be the cheap way past the gate.

The operational recipe (run the workflow, triage, write the record from the
workflow's `record` field, `--check`, land it in one PR) is `/milestone-audit`;
the record format and every rule the gate enforces on it are
`playbook/audit-record.template.md`. This section is the doctrine those two
implement.

### Auto-launch and read-only toolset

**Auto-launch (pre-authorized in the goal).** A milestone `/goal` run carries a
final clause so the audit fires once, automatically, at the milestone boundary —
no cron, no standing agent. **`/milestone` prints the goal text and is its only
owner** — a copy kept here drifted from it. Two things about that text are
load-bearing: the stop clause excludes `followup_of: <milestone>` items, because
a correct audit ends by CREATING work and a run that audits well could otherwise
never stop (a consumer's F11 run hit exactly that); and both stop conditions have a
drain the stop message must name — `/unblock <id>` for a question, `/handoff
<id>` for a task.

(A milestone with an **open hand-off** cannot complete, so its audit is not yet
due and this template does not apply — `/milestone` prints its
hand-offs-outstanding variant instead, which drops the audit clause and says so.
See **Attended items**.)

This applies to **every** milestone regardless of prefix — a second prefix
(e.g. `DS*`) gets audited exactly like the primary one (`/milestone` resolves
across all configured prefixes and always emits the audit clause; see
`backlog.prefix` above). A milestone `/goal` that omits the audit-and-triage
clause is **malformed**: the run drains its items but stops before auditing,
which is stopping early — the audit is part of the milestone's definition of
done, not an optional extra. If a milestone goal is ever hand-written rather
than printed by `/milestone`, the audit clause still travels with it.

The goal's completion state is the audit run and triaged; its other ends
(nothing runnable, a stop you cannot clear, the turn cap) are successful ends
of the run, never completions of the milestone — record them as
awaiting-human or frontier-empty, never goal-met. The `/milestone-audit` workflow finds and reports confirmed
findings; it never edits code. What happens next is the **triage** the
surrounding session performs (below): a bucket-1 fix is a deliberate, gated
*follow-on* PR the session opens, not something the audit workflow does silently.

**Read-only is a toolset, and the toolset has to be addressable.** A plugin
agent registers under its **scoped** name (`sweap:audit-reader`); the same file
in a repo's own `.claude/agents/` registers **bare**. The workflow resolves:
scoped name, then bare name, then — if the runtime rejects both — whatever name
the not-found error says it *does* have, which survives a plugin or marketplace
rename the script cannot see. What it never does is fall back to *no* agent
type: an unresolvable agent is a thrown error, because the alternative is the
default toolset, which can `Write`. (a consumer's F11 audit lost all eleven finders
to `agent type 'audit-reader' not found` before this resolution existed.) Watch
for this class when reviewing: a guarantee that depends on a name is only as
good as that name's addressability in the install it lands in.

**Read-only is a toolset, and its scope is exact.** The workflow's finders and
refuters run as the `audit-reader` agent — `Read`, `Grep`, `Glob`, with no
`Write`, `Edit` or `Bash` — so they *cannot* write to the repo. That is enforced
at three independent layers, because a `tools:` line is a *definition-time*
restriction and a botched edit dropping it inherits every tool without erroring:
the `tools:` list, a `disallowedTools:` list (applied first, so it survives that
edit), and `audit-agent-guard.sh` — a `PreToolUse` hook that fires inside
sub-agents, reads `agent_type`, and denies at the moment of the call regardless
of whether either list took effect. That third layer carries the weight, because
workflow sub-agents run with file edits auto-approved and no human prompt behind
them. The same hook confines `audit-prover` to its worktree by denying an
absolute-path write outside the session cwd; its `Bash` is deliberately NOT
path-checked, because a shell line cannot be parsed reliably enough to be a
control, and pretending otherwise would be worse than saying so. The `Scope`
stage needs `Bash` for `git log` and is therefore governed by instruction only;
say that rather than claiming the whole workflow is sealed. The precision is
earned: until 2026-08-16 "read-only" was doctrine addressed to the calling
session, never to the agent holding the tools, and a refuter wrote a test file
into a consumer's primary checkout to settle a claim empirically. **A guarantee
asserted to a third party is not a guarantee.**

### Evidence, refutation and validation

**Evidence and a number, not a verdict — and the number lives in the pipeline.**
A refuter returns four things about a finding, every time: the `path:line`
spans it actually read, the code it found bearing on the claim, what would
falsify its own answer, and `confidence` — its probability, 0 to 1, that the
finding is **wrong**. It does not return a label. The pipeline cuts: a
refutation is a score strictly above `TUNING.refutedAt` (**0.5**), and
`TUNING.killVotes` (**2**) of the three seats kill a finding. Both numbers live
in one `TUNING` block in the workflow, and the prompt interpolates them so it
can never quote a stale price.

Why a score rather than labels: the three-valued `refuted`/`stands`/`unverifiable`
verdict put the decision boundary inside the model, priced its options
asymmetrically (two costly inlets, one free sink), and the switch to a score
took the panel's kill rate from 63–73% to **2.7%** with an unchanged control
axis holding at 40% — the fix is not better labels, it is no labels. The
research, with every quote re-fetched and string-matched, is
`docs/research/2026-08-18-refuter-verdict-design.md`.

**Evidence is required symmetrically.** The answer that leaves a finding alone
cites code on exactly the same terms as the answer that kills it — the required
schema fields do not branch on which way the score points, and an answer citing
no code is a **schema violation** that the model is made to retry. Never a
demotion: a demotion is a drain into whichever answer is cheapest, which is the
mechanism this design exists to delete.

**`unverifiable` is an out-of-band ticket, not a verdict.** A refuter that
cannot settle a claim by reading names the exact command in `experiment` —
*and still scores*, on what it did manage to read. The ticket **suspends** the
finding for the Validate stage rather than resolving it, and being off the
scoring axis is the whole point: a ticket cannot take probability mass from a
score the way a third label takes it from the other two. One ticket routes
(`TUNING.proofTickets`).

**Why the kill threshold is still 2.** Not because it is known to be right —
there is a real argument for 1 (under documented positive bias an agreeable
majority is the failure mode, and the paper making that case proposes a
minority veto), but the same paper says the optimal threshold "requires a
calibration set with ground-truth labels", and flipping it on intuition re-rolls
the dice that produced 63% and 2.7%. What is fixed is the *renormalisation*:
never "a majority of votes cast", because that lets two lost votes promote the
third refuter to a majority of one. Lost and unscored votes are excluded from
the numerator with the threshold left where it is. **The next piece of work is
the labeled set** — seeded known-bad and known-good findings — and until it
exists no kill rate can be called right or wrong.

**The Validate stage — the empirical gate, spent only where reading ran out.**
When a refuter has ticketed a surviving finding as unsettleable by reading, one
`audit-prover` agent runs the named experiment and returns a verdict backed by a
pasted command and its actual output. It has `Bash` and `Write`; its containment
is `isolation: 'worktree'` — a throwaway git worktree, auto-removed if unchanged
— rather than tool removal. Be equally honest about that: worktree isolation
relocates the working directory, it is not a jail, and an absolute path escapes
it; the agent's own instructions forbid absolute paths, and the failure it
contains is the accidental one that actually happened, not an adversarial one.
The stage exists because adversarial reasoning catches reasoning errors and not
empirical ones. It is dispatched **conditionally**: a worktree per refuter would
mean ninety sandboxes to settle a handful of verdicts. Its own verdict is still
categorical and three-valued, deliberately — that agent *has* the capability,
and its `unverifiable` means "I tried to run it and something blocked me", a
fact it earned rather than a bucket it fell into. Nothing routes onward from it.

**`unverified` findings are a coverage gap, not a defect.** A finding that
survived because nobody could check it is reported separately — a subset of
`confirmed`, plus an optional `unverified:` key in the record and a
`status: UNVERIFIED` line in its block. Triage it as **bucket 2**, a follow-up
item that writes the missing experiment, not as a bucket-1 bug. Never let it be
counted as "confirmed by adversarial review": that claims three adversaries
failed to refute it when in fact three adversaries never looked. A large
`unverified` count is itself the finding — it means the audit's reading tier is
out of its depth on that surface. The block says which of two things happened:
the sandboxed run *could not settle it either* (answered, a coverage gap) or
*was lost* (the prover died — resume the Workflow before triaging). A block
carrying a `Sandboxed run:` section and no `UNVERIFIED` line was settled by
execution and is a verified defect.

**A zero-findings audit must prove it ran.** "This audit was clean" and "this
audit ran" are different claims, and a `0 / 0 / 0` record makes the first while
the second may be false — it is also exactly what a totally failed run produces.
The workflow **throws** rather than returning when no lens reported, lists in
`lenses:` only the lenses that actually ran, and every record carries
`finders_reporting: <n>`, which `audit-gate.sh` demands (`>= 1`) whenever `raw`
is 0 (see the template's "Rules the gate enforces"). A finding no refuter ever
scored is likewise counted as `unverified` rather than as adversarially
confirmed.

### Audit evidence and the audit record

**Audit evidence (mandatory).** The audit only counts if it runs *after* the
milestone's last item has actually merged to the project's default branch —
never from an integration branch, a worktree, or any pre-merge state, since
the workflow reads the merged repo itself. Goal-met requires the workflow's
returned `{milestone, range, stats}` to be quoted verbatim in the run's
summary; a prose "audit clean" claim with no quoted workflow artifact is a
malformed run, not a completed one. A 0-confirmed result is only acceptable
evidence when the echoed `milestone` matches the one that was just shipped —
if it names a different milestone, the run audited the wrong thing and must
be treated as failed, not clean (a 2026-07 run once passed a stringified range
where the workflow expected `{range, milestone}`; the string was silently
discarded, the Scope stage fell back to "most recently completed milestone",
and the run audited the prior milestone while reporting the newly-shipped one
clean). The workflow now throws instead of guessing whenever the args shape
is ambiguous or the resolved milestone doesn't match what was requested — a
thrown error is the correct outcome for a misconfigured run, not something to
route around.

**The audit record + gate (mechanical enforcement).** The audit's definition
of done includes a committed record at `<backlog.dir>audits/<milestone>.md`
(range SHAs, lens set, raw/refuted/confirmed counts, one block per confirmed
finding with its disposition — see `/milestone-audit`). The record is what
makes "the audit ran, on the right range, and its findings went somewhere"
machine-checkable: `hooks/audit-gate.sh` recomputes the binding from git
ancestry (a record for the wrong milestone or a stale range fails
structurally) and verifies every disposition resolves. A completed milestone
without a valid record is **audit debt**: the merge gate denies any
backlog-advancing merge (roadmap item files) until the record PR lands;
code-only PRs (hotfixes, chores) pass. What this cannot do — by design and
per the attestation literature — is judge audit QUALITY: a real-but-shallow
audit passes the gate. The adversarial refuter design and the human on the
direction loop remain the answer for that.

**The record format is versioned (`sweap_format`)**, and the schema lives in
one place — `playbook/audit-record.template.md`, "Rules the gate enforces".
Every record carries the current version; there is no grandfathering (a
milestone that predates adoption goes in `audit.baseline`). When you bump the
format, bump `RECORD_FORMAT` in `hooks/audit-gate.sh`, the `SWEAP_FORMAT`
constant in `workflows/milestone-audit.js` and the template together, and
migrate the merged records in the same PR.

### Enforcing the audit gate in CI

**Enforcing the audit gate in CI (consumer repos).** This is SCAFFOLDED, not
copy-pasted: `.github/workflows/audit-gate.yml` ships in `templates/` and
`scaffold.sh` installs it — including into repos that adopted sweap before the
control existed. Run `/sweap:init` to force it. What you do with it then
depends on your GitHub plan — read the plan paragraphs below before assuming you
can make it a required check.

This job is not a convenience. It is the ONLY surface that validates a record
against the state it will actually land in — the local pre-merge hook detects
debt discharge at PATH level and structurally cannot check validity, because the
record being discharged is not merged yet. Everything else is a backstop.

The gate script is **vendored** into the repo at `.github/scripts/` (both
`audit-gate.sh` and the `roadmap-lint.sh` it shells out to) and kept
byte-identical to the plugin's copy on every session start: a cross-repo
checkout of a private repo needs a PAT in every consumer, and a required check
that dies when that token expires blocks every PR — the same "gate depends on
infrastructure it polices" failure as pinning it to a self-hosted runner. Those
files are sweap-managed, not project-owned: the scaffold REWRITES them when they
drift, as an ordinary diffable working-tree change. Customize via repo
variables, never by editing them. *Why in the repo, not just the plugin:* on
2026-08-11 a consumer merged a malformed record and authored a whole milestone
on top of the debt while every local control was stale-cached three days behind.
**Any control that lives only in the plugin is a control whose version you do
not know.**

**The milestone boundary — the one merge the gate cannot ask for a record on.**
The audit is only legal against the merged default branch (§"Audit evidence"),
so on the PR that flips a milestone's *last* item to `done`, the record cannot
exist yet. The gate exempts a milestone that is **not** complete at the mainline
anchor but **is** complete in the state under review — a *missing* record only
(a present record is still validated strictly), per-milestone (inherited debt
still denies that PR), failing closed when the anchor cannot be resolved. One PR
later the anchor contains the completion and the exemption stops applying by
construction. **So the audit is still mandatory; it is merely sequenced after
the merge that makes it possible.** Merge the completing PR, then run
`/milestone-audit` for it before anything else touches the backlog.

**Required checks may not be available to you — plan the enforcement, not just
the check.** Branch protection and rulesets are a PAID feature for private
repos: on a Free plan both APIs 403 with *"Upgrade to GitHub Pro or make this
repository public"*. sweap's reference consumer is exactly that — a private
Free-plan repo — so "make it a required check" is doctrine that cannot be
followed on the primary target. Know which case you are in:

**Private repo on Free (the default assumption).** There is no server-side
required check, so enforcement is `pre-merge-gate.sh`: it denies `gh pr merge`
unless EVERY entry in the PR's `statusCheckRollup` is green, and once the job is
installed `audit-gate` is one of those entries. That is real enforcement for
agent-driven merges — the way these repos are actually developed — and it is why
the CI job earns its place even with no ruleset behind it. Two residual gaps,
both worth naming out loud rather than pretending away:
  - A **merge from the GitHub web UI** consults no local hook and cannot be
    blocked. On a Free-plan repo `post-merge-auditcheck.sh` is therefore not
    belt-and-suspenders; it is the ONLY thing covering that path, which is why
    it alarms loudly and leaves a durable marker instead of just logging.
  - The hook is plugin-delivered, so it carries plugin-version skew — the
    original failure. The CI job does not, which is the point of having both.

**Public repo, an org, or GitHub Pro.** Rulesets are available; make the check
required and observe the rules below. The GitHub Actions app id is `15368`:

    gh api -X POST repos/OWNER/REPO/rulesets --input - <<'JSON'
    { "name": "main", "target": "branch", "enforcement": "active",
      "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
      "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" },
        { "type": "required_status_checks", "parameters": {
            "strict_required_status_checks_policy": false,
            "required_status_checks": [
              { "context": "audit-gate", "integration_id": 15368 },
              { "context": "ci-status",  "integration_id": 15368 } ] } } ] }
    JSON

Do NOT add a required-approving-review rule on a solo repo: GitHub forbids
approving your own PR, so it wedges every merge. Setting
`strict_required_status_checks_policy: true` additionally makes GitHub report
`mergeStateStatus: BEHIND` — the state `pre-merge-gate.sh` works around with the
compare API precisely because a free-plan repo never reports it.

Hard-won rules for the required check, WHERE ONE IS AVAILABLE (research memo,
2026-08-08):
- **Never** put the job behind a `paths:` filter or a job-level `if:` — a
  job skipped by an `if:` reports SUCCESS and *satisfies* the required check
  (GitHub-documented). Always run; the gate is cheap.
- Pin the required check to the **GitHub Actions app** in the ruleset, never
  "any source": commit statuses can be posted green by any push-access token,
  while check runs are App-only.
- Keep the default `GITHUB_TOKEN` read-only — otherwise the actor can edit the
  validator out of its own way.
- Protecting `.github/workflows/**` and `.github/scripts/**` by path needs a
  PUSH ruleset, which is org/Enterprise-scoped and unavailable to a personal
  repo on any plan. Do not put it on the setup checklist as though it were a
  step. What a personal repo actually has instead: every edit to those files
  appears in the PR diff, and the scaffold rewrites the vendored gate from the
  plugin on the next session, so drift is reverted automatically. That is a
  drift control, not a security control against a determined actor — say so
  rather than implying protection nobody can configure.

### Findings triage (three buckets)

**Findings triage (three buckets — the session running the audit sorts them).**
1. **Bug** (code fails its own spec): the session opens a follow-on fix-PR
   through the gate. Hands-off in an unattended run (no human needed), but still a
   separate gated PR — the audit workflow never edits code.
2. **Small gap / non-urgent** (races, infra): apply the **harm bar**
   (`/milestone`'s triage step owns it). A finding whose fix removes a class of
   harm becomes its own item file with `followup_of: <milestone>` and `harm:`
   (`status: todo`, tagged, lint-clean) and is **auto-folded, debt-first, into
   the next `/milestone` run** — or a standalone **debt-only run** when no
   milestone is runnable. Every finding with no class is **parked**: one
   `status: deferred` item per audit lists them by record block, so each
   disposition resolves and nothing schedules them. True is not the bar —
   follow-ups outrank features, so the bar is the harm the fix removes.
3. **Design / scope gap** (the feature *should* do something it never promised):
   this is a **direction-loop** change, not correctness — do NOT spec or build
   it. Write it as a `status: blocked` item file with the question verbatim in
   `blocked:`, push-notify the human, and move on. It waits for their
   `> ANSWER:` line exactly like any escalation. (If the finding needs a human
   *action* rather than a decision — rotate a key, register a domain — that is a
   hand-off: an `attended` item with a `handoff:` task. Same triage bucket, the
   status follows question-vs-task as always.) This is how a change-of-direction gets back to a human:
   a notification plus a waiting roadmap entry, never an autonomous scope
   expansion. The dividing line between bucket 1 and 3 is the acceptance
   criteria — failed-the-spec is a bug; not-in-the-spec is a direction call.

### UI audit

**UI audit (UI-heavy milestones).** When a completed milestone carries
product-visible UI, run a **UI audit** at the boundary alongside the code audit,
per the ui-design skill. It mirrors this workflow's finder→refute shape but with
UI lenses (visual distinctiveness, hierarchy/density, interaction & state
coverage, design-system consistency, a11y): **independent, anonymized critics**
(an ensemble, never a consensus-seeking debate), **comparative/pairwise** judging
against the committed internal exemplar first and Mobbin references second
(when available), and **independent refutation, majority-survives**. Confirmed
findings triage into the same three buckets and auto-fold into the next
`/milestone` run — aesthetic findings as ratchet/roadmap items, a11y findings with
gate weight.

A UI audit is a SECOND AXIS on the same milestone record, not a second record.
It is its own run with its own lens set, stats and journal, so it lands in the
record's frontmatter as `axes: [ui]` plus `ui.*` keys, and its survivors get
their own disposition blocks (see `playbook/audit-record.template.md`); the gate
bounds `defects` by the survivors of all axes combined. Do NOT fold a UI audit's
stats into the code audit's counts — they measure different runs, and a record
claiming one set of numbers for both is unauditable. Its critics are anonymized,
so record the lens SET that ran and never a per-finding lens attribution.

Running the audit is a deliberate token spend; it is pre-authorized per-run via
the goal clause above, or triggered manually.

Rationale: loop tightness with machine verification remains the PRIMARY
throughput lever, and on this backlog it is very nearly the only one. Frontier
parallelism (next section) recovers CI dead time on genuinely independent items
— which measured **17%** of transitions in a consumer repo, worth **+9.4% at K = 2**. It
is opt-in for that reason; a serially-dependent milestone gains nothing from it
and simply runs the serial loop.

## One item at a time (serial by design)

A run works ONE roadmap item at a time. sweap shipped a coordinator mode
(`parallel: 2+`) and removed it on measurement: across ~99 consecutive consumer
merges only ~17% had two items genuinely in flight together — the rest were
dependency-chained — which is +9.4% at width 2 (Amdahl), bought with board
upkeep, a re-verifying merge queue that RAISES total CI minutes, and workers
forced CI-gated by one shared local services stack. A `parallel:` key or a
`lane:` key in an older project is ignored.

Worktree-per-PR, `post-merge-cleanup.sh` and the pre-merge gate's compare-API
freshness check were never concurrency machinery and stay: `main` moves under an
in-flight branch at width 1 too, and a Free-plan repo never reports BEHIND.

## The three loops (what autonomy replaces, and what it can't)

1. **Correctness loop — fully automated.** Gates: `verify.typecheck`,
   `verify.lint`, the `verify.e2e` gate, immutable tests, fresh-context agent
   review, agentic CI on PRs. No human needed for a PR to be trustworthy.
2. **Prompting loop — fully automated.** The backlog is the interface (index +
   item files): the agent always picks the first unblocked item in frontier
   order. Loops/cron/headless runs keep sessions
   going without a human typing prompts. **Escalate, don't guess:** if an item is
   ambiguous or a gate stays red after ~3 distinct attempts, set the item's
   file to `status: blocked` with the written question in `blocked:`, notify
   the human, move to the next item. Never bluff through ambiguity.
3. **Direction loop — stays human.** The human writes/re-aims the roadmap and
   acceptance criteria (~1 hr/week), answers blocked questions async
   (~15 min/day), **does the work only they can do** (the `[attended]`
   hand-offs — credentials, accounts, third-party approvals, taste calls), and
   personally approves anything irreversible: production deploys, data
   migrations against real data, anything touching sensitive production data.
   The hand-offs are the half that used to be invisible: unlike the other three
   they produce no artifact unless something tracks them, which is what
   `[attended]` is for.

## Claude Code mechanisms available

| Mechanism | What it does | Who initiates |
|---|---|---|
| Agent tool / background agents | Spawn subagents (research, review, parallel features in worktrees) within a session | Claude |
| Workflow (multi-agent orchestration) | Deterministic fan-out: parallel finders + adversarial verifiers; use for audits/reviews, not feature code | Claude, on the user's explicit ask — the goal's driver sentence is that ask for `sweap:run` |
| `/goal` (built-in) | Sets a stop condition checked by an evaluator model after every turn; Claude keeps chaining turns until the condition is demonstrably met. Preferred driver for roadmap execution: `/goal <condition, incl. verification commands shown in transcript> or stop after N turns`. **User-only — Claude cannot invoke `/goal`; a human pastes it** | User sets once; Claude sustains |
| `/loop` + self-scheduled wakeups | Time-paced recurring iteration; better for polling/monitoring (CI, deploys) than for goal-directed backlog work | User starts once; Claude sustains |
| Cron jobs / scheduled cloud agents (`/schedule`) | Sessions that start on a schedule (nightly deps bump, backlog grooming, post-merge audit) — a scheduled kickoff runs `/milestone` non-interactively; a cloud routine cannot merge while CI runs on self-hosted runners that are off | Claude can create; runs unattended |
| Headless `claude -p` + auto permission mode | Scripted/CI-triggered sessions; classifier gates commands | Scripts/CI/events |
| Agentic CI (GitHub Actions) | Claude reviews every PR; merge gated on green e2e + clean review | Git events |
| `claude --continue` / `--resume` | Reopen a session after a crash/reboot from its on-disk transcript. Not run protection: default auto-compact on 1M models fires near the limit, after quality has degraded — end runs via `turns`/frontier | User |
| `/board` (read-only viewer) | Local loopback page showing the live run (frontier/in-flight/open-PRs/hand-offs/blocked) + backlog + dep graph; derives state from item files + git + PRs, never writes | User runs; safe during autonomous runs |
| `/handoff <id>` | Walks one `[attended]` hand-off with the human, then flips it to done through a gated PR on their explicit confirmation | User runs; interactive only |
| `sweap-merge watch <n>` (`sweap-merge status`) | Background merge driver for one PR: waits on the base branch's expected checks pinned to the head, runs the merge gate, merges, runs the post-merge hooks; exits with one terminal word. Run via Bash `run_in_background: true`; Monitor optional. A bare command because the plugin's `bin/` is on the Bash tool's PATH — `$CLAUDE_PLUGIN_ROOT` is unset in a model-issued Bash call. Allowlist `Bash(sweap-merge:*)` | Claude (the session that owns the PR) |
| `/unblock <id>` | Walks one `[blocked]` question with the human — prepares the fork, never answers it — then closes it through a gated PR (`todo` + authored spec, or `done`) | User runs; interactive only |
| `sweap:run` (workflow) | The per-item loop held in a script: frontier before every item (`sweap-frontier`), one fresh implementer per item, the `merge-watcher` agent for the CI wait, a fresh fixer per red; strictly serial; `{ids, milestone}` scope it to the kickoff's batch and then one milestone. Pauses at a 5-hour limit (twice per run, interactive subscription session only), stops at a weekly wall, a dead agent or a red base; a relaunch is a fresh launch with the same args (the frontier is live) | The run session, from the goal's driver sentence; a human only pastes the goal |
| `sweap-fleet` | Can the self-hosted runner fleet run this repo's CI: the label sets CI targets (from the newest run of each workflow) against the runners online, plus runner versions retiring within a week. Read-only JSON. The run's Resume stage, the `merge-watcher` and `/milestone` all ask it, so a dead fleet stops a run instead of queueing a PR per item | Claude (any stage), or the user |

## Model policy

- Implementation grind: the current Opus tier at high effort is sufficient — the gates are
  designed so correctness doesn't depend on the model being right first try.
- Planning, spec-writing, adversarial review, security audits: use the
  strongest available model tier — these are the judgment-heavy stages where
  model quality shows.

## Hard rules for unattended runs

**The rules are in the Run core, at the top of this file** — they moved there so
that an agent that reads only the start of the playbook has them. What stays
here is the one recipe too long for the core.

- **Never spawn background CPU load generators.** If a test genuinely needs
  load, put a unique marker in the command (`yes > /dev/null # sweap-load-<id>`),
  kill by that marker, and VERIFY zero survivors — `pgrep -f <pat>` matches the
  waiting loop's own command line and `jobs -p` is empty in a non-interactive
  shell, so both produce silent no-op cleanup loops. Orphans reparent to init
  and outlive the session: a consumer burned ~4h35m at load average 111 on three
  stray `yes`, where one PR's checks took 7m44s and failed vs 2m4s and passed
  after the kill. A run that leaks them poisons every later timing measurement
  and every CI run on the machine.

## Standing preferences (pre-answered skill checkpoints)

The human's standing answers — treat them as given, do not re-ask in a session.
Worktree isolation, the PR-only finish and TDD are hard rules and worker-brief
rules above, not preferences.

- **Plan execution mode:** `/sweap:run` — the script holds the loop and gives
  each item a fresh implementer (continuous, no between-item check-ins).
- **Milestone brainstorm:** three phases — decide (interactive) →
  `milestone-cross-check` skill (completeness critic, automated) → reconcile
  with the human. See the Milestone brainstorm section. Deciding scope is
  interactive-only: unattended runs never brainstorm scope — they execute
  roadmap items that already have approved specs.

## Build order to full autonomy

1. **Agentic CI** — GitHub Actions: e2e on PRs + Claude PR review + merge gating.
2. **The backlog** — the `ROADMAP.md` index plus the first milestone broken
   into 3–5 feature-sized item files with acceptance criteria; a rough sketch
   of the next milestones in the index. This is the direction-loop artifact;
   its quality bounds everything downstream.
3. **Supervised runs** — a few `/goal`-driven sessions with the human watching,
   to calibrate escalate-vs-proceed judgment. Goal conditions must name the
   verification commands and include a turn bound (`or stop after N turns`).
4. **Unattended** — `/goal` + auto permission mode, nightly cloud routines,
   notify-on-block. `/loop` reserved for time-paced monitoring.

## How to pick up this work cold

1. Read this file, then `git log --oneline -20` and the backlog (`ROADMAP.md`
   index + `roadmap/`, if they exist yet).
2. If the backlog is missing, the current task is step 2 of the build order:
   draft it with the human (or from the notes in `docs/superpowers/specs/`), don't
   invent scope.
3. Otherwise: take the first unblocked item in frontier order and run the per-feature loop.
4. Check `docs/superpowers/plans/` for an in-flight plan with unchecked steps —
   that means a feature was interrupted mid-implementation; resume it before
   starting anything new.
5. Check `.claude/sweap-run.md` for a `stalled:` line. The StopFailure hook
   writes one when the orchestrator's own turn ended on an API error mid-run
   (a consumer, 2026-09-09, Claude Code 2.1.263: a 500 at 23:31 and nothing moved
   for ten hours). Since Claude Code 2.1.269 a `/goal` run retries an API
   error with backoff and pauses only after that, and the line says which
   case applies; several `stalled:` lines within ~25 min are one outage. The
   run is not over: re-read the run file's goal, verify the in-flight item's
   state from git and `sweap-merge status`, and continue.
