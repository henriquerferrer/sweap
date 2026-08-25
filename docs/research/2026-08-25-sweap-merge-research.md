# sweap-merge: what the prior art says about discovery, waiting, and scope

**Research memo — 2026-08-25.** Three questions the 2026-08-22 merge-driver
memo left open or answered under assumptions that have since changed (R2's
manifest was killed by refutation on 2026-08-24; sweap's hooks turned out to
have never been registered until 0.12.1): (1) how a driver decides CI is
conclusive with no hand-written manifest, (2) what process model a 5–30 minute
waiter should have inside or around a Claude Code session, (3) which of four
"maybe" features are necessary for a correct first driver. Method: for each
question four parallel research passes with distinct angles (merge-queue prior
art, GitHub API surface, AI-lab/agent literature, practitioners and failure
modes; for the waiter, Claude Code primitives, durable-execution literature,
agent frameworks, SRE writing on pollers), then one synthesis per question.
Every URL below was fetched by the pass citing it. The design that came out is
`docs/superpowers/specs/2026-08-25-sweap-merge-driver-design.md`.

---



# Conclusiveness by discovery: derive the expected set from base-branch workflow config, verify at the workflow-run level

## 1. Answer

**Recommended design (Zuul model, not observation):** the expected set is *computed* from the base branch's workflow files, keyed by **workflow file path**, and conclusiveness is checked against `GET /actions/runs?head_sha=<headRefOid>&event=pull_request`. No manifest, no "whatever reported."

Mechanics of `sweap-merge`:

