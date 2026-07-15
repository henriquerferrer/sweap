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
