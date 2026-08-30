# sweap-merge — the merge driver (design)

**Status:** v2, 2026-08-25 — revised after a five-reviewer hostile pass (4
approve-with-changes, 1 reject on §8 soundness; every reviewer independently
found the same three defects, all fixed here as E1–E3). Supersedes R1 of
`docs/research/2026-08-22-merge-driver.md`. Research:
`docs/research/2026-08-25-sweap-merge-research.md`. Review record: session
task `wcprhbym0`.

## 1. Problem

Sweap has a merge *gate* — `pre-merge-gate.sh` denies a `gh pr merge` whose PR
is not verifiably green, fresh against base, lane-consistent, and not
self-modifying CI — but no merge *driver*. Every run re-derives the waiting
loop inside the model: poll `gh pr checks`, decide "looks green", merge. The
2026-08-21/22 consumer A run lost six failures to that re-derivation. The gate
cannot fix this: it fires at the last instant and has 25 s.

## 2. Decisions

| # | Decision | Fixed by |
|---|---|---|
| D1 | **Conclusiveness is computed from the base branch's workflow files and verified at the workflow-run level per head SHA.** No manifest (killed 2026-08-24); no "whatever reported". Empty or unparseable set ⇒ `undecidable`, never green. **Every** `pull_request` run on the head must succeed, not only the expected ones (a head that adds a failing workflow is not green). | Zuul's config-derived set with zero-job refusal; GitHub: `if:`-skipped jobs report success, path-skipped workflows create no run; reviewer reproduction on consumer A #212 (workflow `success` while `e2e: skipped`). |
| D2 | **The durable object is a state file, never a process.** `tick` is bounded (≤100 s), re-entrant, idempotent, checkpoints every iteration under a fenced lease. `watch` loops ticks; interactive sessions run it with `Bash(run_in_background)`; Monitor is optional ergonomics. No detached process. | Temporal polling taxonomy; Kleppmann fencing; SRE "claim first"; Claude Code docs: Monitor not restored on resume, stopped by `/bg`, absent under `-p`/Bedrock; Bash default timeout 120 s. |
| D3 | **The driver runs the gate.** Before merging, the driver pipes a synthetic PreToolUse payload for `gh pr merge <n> --squash` through `pre-merge-gate.sh`; any deny ⇒ `failed: gate: <reason>`, no merge. The driver never has a path around the gate's non-greenness denies (self-modifying CI, audit `--files`, 100-file truncation, lane re-derivation, `--admin`). The witness requirement in the gate itself is **0.14.0**, after ≥3 real driver merges; there is no adoption lane. | 5/5 reviewers: an internal merge "invisible to PreToolUse by design" skipped every non-greenness deny; the adoption lane was agent-writable and off forever in worktrees. |
| D4 | **The merge is at-most-once with read-only reconcile, pinned to the head.** `gh pr merge <n> --squash --match-head-commit <head>`; state `merging` before, `merged` after; re-entry in `merging` reconciles from `gh pr view --json state,mergeCommit,headRefOid` and **never issues a merge** from a hand-edited `merging` file. | `gh pr merge` is GraphQL (`expectedHeadOid`), so REST 405/409/422 do not apply — classify by outcome, not status code. |
| D5 | **v1 ships none of the four "maybe" items.** No auto-rerun (classified `failed` only; `gh run rerun --failed <id>` by hand, documented once); no `ci.inflight`; no label routine; no Stop hook. | Every production queue ships without auto-retry; routines are fresh ungated clones; Stop hook is blind where `background_tasks` is absent. |

## 3. Components

```
plugin/hooks/sweap-merge.sh          the driver (bash 3.2-safe, jq required, no yq)
plugin/hooks/sweap-merge.test.sh     offline tests (stub gh, fixture repos; test.sh globs plugin/hooks)
plugin/hooks/pre-merge-gate.sh       gains --verify mode? NO: unchanged; the driver feeds it stdin
plugin/hooks/scaffold.sh             gitignore rule .claude/sweap-merge/
plugin/playbook/agentic-loop-playbook.md   merge section: "prefer sweap-merge watch"
<primary>/.claude/sweap-merge/<pr>.json     state; <pr>.lock lease dir
```

