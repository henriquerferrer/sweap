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
  merge gate** (project-specific; e.g. `just e2e`).
- **`backlog.file`** — the backlog/roadmap file. Default **`ROADMAP.md`**.
- **`backlog.prefix`** — the milestone-tag prefix. Default **`F`** (so milestones
  read `F1`, `F2`, … and items `F1.1`, `F1.2`, …). Referred to below as *the
  milestone prefix*.
- **`services.up`** — optional command that brings up local test services. **Omit
  it entirely if the project has no local services** — the pipeline then runs in
  CI-gated mode (see Environment parity).
- **`audit.lenses`** — the milestone-audit finder lenses. Default = **the generic
  default lens set defined in the audit workflow** (correctness, authz/security,
  data-integrity, concurrency/races, test-integrity, api-contract). Projects
  **append domain lenses** here (they never remove the defaults).
- **`review.dimensions`** — the conditional review dimensions a roadmap item may
  tag. Default: **`security`, `ui`, `migration`**.
- **`notify`** — end-of-run notification channel: **`push`** or **`none`**.
- **`turns.default`** — the default turn budget for an autonomous run. Default
  **`160`**.

References to `ROADMAP.md`, the milestone prefix `F`, and `just …` recipe names
below are the baked defaults; a project that overrides them reads its own values
through this block. When a project's config declares a value, that value wins.

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
4. **Conditional review dimensions** (from the item's `review-dimensions` tags
   in `ROADMAP.md` — see below): run each required extra reviewer before the PR.
5. **Merge, clean up (see End-of-run hygiene), next item.**

## Environment parity (local machine vs. Claude Code web / cloud)

The loop runs identically in any environment because **CI is the authoritative
test gate, not the local machine.** CI runs the verify gates (including
`verify.e2e`) against the same services on every PR, and the merge gate requires
every CI check green — so an item **cannot** reach `[done]` without e2e passing
in CI, regardless of where it was written.

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

- **`/roadmap [milestone]`** — brainstorm the next milestone into `ROADMAP.md`
  items (the 3-phase decide → cross-check → reconcile). Defaults to the next
  unspecced milestone. Interactive.
- **`/milestone [milestone] [turns]`** — if `services.up` is declared, brings up
  local test services itself (starting the daemon if needed; falls back to
  CI-gated mode when services are unavailable), then prints the ready-to-paste
  `/goal` for an autonomous run. Defaults to the next runnable milestone and
  `turns.default` turns. You never run `services.up` by hand; the paste step
  exists only because a human must invoke `/goal`. Ritual:
  `claude --permission-mode auto` → `/milestone` → paste.

## Review dimensions (tagged per ROADMAP item)

Each roadmap item carries `review-dimensions: [...]`, drawn from the project's
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
- `ROADMAP.md` status updates are part of the item's PR, not separate commits.
- At goal end (met or stopped): if `notify` is `push`, send a push notification
  summarizing merged PRs and blocked items; list any leftover worktrees/branches
  in the final message; the primary checkout is already current (see above), so
  `git pull --ff-only` is a no-op for the human.
- **Merge gate (substitute for branch protection, unavailable on the free
  GitHub plan):** never `gh pr merge` until `gh pr checks <n>` shows every
  check green — including the `review` check. The `review` check now **enforces
  the verdict**: its final job greps the reviewer's summary comment and fails
  closed on "Verdict: needs-work" or on no verdict at all, so a green `review`
  check structurally means the reviewer approved. Read the reviewer's inline
  comments and address every one before pushing the fix; a "needs-work" verdict
  is the GitLab-style "resolve the threads before you can merge" — you clear it
  by fixing and re-pushing, which re-runs the review. (The gate is skipped only
  on PRs that edit the reviewer workflow itself, which self-skip the action.)
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
  instruction still governs `gh pr create` (not hooked).

## Deferred items (parked behind a future dependency)

A `[deferred]` item is a *good idea that cannot be built yet* because it depends
on work that doesn't exist. It is distinct from `[blocked]`:

- `[blocked]` = active work is **stuck** and needs a human answer to continue
  *now*. It sits on the "needs-me-now" queue and pings the human.
- `[deferred]` = **parked**, nobody is working on it, nothing is stuck. The agent
  never auto-picks a `[deferred]` item (it is invisible to the top-of-backlog
  picker exactly like a `Later milestone`). It keeps the "needs-me-now" list
  honest — only genuine `[blocked]` items pull the human's attention.

