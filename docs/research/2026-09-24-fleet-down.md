# A dead runner fleet stops the run (2026-09-24)

**What happened.** At 15:30 UTC GitHub retired runner version 2.335.1. Consumer A's
two self-hosted runners, whose image carried that version and cannot update
itself, connected, were refused ("deprecated and cannot receive messages"),
deregistered themselves and restarted, for five hours. The run in flight
(`wf_8e053136-694`, F13, 0.33.0) kept going: the merge driver reported PR
#407 `queued` for 99 minutes and then `timed_out`; the watcher returned that
word; the run filed F13.4 as needing a human and opened F13.5, then F13.6 —
one Opus implementer and one 99-minute watcher per item, against a fleet with
nobody in it. The watchers had seen `"total_count": 0` from the runners
endpoint 30 to 60 minutes before each timeout and kept ticking, because their
table had no row for it. The watchdog on the Mac healed each runner twice from
the same local image and then, correctly, stopped healing.

After the fleet came back (20:28 UTC, a hand `docker pull` + recreate), the
session's `sweap-merge watch 407` reported `timed_out` within nine seconds:
the driver's completion deadline is anchored on the CI run's creation time,
which never moves, and nothing re-arms a stored `timed_out`. Both orphaned
PRs stayed open.

**Method.** Three refuters in parallel (the GitHub API and the driver; the
run script, the relaunch path and the goal loop; the watchdog scripts), then
a hostile review of the diff. Claims and verdicts:

| Claim | Verdict | What decided it |
|---|---|---|
| Fleet-down = a queued job whose labels include `self-hosted` with no ONLINE runner carrying them | SURVIVES-WITH-CHANGE | `self-hosted` alone misses `runs-on: [e2e]` and runner groups; a registered-runner match alone misses a fleet that deregistered itself (`total_count: 0`, today). Built: a set targets the fleet when it names `self-hosted` OR a registered runner carries it; missing when no online runner does. Online-but-busy stays a slow queue: the e2e cap is 60 min and the window is 2× that, so one wedge cannot time a PR out alone. A refused runners endpoint (non-admin token) is `unknown`, never fleet-down. |
| `labels` are present on a queued job | SURVIVES | Live: run 36022056599's `e2e` job, `status: queued`, `labels: ["self-hosted","e2e"]`, `runner_name: ""`. `started_at` on a queued job equals `created_at` — not a start. |
| The label universe is "the newest run's jobs" | REFUTED | The newest run on main was audit-gate with one job; a fleet with the `e2e` carrier dead would pass. Built: the newest run of EACH workflow on the base branch, from the REST list (it carries `path`; `gh run list --json` does not). |
| Classify at the `timed_out` row | SURVIVES-WITH-CHANGE | The watchers already had the answer an hour earlier. Built: on the second consecutive `pending … queued` line the watcher runs `sweap-fleet --base <branch>`, twice 60 s apart; the `timed_out` row keeps the check as a fallback. |
| The driver's reason names `queued` when jobs are queued | SURVIVES-WITH-CHANGE | It names the RUN status of the first pending workflow: `queued`, `pending` or `requested` (the driver's own pending class). `missing` cannot come from a fleet outage: runs are created server-side with no runner alive. Built: the watcher keys on all three. |
| On relaunch the implementer resumes the open PR and the watcher merges it | REFUTED twice | (1) The implementer brief's steps 6–8 are unconditional: a re-review, a push and a `gh pr create` that exits 1 on an existing PR; no transcript shows an implementer resuming an open PR (every Resume result in four journals had `open_prs: []`). Built: the SCRIPT matches an open PR to the item (the Resume mapping or the branch shape, anchored at the start, dot-depth safe) and goes straight to the watcher; a merged PR that left the item not done was a blocked flip and is recorded as blocked. (2) The watcher would die on its first tick: `complete = run_started + window` with `run_started` = the run's creation, and a stored `timed_out` keeps its clocks. Demonstrated live at 20:39 UTC. Built: the window is anchored on the later of run start and arm time, and a stored `timed_out` is disarmed by the next deliberate tick — one fresh window per new watch, bounded by the caller. |
| A kickoff fleet check in `/milestone` | SURVIVES-WITH-CHANGE | It would not have caught today (the fleet died mid-run) and the relaunch loop never passes through `/milestone`. Built: the Resume stage asks `sweap-fleet` and returns `stopped` before any implementer; `/milestone` asks it too and prints the fix instead of the goal; both print a runner version retiring within seven days. |
| The goal's "clear the cause and relaunch" loops against a dead fleet | SURVIVES-WITH-CHANGE | Measured shapes: without the Resume gate a cycle is $4–11 and 2h20 (a resuming Opus implementer plus a 99-minute watcher), 160 turns ≈ 5–8 days; with the gate a cycle is one Sonnet Resume (~$0.60, 90 s) and the turn budget burns in hours as a false `turns-exhausted`. Built: the gate, and the three templates now say "verify it is gone (sweap-fleet prints ok; the default branch is green) and only then relaunch; if you cannot verify that, stop and say which cause". |
| The watchdog: pull before a heal | SURVIVES-WITH-CHANGE | A pull writes ~3.7 GB; the HOST was at 99% with 5.8 GiB free, and when the Mac cannot back Docker's sparse disk image the VM's filesystem goes read-only and takes every container down. Built: the pull is gated on 8 GiB of host free space. It would have fixed today's outage at the first heal (15:35 UTC; the floating tag had carried 2.337.0 since 27 August). |
| A periodic pull is needed to stay ahead of the next retirement | SURVIVES, better than proposed | GitHub publishes the date: `GET .../actions/runners/deprecations/<v>` → `runtime_deprecates_at` (2.335.1: 15:30:55Z today; 2.336.0: 2026-11-05). Built: a daily check in the watchdog; within seven days it pulls once and recreates one idle runner per tick; a busy refusal in the recreate script's single-runner path (`FORCE=1` overrides) narrows the job-loss window to the second between its busy read and the delete. `sweap-fleet` reports the same dates. |
| Other watchdog defects seen today | three built | The exhausted branch alerted on every tick (~90 notifications); the cause was never named (the ALERT said `df -h`); `.heal_at` was never cleared on recovery, so a new fault within the hour waited out the cooldown. |
| A watcher ticking PR #1 | side defect, built | Two watchers read the brief's `<n>` placeholder literally. The dispatch text now carries the PR number in the command. |

**What was built (0.34.0).** `sweap-fleet` (tool, bin, tests); the driver's
anchor and re-arm (tests); run.js: Resume fleet gate, open-PR skip,
`fleet-down` stop without a needs-human entry, the literal tick command;
the watcher's two fleet rows; `/milestone`'s pre-flight and the relaunch
sentence in the three templates; the playbook and README rows. On the Mac:
`recreate-runner.sh` pulls (disk-gated) and refuses a busy runner;
`watchdog.sh` names the cause, alerts once, resets the cooldown, and checks
retirement dates daily with a rolling recreate. Neither script is under
version control; `.bak-2026-09-24` copies sit beside them.

**Not built.** A signal for an online-but-wedged runner (needs a fourth call
and the wedged job's `started_at`); the label universe for PR-only workflows
on a base-branch check (the watcher passes the PR's branch, which has them);
a cure for the host disk at 99%, which is the standing hazard behind all of
this and is the human's.

**Deciders.** Whether a runner refused for its version shows `offline` or is
absent from the list (today: absent). Whether the goal evaluator reads "stop
and say which cause" as met. Both wait for the next incident.

**Consumer follow-ups (consumer A).** Free disk on the Mac. Restart the run
session on 0.34.0: the relaunch resumes #407 and #408 through the watcher
(#408 carries a red review, so its fixer runs). The `general` label is only
proven online through the `checks` set on a base-branch check.
