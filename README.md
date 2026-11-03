# sweap

A Claude Code plugin that turns a roadmap into merged pull requests. You write the backlog and answer the questions that need a human; sweap drives each item through implementation, review, CI and merge, and refuses to merge anything that isn't green.

## How it works

`/roadmap` turns a goal into item files. `/sweap:run` then drains them one at a time through a script, not a long-lived agent:

1. **Scope:** recompute what is runnable, because every merge changes that.
2. **Implement:** a fresh agent per item, which exits once its branch is committed.
3. **Review:** a fresh reviewer, plus a security reviewer when the item is tagged for one.
4. **Merge:** a small watcher drives `sweap-merge` until it reaches a terminal state.
5. **Fix:** a fresh fixer per failure, with every earlier attempt in hand.

Hooks enforce the rules mechanically. `pre-merge-gate.sh` denies a merge when the PR's checks aren't all green or its head is behind its base, so an agent can't talk its way past a red build. When a milestone completes, `/milestone-audit` runs an adversarial cross-feature audit, and a gate blocks further merges until a valid audit record lands.

## Decisions worth reading

Each of these started as something that went wrong or a claim that needed testing:

- [**The merge gate is a hook, not an instruction.**](plugin/hooks/pre-merge-gate.sh) A `gh pr checks | tail` pipe once hid a failed e2e run and a broken PR reached main. A pipe returns `tail`'s exit code, so no prompt could have fixed that.
- [**The loop lives in a script.**](docs/research/2026-09-22-run-cost-and-24-7.md) Measuring one run showed that long-lived agents waiting on CI paid half its cost in cache rewrites. The script now holds the loop, and agents hold context only while they work.
- [**Did review actually catch anything?**](docs/research/2026-10-24-f13-attribution/README.md) Tracing a milestone's audit findings back to their PRs showed which review catches were fixed and which leaked, and led to a fix in the run loop.

Most ideas don't survive here. Proposals go through hostile review by three independent agents before anything is built. [`docs/`](docs/README.md) has the full record, including what was killed and why.

## In real use

sweap runs on three of my projects, called consumer A, B and C in these docs. In one consumer A milestone run it merged 15 PRs in 22.5 hours, and 14 of them passed CI on the first try.

## Known limitations

- **Claude Code only.** It depends on Claude Code's hooks and Workflow tool.
- **One item at a time, by design.** Parallel lanes were tried and removed: two reviewers or two gate runs in one worktree destroy each other's databases.
- **No hosted CI for sweap itself.** A green `./test.sh` is the merge bar.
- **A human still answers real decisions.** Items marked `attended` wait for you, and a run stops rather than guess.

Built with Claude Code, so commits carry a co-author trailer. This history was migrated from a private repository in 2026: commit dates are original, while pull request dates show the migration.

## Install

### Once Per Machine
Add the sweap marketplace to Claude Code:
```
/plugin marketplace add henriquerferrer/sweap
```

### Per Project
Install sweap in your current project:
```
/plugin install sweap
/agentic-loop-init
```

This initializes the agentic-dev loop, enabling per-feature isolation and automated gating.

### Commands on your PATH

While the plugin is enabled, Claude Code adds `plugin/bin/` to the Bash tool's
PATH, so a session (and you, in a session's terminal) can run these by name:

| Command | What it does |
| --- | --- |
| `sweap-merge watch <n>` / `sweap-merge status [<n>]` | The merge driver: waits on the base branch's expected checks pinned to the head, runs the merge gate, merges, runs the post-merge hooks |
| `sweap-merge rerun <n> --reason "<why>"` | A hand rerun of a failed PR's red run, recorded in the PR's state file (one per head SHA and workflow, ever; refused when the base tip is red on the same workflow); a rerun that turns green files a `flaky:` discovered note. Prints one line: `pending` (recorded, exit 0), `refused` (nothing written, exit 1), `failed` (issued but not all, or not recorded, exit 1); a missing `--reason` is a usage error (exit 2) |
| `sweap-roadmap-lint <file>` | The per-item spec gate — a failing `todo` item is not runnable |
| `sweap-stranded` | Lists not-merged branches carrying backlog files nothing will land |
| `sweap-note discovered …` / `sweap-note idea …` | Writes a discovered note / an idea into the capture inboxes |
| `sweap-playbook` / `sweap-playbook --run-core` | The playbook's path — the project's vendored `docs/agentic-loop-playbook.md` when it has one, else the installed plugin's — or its Run core (the top of the file down to `run-core:end`); what run agents read instead of searching the disk for it |
| `sweap-frontier` | The runnable `todo` items in drain order, as JSON (what `/sweap:run` picks from, recomputed before every item) |
| `sweap-fleet` | Can the self-hosted runner fleet run this repo's CI (`ok` / `fleet-down` / `unknown`, with the missing label sets and runner versions retiring within a week), as JSON. Exit 1 on `fleet-down` |
| `sweap-usage-tap install` / `sweap-usage-tap report` | Records the subscription meter (5-hour and 7-day `used_percentage`, timestamped) from the status line; `install` prints the `statusLine` setting to paste, `report` prints the readings |

Add **`Bash(sweap-merge:*)`** to your project's `.claude/settings.json`
`permissions.allow` (and the other three if they should run unprompted).
Without it the driver prompts while `Bash(gh pr merge:*)` does not, and every
run routes around the driver. These are the plugin's only model-facing entry
points: `${CLAUDE_PLUGIN_ROOT}` is exported for *hook* execution only and is
unset in a model-issued Bash call, so it cannot be used in a launch line.

## Testing

sweap has no hosted CI, so a green `./test.sh` is the merge
bar — run it before every PR:

```sh
./test.sh            # everything, with each suite's output
./test.sh --quiet    # header, PASS/FAIL lines and the summary only
```

It runs every `plugin/hooks/*.test.sh` suite serially with per-suite timings,
`node --test plugin/tools/*.test.mjs plugin/workflows/*.test.mjs` (file globs —
Node 21+ rejects a bare directory), and `shellcheck -S warning` over the hooks
and `plugin/bin/` when shellcheck is installed (skipped with a message
otherwise). Expect ~3-4
minutes; `pre-merge-gate.test.sh` is the slow one (it sleeps through real
gh-timeout paths), which is what the per-suite seconds are for. Run one suite
alone with `bash plugin/hooks/<x>.test.sh` or
`node --test plugin/tools/sweap-board.test.mjs`.

## License

MIT
