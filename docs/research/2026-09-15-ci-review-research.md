# The CI reviewer, measured and compared with the vendor's docs (2026-09-15)

Trigger: Henrique asked whether the CI review is done with the right commands and
whether it is needed at all. Two passes: a measurement of what the reviewer has
actually contributed on consumer A, then a research agent over the claude-code-action
docs and source at our pinned SHA, followed by three refuters over its ten
proposals. Built: sweap 0.26.0 (one managed-file change, bundled so consumers
merge one adoption PR).

## What the reviewer has contributed (consumer A #255–#330, 76 PRs)

| measure | result |
|---|---|
| verdicts | 103 approve, 0 needs-work (189/4 over the whole ledger since 08-15; the 4 predate the managed file) |
| comments with any remark beyond approve | ~27 |
| remarks a later push acted on | 1 (#280, a stale comment in a test file) |
| heads it approved that the in-session reviewer then blocked | 3 (#259, #262, #265) |
| PRs with byte-identical comments re-posted on a new push | 7 (+#280 ×4, three of them same-head quota reruns) |
| runs since 09-05 / minutes on the shared general runner | 112 / ~584 |
| red runs unrelated to review (artifact quota ×3, lost verdict ×2, runner drop ×1) | 6 |
| PRs where it was the only review (docs, backlog, chore, off-session) | 13 of 76; two correct-but-ignored cosmetic notes |

Every "first-pass blocking finding, now fixed" phrase in its comments credits the
in-session reviewers' work. Nothing on correctness, authorization or test
integrity came from it that the in-session pass had not already found. Its
strengths are real but narrow: it verifies PR-body claims against the tree
(#276, #281, #329 caught wrong numbers nobody fixed), it is the only read on ~17%
of PRs, and its transcripts made #310 diagnosable.

**Open decision (Henrique's):** keep it as a required check, demote it to
advisory (a sweap-merge change: the driver stops treating the run's conclusion
as required; the workflow keeps posting), or remove it. The evidence supports
advisory; a run under 0.26.0 is the first under the retry, the size notice and
the shared bar, so removal should wait for that witness. Caveat: this window was
unusually well reviewed in-session, so its value on a weaker run is unmeasured.

## Vendor comparison, and what the docs confirm we already do right

`claude_args` with `--model`/`--allowedTools`/`--disallowedTools` is the
documented shape and the per-flag inputs are deprecated; `--disallowedTools`
removes the tools from context on the SDK path; naming the inline-comment MCP
tool in `--allowedTools` is what starts its server; `Bash(gh pr comment|diff|view:*)`
is the vendor's own review tool set; no `github_token` means posts are authored
by `claude[bot]`; `id-token: write` plus `pull_request` (not
`pull_request_target`) is the safe checkout; drafts skip at job level;
concurrency with cancel-in-progress and a job timeout are the documented cost
controls; `show_full_output`/`display_report` stay off. The last-line
`Verdict:` grep has the same shape as the managed service's machine-readable
last line, only the quantity differs (a judgment vs a severity count).

## The ten proposals and their verdicts

| # | proposal | verdict | what survived |
|---|---|---|---|
| 1 | `--json-schema` structured output, gate on a severity count | reject | moves the judgment from approve/needs-work to a self-labelled severity; deletes three incident-backed controls blind. Survivor: a `Findings: important=N nit=M` penultimate line in the summary, for the next audit to read. **Built.** |
| 2 | vendor's high-signal bar and false-positive list | adopt with change | the vendor's list excludes "input-dependent" issues, which is exactly an authorization gap. Survivor: the in-session reviewer's own bar (file:line, the needs-work definition, a `### Advisory` section that never flips the verdict), so both reviewers judge by one rule. **Built.** |
| 3 | `confirmed: true` on inline comments | adopt with change | the Haiku classifier has never run on our consumers (it needs an API key the OAuth path never sets); the pinned SHA has no buffer dedupe, so the prompt form would double-post. Survivor: `classify_inline_comments: 'false'` on both passes. **Built.** |
| 4 | add `reopened` to `pull_request.types` | reject | checks attach to the SHA; a reopened PR keeps its verdict (consumer A #264 proves it). Adds a duplicate run per reopen. |
| 5 | drop `pull-requests: write` and `actions: read` | adopt | the App token posts, our steps only read, nothing uses `actions: read`. Plus `continue-on-error` on the transcript upload, which redded 3 runs on artifact quota after a verdict was posted. **Built.** |
| 6 | incremental re-review on `synchronize` | reject | a whole-PR verdict cannot be a chain of delta verdicts; the model time is not the diff walk (one `gh pr diff` per run); 24% of re-pushes are force-pushes; 189/193 prior verdicts have no findings to confirm. |
| 7 | re-allow `Agent` (keep `ScheduleWakeup` disallowed) | reject | the #310 transcripts show the background-Agent path alone ends the turn ("you will be notified" → end_turn); the action breaks out of the SDK query on the first `result`. Note: the disallow itself is still unwitnessed in a consumer (#331 self-skips; the PR after proves it). |
| 8 | fail closed on a fork PR with no secret | adopt with change | the proposed clause let a fork PR that *does* get the secret run fork code on a fenced runner. Survivor: a same-repository clause on the job-level `if`. **Built.** |
| 9 | `--effort` / model by role | reject | not measurable before findings are the unit; conflicts with the refuted tier decision. Survivor: model and effort stamped in the size notice. **Built.** |
| 10 | pins and fetch depth | adopt with change | `fetch-depth: 0` costs 1–5 s, keep it. The checkout and upload-artifact pins were Node 20, which GitHub removes on 2026-09-23. Bumped to v7.0.1 (node24) in all three templates. **Built.** |

## Consumer notes

`claude-review.yml` and `audit-gate.yml` are managed and arrive as a working-tree
diff at the next session start; `ci.yml` is copy-if-absent, so its Node 24 pins
reach an existing consumer only by hand (seven `checkout` sites and one
`upload-artifact` site in consumer A's ci.yml). Consumer A #331 (the 0.25.0 adoption) is
open; updating the plugin to 0.26.0 and re-syncing before merging it turns two
human-merged adoption PRs into one.
