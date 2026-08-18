# Agentic Loop Playbook

Handoff document for any Claude Code agent (or the human partner) picking up a
project that runs this pipeline. Read this first, then `docs/superpowers/plans/`
and `docs/superpowers/specs/` for per-feature history. This is doctrine: the
mechanisms below are project-independent; everything project-specific is declared
in the `## sweap config` block of the project's `CLAUDE.md` (see **How this
project is configured**).

## How this project is configured

The pipeline is one set of mechanisms parameterized per project. Every command and
skill reads the `## sweap config` block in the project's `CLAUDE.md`; a project
overrides only the keys that differ from the baked defaults. The keys:

- **`verify.typecheck`** — the typecheck command (project-specific; no default —
  e.g. `just typecheck`).
- **`verify.lint`** — the lint command (project-specific; e.g. `just lint`).
- **`verify.e2e`** — the end-to-end test command. **This is the authoritative
  merge gate** (project-specific; e.g. `just e2e`). It must run the project's
  full automated test suite (unit + integration + e2e) — there is no separate
  unit-test key; passing `verify.e2e` is what certifies unit tests passed too.
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
  **`160`**.
- **`parallel`** — max concurrent roadmap items. Default **`1`**, the serial
  loop. `2` or more opts into coordinator mode, which is opt-in for a stated
  reason rather than the standard run shape (see **Parallel runs** for the
  measurements that demoted it, and the conditions that would restore it); hard
  cap **4** — clamp anything higher to 4 and say so.

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
  `roadmap/ideas/archive/`.
- **`.claude/sweap-board.md`** (gitignored) stays the *ephemeral* layer —
  in-flight claims and merge order only (see Parallel runs).

Item file schema. Frontmatter keys are single-line and `depends_on` is an
inline `[a, b]` list — keep it flat so `roadmap-lint.sh` and plain greps stay
trivial (this flatness is a format contract, not a style preference):

    ---
    id: F1.2                 # must equal the filename (F1.2.md)
    title: <short feature name>
    status: todo             # todo | attended | blocked | deferred | done (dropped: archive only)
    depends_on: []           # item IDs (F1.1) and/or bare milestone tags (F2)
    review-dimensions: []    # from the review.dimensions config set
    lane:                    # optional; same-lane items NEVER co-dispatch
    followup_of:             # optional milestone tag — marks an audit-debt item
    premise:                 # REQUIRED when deferred — machine-checkable predicate
    blocked:                 # REQUIRED when blocked — the question awaiting "> ANSWER:"
    carried:                 # optional int — milestone boundaries this question has survived
    handoff:                 # REQUIRED when attended — the task the HUMAN performs
    ---

    # F1.2 — <title>

    ## Spec
    - **Surface:** <files/modules this item is expected to touch>
    - **Interfaces:** <contracts produced/consumed — exact names/signatures wherever two concurrent items share one>
    - **Out of scope:** <what this item deliberately does not do>

    ## Acceptance (e2e)
    - <observable behavior a test asserts>

    ## Notes
    <optional: "> ANSWER:" threads, UNBLOCKED/CARRIED annotations, links>

**Authoring `lane:`** — make a lane as narrow as the real file overlap: two
items share one only if they literally touch the same files. An over-broad lane
serializes genuinely disjoint work — consumer A put FM.3 (which edits
`document-http.ts` and routes) in `lane: documents-storage` alongside FM.1/4/5
(which edit `patient-documents.tsx`), and all four then ran strictly serially
for no reason. The lane only bites in coordinator mode, so this is guidance for
opt-in runs; but it is written when the item is, long before anyone knows which
mode will run it.

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
| `deferred` | nobody | work that doesn't exist yet | `premise:` | never | no |

The line between the two that page the human: **`blocked:` holds a QUESTION,
`handoff:` holds a TASK.** If the human's next move is to answer, the item is
blocked. If their next move is to *do something*, it is attended. See
**Attended items** and **Blocked items** below.

Both queues have a command that *drains* them — `/unblock <id>` for a question,
`/handoff <id>` for a task. A queue that is only displayed is not worked: sweap
listed blocked items in three read-only places for months and consumer A still
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
file before the milestone PR opens; the dispatching session (serial loop or
coordinator) runs it again before dispatch. A todo item failing lint is not
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
Interfaces / Out of scope) + `## Acceptance (e2e)`. The session performs the
split (a purpose-built parser for the project's specific legacy format is
fine) and lints every produced file; multi-segment ids (a `DS.2` milestone
with `DS.2.1` items) are supported.

## Operating model — the per-feature loop

One feature = one session. Target 10–25 turns per feature; consistently >30 means
the item is scoped too big — split it.

1. **Brainstorm + plan** (plan mode): pin down the data model, access-control
   boundaries, permissions per role, and e2e acceptance criteria. Write the spec
   to `docs/superpowers/specs/`, the plan to `docs/superpowers/plans/`.
