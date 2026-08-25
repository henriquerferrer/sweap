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

This initializes the agentic-dev loop, enabling per-feature isolation, automated gating, and cron-driven roadmap management.

## Features

- Per-feature agentic loop with merge gating
- Automated roadmap, milestone, and audit commands
- Cron driver for scheduled tasks
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
when shellcheck is installed (skipped with a message otherwise). Expect ~3-4
minutes; `pre-merge-gate.test.sh` is the slow one (it sleeps through real
gh-timeout paths), which is what the per-suite seconds are for. Run one suite
alone with `bash plugin/hooks/<x>.test.sh` or
`node --test plugin/tools/sweap-board.test.mjs`.
