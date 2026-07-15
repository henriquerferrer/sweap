---
description: Adversarial cross-feature audit of a merged milestone (finder → refuter, majority-survives), then triage confirmed findings.
argument-hint: "[range] — defaults to inferring the merged range from the backlog file"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`
("Milestone audit" section), and `ROADMAP.md` (`backlog.file`) first.

Run the saved **`milestone-audit`** Workflow over `{range}` (the first argument,
e.g. `<base>..<head>`); if omitted, let the Workflow's Scope stage infer the
range from the backlog file's `[done]` items and `git log --oneline --merges`.
The Workflow reads `audit.lenses` from the `## sweap config` block in CLAUDE.md
to build its finder lens set — `default` runs the generic default lens set
baked into the Workflow (correctness, authz/security, data-integrity,
concurrency/races, test-integrity, api-contract); `default + [x, y]` appends
project-drafted lenses for `x, y`; an explicit list replaces the defaults
entirely for that run. The Workflow itself is **read-only**: finder → three
adversarial refuters per finding → majority-survives. It never edits code and
never triages — it returns the confirmed findings, sorted by severity.

Once the Workflow returns, **triage every confirmed finding** into exactly one
of the three buckets per the playbook's "Milestone audit" section (do this
yourself — the Workflow does not):

1. **Bug** (the code fails its own spec) — open a follow-on fix-PR through the
   gate. Hands-off in an unattended run; still a separate gated PR, never an
   edit made by the audit itself.
2. **Small gap / non-urgent** (races, infra) — append it as a `[todo]`,
   tagged fix-item (using the milestone prefix, e.g. `FA.*`) at the top of
   `ROADMAP.md`, under a `## <milestone> audit follow-ups` section. These
   auto-fold, debt-first, into the next `/milestone` run.
3. **Design / scope gap** (the feature should do something it never promised)
   — this is a direction-loop call, not correctness. Do NOT spec or build it.
   Write it to `ROADMAP.md` as a `[blocked]` entry with the question verbatim,
   push-notify the human, and move on.

The dividing line between bucket 1 and bucket 3 is the milestone's acceptance
criteria: failed-the-spec is a bug; not-in-the-spec is a direction call.

Post a summary of the run: range audited, lenses used, raw/refuted/confirmed
counts, and where each confirmed finding landed (fix-PR link, roadmap item, or
`[blocked]` entry).