`<primary>` = `$(dirname "$(git rev-parse --git-common-dir)")` (as
`post-merge-redcheck.sh`), so workers in `.claude/worktrees/<x>` and the gate's
`cd "$cwd"` resolve the same directory (E3).

Argv contract: `sweap-merge.sh <verb> <pr> [--budget <sec>]`; `<pr>` must
match `^[0-9]+$`; no `--repo/-R/--admin`; `GH_REPO` is unset by the script;
the argv never contains the token `git` and never starts with `sleep` (E11).

## 4. State file

```json
{
  "pr": 123, "state": "pending",
  "head": "<sha>", "base": "main", "base_sha": "<sha>",
  "expected": [".github/workflows/ci.yml", ".github/workflows/audit-gate.yml", ".github/workflows/claude-review.yml"],
  "expected_from": "<base_sha>",
  "observed": { ".github/workflows/ci.yml": {"run_id": 1, "attempt": 1, "status": "completed", "conclusion": "success", "created_at": 0} },
  "appear_deadline": 0, "complete_deadline": 0,
  "lease": { "owner": "<session>:<pid>", "epoch": 3, "heartbeat_at": 0 },
  "verdict": null, "post_merge_done": false,
  "history": [ {"at": 0, "from": "missing", "to": "pending", "why": "..."} ]
}
```

All times are **epoch seconds** (bash 3.2 has no ISO parser). States:
`missing → pending → green → merging → merged`; side exits `failed`,
`superseded` (head moved), `behind` (base moved, `behind_by > 0`),
`undecidable`, `timed_out`, `attended` (a run needs human approval),
`held-by:<owner>`. Every transition appends to `history`. Expiry of any clock
is a failure, never a pass. `verdict` is written only at `green`:
`{"head","base_sha","epoch","at","expected"}`.

Writes are fenced (E9): a tick holds the lease dir `<pr>.lock` (created with
`mkdir`, owner + epoch + pid inside); state is written to `<pr>.json.v<seq+1>`
with `ln` (fails if a newer version exists) then `mv` over `<pr>.json`. Stale
takeover runs under a mkdir-atomic `<pr>.lock.takeover` mutex: re-read the
lock and require exactly the owner/epoch judged stale, `mv` it aside, verify
again from the renamed dir, write the new `info` into it, and `mv` it back
onto the lock path (a crashed takeover is recovered from the renamed dir);
`epoch` = max(state epoch, any `.lock.stale.*` epoch) + 1, so it never regresses.
Stale = `heartbeat_at` older than 2 × (sleep cap + call budget) **or** owner
pid on this host not alive (`kill -0`). A lock dir with no `info` yet is a
claimant between its `mkdir` and its first write: it is **live** unless the
dir itself is older than the stale window (two ticks launched in the same
instant yield exactly one `held-by`). The heartbeat is renewed before every
`gh` call and the renew is fenced: a holder whose lock now carries another
owner/epoch never writes its own back (`failed: lease lost to <owner>`), so
a takeover is final and epochs never regress. A `<pr>.json.v<N+1>` left by
a writer killed between `ln` and `mv` is named in the failure reason and
swept once older than the stale window.

## 5. The expected set E(base)

1. `GET /repos/{o}/{r}/actions/workflows` → keep `state == active`; a
   base-branch workflow file whose workflow is `disabled_*` ⇒ `undecidable`.