**Why deferred instead of leaving it `[todo]`.** A `[todo]` item that can't be
built (its deps aren't `[done]`) is clutter: the picker either trips on it every
run and escalates, or a human has to remember it isn't really ready. `[deferred]`
encodes "not ready, don't look" once, mechanically.

**Premise (required on every deferred item).** Each deferred item carries a
`Premise:` line — the assumption it is waiting on, written wherever possible as a
**machine-checkable predicate**, not prose. Good: *"a `billing_events` table
exists with the expected columns"*, *"the target milestone's spec AC-3 still
reads X"*. This is the small authoring discipline that buys the autonomy below — a
checkable premise is one no human ever has to adjudicate.

**Dependency granularity — item-level vs. milestone-level.** The unblock scan is
*item-level*: it fires when a `Depends on:` entry that names a **taggable item**
(a numbered sub-item like `F4.3`, using the configured milestone prefix) turns
`[done]`. A dependency on a **whole milestone** — a bare `F4`, whose section
header never carries a status tag (only numbered sub-items do) — is **not**
auto-scannable and must not be treated as `[done]` by text-match (nor as
vacuously done because the milestone has no items yet). A bare-milestone
dependency is unblocked when that milestone **completes** — its section exists and
every item in it is `[done]` — which coincides with the milestone-audit and the
next `/roadmap`, a human-in-the-loop boundary. So milestone-level deferrals
**surface at the milestone boundary** (the `/milestone` pre-flight backstop and
the next roadmap pass), not via the automated end-of-run item scan. Rule of
thumb: once the target items exist, rewrite `Depends on:` to item granularity so
the scan can fire; a bare-milestone dep is a deliberate "resurface when that
milestone completes" marker, not an auto-promote trigger.

**Lifecycle — an item is *unblocked* when every `Depends on:` item is `[done]`.**
Unblocked ≠ ready; it **never auto-promotes**. On unblock the agent evaluates the
premise and takes exactly one path:

1. **Premise machine-checkable AND verifiably holds** → auto-promote to `[todo]`.
   No human touch. This is the common case (the dependency landed roughly as
   planned) and it must be *verified*, not guessed — the failure mode of a wrong
   promote is a stale feature built against a dead assumption that passes every
   gate (gates verify correctness, not intent) and merges invisibly. Any doubt
   about whether the premise is *truly* mechanically verifiable → treat as
   not-checkable and escalate (path 2/3). Bias toward escalation: a needless
   escalation costs one notification; a wrong auto-promote ships silently.
2. **Premise not machine-checkable, or the check fails but the item still makes
   sense** → **escalate for re-spec.** Keep it `[deferred]`, annotate it
   `> **UNBLOCKED (YYYY-MM-DD):** <what shipped vs. the premise>`, and list it in
   the end-of-run summary. The re-spec itself flows into the next `/roadmap`
   conversation — no new standalone touchpoint.
3. **No longer makes sense** → **propose drop.** Move the item to the
   `## Archived / dropped` section with a one-line reason. This is a *reversible*
   soft-delete (it stays in git history and the archive section), so it does NOT
   block on the human's confirmation — they veto async if they disagree. (Drop is
   cheap and reversible; promote is expensive and invisible — gate each to its
   cost of being wrong.)

