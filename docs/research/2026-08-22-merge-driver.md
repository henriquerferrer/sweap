# A merge gate is not a merge driver — and the four other gaps the same run exposed

**Research memo — 2026-08-22.** Question: a coordinator running consumer A under
sweap sorted one run's failures honestly and found that six of them were its
own inline automation, all of the same species — a hand-written *waiter*. It
proposed five changes: (1) ship a merge-queue driver, (2) discover the check set
instead of hardcoding it, (3) make "absence is not a pass" doctrine, (4) split
`parallel:` into worker concurrency and CI concurrency, (5) add
mutation-restore guidance. Are these right, what does the prior art say each one
must look like, and which of them can sweap actually ship given its constraints
(Claude Code plugin; hooks that deny but cannot block for 20 minutes; a Free-plan
private GitHub repo with no branch protection, no required checks, no merge
queue)?

Method: the run's own post-mortem (`consumer-a/.claude/sweap-board.md`, sections
"Waiter bug", "Agents are bad at waiting", "Process finding — mutation",
"Coordinator error #1/#2/#3", "CI solved — contention was the whole story") read
as primary incident evidence; then five parallel research passes — merge-queue
driver prior art, check-set discovery and fail-closed doctrine, worker-vs-CI
concurrency, mutation-restore isolation, and agent waiting/polling failure
modes. Every cited URL was fetched by a research pass on 2026-08-22; items a
pass could not fetch are marked *(unverified)* in §11. One conflicting claim
between passes (the `gh pr checks` exit code on zero checks) was settled by
reading the `gh` source directly. A sixth pass on 2026-08-23 checked what
Claude Code itself exposes for event-driven waiting (§3.3), after review of
the first draft named the pattern beneath the six failures (§3.2).

---

## 0. The one-sentence answer

Yes — all five, and they are one change plus four consequences of it: **sweap
has a merge *gate* (a deterministic deny at the moment of `gh pr merge`) but no
merge *driver* (the thing that waits, decides the checks are conclusive, merges,
cleans up, and moves on), so every run re-derives the driver inside the model
loop and re-derives its bugs.** Every mature gating system — GitHub's own merge
queue, Zuul, bors, Uber's SubmitQueue, Mergify, Aviator, Trunk — is a *single
long-lived actor* that owns exactly that loop, with the conclusiveness
predicate, the expected-check set, the two timeouts, and the new-push
invalidation in *configuration*, not re-derived per change. The prior art is
unanimous on the invariants (§3), GitHub's own vocabulary already has the
"not-yet-known" states the hand-written predicate ignored (§4), the expected
set must be a committed manifest with drift detection because no server-side
source exists on this plan (§5), the concurrency knob conflates a free resource
with a contended one and every queue product separates them (§6), and the
restore hazard is solved in every mutation-testing tool by never restoring from
`HEAD` (§7). Underneath the six failures is one shape — an action that invalidates a
watcher is never paired with re-arming it — and the fix is two-fold: a
level-triggered poll removes the premise for every invalidation that changes
*what* is watched, and a lease plus hook-paired, boundary-triggered re-arms
cover the one that removes the watcher itself (§3.2). Sweap already has the
hard part — a hook that denies — so the driver slots in as the *only* path
that can satisfy the hook (§9, R1).

---

## 1. The incident, as evidence

The coordinator's own ledger, verbatim where it matters. These are the six
"my own inline automation" failures, plus the worker-side ones, classified:

| # | What happened (board section) | Species | Proposal it motivates |
|---|---|---|---|
| 1 | `gatewait.sh` predicate was "no check is pending"; "fired green on a rebased head where CI's six jobs had **not been created at all**" | absence read as pass | (3), (1) |
| 2 | `gatewait.sh` "requires all EIGHT expected checks present" — CI had changed to five (`checks`, `e2e`, `ci-status`, `review`, `audit-gate`) | hardcoded set went stale | (2) |
| 3 | `drain.sh` re-ran the failing run to attempt 41 (retry-until-green, stderr discarded) → livelock, #189 stalled ~50 min — *see erratum* | unbounded retry loop | (1) |
| 4 | `git checkout -- <file>` as restore advice; FN.4's worker "**wiped its own fix**"; "`git status --porcelain` reads CLEAN afterwards, so the verification step I prescribed actively confirms the wrong thing" | restore from HEAD over uncommitted work | (5) |
| 5 | FM.9's spec named a fix shape (`if (purgeTarget?.id !== target.id) return`) that "**would have shipped a no-op**" — FM.8's exact defect family | spec prescribes the how | doctrine line (§8) |
| 6 | Widened to 4 workers: "6 open PRs (#185-#190) on 3 runners at load average 17.5 … produced false reds I then spent turns diagnosing" | worker width ≠ CI width | (4) |
| w1 | FK.9: `pgrep -f playwright` "**matches the waiting loop's own command line**" — three until-loops could never exit | self-matching liveness check | (1) |
| w2 | FN.2/FN.3: "monitors pinned to **superseded commits**, re-reporting `build: success` for heads that no longer existed" | pinned to a dead SHA | (1) |
| w3 | FJ.7: "chained polls that kept resolving to pre-CI-start snapshots — five consecutive stale notifications" | stale snapshot | (1) |