2. `GET contents/.github/workflows?ref=<base_sha>`; for each `.yml`/`.yaml`,
   one bash line-reader (E10): membership = a `pull_request:` key (or list
   item) directly under top-level `on:`. `pull_request_target` ⇒
   `undecidable` (it is excluded from the `event == pull_request` runs the
   driver evaluates — E6). `branches-ignore`, `paths`, `paths-ignore`, globs
   in `branches`, or a flow-style/scalar `on:` the reader cannot classify ⇒
   `undecidable` with the file named. `branches:` present and not containing
   `<base>` literally ⇒ excluded. A `types:` list that lacks `opened` or
   `synchronize` ⇒ `undecidable` (the workflow would never have a run on a
   fresh head and would sit at `missing` forever).
3. E empty ⇒ `undecidable` — including a base with no `.github/workflows`
   directory at all (a 404 on the listing is E empty, not an API error to
   retry). E is persisted with `expected_from`; recomputed when `base_sha`
   moves. No history diffing in v1.

The template's gate workflows (`ci.yml`, `audit-gate.yml`, `claude-review.yml`)
all classify as members with this reader; the reader's fixtures are the two
consumers' actual workflow files.

## 6. Conclusive for head H

`GET /actions/runs?head_sha=H&per_page=100` (paginate; `total_count >
returned` after pagination ⇒ `undecidable`). Keep runs with `event ==
pull_request` whose `pull_requests[]`, when non-empty, contains `<pr>`. Per
`path`, newest by `created_at` desc then `run_attempt` desc.

| observation | state |
|---|---|
| a path ∈ E with no run, `now < appear_deadline` | `missing` |
| a path ∈ E with no run, after `appear_deadline` | `failed: missing <path>` |
| run `status ∈ {queued, in_progress}`, `now < complete_deadline` | `pending` |
| run `status ∈ {queued, in_progress}`, after `complete_deadline` | `timed_out` |
| run `status ∈ {waiting, action_required, requested, pending}`, or `completed` with `conclusion == action_required` | `attended: <path> needs approval` |
| `status == completed`, `conclusion == success` | contributes to `green` |
| any run on H with `conclusion == startup_failure` — **any event**, not only `pull_request` (may sit on a synthetic `BuildFailed` workflow) | `failed` immediately |
| `conclusion ∈ {failure, cancelled, timed_out, skipped, neutral, stale}` | `failed: <path> <conclusion>` |
| any other status/conclusion pair | `failed: unknown <status>/<conclusion>` |
| a `pull_request` run on H for a path ∉ E, `queued`/`in_progress` | `pending: <path> (not on base)` — it is waited for like a member, then `timed_out` by the same `complete_deadline` |
| a `pull_request` run on H for a path ∉ E, completed | must be `success` (D1); otherwise `failed: <path> (not on base)` |
| a path ∈ E absent from H's `.github/workflows` | `failed: <path> removed on head` |

