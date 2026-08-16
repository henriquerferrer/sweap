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
- **`parallel`** — max concurrent roadmap items. Default **`2`** (coordinator
  mode). Set `1` for the strictly serial loop (see **Parallel runs (coordinator
  mode)**); hard cap **4** — clamp anything higher to 4 and say so.

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
  in-flight claims and queue order only (see Parallel runs).

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
    <optional: "> ANSWER:" threads, UNBLOCKED annotations, links>

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
**Attended items** below.

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
  summarizing merged PRs, blocked items, and **open hand-offs** (`status:
  attended`, with what each one gates — the human's own queue is part of "what
  now?", not a detail); list any leftover worktrees/branches
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
> Stop when only [blocked] or [attended] items remain, or after N turns.*

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
are triaged. The `/milestone-audit` **workflow itself is read-only** — it finds
and reports confirmed findings, never edits code. What happens next is the
**triage** the surrounding session performs (below): a bucket-1 fix is a
deliberate, gated *follow-on* PR the session opens, not something the audit
workflow does silently.

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
throughput lever. Frontier parallelism (next section) is a secondary lever
that mostly recovers CI dead time on genuinely independent items — expect
~1.5–2x on an independent frontier, not K-x; a serially-dependent milestone
gains nothing and simply runs the serial loop.

## Parallel runs (coordinator mode)

Active when `parallel:` is 2 or more — the **default is `2`**, so coordinator
mode is the standard run shape; declare `parallel: 1` to opt back into the
strictly serial loop (hard cap 4). A width-1 frontier (serial dependency
chain) degrades to the serial loop automatically either way. Evidence base and locked
decisions: the parallel-roadmap-runs spec (2026-07-18) in the sweap plugin
repo. The shape is **thin coordinator, fat gates** — the gates do the
verifying; the coordinator only schedules.

**Workers (unchanged).** Each in-flight item runs the standard per-feature
loop in its own worktree — TDD, fresh-context review, review dimensions,
PR — one item to a clean mergeable state. A worker reports back only a
compressed summary (~1–2k tokens): item, worktree@branch, PR number, gate
state, blocked question if any. Workers never merge; the coordinator owns
the queue.

**Coordinator (holds no implementation state — everything durable lives on
disk: the backlog index + item files, the board, per-item progress files,
git, PRs).**

1. **Frontier:** every unblocked `status: todo` item that **passes
   `roadmap-lint.sh`** (the spec gate — a todo item failing lint is not
   runnable: fix mechanically or escalate), in frontier order (debt-first,
   then index milestone order, then numeric item order) — the `/milestone`
   picker taking the top K instead of the top 1. Recompute after every merge
   or block (a merge may unblock items), and dispatch **event-driven**: the
   moment a merge frees or unblocks a slot, fill it — never hold dispatch
   waiting for the rest of a "wave" to finish.
2. **Dispatch** up to `parallel:` workers as background agents in isolated
   worktrees. Co-dispatch rules: items sharing a `lane:` value NEVER run
   together (a declared coupled chain is serial by construction); two
   `migration`-tagged items NEVER run together; and judgment on top — never
   co-dispatch two items plausibly touching the same surface (the
   **Interfaces** bullets are the first thing to compare).
3. **Merge queue (FIFO, always-verify):** when a worker's PR is ready —
   rebase the branch onto current `main`, `git push --force-with-lease`,
   wait for CI green on the rebased head, then `gh pr merge <n> --squash`
   (the pre-merge gate hook independently re-verifies greenness AND
   mechanically verifies the head is not behind its base via the compare
   API — branch-protection-independent — so stale-green merges are denied
   even on free-plan repos where GitHub never reports BEHIND).
   **Speculative rebase:** the moment a merge lands, immediately rebase the
   next queued PR so its combined-state CI runs during otherwise-idle time.
   The rebase runs inside the owning item's worktree (the branch is checked
   out there — git will refuse it in the primary checkout). A textual conflict
   during the rebase — rare by construction now that status lives in per-item
   files and the index changes only at milestone boundaries — is resolved by
   the owning worker, never by force-pushing over the other side.
   Diff-disjointness may pick queue ORDER (least-entangled first); it NEVER
   skips the combined-state CI run — there is no "looks independent"
   fast-path, by locked decision (industry skips are hermetic-build-graph
   proofs or statistically-measured skips with post-land safety nets; this
   pipeline has neither).
4. **Board:** maintain `.claude/sweap-board.md` (gitignored, never
   committed) — one line per in-flight item:
   `<item> | <status/current step> | <worktree>@<branch> | PR #<n> |
   <blocked question or ->`, plus the current merge-queue order. The board
   is BOTH the human's at-a-glance status surface and the coordinator's
   externalized memory: on restart (`claude --continue` or a fresh
   session), rebuild all state from board + the backlog (index + item files) +
   `git worktree list` + open PRs. Losing the coordinator loses nothing.
   Before the first dispatch of a run, ensure `.claude/sweap-board.md` is in
   the project's `.gitignore` — append it if missing (the scaffold self-heals
   this on session start, but the coordinator double-checks).

**Width is review bandwidth, not worker capacity.** A dispatch slot is held
until the item's PR *merges* — not until code-complete — so open unmerged PRs
consume width and the queue self-throttles to what actually lands. This is
the practitioner-converged constraint ("it's only so much my mind can
review"): more workers than the merge queue can absorb just piles up unmerged
branches going stale. Raise `parallel:` only when the instrumentation shows
the queue, not the workers, is idle.

**Failure handling (all existing doctrine, mapped):** worker blocked →
escalate-don't-guess, mark `status: blocked`, notify, fill the slot with the next
frontier item. Worker dies mid-feature → re-dispatch onto the same
worktree; it resumes from the progress file + git history (pick-up-cold).
CI red after rebase — a semantic conflict, exactly what the queue exists to
catch → the owning worker gets the standard ~3 distinct fix attempts, then
`status: blocked` with the PR left open.

**Local services at K≥2:** parallel workers sharing one local services stack
(same DB, same ports) interfere and produce spurious failures that burn fix
attempts. In coordinator mode, workers treat local services as unavailable and
run CI-gated (CI runs per-PR, isolated, and is the authoritative gate anyway)
unless the project explicitly declares its services parallel-safe.

**Instrumentation (mandatory in the end-of-run summary):** max/mean
concurrency achieved, rebases performed, conflicts hit (textual vs
CI-caught semantic), queue-caused CI reruns, and rough wall-clock vs
estimated serial. Widen K (≤4) only when this data says parallelism pays;
retreat to `parallel: 1` when it doesn't.

**CI determinism is a standing constraint:** a merge queue amplifies a
flaky suite (every flake blocks the queue head). Fix or quarantine-with-
flag per existing doctrine; never retry-until-green.

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
| `/board` (read-only viewer) | Local loopback page showing the live run (frontier/in-flight/merge-queue/hand-offs/blocked) + backlog + dep graph; derives state from item files + git + PRs, never writes | User runs; safe during autonomous runs |
| `/handoff <id>` | Walks one `[attended]` hand-off with the human, then flips it to done through a gated PR on their explicit confirmation | User runs; interactive only |

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
