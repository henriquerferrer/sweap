# sweap

SWE Agentic Pipeline — an agentic-dev loop for per-feature development, merge-greenness gates, and automated roadmap/milestone/audit commands.

## Install

### Once Per Machine
Add the sweap plugin to your Claude Code marketplace:
```
/plugin marketplace add ~/Documents/sweap
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
| `sweap-frontier` | The runnable `todo` items in drain order, as JSON (what `/sweap:run` picks from, recomputed before every item) |
| `sweap-fleet` | Can the self-hosted runner fleet run this repo's CI (`ok` / `fleet-down` / `unknown`, with the missing label sets and runner versions retiring within a week), as JSON. Exit 1 on `fleet-down` |
| `sweap-usage-tap install` / `sweap-usage-tap report` | Records the subscription meter (5-hour and 7-day `used_percentage`, timestamped) from the status line; `install` prints the `statusLine` setting to paste, `report` prints the readings |

Add **`Bash(sweap-merge:*)`** to your project's `.claude/settings.json`
`permissions.allow` (and the other three if they should run unprompted).
Without it the driver prompts while `Bash(gh pr merge:*)` does not, and every
run routes around the driver. These are the plugin's only model-facing entry
points: `${CLAUDE_PLUGIN_ROOT}` is exported for *hook* execution only and is
unset in a model-issued Bash call, so it cannot be used in a launch line.

## Features

- Per-feature agentic loop with merge gating
- Automated roadmap, milestone, and audit commands
- Integration with Claude Code's hook system

## Testing

sweap has no hosted CI (billing-blocked), so a green `./test.sh` is the merge
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
