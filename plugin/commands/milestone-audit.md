---
description: Adversarial cross-feature audit of a merged milestone (finder → refuter, majority-survives), then triage confirmed findings.
argument-hint: "[milestone-id] [range] — milestone-id (e.g. F6) is strongly recommended: without it the Workflow can't refuse a wrong-milestone run, it just infers one. range defaults to inferring the merged range from the item files"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`
("Milestone audit" section), and the backlog (index + item files under
`backlog.dir`) first.

Run the saved **`milestone-audit`** Workflow with `args: {milestone: "<id>", range: "<base>..<head>"}` —
resolve `<id>` from the argument (the milestone this invocation is auditing,
e.g. `F6`) and, if a range was also given as an argument, pass it too; if the
range is unknown, omit it and let the Workflow's Scope stage infer it from the
item files at `status: done` and `git log --oneline --merges`. **Always pass
args as an object, never as a bare string** — the Workflow throws if it
detects a range- or JSON-shaped string, precisely because a stringified range
silently discarded by `args?.range` once caused a run to audit the wrong
milestone (see the playbook's "Audit evidence" paragraph). The Workflow also
throws if the milestone it resolves does not match the one requested — treat
that as a failed run, not a result to triage. If no argument was typed at
all, pass no `milestone` (`args: {}` or omit `args` entirely) — the Workflow
then falls back to inferring "the most recently completed milestone" with no
mismatch guard. That fallback is legal but strictly worse: prefer resolving
the milestone id from context (the item files just marked `status: done`,
or the calling goal's `<milestone>`) over invoking with no id.
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
2. **Small gap / non-urgent** (races, infra) — write it as a new item file
   under `backlog.dir` with `followup_of: <milestone>` (`status: todo`,
   tagged, lint-clean). These auto-fold, debt-first, into the next
   `/milestone` run.
3. **Design / scope gap** (the feature should do something it never promised)
   — this is a direction-loop call, not correctness. Do NOT spec or build it.
   Write it as a `status: blocked` item file with the question verbatim in
   `blocked:`, push-notify the human, and move on.

The dividing line between bucket 1 and bucket 3 is the milestone's acceptance
criteria: failed-the-spec is a bug; not-in-the-spec is a direction call.

**Write the audit record (mechanical part of the audit's definition of done).**
After triage, write `<backlog.dir>audits/<milestone>.md`:

    ---
    milestone: F3
    range_base: <base sha of the audited range>
    range_head: <head sha of the audited range>
    lens_mode: default            # default | default-plus | explicit
    lenses: [correctness, authz, data-integrity, concurrency, test-integrity, api-contract]
    raw: 14                       # from the Workflow's stats
    refuted: 9
    confirmed: 5
    workflow_run: wf_...          # the Workflow invocation's runId
    journal_sha256: <sha256 of the run's journal.jsonl>
    ---

One `### <n>. <title>` block per confirmed finding with flat `severity:`,
`lens:`, and exactly one `disposition:` line — `fix_pr #NN` | `followup <id>` |
`blocked <id>`. Transcribe the Workflow's RETURN VALUE — do not restate
findings from memory. Compute `journal_sha256` with
`shasum -a 256 <transcriptDir>/journal.jsonl` from the run's transcript
directory. Land the record, its `followup_of:`-tagged follow-up/blocked item
files, and the index update in ONE PR through the normal gate (the audit gate
recognizes that PR as debt discharge). Take `range_base` / `range_head` from
the Workflow's returned `{milestone, range}` — the record is the committed
form of that evidence, not a re-derivation.

Then run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh --check` from the
repo root and QUOTE its passing output in your summary. A `FAIL:` line means
the record is malformed or mis-bound — fix the record, never the gate.

Post a summary of the run quoting the Workflow's returned `{milestone, range,
stats}` verbatim AND the `audit-gate.sh --check` pass (a prose "audit clean"
claim with neither is a malformed run), plus lenses used and where each
confirmed finding landed (fix-PR link, roadmap item file, or `status:
blocked` item).