Two rows deliberately differ from the v2 table (review of PR #31): `completed`
+ `action_required` is `attended`, not `failed` — GitHub reports it for a
first-time contributor's run awaiting approval, which a human can still
release; and a non-member run still in flight is `pending`, not `failed` —
failing a head for a workflow that has not finished would be a verdict on
nothing. Both stop the driver from merging; neither can reach `green`.

`green` requires every row above to be `success` for E ∪ {runs on H} and
`compare/<base>...<H> --jq .behind_by` = 0 (also returns `.base_commit.sha`
for `base_sha`). Check-runs (`commits/H/check-runs`) are **diagnostic only**
(`filter=latest` dedupes per suite, not per name); check-suites are never
consulted (the `claude` app leaves a permanently queued suite).

Deadlines (E8) are anchored to GitHub time, not poller liveness:
`appear_deadline` = max(head commit's `committedDate`, arm time) + 5 min.
`committedDate` (from `gh pr view --json commits`, last commit) is the
*commit* time, not the push: a commit tested locally for an hour and pushed
just before `watch` starts has no run for a few seconds, and that is
`missing`, not `failed missing <path>` — so the anchor is never earlier than
the moment the driver armed. `complete_deadline` = newest expected run's
`run_started_at` (else arm time) + max(40 min, 2 × longest `timeout-minutes`
in E's files).

## 7. `tick`

`sweap-merge.sh tick <pr> [--budget <sec>]`, default budget 100 s (under
the 120 s Bash default; a longer call is auto-backgrounded, which the
lease tolerates). Every `gh` call goes through `bounded_run` (≤20 s).

1. Resolve `<primary>`; claim or renew the lease (§4). Live holder ⇒ exit
   `held-by:<owner>` immediately.
2. Loop until budget: re-resolve `headRefOid`, `baseRefName`, `base_sha`.
   Head moved ⇒ `superseded` (re-arm on the new head with fresh deadlines).
   Base moved ⇒ recompute E; `behind_by > 0` ⇒ `behind`. Evaluate §6. Write
   the file (fenced) with `heartbeat_at` and per-path observations. Sleep
   30 s ± U(0, 15); backoff only on API errors.
3. On `green`: write `verdict`; **run the gate** (D3): pipe
   `{"tool_name":"Bash","tool_input":{"command":"gh pr merge <pr> --squash"},"cwd":"<primary>"}`
   to `pre-merge-gate.sh` **resolved from the driver's own directory**
   (`dirname` of the script's real path, symlinks followed) with cwd
   `<primary>`. Never from `CLAUDE_PLUGIN_ROOT`: that variable can be set
   inline on the Bash call that launches the driver, and such a call carries
   no `gh pr merge` for the harness gate to see. The gate's stdout must be
   empty (the only allow) or parse entirely to decision objects; a `deny` ⇒
   `failed: gate: <reason>`, anything unparseable ⇒ `failed: gate output
   unparseable` (fail closed). Before the gate runs, the driver scrubs the
   knobs the harness never lets the model set for a hook (`GH_REPO`,
   `SWEAP_MAIN_REF`, `SWEAP_PUSH_GATE`, `SWEAP_BASE_BRANCH`,
   `MERGE_GATE_GH_TIMEOUT`, `MERGE_GATE_TOTAL_BUDGET`,
   `SWEAP_AUDITCHECK_TIMEOUT`) and its own `SWEAP_MERGE_*` test seams unless
   `the `.sweap-merge-test-seams` sentinel next to the driver`. Then write `merging` (with `merge_attempts`
   += 1); run `gh pr merge <pr> --squash --match-head-commit <head>`; on exit
   0 write `merged`; else reconcile (D4): `gh pr view --json
   state,mergeCommit,headRefOid` → merged ⇒ `merged`; open and head moved ⇒
   `superseded` (`merge_attempts` reset); open and same head ⇒ `pending`
   (re-evaluate) **once** — a second refusal on the same head (`merge_attempts
   ≥ 2`) ⇒ `failed: merge <stderr> after N attempts` (D5: a refusal that
   re-evaluation cannot change is a finding, not a loop); other ⇒
   `failed: merge <stderr>`.
4. After `merged`, unless `post_merge_done`: run the three post-merge hooks
   with a synthetic PostToolUse payload (`tool_input.command` =
   `gh pr merge <pr> --squash`, `tool_response` = the merge output, `cwd` =
   **the directory the driver was launched from**, so
   `post-merge-cleanup.sh`'s self-skip protects the session's live worktree;
   every hook derives `<primary>` itself) in order `post-merge-cleanup.sh`,
   `post-merge-redcheck.sh`, `post-merge-auditcheck.sh`, each `|| true` but
   never silent: each hook's stderr is forwarded prefixed `[<hook>]`, an exit
   2 (redcheck's "RED MAIN", auditcheck's "AUDIT DEBT") records its banner in
   `post_merge_alerts[]` and appends ` | <hook>: <banner>` to the terminal
   `merged` reason (still one line), cleanup's `additionalContext` is forwarded
   likewise. Then set `post_merge_done` (E2). `hooks.json` is unchanged — a
   hook `if` holds one rule and none of the three would match a `sweap-merge`
   command.

Threat model. The gate's verdict must not come from an environment the
session shaped, so the driver pins what a Bash call can otherwise set inline.
Two channels reach the driver before any in-script scrub can (round-3
findings): **F1** — bash sources `$BASH_ENV` before the script body, so a
file that redefines `command` poisons tool resolution (`command -v gh/jq`)
and yielded a one-prefix red merge; **F2** — `GIT_DIR=/forged/.git` (and
`GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_CONFIG_GLOBAL`, `GIT_CEILING_DIRECTORIES`,
…) moves `<primary>` — the state file, the lease and the gate's cwd — into
another checkout, and the state-split check is blind to a *consistently*
forged primary. Two belts. **Belt A (driver, first line):** unless
`SM_REEXEC=1`, the driver re-execs itself as `/usr/bin/env -i SM_REEXEC=1
PATH=<pinned> [HOME USER LANG TMPDIR GH_TOKEN GITHUB_TOKEN CLAUDE_SESSION_ID
when set] /bin/bash -p <self> "$@"` — `env -i` drops every caller variable
(all of `GIT_*`, `BASH_ENV`, `CDPATH`, …), `bash -p` does not process
`BASH_ENV`/`ENV`, imports no functions and ignores `SHELLOPTS`/`BASHOPTS`/
`CDPATH`/`GLOBIGNORE`; the `SWEAP_MERGE_*` seams (and the hook knobs they
name) cross only when the sentinel sits next to the driver, computed with
parameter expansion and `[ -f ]` alone. Sourcing as a library never
re-execs. `sm_resolve_primary` additionally requires `<primary>/.git` to exist
and `git -C <primary> rev-parse --show-toplevel` to name `<primary>` itself.
**Belt B (gate, PreToolUse on every Bash call):** a command that names
`sweap-merge.sh` and carries `BASH_ENV=`, `ENV=`, `SHELLOPTS=`, `BASHOPTS=`,
`PATH=`, `CDPATH=`, `HOME=`, `GIT_DIR=`, `GIT_WORK_TREE=`, `GIT_CONFIG_GLOBAL=`,
`LD_PRELOAD=`, `DYLD_INSERT_LIBRARIES=`, any `SWEAP_MERGE_*=`, or an `env `
wrapper is denied (`merge-driver: refusing to launch sweap-merge.sh with an
environment override (<var>)`); textual and greedy, so a mention of the
driver next to such a token (an `echo`, `grep -n PATH= …/sweap-merge.sh`) is
over-denied — rephrase, never bypass. **Exact residual of belt A:** the FIRST
process has already sourced `$BASH_ENV` when the re-exec line runs, so a
file that shadows `exec`, `[`, `case`, `set`, or the `env` it execs defeats
belt A; that is the interpreter-takeover class, outside the honest-slip
model, and belt B is what stands in front of it (its own residual is the
token-hiding class of lib-merge-parse.sh: `eval "$(printf …)"`, `bash -c`).
The WHOLE driver runs under a pinned PATH
(`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, then `~/.local/share/mise/shims`
as a last resort) exported at startup, before its own directory is even
resolved; `gh`, `jq`, `git` and `env` are resolved ONCE under that PATH to
absolute paths and invoked as such (a caller-PATH `jq` cannot rewrite the run
evaluation or the gate's deny, a caller-PATH `env` cannot ignore `-i`, a
caller-PATH `git` cannot forge `<primary>`) — any of the four missing ⇒
`failed <tool> ... not found under pinned PATH`, before any call; `CDPATH`,
`BASH_ENV`, `GH_HOST`, `GH_CONFIG_DIR`, `GH_REPO` and the gate's own knobs are
unset at startup and every `cd` the driver performs is `CDPATH='' cd -P --`;
the gate and the post-merge hooks run under the absolute `env -i` with
`PATH=<resolved gh dir>:<pinned>` and only `HOME USER LANG TMPDIR GH_TOKEN
GITHUB_TOKEN CLAUDE_SESSION_ID` passed through when set. The `SWEAP_MERGE_*`
test seams (stub gh, clocks, budgets, extra hook env) are honoured only when a
sentinel file `.sweap-merge-test-seams` exists next to the driver's real path
— the suite creates it in its fixture copies of the hooks dir; the plugin dir
never carries it (asserted by the suite), and no env prefix can create it. The
state file and the lease record the `<primary>` they were written under; a
tick that derives a different one for the same PR refuses to run (`failed
state split`), so the durable object is never split across checkouts.
Residual (recorded, not prevented): an attacker who can write into the plugin
directory (the sentinel, or a driver *copied* next to a stub gate — that copy
runs the stub) or replace a pinned binary itself (`/opt/homebrew/bin/gh`, or,
through `HOME`, a mise shim on a host with no system gh). Both are outside the
honest-slip model: the harness gate does not see such a call either, and the
allowlist entry (§8) names the plugin's own script path, which a copied driver
is not.
5. Print exactly one terminal word plus a one-line reason; exit 0 on
   `merged`, 1 otherwise (so `run_in_background` reports the state).

`watch <pr>` = loop of ticks, one stdout line per transition, exits on a
terminal state. Sessions run `sweap-merge.sh watch <pr>` with
`Bash(run_in_background: true)` (E-cuts: survives `/bg`, works under `-p`);
Monitor is allowed but never required. `status [<pr>]` prints the files and
flags dead pollers.

## 8. Gate coupling

**0.13.0 (this build):** `pre-merge-gate.sh` gains exactly one rule, the
launch-hygiene belt B of the threat model (§7): a Bash call that names
`sweap-merge.sh` together with an environment override (`BASH_ENV=`,
`PATH=`, `GIT_DIR=`, `SWEAP_MERGE_*=`, an `env ` wrapper, …) is denied before
any parse; a plain `bash "${CLAUDE_PLUGIN_ROOT}/hooks/sweap-merge.sh" watch
<n>` is untouched. The merge and push branches are unchanged. The driver is
the recommended path; a session-issued `gh pr merge` still meets the same gate.
**Reachability (0.13.1, measured).** `${CLAUDE_PLUGIN_ROOT}` is exported for
HOOK execution only: in a model-issued Bash tool call it is UNSET (verified —
`echo "[${CLAUDE_PLUGIN_ROOT:-UNSET}]"` prints `UNSET`), so the launch line
above expanded to `bash /hooks/sweap-merge.sh` and could not run. Consumer A's first
run with 0.13.0 installed mentions `sweap-merge` zero times across the run file
and a 1030-line board, and never created a state dir. The fix is the plugin's
own `bin/` directory:

- **Measured mechanism.** Claude Code adds `<plugin-root>/bin` to the Bash
  tool's session PATH for every ENABLED plugin, unconditionally — the directory
  need not exist on disk (verified on this machine: `echo $PATH` in a
  model-issued Bash call contains the bin path of two enabled plugins that have
  no `bin/` at all). Documented at
  https://code.claude.com/docs/en/plugins-reference.md ("bin/ Directory"):
  "Executables added to the Bash tool's `PATH` and invokable as bare commands
  while the plugin is enabled."
- `plugin/bin/` ships four wrappers — `sweap-merge`, `sweap-roadmap-lint`,
  `sweap-stranded`, `sweap-note` — each of which resolves the plugin root from
  its OWN real path (symlinks followed by hand; macOS `readlink` has no `-f`)
  and execs the real script under `hooks/` (or `tools/sweap-note.mjs`). They
  never read `${CLAUDE_PLUGIN_ROOT}`, which is the whole point. The driver's
  `SM_HOOKS_DIR` therefore still resolves to `plugin/hooks/` and it finds
  `pre-merge-gate.sh` and the post-merge hooks beside it (verified end to end
  from a consumer checkout with only `plugin/bin` prepended to PATH).
- Consumers allowlist **`Bash(sweap-merge:*)`** in project `settings.json`
  (plus `Bash(sweap-roadmap-lint:*)`, `Bash(sweap-stranded:*)`,
  `Bash(sweap-note:*)` for the rest). Per the permissions reference, "The `:*`
  suffix is an equivalent way to write a trailing wildcard, so `Bash(ls:*)`
  matches the same commands as `Bash(ls *)`", and "A `*` at the end, with a
  space before it, also matches the bare command" — so the rule covers
  `sweap-merge watch 12` and bare `sweap-merge`, and the implied space stops it
  matching an unrelated `sweap-merge…` program. A prefix pattern against the
  script path is not writable — it contains the commit sha. Consumer A allowed only
  `Bash(gh pr merge:*)` (E11), so the raw merge was the frictionless path and
  the driver the one that prompts: a preference is not a mechanism.
- `templates/justfile` keeps `merge PR` / `merge-status PR=""` as terminal
  conveniences, reimplemented as thin `sweap-merge watch {{PR}}` /
  `sweap-merge status {{PR}}` calls that fail with an install instruction when
  the command is not on PATH. They are no longer the primary surface.

*Rejected: a plugin-root pointer file.* An earlier pass had `scaffold.sh` write
`$CLAUDE_PLUGIN_ROOT` to `<proj>/.claude/sweap-plugin-root` for `just merge` to
read back. `bin/` is strictly better: no per-session write into the consumer
repo, no gitignore rule, no `just` dependency, and the allowlistable string is
the command itself rather than a `just` recipe name.

**Why not vendored.** `audit-gate.sh` is copied into `.github/scripts/` because
CI must run it without cross-repo access. The driver may NOT be: it resolves
`pre-merge-gate.sh` and the post-merge hooks from `SM_HOOKS_DIR` — its own
directory — so it must run from the plugin dir beside its siblings. A vendored
copy would find neither, and its re-exec belt (`env -i` + `bash -p`) plus the
gate's belt B both assume the plugin layout. `bin/` resolves the tension: it
gives the driver a stable, allowlistable NAME without moving the script out of
the plugin dir — the wrapper hands `hooks/sweap-merge.sh` its own real path, so
every sibling lookup still lands.

**0.14.0 (after ≥3 real driver merges on consumer A):** the gate additionally
denies a session-issued `gh pr merge <n>` unless `<primary>/.claude/sweap-merge/<n>.json`
has `verdict.head == headRefOid`, `verdict.base_sha ==` the compare call's
`.base_commit.sha`, `verdict.at` within 30 min, `state ∈ {green, merging}`.
No adoption lane (E4).

## 9. Playbook (0.13.1)

The merge bullet reads: "**The merge path is `sweap-merge watch <n>`** — it
waits, verifies, runs the gate, merges, and runs the post-merge hooks, and it
ENDS THE TURN while it waits, so the terminal word is the result. A `failed`
result is a finding, not a retry; `gh run rerun --failed <run-id>` once, by
hand, with the reason in the PR." No fallback spelling is needed: the command
is on PATH wherever the plugin is enabled, and where it is not, nothing in the
plugin runs anyway. The waiting-discipline rules stay as documentation of what
the driver does.

Three other model-issued launch lines were broken by the same
`${CLAUDE_PLUGIN_ROOT}` expansion and are fixed the same way: the discovered
note (`sweap-note discovered …`, playbook), the stranded-branch scan
(`sweap-stranded`, playbook), the pre-dispatch spec gate
(`sweap-roadmap-lint <file>`, `/milestone`) and the idea writer (`sweap-note
idea …`, `/idea`). `${CLAUDE_PLUGIN_ROOT}` is left alone in `hooks.json` and in
`/agentic-loop-init`'s scaffold invocation — those are hook contexts, where it
is set and works.

**One bullet is not a mechanism (0.13.0's second failure).** The 0.13.0 text
was a single "preferred" bullet competing with a dozen established
`gh pr merge` idioms elsewhere in the same file. 0.13.1 routes every
*instructional* merge site through `sweap-merge watch <n>` — the per-feature loop's
step 5, the end-of-run-hygiene cleanup sequence's step 1, the
pre-authorized-merge bullet, the mechanisms table, and `/milestone`'s dispatch
section — while every *descriptive* site keeps naming `gh pr merge`, because
those describe what the gate hook fires on, what it denies, and what a human
does from their own shell. Renaming a trigger would break the description of
the control.

## 10. Tests (offline, stub `gh`; fixtures from the public runs reviewers found)

- E: each `on:` shape in consumer A/B workflows; `paths` ⇒ undecidable;
  `pull_request_target` ⇒ undecidable; disabled ⇒ undecidable; empty ⇒
  undecidable; base move recomputes; removed-on-head ⇒ failed.
- §6 table, every row, incl. reopen duplicates (`created_at` order),
  `run_attempt` order, pagination overflow ⇒ undecidable, `pull_requests[]`
  filter, extra failing run on H ⇒ failed, `startup_failure` on synthetic
  workflow ⇒ failed, `action_required` ⇒ attended.
- Lease: double launch ⇒ `held-by` (also two launches in the same instant,
  ×10); stale takeover increments epoch; stale holder's fenced write fails;
  a taken-over holder's renew is refused; dead-pid takeover; a leftover
  version file is named, then swept.
- Deadlines survive re-invocation; anchored to GitHub time; expiry ⇒ failure;
  an hours-old `committedDate` with no runs yet ⇒ `missing`, not `failed`.
- Gate integration: a gate deny ⇒ no merge call (assert the stub never sees
  `gh pr merge`); gate allow ⇒ merge with `--match-head-commit`; plain-text
  or junk-before-JSON gate output ⇒ failed (fail closed); `CLAUDE_PLUGIN_ROOT`
  pointing at a stub gate is ignored (the REAL gate next to the driver
  denies); scrubbed knobs never reach the gate's env; `SWEAP_MERGE_*` seams
  are inert without the sentinel file.
- Merge outcomes: success ⇒ merged + post-merge scripts invoked once (flag);
  failure with merged-on-reconcile ⇒ merged; head moved ⇒ superseded (resets
  `merge_attempts`); a hand-edited `merging` file never issues a merge; a
  persistent refusal under `watch` ⇒ terminal `failed` after 2 attempts; a
  redcheck exit 2 is folded into the `merged` reason and the state file.
- Argv: bad `<pr>`, forbidden flags, `GH_REPO` ignored.
- Worktree: driver run from `.claude/worktrees/x` writes to `<primary>`; the
  REAL `post-merge-cleanup.sh`, driven from inside a worktree, retires another
  merged worktree and leaves the session's own.

## 11. Out of scope (recorded)

Auto-rerun; `ci.inflight`; label routines; Stop hook; ci.yml `concurrency`
(`queue:` on Free unverified); `yq`; E-history diffing; moving state into
the PR. Not prevented by this design: memo §1 failure #6 (CI contention on a
self-hosted pool) and bare `gh run rerun` issued outside the driver (observed
by the next tick, not capped).

## 12. Build order

- **T1** E computation + §6 predicate + state file + fenced lease (pure
  functions over stub `gh` JSON; fixtures first).
- **T2** `tick`/`watch`/`status`: budget, deadlines, superseded/behind, argv.
- **T3** merge step: gate-in-the-loop, pinned merge, read-only reconcile,
  post-merge scripts, scaffold gitignore rule, playbook bullet. Ship
  **0.13.0**; consumer allowlist PRs.
- **T4** (0.14.0, later): gate witness requirement + playbook rewrite.
