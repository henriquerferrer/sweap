---
description: Adversarial cross-feature audit of a merged milestone (finder → scoring refuters, majority-survives), then triage confirmed findings.
argument-hint: "[milestone-id] [range] — milestone-id (e.g. F6) is strongly recommended: without it the Workflow can't refuse a wrong-milestone run, it just infers one. range defaults to inferring the merged range from the item files"
---

Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`
("Milestone audit" section), and the backlog (index + item files under
`backlog.dir`) first.

**This command is not done when the Workflow returns.** Its deliverable is a
merged, VALID audit record — the run's findings are worthless to the pipeline if
the record they land in does not parse. In order:

1. Run the Workflow (below).
2. Triage every confirmed finding into one of the three buckets.
3. Write `<backlog.dir>audits/<milestone>.md` **from the Workflow's returned
   `record` field** — it is the format template already filled in from the run's
   own data. Fill its `<FILL:...>` markers; do not compose the record yourself.
4. Run `bash "$([ -f .github/scripts/audit-gate.sh ] && echo .github/scripts/audit-gate.sh || echo "${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh")" --check` and fix any
   `FAIL:` line before opening the PR. (Run it from the repo root on the merged
   default branch. A `DEFERRED:` line for the milestone you are auditing means
   you are standing on a checkout where its last item is not yet merged — the
   audit is not legal there; merge first.)
5. Land record + follow-up items + index update in ONE PR through the gate.

Step 3 is the one that has actually failed in the field: a consumer repo's F9
record landed as pure prose with no frontmatter at all, and the miss went
unnoticed for days. If the Workflow's return value has no `record` field you are
running an old plugin build — stop and say so rather than improvising the
format, because a record written to a stale format is exactly the failure this
step exists to prevent.

Run the saved **`sweap:milestone-audit`** Workflow (`Workflow({name: "sweap:milestone-audit", args: {...}})` — the plugin-scoped name; the bare `milestone-audit` is "not found", a consumer, 2026-09-02) with `args: {milestone: "<id>", range: "<base>..<head>"}` —
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
entirely for that run. The Workflow is finder → three adversarial refuters per
finding → majority-survives (the refuters score, the pipeline cuts — see below).
It never triages — it returns the confirmed findings, sorted by severity.

Its finders and refuters are **mechanically read-only**: they run as the
`audit-reader` agent (`Read`, `Grep`, `Glob` — no `Write`, no `Edit`, no
`Bash`), so they cannot touch the repo even where a prompt might seem to invite
it. The Workflow addresses that agent by *resolving* it rather than naming it:
plugin-scoped `sweap:audit-reader` when installed as a plugin, bare when the
repo ships its own `.claude/agents/` copy, and an agent type it cannot resolve
aborts the run rather than dispatching without one. Be precise about that guarantee's scope: the **Scope** stage needs `Bash`
for `git log` and is constrained by instruction only. Until 2026-08-16 the whole
workflow was read-only by documentation alone, and a refuter wrote a test file
into a consumer repo's primary checkout to settle a claim it could not settle by
reading — the docs did say read-only, but they said it to the calling session,
never to the agent holding the tools.

A refuter does **not** return a verdict. It returns the `path:line` spans it
read, the code bearing on the claim, what would falsify its own answer, and
`confidence` — its probability, 0 to 1, that the finding is wrong. The pipeline
cuts: a score strictly above `TUNING.refutedAt` (0.5) is a refutation, and
`TUNING.killVotes` (2) of the three seats kill a finding. Both numbers live in
one `TUNING` block in the Workflow. Evidence is required symmetrically — the
answer that leaves a finding alone cites code on the same terms as the one that
kills it, and an answer citing none is a schema violation, never a demotion.
Lost or unscored votes are excluded from the count and never lower the bar.

This replaces a three-valued verdict that took the kill rate from 63–73% to
2.7% in one change, so if you see `refuted`/`stands`/`unverifiable` in a run's
journal you are on an old plugin build — say so rather than reading the numbers.
`unverifiable` is now an **out-of-band ticket**: a refuter that cannot settle a
claim by reading names the exact command in `experiment` *and still scores*. One
such ticket on a surviving finding routes it to the **Validate** stage, which
runs that experiment in a throwaway git worktree (`audit-prover`,
`isolation: 'worktree'`) and returns a verdict backed by a pasted command and
its actual output.

**This changes what you triage.** The Workflow now returns `unverified` — a
subset of `confirmed` — and the record carries an `unverified:` count plus a
`status: UNVERIFIED` line on those blocks. Those are **coverage gaps, not
established defects**: nothing disproved them and nothing demonstrated them.
Triage them as **bucket 2** — where the claimed harm has a class, the follow-up
item writes the experiment named in the block; where it has none, the finding is
parked like any other — and reach for bucket 1 or 3 only if you verified the
claim yourself. Read the status line first, though: a block that says the sandboxed
run **was lost** had its prover die, not fail — resume the Workflow
(`resumeFromRunId`) before triaging, exactly as for a panel that stopped
answering; a block that says the sandboxed run **could not either** was
answered and is a real coverage gap. And a block with a `Sandboxed run:`
section and no `UNVERIFIED` line was settled by execution — that one IS a
verified defect (or, if the prover refuted it, it is not in the record at all). Do not report them as "confirmed by adversarial review" — that claims
three adversaries failed to refute what three adversaries never looked at. If
the `unverified` count is large, say so in the summary: it means the audit's
reading tier was out of its depth on that surface, which is worth more than any
single entry in the list.

Once the Workflow returns, **triage every confirmed finding** into exactly one
of the three buckets per the playbook's "Milestone audit" section (do this
yourself — the Workflow does not):

1. **Bug** (the code fails its own spec) — open a follow-on fix-PR through the
   gate. Hands-off in an unattended run; still a separate gated PR, never an
   edit made by the audit itself.
2. **Small gap / non-urgent** (races, infra) — apply `/milestone`'s **harm bar**
   (its "Discovered-items triage" step owns the four classes and the
   weak-check rule; do not restate them here).
   - **Has a class → a follow-up:** a new item file under `backlog.dir` with
     `followup_of: <milestone>`, `harm: <class>` and a `## Harm` section
     (`status: todo`, tagged, lint-clean). It folds, debt-first, into the next
     `/milestone` run.
   - **No class → parked.** ALL such findings of this audit share ONE item:
     `<id> — <milestone> audit: parked findings`, `status: deferred`,
     `followup_of: <milestone>`, `depends_on: []`, `premise: parked <date> — no
     harm class`. Its body is one line per finding pointing at the record block
     (`### <n> — <title>`), never a copy — the record already holds the finding
     and its proof. Every such block's disposition is `followup <that id>`. The
     item exists so the disposition resolves; nothing schedules it, and only a
     human un-parks a finding (by authoring it as its own item). Never archive
     it: the record names the file.
3. **Design / scope gap** (the feature should do something it never promised)
   — this is a direction-loop call, not correctness. Do NOT spec or build it.
   Write it as a `status: blocked` item file with the question verbatim in
   `blocked:`, push-notify the human, and move on.

The dividing line between bucket 1 and bucket 3 is the milestone's acceptance
criteria: failed-the-spec is a bug; not-in-the-spec is a direction call.

**Write the audit record (step 3 — mechanical part of the audit's definition of
done).** The Workflow returns a `record` field: the full record, already
conformant, populated from the run's own milestone / range / lens set / stats /
confirmed findings. **Write that string to `<backlog.dir>audits/<milestone>.md`
and fill its `<FILL:...>` markers.** Do not retype it from memory and do not
re-derive any value it already contains — the record is the committed form of
the run's evidence, not a fresh composition.

The markers a machine could not fill:

- `workflow_run` — this run's Workflow id.
- `journal_sha256` — `shasum -a 256 <transcriptDir>/journal.jsonl` from the
  run's transcript directory.
- one `disposition:` per finding block — `fix_pr #NN` | `followup <id>` |
  `blocked <id>`, matching the bucket you triaged it into above.

If this milestone also had a **Tier-2 UI audit**, that is a second axis on this
same record, not a second record: add `axes: [ui]` plus the seven `ui.*` keys
(its own raw/refuted/confirmed, lens set, workflow_run, journal_sha256) and give
its survivors their own disposition blocks. Never fold its stats into the code
audit's counts. Its critics are anonymized, so record the lens set that ran and
do not attribute a lens to an individual UI finding.

The Workflow emits one block per confirmed finding because it cannot tell
convergence from independence. If several lenses turned out to be reporting the
SAME underlying defect, collapse those blocks into one and add `defects: <n>`
to the frontmatter — the gate matches blocks against `defects` when present.
Convergence is signal worth stating in the block ("six lenses hit this
independently"), not duplication to be padded out.

The format contract itself lives in ONE place:
`${CLAUDE_PLUGIN_ROOT}/playbook/audit-record.template.md`. Read it if you are
writing a record by hand, if a `--check` FAIL is unclear, or if the Workflow
returned no `record` field. Never restate the format from memory.

Land the record, its `followup_of:`-tagged follow-up/blocked item files, and the
index update in ONE PR through the normal gate (the audit gate recognizes that
PR as debt discharge).

**Then run the gate (step 4):**

    # The repo's VENDORED gate is what CI runs — prefer it over the plugin's
    # copy, which is whatever build this session resolved and can lag the
    # record format. A pre-flight that can disagree with CI is worse than none.
    GATE=.github/scripts/audit-gate.sh
    [ -f "$GATE" ] || GATE="${CLAUDE_PLUGIN_ROOT}/hooks/audit-gate.sh"
    bash "$GATE" --check

A `FAIL:` line means the record is malformed or mis-bound — fix the record,
never the gate. One `FAIL:` is not about formatting: if the record says `raw: 0`
the gate demands `finders_reporting: >= 1`, because a zero-findings record and a
record from a run whose finders all died are the same document otherwise. The
Workflow emits that key; if you are hand-writing a record and cannot honestly
fill it, the audit did not run and the answer is to run it, not to fill it in.

Post a summary quoting the Workflow's returned `{milestone, range, stats}`
verbatim plus lenses used and where each confirmed finding landed (fix-PR link,
roadmap item file, or `status: blocked` item). Report the `--check` result too —
but do not present it as proof: it is a pre-flight you ran on yourself, and the
binding verification is the `audit-gate` required check on the record PR, which
re-runs the same script where no session can vouch for it. If this repo has no
such CI job, say so in the summary as an open gap rather than claiming the
record is verified.