2. **Implement with TDD:** write e2e/integration tests first — they are the spec.
   **Never modify tests to make them pass**; fix the root cause. Iterate until the
   verify gates (`verify.typecheck`, `verify.lint`, `verify.e2e`) are all green —
   locally when the project's services are available, else verified by CI on the
   PR (see Environment parity).
3. **Adversarial review:** dispatch a fresh-context review agent that sees only
   the diff + the plan. Fix confirmed findings.
4. **Conditional review dimensions** (from the item file's `review-dimensions`
   frontmatter — see below): run each required extra reviewer before the PR.
5. **Merge, clean up (see End-of-run hygiene), next item.**

## Environment parity (local machine vs. Claude Code web / cloud)

The loop runs identically in any environment because **CI is the authoritative
test gate, not the local machine.** CI runs the verify gates (including
`verify.e2e`) against the same services on every PR, and the merge gate requires
every CI check green — so an item **cannot** reach `status: done` without e2e
passing in CI, regardless of where it was written.

- **Local (services available):** if `services.up` is declared, `/milestone` runs
  it (starting the daemon if the command is daemon/Docker-based), then the local
  gates are a fast pre-check before pushing — seconds of feedback instead of
  waiting on CI. If `services.up` is *not* declared, the loop runs in CI-gated
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
  `/goal` for an autonomous run. Defaults to the next runnable milestone and
  `turns.default` turns. You never run `services.up` by hand; the paste step
  exists only because a human must invoke `/goal`. Ritual:
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
    focus + required empty/loading/error states, and the "no arbitrary values"
    token/primitive-reuse lint (raw hex / arbitrary utility values fail). The
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
  unavailable: <reason>` note) in the PR; behavior-preserving retrofits are exempt.
  All product-visible UI builds on the project's declared design system (tokens +
  primitives; see the ui-design skill); the human remains the spot-check on
  visual polish.
- **`migration`** — any schema change beyond a new table: reviewer checks
  reversibility, data backfill, and access-control continuity.

Untagged items get the standard fresh-context review only. The orchestrator
may ADD dimensions it judges necessary; it may not remove tagged ones.

## End-of-run hygiene (mandatory)

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
  1. **Merge:** `gh pr merge <n> --squash` (the `--delete-branch` flag is a no-op
     footgun here; omit it).
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
  verify (6). The hook (shipped by the plugin and wired via `plugin.json`) fires
  after any `gh pr merge`, fast-forwards the primary, prunes stale
  remote-tracking refs, and for any worktree whose branch has a **merged** PR
  removes the worktree, deletes the local branch, **and `git push origin
  --delete`s its origin branch** (the reliable remote delete `--delete-branch`
  fails to do here). It only ever touches merged-PR branches, never
  `--force`-removes (so a dirty in-flight worktree is safe), and **skips the
  worktree the caller is standing in** — it will not delete the live session's cwd
  out from under it, so that one is left for the explicit manual step (or the next
  hook pass once the session has moved on). The hook is belt-and-suspenders: still
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
    (`pre-merge-gate`, shipped by the plugin and wired via `plugin.json`) fires on
    every `gh pr merge`, independently queries the PR's `statusCheckRollup`, and
    **denies the merge** unless every check is green — plus it denies
    `--admin`/`--repo`/`-R` outright. On any uncertainty (gh errors/times out) it
    denies *recoverably* (fail-closed, never fail-open, never a permanent wedge);
    a later retry passes once checks are green. A `PostToolUse` backstop
    (`post-merge-redcheck`) re-checks after the merge and, if `main` somehow landed
    red, drops a gitignored `.claude/main-red-<sha>.flag` marker + a loud banner so
    the next run opens a remediation PR (it never commits to `main`). **Why it
    exists:** the instruction-level gate silently failed once — a `gh pr checks
    <n> --watch | tail` pipe masked the real exit code (a pipe returns `tail`'s
    `0`), so a PR whose `e2e` had FAILED got merged and briefly broke `main`. The
    hook removes the human-reads-the-output link. This *strengthens* the gate and
    never weakens it — the hook only ever denies, never auto-approves.
- **Merging a green PR is pre-authorized — do not ask.** Once `gh pr checks <n>`
  is green (every check, including `review`), merging an unblocked item's PR is a
  standing authorization: `gh pr merge <n> --squash` with no confirmation prompt.
  The *gate* is the control, not a human click; pausing to ask "may I merge?" is
  a judgment the gate already answered. (This is why some earlier runs prompted
  and some didn't — the confirm was a per-run judgment call, not a rule. Stating
  the authorization here removes the ambiguity.) The one thing never
  self-authorized: **weakening the gate to get a merge** — editing
  `.github/workflows`, `gh workflow disable`, or changing required checks. A run
  must never be able to turn off the verification that makes its own autonomy
  safe; if the gate is in the way, escalate, don't disable it.
- **Allowlist scope and its limit (`.claude/settings.json`).** The `gh` allowlist
  is scoped to the verbs the loop uses — reads plus the two intentional writes
  `gh pr create` and `gh pr merge` — so `gh pr close`, `gh issue close`,
  `gh run delete`, etc. still prompt. Be aware it scopes *verbs, not flags*:
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
  instruction still governs `gh pr create` (not hooked). Coordinator mode
  additionally uses `git rebase` and `git push --force-with-lease` on item
  branches as routine loop verbs.

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
pending>` note under `## Notes`, the same convention deferred items use for
`> **UNBLOCKED:**`. One that stops mattering is archived with a
`dropped_reason:` like any other item.