1. **Expected set E(base, PR)** — recomputed when head or base moves, cached in `.claude/sweap-merge/<pr>.json` with the base SHA it came from:
   - `GET /repos/{o}/{r}/actions/workflows` → keep `state == active`. A base-branch file whose workflow is `disabled_manually`/`disabled_inactivity` → **fail closed** ("expected workflow disabled"), never wait.
   - `GET contents/.github/workflows?ref=<base>` + each file at `ref=<base>`; keep workflows whose `on.pull_request` (or `pull_request_target`) admits the base ref (`branches`/`branches-ignore`) and whose `types`, if set, include `opened`/`synchronize`.
   - Workflow-level `paths`/`paths-ignore` on a gate workflow → **lint failure on base** (GitHub, Mergify, Trunk all say don't; consumer A templates already forbid it). Don't reimplement GitHub's glob evaluation.
   - **E empty → `undecidable`, refuse** (Zuul's noop rule; sweap repo itself yields zero).
2. **Conclusive for head H** iff every `path ∈ E` has a run in `actions/runs?head_sha=H&event=pull_request` — newest run per path (reopen duplicates suites on the same SHA), latest `run_attempt` — with `status == completed && conclusion == success`. The run conclusion already folds in `if:`-skipped jobs and dynamic matrices, so job enumeration is unnecessary except as a belt: the base-declared `if: always()` aggregator (`ci-status`, `audit-gate`, `review`) must appear in `commits/H/check-runs?filter=latest` with `app.slug == github-actions` and `conclusion == success`.
3. **Terminal mappings:** `startup_failure`, `action_required`/`waiting` (approval-held), `cancelled`, `timed_out`, `failure` → failed with reason; absent → `missing` until an **appear-by** deadline (~2–5 min; queued runs show immediately) then failed; `queued/in_progress` → pending until a **complete-by** deadline (p95 of recent runs of that path + margin, ~40 min for a 25-min e2e). Never consult check-suite completion — the `claude` app leaves a permanently `queued`, zero-run suite on every head in both repos. `skipped`/`neutral`/`stale` are never green at the run level.
4. **Extras/removals:** runs on H not in E are logged, not required. A head that removes or disables an expected workflow never becomes conclusive — surface as `missing: <path> (present on base, absent on head)`, the intended CI-weakening block.
5. **Gate coupling:** `pre-merge-gate.sh` accepts only a verdict with `head == headRefOid`, `base_sha` == current base tip, non-empty `expected`. Prefer that the gate **recomputes the predicate** from the API and treats the JSON as a witness — an agent-writable verdict file is a scoring function the agent can patch.
6. **Drift belt:** union observed `(path, event=pull_request)` from the last ~5 merged PR heads; disagreement with E → deny + discovered item, never auto-adopt. Never sample the base tip (verified: main lacks Claude Review, which is `pull_request`-only).

## 2. Evidence

- No commercial queue discovers: Aviator reads branch protection or an explicit list, and is the only one with a `pending` vs `missing` split (https://docs.aviator.co/mergequeue/concepts/ci-status-requirements); Mergify injects ruleset requirements and its maintainers say "check-success=* can't work … hard coding of the required checks are needed" (https://github.com/Mergifyio/mergify/discussions/2184); Trunk (https://docs.trunk.io/merge-queue/getting-started/configure-branch-protection); bors explicit `status = […]` (https://bors.tech/documentation/).
- Zuul computes jobs from branch config and refuses zero-job gates (noop commit: https://opendev.org/zuul/zuul/commit/18c6444f3226dc0b22489955bc97a79a188b8443; https://zuul-ci.org/docs/zuul/latest/config/job.html).
- Observation-only tools admit the hole: poseidon/wait-for-status-checks "doesn't wait for checks that haven't appeared yet"; DataDog/ensure-ci-success same.
- GitHub: path/branch/`[skip ci]` skips create no run and no check run; `if:` skips report Success (https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks; https://github.com/orgs/community/discussions/44490). `startup_failure` runs have no check runs (https://github.com/orgs/community/discussions/57536). API refs: https://docs.github.com/en/rest/actions/workflow-runs, https://docs.github.com/en/rest/actions/workflows, https://docs.github.com/en/rest/checks/runs. Bot-created PRs need approval since 2026-06-11 (https://github.blog/changelog/2026-06-11-bot-created-pull-requests-can-run-workflows-if-approved/).
- Live probes on consumer A (Free, private): `actions/runs?head_sha` returns path/event/attempt per workflow; `filter=latest` dedupes per suite not per name (PR 207 reopen → duplicate `ci-status`); `isRequired` false everywhere; `gh pr checks` exits 1 for both "failed" and "no checks" (cli/cli#9691 unmerged).
- Agent literature: METR reward hacking (https://metr.org/blog/2025-06-05-recent-reward-hacking/), Anthropic emergent misalignment (12% sabotage of detection), Berkeley RDI conftest exploit (https://rdi.berkeley.edu/blog/trustworthy-benchmarks-cont/), GitHub Blog "Any change that weakens CI is a blocker" — all say isolate the evaluator from the agent's write reach.
- Practitioner post-mortem of exactly this failure: https://www.todzhang.com/blogs/tech/en/ci-fix-verification-blind-spots.

## 3. Disagreements

- **Memo §5 vs. decided direction:** memo ranks a committed manifest first, static base-parse as drift detector. Prior art shows manifests are what users complain about (bors #1140, Mergify "most common silent failure"); Zuul shows config-derived sets are sound if fail-closed on zero jobs. Reports agree the parse can be promoted to the rule — but every vendor still anchors to a materialized list, so E must be persisted and diffed, not read live.
- **Zuul vs. memo:** Zuul tests the change's own config speculatively; memo/decided direction reads base. Base-read is stricter and matches GitHub's CI-weakening rule.
- **Memo R1 (trust the JSON verdict) vs. lab literature:** an agent-writable verdict is not a gate. Report 3 recommends the gate recompute.
- **Memo §5 on `fromJSON` matrices:** true but moot at the workflow-run level.
- **Memo attributes missing/pending to Aviator:** confirmed; Mergify does not distinguish.
- **Memo's claim hooks block under bypassPermissions:** not stated in the fetched hooks doc — unverified.
- One WebFetch summary said cli/cli#9452 made "no checks" exit 0 — wrong on gh 2.92.0 (exits 1).

## 4. Open risks / refuter's attacks

- **Novel design:** no shipped merge queue infers from workflow files. The observed-history belt (§1.6) is the mitigation, not proof.
- **Unreproduced (PLAUSIBLE):** that `startup_failure` produces zero check runs on a PR head, and that approval-held runs surface as `action_required` in `actions/runs`. Test on a throwaway PR before shipping.
- **`filter=latest` dedupe semantics** are empirical from one reopen case, undocumented.
- **YAML parsing of `on:` in a hook** (`branches`, `types`, `pull_request_target`, reusable workflows) is new surface; parse failure must refuse, and the lint must be enforced on base or the parse becomes undecidable again.
- **Verdict-file forgeability** remains unless the gate recomputes or the file is made unwritable (PreToolUse deny + external HMAC).
- **GITHUB_TOKEN rule** bites the day the driver runs inside Actions/cloud: zero or held runs; only the appear-by deadline makes that visible. Record `triggering_actor`.
- **Cancelled-by-concurrency** aggregator state (cancelled vs absent) is undocumented; SHA pinning sidesteps it today.

---

# Waiter process model for `sweap-merge`: decision brief

## 1. Answer

**Build C as the contract, A as an interactive front-end, reject B.** The four angle reports converge independently on this; none picks A or B as the mechanism.

The durable object is the state file `.claude/sweap-merge/<pr>.json`, never a process. Mechanics:

- **`sweap-merge tick <pr>`** is the only thing that touches GitHub. Bounded to `BASH_MAX_TIMEOUT_MS` (default cap ~8 min, under the 10-min ceiling), argv containing no `git` token and not starting with `sleep` (both are killed at timeout rather than backgrounded). Each call: claim or renew the lease atomically (`mkdir`/rename of `<pr>.lock`; `owner = session_id:pid`), re-resolve `headRefOid` every poll, poll with Full Jitter (base 20 s, cap 90 s), stamp `heartbeat_at` plus a progress payload (`last_seen` = head SHA + per-check state) every poll, and exit with exactly one of `green|pending|missing|failed|superseded|behind|timed_out|held-by:<owner>`. If the lease is held by a live owner (heartbeat < 2× interval) exit `held-by` immediately: skip beats double-launch.
- **Four clocks in the file**, not in the process: `heartbeat_at` (poller dead), `appear_deadline` (checks never showed up), `complete_deadline` (compare to workflow `timeout-minutes`), `attempts` cap per head SHA. Expiry of any is a fail, never a pass.
- **Fence the lease**: monotonic `lease_epoch`, incremented on every takeover; every tick re-reads before writing and aborts if stale. Merge via `gh api -X PUT .../pulls/N/merge -f sha=<pinned head>` (or GraphQL `expectedHeadOid`) so GitHub rejects a resurrected holder with 409. The gate accepts only a verdict whose `(head_sha, lease_epoch)` match the current head and epoch.
- **Merge step is at-most-once + reconcile**: write `state: merging, merge_sha, merge_epoch` before the PUT, `merged` after. On re-entry in `merging`, query `merged`/`mergeCommit` and reconcile; treat "already merged" as success, 405 base-modified as `behind` (re-arm), 409 as `superseded`.
- **`sweap-merge watch <pr>`** = loop of ticks emitting one stdout line per transition and on every terminal state (silence is not success). Interactive sessions arm it as `Monitor(persistent: true)`; better, ship it as a plugin-declared monitor (`monitors/monitors.json`, `when: "always"`, idling when no leases exist) so the model never decides whether to arm. Its death costs nothing because the file is authoritative.
- **Fallback = C alone, first-class**: `-p`, cloud routines, Bedrock/Vertex/Foundry, and `DISABLE_TELEMETRY`/`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` all lack Monitor. There the loop lives outside the model: orchestrator or routine re-invokes `tick` until terminal. Optionally register `tick` as a `PostToolUse` `asyncRewake` hook on `git push`/`gh pr create` (works where Monitor does not; cancelled at `-p` teardown).
- **Stop hook**: non-blocking summary only, or at most a boundary backstop honouring `stop_hook_active`. Never make it wait for CI.
- **Routines**: trigger on `pull_request.labeled` from CI's final job; fresh clone means the verdict must be recoverable from the PR (check-run/comment carrying verdict SHA) or the routine only re-arms.

## 2. Evidence

- Monitor: session-bound, interactive-only, unavailable under telemetry-off/Bedrock/Vertex/Foundry — https://code.claude.com/docs/en/tools-reference ; plugin monitors — https://code.claude.com/docs/en/plugins-reference#monitors
- "Background Bash and monitor tasks aren't [restored]" on resume — https://code.claude.com/docs/en/sessions , https://code.claude.com/docs/en/scheduled-tasks#limitations
- `/bg` stops monitors but carries over background shells — https://code.claude.com/docs/en/agent-view
- `-p`: background shell killed ~5 s after result; SIGTERM kills process tree — https://code.claude.com/docs/en/headless
- Hooks: async/asyncRewake, Stop `background_tasks`, 8-block cap, fail-open timeouts — https://code.claude.com/docs/en/hooks
- Temporal polling taxonomy (≥1 min → retry, not in-activity loop), heartbeat payload — https://docs.temporal.io/design-patterns/polling , https://docs.temporal.io/encyclopedia/detecting-activity-failures , https://temporal.io/blog/activity-timeouts
- At-least-once activities; merge idempotency from the resource — https://docs.temporal.io/activity-execution , https://docs.aws.amazon.com/durable-execution/patterns/best-practices/idempotency/
- Fencing tokens — https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html ; GitHub merge `sha` → 409 — https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request
- Leases + "skip over double launch" — https://sre.google/sre-book/data-processing-pipelines/ , https://sre.google/sre-book/distributed-periodic-scheduling/
- Jitter — https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
- Orphan/tight-loop folklore: https://github.com/anthropics/claude-code/issues/25188 , /43944 , /50865 , /65985
- Practitioner convergence (wait outside the model): https://github.com/AnandChowdhary/continuous-claude ; https://www.anthropic.com/engineering/managed-agents ; https://openai.github.io/openai-agents-python/human_in_the_loop/

## 3. Disagreements

- **With memo §9 R1 (Monitor as primary poller)**: docs make Monitor the *least* durable primitive across session moves (not restored on resume, stopped on `/bg`, absent under telemetry-off). All four reports demote it to ergonomics.
- **With memo R1's blocking Stop hook**: report 4 argues it recreates the spinner and burns up to 8 turns; report 1 keeps it as backstop. Recommend non-blocking.
- **With memo's ≤10-min in-call loop**: Temporal classifies minute-scale polling as "retry, not loop"; acceptable only if every iteration checkpoints to the file.
- **With memo §3.2 "any reader may run one poll"**: SRE cron says claim first; a reader without the lease is a second writer.
- **Between reports**: report 3 could not find the 8-consecutive-block cap on the hooks page; report 1 quotes it verbatim. Treat as verify-before-citing.
- **With issue #65985's `gh run watch` fix**: reject; it pins a run id, not the PR head (reintroduces w2/w3).
- **Compaction killing background tasks** is one user issue, not documentation.

## 4. Open risks / refuter's attacks

- Detached-process survival is undocumented and contradicted (#25188 vs #43944); B's rejection rests on liability, not proven death.
- Plugin-declared monitors are experimental; the `when: always` daemon may not exist on the consumer's pinned plugin cache (known version skew).
- A monitor silently killed mid-session is indistinguishable from a finished one (#63023); the design assumes this and relies on heartbeat staleness, which adds up to 2× interval of latency before takeover.
- The process model closes only incidents #3, w1–w3; the predicate/doctrine failures (#1, #2, #4–#6) remain with R2–R5.
- No METR/Majors/Hightower/Frazelle primary text on this topic was found; the practitioner leg is thin (continuous-claude plus Anthropic engineering posts).
- Routine tick in a fresh clone cannot read the local state file; the PR-side verdict carrier is unspecified and is itself a forgeability surface (see audit-enforcement memo).

---

# V1 scope brief — sweap-merge: four "build if necessary" items

## 1. Answer

**None of the four items is necessary for a correct first driver. Ship zero of them as designed; ship two cheap substitutes.** Driver correctness is entirely carried by: state file + lease + heartbeat, head SHA pinned per poll (superseded on push), appear-by/complete-by deadlines that fail closed, and the gate accepting only a verdict written for the PR's current `headRefOid`. Nothing in items 1–4 touches that chain.

| Item | Necessary? | v1 disposition |
|---|---|---|
| 1. Auto re-run failed checks | No | **Risky-later.** Driver emits a *classified* terminal `failed` (`conclusion`, `run_attempt`, `red_on_base: true/false/unknown`, `reruns_used: n/50`). Optional manual verb `sweap-merge rerun <pr>`: refuses unless run is `completed`, `--failed` only, refuses when `red_on_base` ≠ false, cap 1 per head SHA, re-reads `run_attempt`, records `rerun:{reason,by,at}` in the state file and re-arms deadlines. No automatic invocation. |
| 2. `workers:` / `ci.inflight:` split | No | **Risky-later (v2, on top of the driver's state files).** v1 substitute: one doctrine line (`parallel ≤ runners − 1`), and offer a job-level `concurrency: {group: e2e-pool, queue: max}` on the e2e job in the ci.yml template — GitHub-native `ci.inflight: 1`, server-side, no plugin state. Must sit at job level, separate from the per-ref cancel-in-progress group (the two are incompatible in one group). |
| 3. Label-triggered cloud routine | No | **Risky-later.** Driver state is local; a routine is a fresh clone of `main`, cannot see `.claude/sweap-merge/*.json`, and the PreToolUse gate does not run there — it would be an ungated second actor merging as the maintainer. Prerequisite for ever enabling: state moved to a PR-visible home, and routine restricted to "re-run `sweap-merge.sh`", never merge. |
| 4. Blocking Stop hook | No — actively harmful | **Ship an observe-only Stop hook** that always exits 0: if a watch is armed and a `monitor` entry is in `background_tasks`, output nothing; if armed with no monitor, emit `additionalContext` once (re-arm instructions), honouring `stop_hook_active`. Never `decision: block`. |

## 2. Evidence that carries it

**Item 1.** Every production queue ships with auto-retry off or absent: Mergify `max_checks_retries` added 2026-03-18, default 0, retries by recreating the draft PR (https://docs.mergify.com/changelog/2026-03-18-automatic-ci-retries-in-merge-queue/, https://github.com/Mergifyio/mergify/discussions/5158); Aviator `max_requeue_attempts` default none, parallel-mode only, requeues only if original PR CI passes while draft fails (https://docs.aviator.co/mergequeue/reference/complete-reference-guide); Zuul `attempts` retries only pre-run/infra errors, never test failures (https://zuul-ci.org/docs/zuul/latest/config/job.html); bors retry is a human command (https://forge.rust-lang.org/release/rollups.html); GitHub merge queue has no retry at all (https://github.com/orgs/community/discussions/189451). GitHub caps reruns at 50 per run since 2026-04-10, explicitly to stop automations (https://github.blog/changelog/2026-04-10-actions-workflows-are-limited-to-50-reruns/); reruns reuse `GITHUB_SHA`, need `completed`, and 403 on stale attempt job ids (https://github.com/cli/cli/issues/9221, https://github.com/orgs/community/discussions/176756). Fowler: quarantine, don't rerun (https://martinfowler.com/articles/nonDeterminism.html).

**Item 2.** The knob exists everywhere but always *inside* the merging actor: Zuul `window`/floor/adaptive on the dependent pipeline manager (https://zuul-ci.org/docs/zuul/latest/config/pipeline.html); Mergify `max_parallel_checks` (https://docs.mergify.com/merge-queue/parallel-checks/); GitHub merge queue build concurrency, unavailable on Free private repos (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue, https://github.com/orgs/community/discussions/131130); SubmitQueue planner (https://dl.acm.org/doi/pdf/10.1145/3302424.3303970). Actions concurrency `queue: max` semantics and incompatibility with `cancel-in-progress` (https://docs.github.com/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs).

**Item 3.** Routines: `pull_request.labeled` supported, fresh clone of default branch, no session reuse, hourly/daily caps drop events, research preview (https://code.claude.com/docs/en/routines). Queues are webhook-driven *and* reconcile by polling; webhooks lie (https://trunk.io/blog/your-merge-queue-shouldnt-go-down-when-github-does, https://mergify.com/blog/when-github-webhooks-lie-how-an-empty-array-broke-our-merge-queue/); at-least-once delivery (https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks); Temporal signals wake, heartbeats verify (https://docs.temporal.io/encyclopedia/detecting-activity-failures).

**Item 4.** Hooks doc: Stop receives `background_tasks` (type `monitor`) precisely to distinguish "done" from "waiting for background work"; 8-consecutive-block override (https://code.claude.com/docs/en/hooks.md). Monitor persists across turns (https://code.claude.com/docs/en/tools-reference). Failure record: #55754 (>100 "waiting for e2e" turns in 50 min), #54360 (`stop_hook_active` defeated by interleaved notifications), #87972 (Stop skipped on stream stall; StopFailure ignores decisions), #10412 (plugin-shipped exit-2 Stop hooks flaky).

## 3. Disagreements

- **Memo §9 R1 vs prior art (item 1):** memo lists bounded auto-rerun as a driver feature; every system shipped years without it and Zuul/bors never added it for test failures. Memo attributes "never when red on base" to Cursor — no primary Cursor source found; correct attributions are Aviator's differential guard and Trunk's downstream-proves-flake.
- **Memo §6 "throttle before `git push`" (item 2):** a job-level concurrency group throttles at runner acquisition, server-side, and avoids the memo's stated objections (draft-PR `if:` spinning runners, `[skip ci]` never reporting), which the memo did not consider. Memo also cites Zuul's window as a separable model; in Zuul it is a property of the pipeline manager. "Chromium CQ = 1-at-a-time" is inaccurate (4 CLs/8 min); true only for bors.
- **Memo §3.3 "functionally equivalent" (item 3):** only true if driver state and gate live in the repo/PR; in v1 both are local.
- **Memo §3.2/§9 "8-block override is the right backstop" (item 4):** docs and #55754 say the opposite — turn end with an armed Monitor is the intended resting state; blocking fights the harness.

## 4. Open risks / what a refuter attacks

- **Item 1:** "Without any retry the loop stalls on every flake." Counter: the classified verdict plus manual verb gives the same recovery with an audit trail; but no flake classifier exists yet, so the rerun verb will be used blindly at first. Risk: agents route around the verb via bare `gh run rerun` — needs the PreToolUse redirect.
- **Item 2:** `queue:` availability on the consumer's plan is unverified; N=1 only; pending time now counts against complete-by, so the driver must treat queued as legal waiting. Without any cap, consumer A at `parallel: 2` on 3 runners can still produce contended reds — doctrine, not mechanism, holds that line in v1.
- **Item 3:** Headless/unattended wake latency remains clocked; whether a `GITHUB_TOKEN`-applied label reaches the Claude GitHub App is unverified.
- **Item 4:** Whether `background_tasks` is populated in `-p` mode and via the plugin-hook path is unverified ("present when the task registry is reachable"). If not, the observe-only hook degrades to silence — safe, but blind.
- **Thinness:** report evidence for items 1–2 is strong on prior art but has no measured sweap flake rate; items 3–4 rest on docs plus GitHub issues, not on a tested prototype.