**When the check runs (it is stateless — just "are this item's `Depends on:` all
`[done]`?", recomputed from `ROADMAP.md`, so missing it once costs nothing):**

- **Primary — end of every run.** Any run that merges a PR scans for
  newly-unblocked deferred items and applies the lifecycle above, surfacing
  paths 2/3 in the end-of-run summary. The dependency landing *is* a merge in that
  run, so the merging agent is best placed to notice.
- **Backstop — `/milestone` pre-flight.** `/milestone` re-runs the same scan when
  it reads `ROADMAP.md`, catching anything unblocked *outside* an autonomous run
  (e.g. a hand-merged dependency).

Un-checkable premises are not a hole in this design — they are its **sorting
function.** A premise that can't be mechanically verified *is* a judgment about
what shipped, i.e. a taste call, i.e. the "which problems matter" work that stays
human. Checkable premises auto-resolve; un-checkable ones route to the human
*because* they are direction calls. Human load compresses toward a floor of
roadmap authoring + genuine-divergence calls, and that floor is deliberate: it is
where product direction lives, which no gate can verify.

## Milestone brainstorm (before a milestone starts)

Authoring a milestone's `ROADMAP.md` items is direction-loop work —
interactive-only, done with the human. It runs in three phases; the pair of a
decisive pass and an independent completeness critic is the same finder/refuter
shape as the audit.

1. **Decide** (interactive) — `superpowers:brainstorming` with the human.
   Socratic, one question at a time; it *locks* the core decisions and produces
   draft items in the ROADMAP house format (status tag, `Depends on:`,
   `review-dimensions:`, e2e acceptance criteria). This is where the human's
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
   the items are written into `ROADMAP.md`'s active section via a PR through the
   gate.

Rationale: a single decisive pass is fast but blind-spotted. The A/B that
motivated this: a decisive pass locked a milestone's core but missed timezone
handling and a cross-record overlap case; an independent breadth pass caught both.
Phase 2 makes that second lens a standard, cheap step instead of luck.

## Milestone audit (after a milestone completes)

When the last item of a milestone merges, run the saved audit workflow via
`/milestone-audit` (optionally with `{range: "<base>..<head>"}`). It audits the
merged whole with the finder lenses declared in `audit.lenses` — by default **the
generic default lens set defined in the audit workflow** (correctness,
authz/security, data-integrity, concurrency/races, test-integrity, api-contract),
plus whatever **domain lenses the project appends via `audit.lenses`** — and
adversarially refutes every finding — only majority-surviving findings are
reported. It exists to catch what per-PR review structurally cannot: cross-feature
interactions, systemic patterns, and plan-level mistakes.

**Auto-launch (pre-authorized in the goal).** A milestone `/goal` run carries a
final clause so the audit fires once, automatically, at the milestone boundary —
no cron, no standing agent. Standard template:

> *First, every outstanding audit follow-up item in `ROADMAP.md` is [done] (the
> `/milestone` run drains them debt-first — see the bucket-2 note above); then
> every unblocked <milestone> item in `ROADMAP.md` is [done] per the definition
> of done; and when the last item merges, run `/milestone-audit` for that range,
> triage the confirmed findings (below), and post a summary before stopping.
> Stop when only [blocked] items remain, or after N turns.*

The evaluator won't call the goal met until the audit has run and its findings
are triaged. The `/milestone-audit` **workflow itself is read-only** — it finds
and reports confirmed findings, never edits code. What happens next is the
**triage** the surrounding session performs (below): a bucket-1 fix is a
deliberate, gated *follow-on* PR the session opens, not something the audit
workflow does silently.

**Findings triage (three buckets — the session running the audit sorts them).**
1. **Bug** (code fails its own spec): the session opens a follow-on fix-PR
   through the gate. Hands-off in an unattended run (no human needed), but still a
   separate gated PR — the audit workflow never edits code.
2. **Small gap / non-urgent** (races, infra): append as an audit-follow-up
   fix-item (using the milestone prefix, e.g. `FA.*`) at the top of `ROADMAP.md`
   (`[todo]`, tagged), under this milestone's `## <milestone> audit follow-ups`
   section. Hands-off. These are **auto-folded, debt-first, into the next
   `/milestone` run** — its pre-flight audit-debt scan collects every unblocked
   `[todo]` under a `## <milestone> audit follow-ups` section and drains it ahead
   of the named milestone (or as a standalone **debt-only run** when no milestone
   is runnable). Bucket-2 is a tracked queue with a defined drain, not a
   dead-drop — nobody has to remember it.
3. **Design / scope gap** (the feature *should* do something it never promised):
   this is a **direction-loop** change, not correctness — do NOT spec or build
   it. Write it to `ROADMAP.md` as a `[blocked]` entry with the question verbatim,
   push-notify the human, and move on. It waits for their `> ANSWER:` line exactly
   like any escalation. This is how a change-of-direction gets back to a human:
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

Running the audit is a deliberate token spend; it is pre-authorized per-run via
the goal clause above, or triggered manually.

Rationale: the throughput lever is loop tightness with machine verification, not
parallelism. Core features are often serially dependent; parallelize only
genuinely independent tracks (marketing site, CI, polish on merged features) via
worktree-isolated agents.

## The three loops (what autonomy replaces, and what it can't)

1. **Correctness loop — fully automated.** Gates: `verify.typecheck`,
   `verify.lint`, the `verify.e2e` gate, immutable tests, fresh-context agent
   review, agentic CI on PRs. No human needed for a PR to be trustworthy.
2. **Prompting loop — fully automated.** `ROADMAP.md` is the interface: the agent
   always picks the top unblocked item. Loops/cron/headless runs keep sessions
   going without a human typing prompts. **Escalate, don't guess:** if an item is
   ambiguous or a gate stays red after ~3 distinct attempts, mark the item
   blocked with a written question in `ROADMAP.md`, notify the human, move to the
   next item. Never bluff through ambiguity.
3. **Direction loop — stays human.** The human writes/re-aims the roadmap and
   acceptance criteria (~1 hr/week), answers blocked questions async
   (~15 min/day), and personally approves anything irreversible: production
   deploys, data migrations against real data, anything touching sensitive
   production data.

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
2. **`ROADMAP.md`** — the first milestone broken into 3–5 feature-sized items with
   acceptance criteria; a rough sketch of the next milestones. This is the
   direction-loop artifact; its quality bounds everything downstream.
3. **Supervised runs** — a few `/goal`-driven sessions with the human watching,
   to calibrate escalate-vs-proceed judgment. Goal conditions must name the
   verification commands and include a turn bound (`or stop after N turns`).
4. **Unattended** — `/goal` + auto permission mode, nightly cloud routines,
   notify-on-block. `/loop` reserved for time-paced monitoring.

## How to pick up this work cold

1. Read this file, then `git log --oneline -20` and `ROADMAP.md` (if it exists yet).
2. If `ROADMAP.md` is missing, the current task is step 2 of the build order:
   draft it with the human (or from the notes in `docs/superpowers/specs/`), don't
   invent scope.
3. Otherwise: take the top unblocked roadmap item and run the per-feature loop.
4. Check `docs/superpowers/plans/` for an in-flight plan with unchecked steps —
   that means a feature was interrupted mid-implementation; resume it before
   starting anything new.