**An open hand-off keeps its milestone incomplete**, so the milestone-audit is
not due until it is closed. No merges are blocked and no audit debt accrues —
the audit is simply not owed yet. That is the leverage that makes a hand-off
impossible to ignore, and the accepted cost is that audit timing depends on a
person.

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
survived milestone after milestone (consumer A: five of six questions outlived a full
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

## Deferred items (parked behind a future dependency)

A `[deferred]` item is a *good idea that cannot be built yet* because it depends
on work that doesn't exist. It is distinct from `[blocked]`:

- `[blocked]` = active work is **stuck** and needs a human answer to continue
  *now*. It sits on the "needs-me-now" queue and pings the human.
- `[attended]` = a **planned hand-off**: the human's own work, waiting on them
  to do it. Also on the needs-me-now queue, but as a task rather than a failure
  (see **Attended items**).
- `[deferred]` = **parked**, nobody is working on it, nothing is stuck. The agent
  never auto-picks a `[deferred]` item (it is invisible to the top-of-backlog
  picker exactly like a `Later milestone`). It keeps the "needs-me-now" list
  honest — only genuine `[blocked]` items and hand-offs pull the human's
  attention.

**Why deferred instead of leaving it `[todo]`.** A `[todo]` item that can't be
built (its deps aren't `[done]`) is clutter: the picker either trips on it every
run and escalates, or a human has to remember it isn't really ready. `[deferred]`
encodes "not ready, don't look" once, mechanically.

**Premise (required on every deferred item).** Each deferred item carries a
`premise:` frontmatter key — the assumption it is waiting on, written wherever possible as a
**machine-checkable predicate**, not prose. Good: *"a `billing_events` table
exists with the expected columns"*, *"the target milestone's spec AC-3 still
reads X"*. This is the small authoring discipline that buys the autonomy below — a
checkable premise is one no human ever has to adjudicate.

**Dependency granularity — item-level vs. milestone-level.** The unblock scan is
*item-level*: it fires when a `depends_on` entry that names an **item** (a
dotted ID like `F4.3`, using the configured milestone prefix) turns
`status: done` in its file. A dependency on a **whole milestone** — a bare
`F4`, which has no single file to read a status from — is **not**
auto-scannable and must not be treated as done by text-match (nor as
vacuously done because the milestone has no item files yet). A bare-milestone
dependency is unblocked when that milestone **completes** — item files for
that milestone exist and every one is `status: done` — which coincides with
the milestone-audit and the next `/roadmap`, a human-in-the-loop boundary. So
milestone-level deferrals **surface at the milestone boundary** (the
`/milestone` pre-flight backstop and the next roadmap pass), not via the
automated end-of-run item scan. Rule of thumb: once the target item files
exist, rewrite `depends_on` to item granularity so the scan can fire; a
bare-milestone dep is a deliberate "resurface when that milestone completes"
marker, not an auto-promote trigger.

**Lifecycle — an item is *unblocked* when every `depends_on` item is `status: done`.**
Unblocked ≠ ready; it **never auto-promotes**. On unblock the agent evaluates the
premise and takes exactly one path:

1. **Premise machine-checkable AND verifiably holds** → auto-promote to `status: todo`.
   No human touch. This is the common case (the dependency landed roughly as
   planned) and it must be *verified*, not guessed — the failure mode of a wrong
   promote is a stale feature built against a dead assumption that passes every
   gate (gates verify correctness, not intent) and merges invisibly. Any doubt
   about whether the premise is *truly* mechanically verifiable → treat as
   not-checkable and escalate (path 2/3). Bias toward escalation: a needless
   escalation costs one notification; a wrong auto-promote ships silently.
2. **Premise not machine-checkable, or the check fails but the item still makes
   sense** → **escalate for re-spec.** Keep it `status: deferred`, annotate it
   `> **UNBLOCKED (YYYY-MM-DD):** <what shipped vs. the premise>` under its
   `## Notes`, and list it in the end-of-run summary. The re-spec itself flows
   into the next `/roadmap` conversation — no new standalone touchpoint.
3. **No longer makes sense** → **propose drop.** Move the file to
   `roadmap/archive/` with `status: dropped` and a one-line `dropped_reason:`.
   This is a *reversible*
   soft-delete (it stays in git history and the archive dir), so it does NOT
   block on the human's confirmation — they veto async if they disagree. (Drop is
   cheap and reversible; promote is expensive and invisible — gate each to its
   cost of being wrong.)

**When the check runs (it is stateless — just "are this item's `depends_on` all
done?", recomputed from the item files, so missing it once costs nothing):**

- **Primary — end of every run.** Any run that merges a PR scans for
  newly-unblocked deferred items and applies the lifecycle above, surfacing
  paths 2/3 in the end-of-run summary. The dependency landing *is* a merge in that
  run, so the merging agent is best placed to notice.
- **Backstop — `/milestone` pre-flight.** `/milestone` re-runs the same scan when
  it reads the backlog, catching anything unblocked *outside* an autonomous run
  (e.g. a hand-merged dependency).

Un-checkable premises are not a hole in this design — they are its **sorting
function.** A premise that can't be mechanically verified *is* a judgment about
what shipped, i.e. a taste call, i.e. the "which problems matter" work that stays
human. Checkable premises auto-resolve; un-checkable ones route to the human
*because* they are direction calls. Human load compresses toward a floor of
roadmap authoring + genuine-divergence calls, and that floor is deliberate: it is
where product direction lives, which no gate can verify.

## Milestone brainstorm (before a milestone starts)

Authoring a milestone's item files is direction-loop work —
interactive-only, done with the human. It runs in three phases; the pair of a
decisive pass and an independent completeness critic is the same finder/refuter
shape as the audit.

1. **Decide** (interactive) — `superpowers:brainstorming` with the human.
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
3. **Reconcile** (brief, interactive) — the human answers the net-new forks; then
   one item file per drafted item is written under `backlog.dir` (plus the
   index's milestone-list update), each linted by `roadmap-lint.sh`, and it all
   lands as one PR through the gate.

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
that guard. It audits the
merged whole with the finder lenses declared in `audit.lenses` — by default **the
generic default lens set defined in the audit workflow** (correctness,
authz/security, data-integrity, concurrency/races, test-integrity, api-contract),
optionally extended with **domain lenses the project appends via `audit.lenses`**
(the preferred `default + [...]` form), or replaced entirely by an explicit list
when the project deliberately wants a custom set — and adversarially refutes
every finding — only majority-surviving findings are
reported. It exists to catch what per-PR review structurally cannot: cross-feature
interactions, systemic patterns, and plan-level mistakes.

**Auto-launch (pre-authorized in the goal).** A milestone `/goal` run carries a
final clause so the audit fires once, automatically, at the milestone boundary —
no cron, no standing agent. Standard template:

> *First, every outstanding audit follow-up item in the backlog is [done] (the
> `/milestone` run drains them debt-first — see the bucket-2 note above); then
> every unblocked <milestone> item in the backlog is [done] per the definition
> of done; and when the last item merges, run `/milestone-audit` with
> `{milestone: "<milestone>", range: "<base>..<head>"}` for that range,
> triage the confirmed findings (below), and post a summary before stopping.
> Stop when the only [todo] items left are audit follow-ups carrying
> followup_of: <milestone> (the next run's debt, not this run's work), and
> everything else remaining is [blocked] or [attended] — or after N turns.*

(The follow-up clause is load-bearing, not padding. A correct audit ends by CREATING work: bucket-2 triage writes
`followup_of:` todo items, so a run that audits well can never literally reach
"only blocked or attended remain" — consumer A's F11 run hit exactly that and had to
escalate the ambiguity. Those items are the NEXT run's debt (the frontier drains
them debt-first), not this one's.)

(Both stop conditions have a drain: `/unblock <id>` for a question, `/handoff
<id>` for a task. Name them in the stop message — "3 blocked, 1 hand-off" without
the next move is what let consumer A carry five questions across whole milestones.)

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
than printed by `/milestone`, the audit clause still travels with it. (Learned
the hard way: a hand-written milestone goal that once omitted the clause
drained its items but stopped before its audit.)

The evaluator won't call the goal met until the audit has run and its findings
are triaged. The `/milestone-audit` workflow finds and reports confirmed
findings; it never edits code. What happens next is the **triage** the
surrounding session performs (below): a bucket-1 fix is a deliberate, gated
*follow-on* PR the session opens, not something the audit workflow does silently.

**Read-only is a toolset, and the toolset has to be addressable.** A plugin
agent registers under its **scoped** name (`sweap:audit-reader`); the same file
in a repo's own `.claude/agents/` registers **bare**. The workflow dispatched
the bare name unconditionally, so it worked in sweap's checkout and was broken
for every plugin install — consumer A's F11 audit lost all eleven finder agents to
`agent type 'audit-reader' not found` and only completed because the session
hand-patched its own copy of the script. It now resolves: scoped name, then bare
name, then — if the runtime rejects both — whatever name the not-found error
says it *does* have, which survives a plugin or marketplace rename the script
cannot see. What it never does is fall back to *no* agent type: an unresolvable
agent is a thrown error, because the alternative is the default toolset, which
can `Write`. Watch for this class when reviewing: a guarantee that depends on a
name is only as good as that name's addressability in the install it lands in.

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
say that rather than claiming the whole workflow is sealed. Why this is stated
so precisely: until 2026-08-16 "read-only" lived exclusively in this paragraph
and in `/milestone-audit`, both of which address the **calling session** — the
finders and refuters never saw either, their prompts said nothing about writing,
and they ran with the default toolset. A refuter in a consumer repo wrote a test
file into the human's primary checkout to settle a claim empirically, where it
sat untracked and would have run in their next test invocation. It did what the
prompt invited with the tools it was handed. **A guarantee asserted to a third
party is not a guarantee** — the same lesson as the hand-off escape hatch, one
rung worse, because here the doctrine was never even communicated to the actor.

**Evidence and a number, not a verdict — and the number lives in the pipeline.**
A refuter returns four things about a finding, every time: the `path:line`
spans it actually read, the code it found bearing on the claim, what would
falsify its own answer, and `confidence` — its probability, 0 to 1, that the
finding is **wrong**. It does not return a label. The pipeline cuts: a
refutation is a score strictly above `TUNING.refutedAt` (**0.5**), and
`TUNING.killVotes` (**2**) of the three seats kill a finding. Both numbers live
in one `TUNING` block in the workflow, and the prompt interpolates them so it
can never quote a stale price.

Why the shape rather than the labels. This was a boolean, then
`refuted`/`stands`/`unverifiable`, and that one change took the panel's kill
rate from 63–73% to **2.7%** (1 of 36) — while a UI-critic axis with an
unchanged prompt held at 40% in the same run, which is the control that makes it
causal. 216 verdicts split 210 `stands` / 6 `refuted` / 0 `unverifiable`. A
categorical verdict puts the decision boundary **inside the model**, where an
adjective moves it 25×, and the labels were priced asymmetrically on top of
that: `refuted` demanded a "positive, code-grounded disproof" from an agent that
cannot run code, `unverifiable` demanded an experiment and was demoted to
`stands` without one, and `stands` demanded nothing. Two costly inlets, one free
sink. The generic version of that is worse than the specific one — adding an
option perturbs the distribution for non-semantic reasons at all — so the fix is
not better labels, it is no labels. Every lab externalises this: OpenAI's
`score_model` grader returns `{"result": float, "steps": ReasoningStep[]}` with
a separate `pass_threshold` in the config; the model scores, the system cuts.
The research behind this paragraph, with every quote re-fetched raw and
string-matched, is `docs/research/2026-08-18-refuter-verdict-design.md`.

**Evidence is required symmetrically.** The answer that leaves a finding alone
cites code on exactly the same terms as the answer that kills it — the required
schema fields do not branch on which way the score points, and an answer citing
no code is a **schema violation** that the model is made to retry. Never a
demotion: a demotion is a drain into whichever answer is cheapest, which is the
mechanism this design exists to delete.

**`unverifiable` is now an out-of-band ticket, not a verdict.** A refuter that
cannot settle a claim by reading names the exact command in `experiment` —
*and still scores*, on what it did manage to read. The ticket **suspends** the
finding for the Validate stage rather than resolving it, and being off the
scoring axis is the whole point: a ticket cannot take probability mass from a
score the way a third label takes it from the other two. One ticket routes
(`TUNING.proofTickets`); the old ">=2 of 3 abstained" bar, combined with a
label nobody ever chose, is what made the Validate stage structurally
unreachable.

**Why the kill threshold is still 2.** Not because it is known to be right —
63–73% was very likely also wrong, in the direction nobody was measuring. There
is a real argument it should fall to 1: under documented positive bias an
agreeable majority is the failure mode rather than the safeguard, and the paper
making that case proposes a minority veto. That same paper is why it has not
moved — the optimal threshold "requires a calibration set with ground-truth
labels", and flipping it on intuition re-rolls the dice that produced 63% and
2.7%. What is fixed is the *renormalisation*: never "a majority of votes cast",
because that lets two lost votes promote the third refuter to a majority of one,
handing a single voter a veto exactly when the panel is least informed. Lost and
unscored votes are excluded from the numerator with the threshold left where it
is. **The next piece of work is the labeled set** — seeded known-bad and
known-good findings — and until it exists no kill rate, 2.7% or 73%, can be
called right or wrong.

**The Validate stage — the empirical gate, spent only where reading ran out.**
When a refuter has ticketed a surviving finding as unsettleable by reading, one
`audit-prover` agent runs the named experiment and returns a verdict backed by a pasted command and its actual
output. It has `Bash` and `Write`; its containment is `isolation: 'worktree'` —
a throwaway git worktree, auto-removed if unchanged — rather than tool removal.
Be equally honest about that: worktree isolation relocates the working
directory, it is not a jail, and an absolute path escapes it. The agent's own
instructions forbid absolute paths, and the failure it contains is the
accidental one that actually happened, not an adversarial one. The stage exists
because adversarial reasoning catches reasoning errors and not empirical ones —
in that same published system, ten agents including a senior arbiter unanimously
confirmed a finding that one fresh instance killed by compiling the code and
running three tests. It is dispatched **conditionally**: a worktree per refuter
would mean ninety sandboxes to settle a handful of verdicts. Its own verdict is
still categorical and still three-valued, deliberately — that agent *has* the
capability, its answer is backed by a pasted command and its actual output, and
its `unverifiable` means "I tried to run it and something blocked me", a fact it
earned rather than a bucket it fell into. Nothing routes onward from it either.

**`unverified` findings are a coverage gap, not a defect.** A finding that
survived because nobody could check it is reported separately — a subset of
`confirmed`, plus an optional `unverified:` key in the record and a
`status: UNVERIFIED` line in its block. Triage it as **bucket 2**, a follow-up
item that writes the missing experiment, not as a bucket-1 bug. Never let it be
counted as "confirmed by adversarial review": that claims three adversaries
failed to refute it when in fact three adversaries never looked. A large
`unverified` count is itself the finding — it means the audit's reading tier is
out of its depth on that surface.

**A zero-findings audit must prove it ran.** "This audit was clean" and "this
audit ran" are different claims, and a `0 / 0 / 0` record makes the first while
the second may be false: it satisfies every arithmetic and binding check the
gate performs. It is also exactly what a totally failed run produces. Two
layers close that. The workflow **throws** rather than returning when no lens
reported — fail at the source, where the failure is still attributable — and
lists in `lenses:` only the lenses that actually ran, logging any that were
lost. And every record carries `finders_reporting: <n>`, which
`audit-gate.sh` demands (`>= 1`) whenever `raw` is 0. A finding no refuter ever
scored is likewise counted as `unverified` rather than as adversarially
confirmed.

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

**Enforcing the audit gate in CI (consumer repos).** This is SCAFFOLDED, not
copy-pasted: `.github/workflows/audit-gate.yml` ships in `templates/` and
`scaffold.sh` installs it — including into repos that adopted sweap before the
control existed (the self-heal runs ahead of the already-scaffolded fast-guard,
same as the gitignore rules). Run `/agentic-loop-init` to force it. What you do with it
then depends on your GitHub plan — read the next paragraph before assuming you
can make it a required check.

This job is not a convenience. It is the ONLY surface that validates a record
against the state it will actually land in — the local pre-merge hook detects
debt discharge at PATH level and structurally cannot check validity, because the
record being discharged is not merged yet. Everything else is a backstop.

The gate script is **vendored** into the repo at `.github/scripts/` (both
`audit-gate.sh` and the `roadmap-lint.sh` it shells out to) and kept
byte-identical to the plugin's copy on every session start. It is vendored
rather than checked out from sweap in CI because a cross-repo checkout of a
private repo needs a PAT in every consumer repo, and a required check that dies
when that token expires blocks every PR — the same "gate depends on
infrastructure it polices" failure as pinning it to a self-hosted runner.
Vendored, the check needs no auth, no network and no cross-repo access.

Those files are sweap-managed, not project-owned: the scaffold REWRITES them
when they drift, because a consumer repo silently running an old gate is the bug
this subsystem exists to fix. Every rewrite is an ordinary diffable working-tree
change. Customize via repo variables, never by editing them — and protect
`.github/scripts/**` exactly like `.github/workflows/**`.

*Why it must live in the repo, not just in the plugin:* on 2026-08-11 a consumer
repo merged a malformed audit record and then authored a whole new milestone on
top of the undischarged debt. Every local control was correct and every local
control was skew-broken — the machine's plugin cache was pinned to a build from
three days earlier that contained no audit gate at all, and the cache did not
refresh until sixteen hours after the bad merge. A check pinned in the repo
cannot be stale-cached. **Any control that lives only in the plugin is a control
whose version you do not know.**

**The milestone boundary — the one merge the gate cannot ask for a record on.**
The audit is only legal against the merged default branch (§"Audit evidence"),
so on the PR that flips a milestone's *last* item to `done`, the record it would
be asked for cannot exist yet: unwritable before the merge, and the merge
unreachable without it. Both gate modes read the tree they run in, so on that
PR's own checkout the milestone reads complete-with-no-record and both modes
denied it — no milestone could ever be completed. Consumer A hit this on F10.4
(2026-08-15), the first milestone to complete after the CI job was installed.

The gate now exempts a milestone that is **not** complete at the mainline anchor
but **is** complete in the state under review. The exemption is narrow: it covers
a *missing* record only (a record that is present is still validated strictly, so
CI keeps catching a malformed one before it merges), it is per-milestone (debt
inherited from the anchor still denies that same PR), and it fails closed when
the anchor cannot be resolved. Nothing is deferred to a backstop — one PR later
the anchor contains the completion, the exemption stops applying by construction,
and `--files` denies every backlog-advancing PR until the record lands. **So the
audit is still mandatory; it is merely sequenced after the merge that makes it
possible.** Merge the completing PR, then run `/milestone-audit` for it before
anything else touches the backlog.

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

**The audit record format is versioned (`sweap_format`).** The record schema
lives in one place — `playbook/audit-record.template.md` — and every record
carries the format version it was written under. This exists because a gate that
retroactively invalidates already-merged records strands every consumer repo on
every tightening: the loop wedges, and the only ways out are hand-editing config
or re-running an expensive audit. So the gate classifies rather than fails:

- A record **already merged** (its adding commit is reachable from the mainline
  anchor) that carries **no** `sweap_format` was written before the format
  existed. `--check` reports it as `STALE:` and it never blocks a merge.
- A record **introduced by the work under review** is judged strictly, always.
  `git log <anchor> -- <path>` only walks commits reachable from the anchor, so
  a record added by the PR is invisible there and gets no grandfathering.

That asymmetry is the whole design: legacy can be **inherited but never
authored**. Provenance comes from git, not from file content, so nobody
discharges debt by committing an empty file. Uncertainty (no remote, unresolvable
anchor) means nothing is legacy and everything is judged strictly.

When you bump the format, bump `RECORD_FORMAT` in `hooks/audit-gate.sh`, the
`SWEAP_FORMAT` constant in `workflows/milestone-audit.js`, and the template
together.

**Consumer repos then drain `STALE:` records by TRANSCRIPTION, not by
re-auditing.** A stale record means the audit already ran — its findings were
already triaged and its fix-PRs and follow-up items already exist. Re-running
`/milestone-audit` spends a full adversarial audit to produce a *different*
result set, and the record it lands then documents a run that nothing in the
backlog traces to. The migration is: recover the frontmatter from the old
record's own stated range and stats plus the run's surviving `wf_*` transcript
(`workflow_run`, `journal_sha256`), and give each distinct defect a
`disposition:` line pointing at the fix-PR or follow-up item it already
produced. `audit.baseline` is the fallback only when that evidence is genuinely
unrecoverable — and re-audit only when no audit ever actually ran. Full recipe
in `playbook/audit-record.template.md`.

**Findings triage (three buckets — the session running the audit sorts them).**
1. **Bug** (code fails its own spec): the session opens a follow-on fix-PR
   through the gate. Hands-off in an unattended run (no human needed), but still a
   separate gated PR — the audit workflow never edits code.
2. **Small gap / non-urgent** (races, infra): write it as a new item file under
   `backlog.dir` with `followup_of: <milestone>` set (`status: todo`, tagged,
   lint-clean). Hands-off. These are **auto-folded, debt-first, into the next
   `/milestone` run** — its pre-flight audit-debt scan collects every unblocked
   `status: todo` item file with `followup_of:` set and drains it ahead
   of the named milestone (or as a standalone **debt-only run** when no milestone
   is runnable). Bucket-2 is a tracked queue with a defined drain, not a
   dead-drop — nobody has to remember it.
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
— which measured **17%** of transitions in consumer A, worth **+9.4% at K = 2**. It
is opt-in for that reason; a serially-dependent milestone gains nothing from it
and simply runs the serial loop.

## Parallel runs (coordinator mode — opt-in)

**The default is `parallel: 1`.** Coordinator mode is opt-in and wants a stated
reason; it is not the standard run shape.

That is measured, not argued. Across ~99 consecutive merged-PR transitions in
Consumer A only **17 had two roadmap items genuinely in flight together (~17%)** —
the rest were lane-locked or dependency-chained (F11.1 → … → F11.7 is a strict
7-deep chain). Amdahl at p = 0.17: **+9.4% at K = 2**, ceiling **+20.7% at
K = ∞**. This section used to promise "~1.5–2x on an independent frontier", and
1.5x at K = 2 needs p ≥ 0.667 — two thirds of the frontier independent. 17% is
already the generous reading: it counts a PR idling in CI while another opens,
not only true co-dispatch. There was no contention to manage either — CI e2e is
11–14 min (~110 merges/day of serial capacity) against ~1 PR/hour arriving,
utilization ~0.2, where Uber built SubmitQueue for 1,000 changes/day and
GitHub's merge queue serves 2,500 PRs/month across 500 engineers. Worse, at
K ≥ 2 the always-verify queue *increases* total CI minutes (every queued PR
rebases and re-runs the full e2e on the combined state) and the CI-gated rule
below makes each worker slower. Board upkeep, frontier recomputation and
mandatory instrumentation were ceremony bought for a single-digit gain.

**Re-enable on numbers, not intuition:** set `parallel: 2` when a run's
instrumentation shows **≥2/3 of the frontier genuinely independent** AND PR
arrival approaching **~4/hour**. Both conditions, not either.

**When opted in** (2–4; hard cap 4): thin coordinator, fat gates — workers in
isolated worktrees, each slot held until the PR *merges*, FIFO merges that
rebase and re-verify green, `.claude/sweap-board.md` (gitignored) as the
coordinator's externalized memory. Three rules carry the risk: never co-dispatch
items sharing a `lane:`, two `migration`-tagged items, or anything plausibly
touching the same surface; and at K ≥ 2 workers run CI-gated, because one shared
local services stack produces spurious failures. Everything else —
mechanics, evidence base, locked decisions — is in
`docs/superpowers/specs/2026-07-18-parallel-roadmap-runs-design.md` in the sweap
plugin repo. Read it there; it is not restated here, deliberately.

**Not coordinator machinery, and unaffected by `parallel:`** — worktree-per-PR,
`post-merge-cleanup.sh`, and the pre-merge gate's compare-API freshness check.
That last is a *correctness* control, not a concurrency one: `main` moves under
an in-flight branch at width 1 too, and a Free-plan repo never reports BEHIND.

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
| Workflow (multi-agent orchestration) | Deterministic fan-out: parallel finders + adversarial verifiers; use for audits/reviews, not feature code | Claude (user opt-in, e.g. "ultracode") |
| `/goal` (built-in) | Sets a stop condition checked by an evaluator model after every turn; Claude keeps chaining turns until the condition is demonstrably met. Preferred driver for roadmap execution: `/goal <condition, incl. verification commands shown in transcript> or stop after N turns`. **User-only — Claude cannot invoke `/goal`; a human pastes it** | User sets once; Claude sustains |
| `/loop` + self-scheduled wakeups | Time-paced recurring iteration; better for polling/monitoring (CI, deploys) than for goal-directed backlog work | User starts once; Claude sustains |
| Cron jobs / scheduled cloud agents (`/schedule`) | Sessions that start on a schedule (nightly deps bump, backlog grooming, post-merge audit) — cloud routines run even if the PC is off | Claude can create; runs unattended |
| Headless `claude -p` + auto permission mode | Scripted/CI-triggered sessions; classifier gates commands | Scripts/CI/events |
| Agentic CI (GitHub Actions) | Claude reviews every PR; merge gated on green e2e + clean review | Git events |
| `claude --continue` / `--resume` | Pick a session back up after a crash/reboot; long sessions survive via context summarization | User |
| `/board` (read-only viewer) | Local loopback page showing the live run (frontier/in-flight/merge-gate/hand-offs/blocked) + backlog + dep graph; derives state from item files + git + PRs, never writes | User runs; safe during autonomous runs |
| `/handoff <id>` | Walks one `[attended]` hand-off with the human, then flips it to done through a gated PR on their explicit confirmation | User runs; interactive only |
| `/unblock <id>` | Walks one `[blocked]` question with the human — prepares the fork, never answers it — then closes it through a gated PR (`todo` + authored spec, or `done`) | User runs; interactive only |

## Model policy

- Implementation grind: Opus 4.8 (high effort) is sufficient — the gates are
  designed so correctness doesn't depend on the model being right first try.
- Planning, spec-writing, adversarial review, security audits: use the
  strongest available model tier — these are the judgment-heavy stages where
  model quality shows.

## Hard rules for unattended runs

- Tests are the spec: never edit a failing test to pass; never skip/quarantine
  tests without flagging it.
- Never touch production or real user data; no irreversible actions without
  explicit human approval.
- Every merge requires: the verify gates (`verify.typecheck`, `verify.lint`,
  `verify.e2e`) green, plus a fresh-context review with confirmed findings
  addressed.
- When blocked: write the question down, notify, move on. A stalled item must
  never stall the loop; a guess must never resolve ambiguity.
- **Never create an `[attended]` item, and never transition one into it.** Work
  an agent cannot finish is `[blocked]` with the question — never re-labelled as
  the human's own work. Hand-offs are authored with the human present, in
  `/roadmap`. (Mechanically enforced by `audit-gate.sh --check`; the rule is
  here so the mechanism never has to fire.)
- Report honestly: failing output verbatim, skipped steps named.

## Standing preferences (pre-answered skill checkpoints)

The superpowers skills honor declared user preferences without asking. These are
the human's standing answers — treat them as given, do not re-ask in a session:

- **Workspace isolation:** yes, always work in an isolated worktree/branch;
  never implement on `main` directly.
- **Finishing a branch:** default to opening a PR (merge only when agentic CI +
  review gates are green). Never discard work autonomously — "discard" always
  requires the human's typed confirmation.
- **Plan execution mode:** subagent-driven-development (continuous execution,
  no between-task check-ins), not inline executing-plans.
- **TDD:** no exceptions in product code; don't ask for exemptions, just do TDD.
  The implementer's report MUST include TDD Evidence: the RED (failing) output
  and the GREEN (passing) output, pasted.
- **When a skill says "ask your human partner"** and it's an exception/blocker
  (not a safety rail above): apply the escalate-don't-guess rule — write the
  question to the blocked item, notify, move on.
- **Milestone brainstorm:** three phases — `superpowers:brainstorming` (decide,
  interactive) → `milestone-cross-check` skill (completeness critic, automated) →
  reconcile with the human. See the Milestone brainstorm section.
- **Brainstorming skill:** interactive-only. Use it when the human is present
  (roadmap/spec authoring). Unattended runs never brainstorm scope — they
  execute roadmap items that already have approved specs.

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
