# <project> — agent instructions

<!-- sweap:begin -->
**Read the sweap playbook before any feature work:** it defines the operating
model, autonomy rules, and how to resume interrupted work. Specs live in
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Backlog: `ROADMAP.md`.

## sweap config (read by pipeline commands — override only what differs)
```
verify.typecheck: <your typecheck cmd>     # e.g. pnpm check-types / tsc --noEmit / cargo check
verify.lint:      <your lint cmd>
verify.e2e:       <your e2e cmd>           # authoritative merge gate — must run the FULL suite (unit+integration+e2e), e.g. `just ci-local`
backlog.file:     ROADMAP.md
backlog.prefix:   F                        # one or more comma-separated prefixes, e.g. `F` or `F, DS`
# services.up:    just services-up          # uncomment only if you have local test services
audit.lenses:     default
review.dimensions: security, ui, migration
notify:           push
turns.default:    160
```

## Standing preferences — treat as already answered, do not re-ask
- Always work in an isolated worktree/branch; never implement on `main`.
- Finishing a branch: open a PR by default. Never discard work autonomously.
- Merging an unblocked PR whose gate is green is pre-authorized — do not ask.
  Never pass `--admin`/`--repo`/`-R`; never disable or weaken the gate.
- Plan execution: subagent-driven-development (continuous, no check-ins).
- TDD, no exceptions in product code. The implementer's report MUST include TDD
  Evidence: the RED (failing) output and the GREEN (passing) output, pasted.
  Never modify a test to make it pass; never skip/quarantine silently.
- Do not rationalize skipping a code review ("nothing to review", "trivial
  adapter"). Every task gets its fresh-context review.
- When blocked or ambiguous in an unattended run: escalate, don't guess —
  record the question on the item in ROADMAP.md, notify, move to the next item.
- Honor each ROADMAP item's `review-dimensions` tags.
- At the end of an autonomous run: notify with merged-PRs + blocked-items summary.
<!-- sweap:end -->

<!-- agentic-ci: ci-section -->
## CI

CI uses GitHub Actions. Every job runs as `just <recipe>` — both locally and in
CI use the same commands. The `justfile` and `.github/workflows/*.yml` in this
repo are scaffolded from a template with `# <fill in for your stack>` stubs;
this section documents the convention those stubs must honor once filled in.

### Reproduce a CI failure locally

```bash
just ci-replay <job-name>   # e.g. just ci-replay test
just ci-local               # run the entire pipeline locally
```

### Read CI status from outside the runner

Each CI job emits a JSON status block to its step summary with shape:

```json
{
  "job": "<job-name>",
  "status": "success | failure | cancelled",
  "annotations": [{"file": "...", "line": 0, "level": "...", "message": "..."}],
  "repro": "just ci-replay <job-name>",
  "next_action": "..."
}
```

To read the status of a CI run without scraping logs:

```bash
gh run view <run-id> --json jobs
gh api repos/OWNER/REPO/actions/runs/<run-id>/jobs
```

The block is emitted by `.github/scripts/ci-status.sh <job> <status>` (per-job)
and aggregated by `.github/scripts/ci-summary.sh` (run-level). These two
scripts are stack-specific enough (they parse your lint/test tool's report
format) that the scaffold does not ship them — write them once for this
project (or generate them via the `agentic-ci` skill) to emit the shape above.

### Available `just` recipes

- `lint`, `typecheck`, `test`, `e2e` — individual checks (fill in per your stack)
- `ci-local` — run the full pipeline locally
- `ci-replay <job>` — re-run a single job

### Conventions

- All jobs run with `NO_COLOR=1`, `FORCE_COLOR=0`, `CI=true` to keep logs
  agent-parseable.
- Jobs run independently so a failure in one doesn't cancel the others —
  every gate reports its own result in the same pass.
- Third-party actions are pinned to 40-char SHAs; keep them updated on a
  schedule (e.g. Renovate/Dependabot).
<!-- /agentic-ci -->