> **Erratum (2026-08-24).** Row 3 originally read "re-ran in-progress runs →
> livelock", following the coordinator's self-diagnosis. Attempt-level API data
> for run 32582950754 (fetched 2026-08-24) contradicts it: the run ended at
> attempt 41 and every sampled attempt (1, 2, 10, 25, 40) was `completed
> failure` at the moment it was re-run — GitHub refuses reruns of unfinished
> runs (cli/cli #9221), and drain.sh v1's own selector (`.conclusion ==
> "failure"`) cannot even match an in-progress run (`conclusion: null`). The
> real defect was an unbounded retry-until-green loop with stderr discarded,
> violating doctrine the board already carried ("Re-run ONCE as diagnosis").
> §3's "never act on a non-terminal run" invariant stands on the cited prior
> art; this incident is evidence for a different rule — an attempt cap and a
> completed-check *inside* the loop. A refutation round on 2026-08-24 (five
> adversarial agents) also revised §9: the expected-checks manifest, the thin
> waiter script, and a rerun-deny hook were refuted; what survived and shipped
> instead: a fail-closed `ci-lane.sh` config read, a hardened `ci-status`
> aggregator, a ci-status presence check in the gate, and the playbook's
> waiting-discipline rules.

Two facts from the same ledger frame everything below. First, the measured
cause of the "false reds": `#181 e2e, ALL THREE RUNNERS OTHERWISE IDLE: 8m54s
PASS` versus `#181/#182 e2e, 3 jobs concurrent: 30-32 min CANCELLED (timeout)`
— "~3.4x inflation under contention", and "Every diagnosis I made from a
contended run was wrong." Second, the coordinator's own reading of the pattern:
"Four separate workers burned real cycles on waiters in this run. Treat as a
pattern, not four lapses." That is the right reading. The sweap gate — which
"never once let a bad merge through" — is doing its job; what it guards is the
*last* step of a loop nobody owns.

## 2. What sweap has today (repo facts)

- `plugin/hooks/pre-merge-gate.sh` is a `PreToolUse` deny on `gh pr merge`. It
  fails closed on *zero* checks (`:255`), on any non-`SUCCESS`/`SKIPPED`/
  `NEUTRAL` check (`:261-270`), on `BEHIND` and on a non-zero compare-API
  `behind_by` (`:287-313`), on `--admin`/`--repo`, and on any wrapped
  invocation. It has **no expected-set**: `:263-265` maps the rollup to
  offenders, so five green checks out of an intended eight pass. It is also
  bounded by the hook timeout (`plugin.json`: 25 s) — it can deny, it can never
  *wait*.
- Nothing in the plugin waits. `plugin/commands/milestone.md` mentions polling
  once (Docker boot). The playbook's merge section says "never `gh pr merge`
  until `gh pr checks <n>` shows every check green" and records the
  `--watch | tail` incident — and stops there. *How* to wait is left to the
  session, which is the vacuum the six scripts filled.
- The `parallel:` knob (`plugin/templates/CLAUDE.md:23`; consumer A runs `2`) is
  the only concurrency control, and the playbook's own "Parallel runs" section
  already concedes the point in passing: "width is review bandwidth, not worker
  capacity" — but offers no second knob.
- The word "mutation" does not appear in the sweap playbook. The discipline
  lives in consumer A plans (`docs/superpowers/plans/2026-08-20-fn.2-…`: "Every
  test below names the mutation it must fail under") and in the TDD-evidence
  rule of the CLAUDE template. Restore is unaddressed anywhere.

## 3. What a merge driver is, according to everyone who has built one

Every production gating system is one actor owning *wait → verify conclusive →
merge → next*, and they agree on the invariants to a degree that is unusual:

**Conclusive means an expected set, each terminal, each passing — never "nothing
pending".** GitHub's merge queue "will wait for required checks to be reported
before it can proceed with merging" and has a "Status check timeout: Choose how
long the queue should wait for a response from CI before assuming that checks
have failed" ([managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)).
Aviator names the three states the hand-written predicate collapsed: "a check is
`pending` when it has been reported but has not finished yet, whereas a check is
`missing` when it has not been reported at all" — and `missing` is accepted only
by explicit opt-in ([Aviator CI status requirements](https://docs.aviator.co/mergequeue/concepts/ci-status-requirements)).
bors reads an explicit `status = [...]` allowlist and times out at one hour by
default ([bors getting started](https://bors.tech/documentation/getting-started/)).

**Two timeouts, not one: appear-by and complete-by, and both fire *fail*.**
Sibz/await-status-action separates `notPresentTimeout` ("Maximum time in
seconds to wait for a check to appear", default 300) from `timeout` (complete,
default 600), because "it may take … a status-adding workflow to add its state,
bearing in mind that it may be queued". Mergify's `checks_timeout` default
`auto` "computes the timeout from the queue's own recent CI runtime, using the
95th-percentile duration of successful runs plus a safety margin" ([Mergify
lifecycle](https://docs.mergify.com/merge-queue/lifecycle/)). A timeout
*dequeues*; it never passes.

**A new head invalidates everything.** Zuul's `dequeue-on-new-patchset` defaults
to `true`: "if a new patchset is uploaded to a change that is in a pipeline, the
existing entry in the pipeline will be removed (with jobs canceled …)" ([Zuul
pipeline config](https://zuul-ci.org/docs/zuul/latest/config/pipeline.html)).
bors: "pushing new commits to a PR branch after it's marked `bors r+` will
cancel it" — and a case where it *didn't* was filed as a bug (bors-ng #1138).
Aviator on a new commit: "Closes the associated draft (bot) PR. Resets all
subsequent draft PRs. Requeues." Trunk: PRs "get kicked since they were
updated." GitHub's own `MergeQueueEntry` carries `baseCommit` *and*
`headCommit` — an entry is a (base, head) pair, and a head change is a different
entry. Worker failures w2 and w3 are exactly a waiter that was not an entry.

**Never act on a non-terminal run.** GitHub refuses: `gh run rerun` on an
unfinished run fails because "the workflow must complete before reruns are
permitted" (cli/cli #9221), and a re-run "will also use the same `GITHUB_SHA`"
as the original ([re-running workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs))
— so re-running after a force-push tests the wrong commit even when it
succeeds. Check-run `conclusion` is `null` until `status == completed`; only then
is it meaningful ([REST check runs](https://docs.github.com/en/rest/checks/runs)).
`drain.sh`'s livelock looked like the consequence of skipping that predicate
(see the §1 erratum: attempt-level data shows the loop re-ran *completed*
failures — the missing discipline was an attempt cap and a completed-check
inside the loop).

**Test what will actually land.** Zuul tests each change "applied to the tip of
the branch exactly as it is going to be merged"; SubmitQueue's guarantee is
green "for every commit point" (Ananthanarayanan et al., *Keeping Master Green
at Scale*, EuroSys 2019); Aviator handles staleness by *sync then requeue*, not
by merging anyway. Sweap's compare-API freshness check already enforces this at
the gate; the driver must re-arm the whole predicate after the rebase it
demands.

**One actor owns the loop.** Cognition: "Actions carry implicit decisions, and
conflicting decisions carry bad results" ([Don't build multi-agents](https://cognition.com/blog/dont-build-multi-agents)).
A drain script and a waiter running side by side *are* two actors making the
rerun-vs-wait decision differently. The board's own rule — "One watcher per PR.
The coordinator owns the merge, so the coordinator owns the waiter" — is the
same conclusion, arrived at the hard way.

**Enforce it mechanically.** OpenAI's account of agents that "often squash and
merge their own pull requests" is explicit about where the rules live: "When
documentation falls short, we promote the rule into code … enforced
mechanically via custom linters … and structural tests" ([Harness engineering](https://openai.com/index/harness-engineering/)).
Böckeler's split is the useful vocabulary: computational controls are
"deterministic and fast, run by the CPU … results are reliable"; inferential
ones are "slower and more expensive; results are more non-deterministic"
([Harness engineering for coding agent users](https://martinfowler.com/articles/harness-engineering.html)).
Letting the model re-derive the waiter each run turns a computational control
into an inferential one. Claude Code's docs say the same about the plugin's own
substrate: "Unlike CLAUDE.md instructions which are advisory, hooks are
deterministic and guarantee the action happens … If Claude already does
something correctly without the instruction, delete it or convert it to a hook"
([best practices](https://code.claude.com/docs/en/best-practices)).

### 3.1 Why agents specifically are bad at this

The waiting bugs are not exotic; they are the canonical bugs of their class,
and agents hit them because each session writes the loop fresh:

- **Self-match.** `pgrep -f` "will never report itself as a match" — but that
  exempts only pgrep, not the `bash -c '…'` parent whose argv contains the
  pattern ([pgrep(1)](https://man7.org/linux/man-pages/man1/pgrep.1.html)).
  Claude Code issue #52328 is this exact failure inside a `Monitor` until-loop:
  "That bash's own argv contains the literal string the check is searching for
  … the loop never exits" — closed not-planned, i.e. it is the caller's job.
- **Pipe masks exit.** `pipefail` "is disabled by default" ([bash manual](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html));
  the `--watch | tail` incident the hook was built after is ShellCheck SC2312.
- **Stale reads.** `gh pr checks` "retains stale checks until a new commit is
  pushed" (cli/cli #4946) and races "no checks" right after PR creation
  (cli/cli #7401); `statusCheckRollup` is per-SHA, so any poll that does not
  re-resolve the head each iteration reports on history.
- **Time-blindness.** "Claude can't tell time and, left alone, will happily
  spend hours running tests instead of making progress" (Carlini, [Building a C
  compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler)).
  A wait without a deadline is a bug, and the model will not add one.
- **The harness kills waits.** Background commands started by a foreground
  subagent end "when that subagent gives its final response"; in `-p` mode
  "background tasks end shortly after the run's final result"; a command
  containing `git` anywhere is *never* auto-backgrounded ([tools reference](https://code.claude.com/docs/en/tools-reference));
  on SIGTERM "Claude Code terminates the process tree of any Bash command"
  ([headless](https://code.claude.com/docs/en/headless)). Issue #63023: killed
  background agents "look indistinguishable from successfully-completed
  agents." So a waiter whose state lives in its *process* is wrong by
  construction; it must live in a file and be re-armable (Anthropic's own
  long-running-agent harness keeps progress in `claude-progress.txt` + git for
  the same reason — [Effective harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
- **Polling floods shared state.** Anthropic's multiagent study: agents with no
  coordination protocol "quickly flooded the system with high-frequency (30
  times per second) polling daemons … 2.4 million job requests and only 117
  jobs accepted" ([Patterns and problems in multiagent systems](https://www.anthropic.com/research/multiagent-systems)).
  Kubernetes' principle is the antidote: "Functionality must be *level-based*
  … regardless of how many intermediate state updates may have been missed"
  ([K8s design principles](https://github.com/kubernetes/design-proposals-archive/blob/main/architecture/principles.md)),
  with backoff and jitter ([Brooker, AWS](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)).

Hashimoto's definition of harness engineering is the policy: "anytime you find
an agent makes a mistake, you take the time to engineer a solution such that
the agent never makes that mistake again" — and his ladder goes from an
AGENTS.md line to "actual, programmed tools. For example, scripts to take
screenshots, run filtered tests" ([My AI adoption journey](https://mitchellh.com/writing/my-ai-adoption-journey)).
Six waiter bugs in one run is past the AGENTS.md rung.

### 3.2 The pattern under the pattern: invalidation without re-arm

Read the nine rows of §1 once more and a single shape appears beneath the
"waiter" species: **an action that invalidates the watcher — a force-push, a
merge, a re-run, a kill — is never paired with re-arming it.** The monitor
pinned to a superseded SHA was invalidated by a push nobody told it about; the
drain script re-ran a job whose watcher still believed the previous attempt;
the waiter that died with its turn left a file that said "waiting" and a
session that believed it. Each fix above addresses an instance; this section
says what fixes the shape, because the two halves need different mechanisms.

**For every invalidation that changes *what is watched* — push, merge,
re-run — the fix is not pairing but removing the premise.** A level-triggered
poll (§3, Kubernetes: "operate correctly … regardless of how many intermediate
state updates may have been missed") re-derives the head SHA, the base
distance and the latest check attempt on every iteration. There is nothing to
re-arm because nothing was armed: a force-push does not need to notify the
watcher, the next poll simply sees a different SHA and restarts the appear-by
clock; a merge that moves `main` does not need to re-arm the other PRs'
watchers, their next poll returns `behind`; a re-run shows up as the latest
attempt going `queued`. This converts the pairing obligation into a property
and covers failures w2, w3 and the drain livelock outright.

**For the one invalidation that removes *the watcher itself* — the kill —
level-triggering cannot help, because there is no poller left to re-derive
anything.** "File-backed and re-armable" is necessary but restates the
problem as a feature: the harness ends the turn, nothing re-arms, and
re-armability depends on someone noticing. Three mechanisms close it, and they
share one idea — liveness of the *poller* is re-derived the way liveness of
the *SHA* is, never assumed:

1. **A lease, not a process.** The state file carries `heartbeat_at`, stamped
   on every poll. Any reader that finds a watch in `waiting` whose heartbeat is
   older than ~2× the poll interval treats the poller as dead — and either runs
   one poll itself or reports the watch as dead with its last known state.
   That is the standard lease pattern (the `git worktree lock` Claude Code
   itself takes while an agent runs is the same idea at the filesystem level),
   and it is what "death must be loud" requires mechanically: loudness needs a
   listener, and the lease makes every reader one.
2. **Pair invalidating actions with their re-arm in the same hook.** sweap
   already has a `PostToolUse` on `gh pr merge` (`post-merge-cleanup`). The
   same family extends to every action that invalidates a watch: after a
   merge, stamp every *other* open watch `base_moved`; on `gh run rerun`,
   `gh run cancel` or `git push --force*`, reset the affected watch's deadlines
   and record `invalidated: <reason>`. The re-arm cannot be forgotten because
   it is not a separate step — it lives in the hook that fires on the action.
3. **Re-arm at every boundary the harness crosses.** The kill always happens
   at a harness event — turn end, compaction, `-p` exit, SIGTERM, session
   resume — and every one of those is hookable. `SessionStart` and
   `UserPromptSubmit` read `.claude/sweap-merge/*.json` and surface every
   lease-expired watch ("#189 armed at T, poller dead, last known `pending`
   with 2 of 5 checks reported"). A `Stop` hook blocks the turn from ending
   while *this session* owns an armed, unexpired watch — Claude Code overrides
   after 8 consecutive blocks, which is the right backstop, not a defect. For
   headless and scheduled runs, where the shell dies five seconds after the
   final result, the next driver tick *is* the boundary: it reads the watch
   directory before it reads the roadmap.

The reframe that falls out: **"re-arm" should never be an action anyone
takes.** The SHA is re-derived per poll; the poller's liveness is re-derived
per boundary; the only explicit pairing left is (2), and it is pairing inside
a hook rather than inside a session's memory.

### 3.3 What Claude Code offers for event-driven waiting today

Whether the plugin can do better than polling depends on what the harness
exposes, so this was checked against the current docs and against the tool
schemas of the build this memo was written in (2026-08-23). The precise
state:

- **Within a live session, event-driven wake exists.** The `Monitor` tool
  streams a script's stdout lines as notifications; the docs state "Watch
  persists across turns and Claude interjects when events arrive"
  ([tools reference](https://code.claude.com/docs/en/tools-reference)). In
  this build it takes `persistent: true` ("runs until you call TaskStop or
  the session ends") and a `ws` source that opens a WebSocket and turns each
  frame into an event with "no shell, no polling: the server pushes." A
  subagent's completion notification re-invoking a session between turns —
  which is how this memo's own research passes reported back — is the same
  mechanism. This is exactly the primitive a driver's poller should be: the
  turn ends, the watch lives, a state transition re-invokes the session.
- **It does not survive the session.** "Background Bash and monitor tasks
  aren't [restored]" on `--resume` ([sessions](https://code.claude.com/docs/en/sessions));
  `-p` mode terminates the shell "about five seconds after Claude has returned
  its final result"; `Monitor` is unavailable on Bedrock, Vertex and Foundry.
  So the Monitor is the poller for the *interactive* case only, and every
  session boundary still needs the lease-based re-arm of §3.2.
- **Event-triggered *new* sessions exist; event-resumed sessions do not.**
  Routines accept three trigger kinds — "Scheduled", "API: trigger on demand
  by sending an HTTP POST to a per-routine endpoint with a bearer token", and
  "GitHub: run automatically in response to repository events such as pull
  requests or releases" ([routines](https://code.claude.com/docs/en/routines)).
  The GitHub events are `pull_request` ("opened, closed, assigned, labeled,
  synchronized, or otherwise updated") and `release` — **not** `check_run` or
  `workflow_run`. This build's `RemoteTrigger` tool exposes
  `create_webhook_trigger` ("attaches an event source to an existing routine,
  e.g. a GitHub event that fires it"). No hook event fires on an external
  GitHub event (the full list is session-lifecycle, tool, file/config, and
  `Notification`); channels "only arrive while the session is open".
- **The glue that makes CI completion a wake, today:** a final CI job that
  runs on `workflow_run: completed` and does `gh pr edit <n> --add-label
  ci:done` fires a routine on the PR `labeled` event; or the same job `POST`s
  the routine's `/fire` endpoint. Either starts a fresh cloud session whose
  first act is to read the watch directory — the boundary re-arm of §3.2,
  triggered by the event rather than by the clock. Labels work on the Free
  plan; the workflow edit is one job. This is not Cursor's "subscribe, end
  the turn, wake on the event" for the *same* session — that does not exist
  in Claude Code's public surface as of this date — but for a pipeline whose
  state is already in files it is functionally equivalent.

One first-party detail is worth recording because it shows how natural the
original error is. This build's `Monitor` tool description carries a sample
script for "emit each CI check as it lands, exit when the run completes",
gated on `jq -e 'all(.bucket!="pending")'` over `gh pr checks --json`. `all`
over an empty array is `true` — verified — so the harness's own example exits
"complete" on a head whose checks have not been created yet. Failure #1 is not
an idiosyncratic mistake; it is the predicate the tooling suggests. The
expected-set manifest (§5) is what makes it wrong by construction.

## 4. "Absence is not a pass" — it is already GitHub's doctrine

The coordinator's predicate inverted GitHub's own default. The combined-status
API is "pending if there are no statuses or a context is pending; success if
the latest status for all contexts is success" ([REST commit statuses](https://docs.github.com/en/rest/commits/statuses)).
The GraphQL vocabulary has explicit not-yet-known states — `StatusState.EXPECTED`
("Status is expected."), `MergeStateStatus.UNKNOWN` ("The state cannot currently
be determined."), `CheckConclusionState.STALE` — and branch protection blocks on
them: "Associated checks stay in a 'Pending' state and block merging … 'Waiting
for status to be reported'" ([troubleshooting required checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)).
The catch is that `EXPECTED` only *exists* when branch protection declares a
required check. On a Free-plan private repo nothing is declared, so GitHub never
materialises "expected but not reported"; a missing check is simply not in the
list, and anything that iterates the list and finds no red is satisfied. That is
the whole mechanism of failure #1, and it is why the expected set has to be
supplied locally (§5).

`gh` itself is *not* the hole, contrary to one pass's reading: the current
source returns `"no checks reported on the '%s' branch"` as an error (exit 1)
when the rollup is empty — fail-closed, if conflated with failure. The hole was
a hand-written predicate on top of it. Mergify's maintainer, asked to allow
"just require that no check matching `matrix*` fails", refused for the same
reason: "when a PR is created, there is no failure of tests with 'matrix' in
the name, so the PR would be merged without any test run at all … You need to
list all the test you want to be passing, that's the only safe thing to do"
(Mergify discussion #5082).

The general principle is Saltzer & Schroeder's fail-safe default: "A design or
implementation mistake in a mechanism that gives explicit permission tends to
fail by refusing permission, a safe situation … a mechanism that explicitly
excludes access tends to fail by allowing access, a failure which may go
unnoticed in normal use" ([1975](https://www.cs.virginia.edu/~evans/cs551/saltzer/)).
"No check is pending" is exclusion-based; "every expected check is present and
succeeded" is permission-based. The playbook should say the general rule, not
only the `--watch | tail` instance — and the gate should *enforce* it (§9, R2).

There is an adjacent GitHub rule the manifest must encode rather than fight: "A
job that is skipped will report its status as 'Success'. It will not prevent a
pull request from merging, even if it is a required check" ([conditions
docs](https://docs.github.com/actions/using-jobs/using-conditions-to-control-job-execution)),
and a gate job with `needs:` whose upstream fails is itself *skipped* — i.e.
green (actions/runner #2566, open). sweap's gate treats `SKIPPED` as green today
(`:265`). With an expected set that becomes per-entry policy: a check marked
required is green only on `SUCCESS`.

## 5. Discovering the expected set

No server-side source exists on this plan — no branch protection, no rulesets
("customers on GitHub Team and GitHub Enterprise plans"), no required workflows
(Enterprise only since 2023-08), and `gh pr checks --required` is therefore
always empty. The options, ranked by what the prior art does:

**Committed manifest, with two drift detectors (recommended).** bors and homu
read an explicit list from repo config — the only form Mergify's maintainer
calls safe — and Zuul makes the job list itself config-under-test, so a change
that breaks the job definitions is "reported by any applicable pipelines" as a
failure, never an empty pass ([Zuul config](https://zuul-ci.org/docs/zuul/4.0.0/reference/config.html)).
The manifest's known failure mode is the one bors users hit: "Waiting for PR
status … particularly problematic since required statuses change frequently"
(bors-ng #1140) — the 8→5 incident, from the bot's side. Two detectors close
it:

1. *Static:* parse `.github/workflows/*.yml` **on the base branch**, keep jobs
   that trigger on `pull_request`, expand `name:`/job-id and simple matrices,
   prefix reusable-workflow callees with `caller / ` (community #46752), and
   fail the gate with "expected-set out of date" when the derived names differ
   from the manifest minus entries marked `optional`/`external`. Dynamic names
   (`fromJSON` matrices) are undecidable statically — those jobs must be fronted
   by a fixed-name gate job with `if: always()` inspecting `needs.*.result`,
   which is what every vendor doc converges on anyway.
2. *Observed:* after each merge, read `commits/{sha}/check-runs?filter=latest`
   on the merged PR's head and diff the `(name, workflow)` set against the
   manifest; on drift, file a discovered item rather than auto-adopt. GitHub's
   own UI uses "the app that most recently reported the status" only as a
   default *suggestion* when adding a required check ([changelog 2021-12-01](https://github.blog/changelog/2021-12-01-ensure-required-status-checks-provided-by-the-intended-app/)),
   never as the live rule — mirror that.

Read the manifest from the base branch too, so the PR that weakens CI cannot
also rewrite what the gate expects of it (GitHub Blog on agent PRs: "Any change
that weakens CI is a blocker. Full stop." — and sweap's audit record should carry
the manifest diff, per the 2026-08-08 memo).

**Last-green-PR observed set (fallback).** Union of `filter=latest` check runs
over the last ~5 merged PRs' head SHAs (PR heads, not base tips — `push` runs
differ from `pull_request` runs). Fails closed on a fresh repo; a deliberate
removal is indistinguishable from a rename, so it blocks until re-seeded — the
correct direction. One-merge lag if an agent lands a CI-weakening PR.

**Not acceptable:** "any all-green subset" (the current gate — the *inverse*
stale-list hole, a removed check silently stops gating); a hardcoded list with
no detector; `SKIPPED` as green without per-entry opt-in.

Provenance matters less here than on a protected repo — there is no app-pinning
to lose — but the rollup exposes `workflowName`, and the manifest should record
`(workflow, job)` pairs so a same-named commit status from another integration
does not satisfy an entry (the forgeability point from the 2026-08-08 memo).

## 6. Two knobs: thinking is free, landing is contended

The board's corrected model is exactly the one every queue product encodes:
"worker concurrency and PR concurrency are DIFFERENT resources. Thinking is free
and parallelisable; landing is serial and contended. Widening the first without
throttling the second just relocates the queue."

**The constraint sets the pace.** GitHub's merge queue has a dedicated
CI-concurrency knob separate from queue depth — "Build concurrency: The maximum
number of `merge_group` webhooks to dispatch (between 1 and 100), throttling the
total amount of concurrent CI builds." Aviator's `max_parallel_builds`: "The bot
will pause queuing PRs once it hits the parallel limit." Mergify's
`max_parallel_checks` comes with sizing guidance — "slow CI or constrained
runners need a conservative setting, since reruns on failure are expensive"
([parallel checks](https://docs.mergify.com/merge-queue/parallel-checks/)).
Zuul's window is TCP: default 20, floor 3, "Each time a change successfully
merges, the window is increased by one. Each time a change fails, the window is
halved," because otherwise "Zuul can end up using increasingly large amounts of
test resources for little gain" ([Zuul gating](https://zuul-ci.org/docs/zuul/latest/gating.html)).
That is Goldratt's drum-buffer-rope: release work at the rate the constraint
consumes it.

**Why contention makes reds, not just delays.** Kingman's formula: wait ≈
ρ/(1−ρ) × variability — it explodes as utilization approaches 1, and e2e has
high service-time variance. Under load the *tests themselves* fail: 46.5% of
flaky tests in a 52-project study are resource-affected, and "CPU starvation is
the most significant and ubiquitous factor for increasing test failures"
(Silva et al., [arXiv 2310.12132](https://arxiv.org/abs/2310.12132)); at
Microsoft "86% of [flaky tests] are only flaky in the CI pipeline" (Lam et al.,
ISSTA 2019); flakes cluster — "75% of flaky tests across all projects belong to
a cluster" ([arXiv 2504.16777](https://arxiv.org/abs/2504.16777)), which is why
one contended run produces a *wave* of reds. Anthropic's swarm data is the
agent-shaped version: "Merged PR fraction fell as agents rose from 10 to 80"
([multiagent systems](https://www.anthropic.com/research/multiagent-systems)).
The measured 8m54s → 30 min at three concurrent e2e jobs is the same curve.

**Where the throttle sits: before `git push`.** Pushing is the resource
acquisition (it triggers CI). Aviator pauses *PR creation*; Zuul's window gates
*entry into test*. Holding the branch locally needs no target-repo config,
unlike draft-PR gating (`if: github.event.pull_request.draft == false` still
spins a runner and leaves a stale-check window — community #25722) or
`[skip ci]` (checks never report; history pollution). The cost is a rebase
before push, which the gate already demands. Throttling at *merge* time is too
late: the false reds and the diagnosis turns happen at PR-CI time.

**Defaults.** `workers:` keeps today's semantics (default 1, cap 4; Claude
Code's own guidance is "Start with 3-5 teammates … Diminishing returns"
([agent teams](https://code.claude.com/docs/en/agent-teams))). `ci.inflight:`
default **1** — the bors/Chromium-CQ value, the only one provably safe on an
unknown pool, and the one consumer A measured as *faster* than 3. A Zuul-style
`auto` (additive increase, halve on failure, floor 1) is a v2.

Note what this does to the playbook's own parallelism argument. The "Parallel
runs" section measured +9.4% at K=2 and demoted coordinator mode on that basis,
with "no contention to manage" as a premise (utilization ~0.2 on hosted
runners). On a self-hosted 3-runner pool that premise is false — the run proved
contention dominates — so the second knob is not ceremony; it is what makes
K≥2 produce *any* gain instead of a loss.

## 7. Mutation restore: never from `HEAD`

Every production mutation tool does one of three things, in order of
preference: mutate in memory and never touch files (PIT: "Pitest mutates
bytecode. It does not produce mutated source code"; Mull likewise); mutate a
*copy* (Stryker: "Stryker currently never mutates your code directly. Instead,
it makes a copy of it in a sandbox directory"; cargo-mutants: "Make a copy of
the source tree into a scratch directory"; mutmut's `mutants/`); or mutate in
place only as an explicit opt-in with a file-level backup that is restored in a
`finally` (universalmutator's `shutil.copy(src, backup)` … `finally:
shutil.copy(backup, src)`; Stryker `inPlace` "will keep a copy of the originals
in the temp directory … and it will place the originals back"). **None restores
with `git checkout --`.**

cargo-mutants names all three sweap hazards on one page: "cargo-mutants will
try to restore the code to its original state after testing each mutant, but
it's possible that it might fail to do so if it's interrupted" (FM.6's
"restore was swallowed by a command timeout"); "you shouldn't edit the code,
commit, or run your own tests while tests are running, because cargo-mutants
will be modifying the code at the same time" (FN.9's reviewer "ran mutation
experiments inside a live worktree"); and `--in-place` "is currently
incompatible with the `--jobs` option, because running multiple jobs requires
making multiple copies of the tree" ([mutants.rs/in-place](https://mutants.rs/in-place.html)).
mutmut: "You should **REALLY** have the file you mutate under source code
control and committed before you apply a mutant!"

Git's own documentation is unambiguous about the command the coordinator
prescribed: "`git checkout -- <file>` is a dangerous command. Any local changes
you made to that file are gone — Git just replaced that file with the last
staged or committed version … anything you lose that was never committed is
likely never to be seen again" ([Pro Git, Undoing Things](https://git-scm.com/book/en/v2/Git-Basics-Undoing-Things)).
Anthropic's own system-prompt rule already covers it: "run `git status` before
any command that could discard uncommitted work (git checkout/restore/reset/
clean …), and stash (with `-u` for untracked) or commit anything you find
first." It did not hold, because it is advisory — and Claude Code's own issue
tracker has the same incident five times over (#11237 "THESE COMMANDS DESTROY
UNCOMMITTED WORK!!!", #14293, #17190, #34327, #55024), each reporter asking for
a mechanical deny. The run's own second finding — the *reviewer* with Bash
mutating a live worktree — is the concurrency hazard, and it says the
mutation must happen in a tree with exactly one writer.

FN.4's worker arrived at the right protocol independently ("Copy the file to the
scratchpad BEFORE mutating … Restore FROM THE BACKUP, then `diff -q`"). The
evidence-backed version, ordered:

0. **Preflight: refuse on a dirty file.** `git status --porcelain -- <file>`
   empty, or commit a checkpoint first (`wip: pre-mutation`). Not `git stash`:
   the stash is a stack shared by every agent on the same `.git` (#14293 is a
   stash-pop ending in `reset --hard`).
1. **Record the baseline** as an explicit SHA (`BASE=$(git rev-parse HEAD)`) and
   a hash of the file. The restore target is `$BASE`, never the word `HEAD`.
2. **Prefer isolation:** `git worktree add --detach <scratch> $BASE`, mutate and
   test there, remove it. In-place only when paths matter.
3. **In-place fallback:** backup independent of git + `trap … EXIT` inside *one*
   script invocation (the Bash tool runs each call in a fresh shell, so a trap
   spread across calls never fires); or `git diff $BASE -- f > mut.patch` and
   restore with `git apply --check -R && git apply -R` (atomic: "fails the whole
   patch and does not touch the working tree when some of the hunks do not
   apply").
4. **Verify the restore mechanically** — `git diff --quiet $BASE -- f` and the
   hash — because a restore the agent *says* happened is a claim (Replit's
   agent reported rollback impossible when it was not), and typecheck+lint
   "were both GREEN on the mutated tree".
5. **Forbidden while any mutation is live:** `git checkout -- <path>`,
   `git checkout <ref> -- .`, `git restore <path>` without `--source=$BASE`,
   `git reset --hard`, `git clean -f`, `git stash`.

And the reason the discipline is worth the protocol: "developers using
mutation testing write more tests, and actively improve their test suites …
mutants are indeed coupled with real faults" (Petrović et al., [arXiv
2103.07189](https://arxiv.org/abs/2103.07189)); agent-written tests "mainly
serve as observational feedback channels, with value-revealing print
statements appearing much more often than assertion-based checks"
([arXiv 2602.07900](https://arxiv.org/abs/2602.07900)); and the cheapest
reward hack is to make the runner exit 0 — Anthropic observed models "calling
`sys.exit(0)` in Python to break out of a test harness with an exit code of 0"
([emergent misalignment](https://www.anthropic.com/research/emergent-misalignment-reward-hacking)).
Mutation is the cheapest detector of a vacuous test. It must not become the
cheapest way to lose work.

## 8. The spec-shape error, briefly

FM.9 is not a sweap gap the way the other five are, but it has a one-line
doctrine form worth adding to item authoring: state the invariant and point at
the committed idiom; never prescribe the expression. The prior art agrees
without dissent — Spec Kit: "Focus on the 'what' and 'why' of your project, not
the technical details"; Osmani: "an overbearing spec can actually confuse more
than help"; Claude Code best practices: "Provide the symptom, the likely
location, and what 'fixed' looks like"; Cognition's "conflicting decisions
carry bad results" is the mechanism — the coordinator decided the shape without
the implementer's context, and the implementer inherited the error. The board's
own phrasing is already the rule: "Prefer stating the **invariant** … and
pointing at the committed idiom, over prescribing the expression."

## 9. Recommendation, ranked, mapped onto sweap

### R1 — `sweap-merge`: the driver, as the only path the gate accepts (load-bearing)

A plugin-shipped script (`plugin/scripts/sweap-merge.sh <pr>`; leave bash past
~100 lines — Google's rule — but start there, with the test harness the hooks
already have). It owns *wait → verify conclusive → merge → cleanup → next* and
is the thing sessions run instead of writing a waiter. Invariants, each traced
to §3:

- **State in a file, not a process — with a lease.** `.claude/sweap-merge/<pr>.json`
  holds `{pr, expected_head, base_at_verify, state, attempts, appear_deadline,
  complete_deadline, last_seen, heartbeat_at, owner}`. Every invocation is
  idempotent: a wait killed by turn end, compaction, `-p` exit, SIGTERM or a
  network drop resumes from the file. `heartbeat_at` is stamped every poll;
  any reader that finds `waiting` with a heartbeat older than 2× the interval
  treats the poller as dead and says so ("#189 armed at T, poller dead, last
  known S") — liveness is re-derived, never assumed (§3.2).
- **The poller is a `Monitor`, not a Bash loop, in interactive sessions.**
  `sweap-merge.sh watch <pr>` emits one stdout line per state transition and
  exits on a terminal state; armed as `Monitor(persistent: true)` it survives
  turn ends and re-invokes the session on each transition (§3.3). The session
  ends its turn instead of spinning. Where `Monitor` is unavailable
  (Bedrock/Vertex/Foundry) or the run is headless, the bounded-call form
  below applies.
- **Invalidating actions re-arm in the same hook.** `PostToolUse` on
  `gh pr merge` (the existing `post-merge-cleanup` slot) stamps every other
  open watch `base_moved`; `PostToolUse` on `gh run rerun`, `gh run cancel`
  and `git push --force*` resets the matching watch's deadlines and records
  `invalidated: <reason>`. No session has to remember to do it.
- **Boundary re-arm.** `SessionStart` and `UserPromptSubmit` list
  lease-expired watches; a `Stop` hook blocks turn end while this session owns
  an armed, unexpired watch (the harness's 8-block override is the backstop);
  a headless or scheduled driver tick reads the watch directory before the
  roadmap. Optionally, CI's final job labels the PR and a routine fires on the
  `labeled` event, so the tick is event-driven rather than clocked (§3.3).
- **Bounded per call.** Each invocation polls for at most the Bash tool budget
  (≤10 min) with backoff+jitter and returns a structured terminal state —
  `green | pending | missing | failed | superseded | behind | timed_out` — and
  the next legal action. The session re-invokes (or backgrounds it; the name
  must not contain `git`, which is never auto-backgrounded). The appear-by and
  complete-by deadlines live in the file, so they survive re-invocation.
- **Level-triggered, SHA-pinned each poll.** Re-resolve `headRefOid` every
  iteration; if it moved, state → `superseded`, old-SHA results are ignored
  (they will read `CANCELLED`/`STALE`), and the appear-by timer restarts.
- **Conclusive = manifest satisfied** (§5): every expected `(workflow, job)`
  present on *this* SHA, `status == COMPLETED`, conclusion `SUCCESS` (or
  `SKIPPED` only where the entry is optional). Extra checks are logged, not
  failed.
- **Re-runs only on terminal runs, bounded.** Re-run a failed job only when its
  run is `completed`, never more than N per PR, and never when the same check
  is red on the base tip (Cursor's "already fails on the base branch" rule).
- **Then merge, then cleanup, then next** — `gh pr merge --squash` from inside
  the driver, the existing `post-merge-cleanup` hook fires as today, and the
  driver reports the next queued PR.

The mechanical link that makes it *the* path: the driver writes its verdict
(`green at <head> against <base> at <time>`) to the state file, and
`pre-merge-gate.sh` gains one check — deny unless a driver verdict exists for
exactly the PR's current `headRefOid`, fresher than the hook's own budget
allows. The gate keeps every current deny (belt), the driver becomes the only
way to satisfy it (suspenders), and a session that reinvents a waiter simply
cannot merge. That is invariant 10 of §3 at the right altitude.

### R2 — Expected-check manifest + drift detectors; gate strengthening

Add `checks.expected:` to the consumer config block — a list of
`workflow / job` entries with optional `optional: true` — seeded at adoption
by `scaffold.sh` from the last merged PR's check runs. Two detectors (§5):
static (workflows on the base branch) as a roadmap-lint-style CI lane, observed
(post-merge check runs) as a `post-merge-*` hook that files a discovered item
on drift. `pre-merge-gate.sh` requires the manifest satisfied — closing the
"any all-green subset" hole — and treats `SKIPPED` as green only on optional
entries. Until the manifest exists, the gate behaves as today (no regression
for repos that have not adopted).

### R3 — Doctrine lines in the playbook

Three sentences, each a general rule that currently exists only as an
incident: (a) *a check that has not been reported is not a passing check — the
predicate is "every expected check present and succeeded", never "nothing
pending"*; (b) *never act on a run that is not `completed`, and never re-run a
run for a head that no longer exists*; (c) *state the invariant, point at the
committed idiom, never prescribe the expression* (§8). Plus the waiting rules
the board already wrote — PID you own, SHA you pinned, expected set you
enumerated, one watcher per PR — and the pointer that they are documentation of
R1, not a substitute for it.

### R4 — Split `parallel:` into `workers:` and `ci.inflight:`

`workers:` inherits `parallel:`'s semantics and cap. `ci.inflight:` (default
1) caps branches that have been *pushed*; a finished worker enters
`ready-to-push` in the run file, rebases, and pushes only when a slot frees —
the board shows the waiting state so the stall is legible (the same
legibility rule the running-milestone card already enforces). `parallel:`
remains accepted as an alias for `workers:` with a deprecation note. Revise
the "Parallel runs" section's "no contention to manage" premise: true on
hosted runners, false on a self-hosted pool, and the second knob is the
condition under which K≥2 gains rather than loses.

### R5 — `mutate-verify`: a script plus a deny hook, and a playbook section

Ship the §7 protocol as `plugin/scripts/mutate-verify.sh <file> <patch-or-sed>
<test-cmd>`: preflight-dirty refusal, explicit `$BASE`, scratch worktree by
default, in-place with backup + `EXIT` trap as fallback, mechanical restore
verification, non-zero exit on any step. Add a `PreToolUse` Bash deny for the
§7 forbidden list whenever a mutation marker file exists (the hook "blocks the
tool even in `bypassPermissions` mode"), mirroring what the audit-agent guard
already does for absolute-path writes. Extend the reviewer agents' brief: a
reviewer with Bash never mutates the worktree it is reviewing — it uses the
script, which refuses a shared tree. The playbook gets its first
"Mutation verification" section, and it documents the script.

### Order

R2's manifest is a prerequisite for R1's conclusiveness predicate, so: R2 →
R1 → R3 (one PR, since R3 documents R1/R2) → R4 → R5. R5 is independent and can
land in parallel. Everything here is plugin-side; nothing needs a GitHub plan
feature the consumer does not have.

## 10. Residual limits — what this still cannot fix

- **Network drops and runner contention are environmental.** The driver makes
  them *legible* (a `timed_out` with the run's duration against
  `timeout-minutes`, which is the discriminator the coordinator "failed to
  check") and bounded; it does not make them go away. The `ci.inflight: 1`
  default removes the self-inflicted share.
- **The harness still kills processes, and the same-session event wake does
  not exist.** Within a live interactive session the `Monitor` poller survives
  turn ends; across a session boundary it does not, and Claude Code has no
  "end the turn, idle, be resumed by a CI event" for the same session (§3.3 —
  checked against the docs and this build's tool schemas on 2026-08-23). The
  lease plus boundary re-arm make a killed wait a *resume*, never a loss, but
  a wait killed mid-headless-run still costs the gap until the next driver
  tick — bounded by the schedule, or by the PR-label routine trigger where
  that glue is installed. That gap is the residual, and it is visible on the
  board rather than silent.
- **The manifest can be wrong in the safe direction.** A renamed job blocks
  every PR until the manifest is re-seeded — bors #1140's complaint. The static
  detector makes that a loud failure on the CI-refactor PR itself, which is
  the best available outcome.
- **Flakes under honest load remain flakes.** The driver's bounded re-run and
  the "red on base too" short-circuit limit the chase; the standing doctrine
  (quarantine-with-flag, never retry-until-green) still governs.
- **Mutation in a scratch worktree costs a second install/build** where the
  project's test command needs one; the in-place fallback exists for that, and
  it is the less safe path by construction.

## 11. Evidence strength, bluntly

- **First-party and current, but a moving target:** the Claude Code
  capabilities in §3.3 come from the live docs and from this build's own tool
  schemas (`Monitor`, `RemoteTrigger`, `CronCreate`) on 2026-08-23; the
  `all(.bucket!="pending")` example was executed against `[]` to confirm it.
  Not verified: whether a routine can resume a *local* session rather than
  start a cloud one; whether the cross-session messaging socket could be
  driven from a CI runner. Re-check before relying on any of it — this
  surface changes monthly.
- **Strong, convergent, primary:** the merge-driver invariants (§3) — every
  system fetched says the same things in its own docs; GitHub's own
  state vocabulary (§4, from live GraphQL introspection); the mutation-tool
  isolation mechanisms and git's own warnings (§7); the two-knob separation in
  GitHub/Aviator/Mergify/Zuul configuration (§6).
- **Strong, quantified, but from adjacent fields:** contention → flakiness
  (Silva et al., Lam et al.); queueing theory; Anthropic's swarm data. No
  source measures "flake rate versus N concurrent jobs on a fixed pool"
  directly — the chain is CPU starvation + Kingman + flake clustering, and the
  run's own 3.4× measurement is the local confirmation.
- **First-party incident, single run:** the six-failure ledger is one
  coordinator's honest accounting of one run. It is unusually good evidence
  because it is self-reported against interest, but it is n=1; the prior art
  is what says the pattern generalises.
- ***Unverified* items, not relied on:** the Uber EuroSys paper body (ACM
  403; quoted via abstract and The Morning Paper); OpenAI's harness-engineering
  post (403 direct; read via a proxy); GitHub merge-queue default group sizes;
  Codex/Cursor/Devin worker caps (snippets only); the GitHub API error text for
  re-running an in-progress run; the original 2025 wording of Anthropic's
  TDD-fail-first guidance (no longer on the live page); bors
  `prerun_timeout_sec`. One pass claimed `gh pr checks` exits 0 on zero checks
  (cli/cli #9452); the current source contradicts it and is what §4 states.
- **Attribution corrected:** "commit often so the agent can't lose your work"
  is *not* attributable to Willison, Hashimoto or Ronacher from their pages;
  Hashimoto's and Ronacher's actual quotes are used instead.
