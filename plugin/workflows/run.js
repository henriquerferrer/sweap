export const meta = {
  name: 'run',
  description: 'Drive runnable backlog items to the default branch one at a time: a fresh implementer per item, a small watcher for the merge wait, a fresh fixer per red',
  whenToUse: 'The run session invokes it instead of driving the per-item loop itself. Pass {ids: [...]} to drain a batch in a given order, {max_items: n} to bound the batch, or nothing to drain the frontier in the playbook\'s pick order (follow-ups first, then numeric). It stops at a usage limit, an API death, a red base branch, or an empty frontier, and returns what merged, what needs a human, and where it stopped. The session then runs /milestone-audit when a milestone completed and records .claude/sweap-run.md.',
  phases: [
    { title: 'Resume', detail: 'what an interrupted run left behind: worktrees, open PRs, armed watches, plans with unchecked steps' },
    { title: 'Scope', detail: 'sweap-frontier before every item — a merge changes what is runnable' },
    { title: 'Implement', detail: 'one fresh implementer per item; it exits when its PR is open' },
    { title: 'Merge', detail: 'a small watcher drives sweap-merge watch to a terminal word and verifies the flip' },
    { title: 'Fix', detail: 'a fresh fixer per red, with every prior round in hand; three distinct root-cause attempts, then blocked' },
  ],
}

// WHY THIS SHAPE. The consumer A F13 run (2026-09-18..20) drove items with eight
// long-lived "lane runner" subagents that each held the loop for 8-13 items and
// waited on CI inside 600-second Bash calls. They grew to 758k and 806k of
// context, read 464M tokens, and paid 116M of the run's 130M cache-expiry
// rewrites — half the run's cost — for the privilege of learning one word from
// the merge driver. Design memo: docs/research/2026-09-22-run-cost-and-24-7.md.
// Here the SCRIPT holds the loop, an implementer holds context only while it
// implements, and the hours a PR spends in CI are watched by an agent that
// holds nothing. Strictly serial: one item in flight, ever (the playbook's
// "One item at a time" section; two reviewers or two gate runs against one
// worktree destroy each other's databases — lane lessons 1 and 9).

// ---------------------------------------------------------------------------
// Arguments. Either an object or nothing; a bare string is a comma list of ids.
const ARGS = (typeof args === 'string')
  ? { ids: args.split(/[,\s]+/).filter(Boolean) }
  : (args && typeof args === 'object' ? args : {})
const IDS = Array.isArray(ARGS.ids) && ARGS.ids.length ? ARGS.ids.map(String) : null
const MAX_ITEMS = Number.isFinite(Number(ARGS.max_items)) && Number(ARGS.max_items) > 0 ? Number(ARGS.max_items) : Infinity
// The implementer's model is named, never inherited: a workflow agent otherwise
// runs on the SESSION model, and the session that launches this is usually on
// the strongest tier for planning. Implementation grind is Opus per the
// playbook's "Model policy"; the cost basis of the memo is Opus subagents.
const MODEL = typeof ARGS.model === 'string' && ARGS.model ? ARGS.model : 'opus'
const SMALL_MODEL = typeof ARGS.small_model === 'string' && ARGS.small_model ? ARGS.small_model : 'sonnet'
const MAX_FIX_ROUNDS = 3
const PLUGIN_NAME = 'sweap'

// ---------------------------------------------------------------------------
// Schemas — the workflow reads fields, never prose.
const RESUME = {
  type: 'object',
  required: ['worktrees', 'open_prs', 'watches', 'plans_unchecked', 'notes'],
  properties: {
    worktrees: { type: 'array', items: { type: 'object', required: ['path', 'branch', 'item'], properties: {
      path: { type: 'string' }, branch: { type: 'string' }, item: { type: 'string', description: 'item id the worktree belongs to, or "" when unclear' },
      dirty: { type: 'boolean' }, commits_ahead: { type: 'number' } } } },
    open_prs: { type: 'array', items: { type: 'object', required: ['number', 'branch', 'item'], properties: {
      number: { type: 'number' }, branch: { type: 'string' }, item: { type: 'string' }, checks: { type: 'string' } } } },
    watches: { type: 'array', items: { type: 'object', required: ['pr', 'state'], properties: { pr: { type: 'number' }, state: { type: 'string' } } } },
    plans_unchecked: { type: 'array', items: { type: 'string' } },
    base_red: { type: 'boolean', description: 'true when the default branch tip has a red or cancelled workflow run' },
    notes: { type: 'string' },
  },
}

const SCOPE = {
  type: 'object',
  required: ['frontier'],
  properties: {
    frontier: { type: 'array', items: { type: 'object', required: ['id'], properties: {
      id: { type: 'string' }, followupOf: { type: ['string', 'null'] }, reviewDimensions: { type: 'array', items: { type: 'string' } },
      answeredQuestion: { type: ['string', 'null'] }, lint: { type: 'string', description: 'pass, or the lint failure text' } } } },
    malformed: { type: 'array', items: { type: 'string' } },
  },
}

const IMPLEMENT = {
  type: 'object',
  required: ['outcome', 'pr', 'branch', 'worktree', 'red_green', 'review_rounds', 'reviewer_verdict', 'report'],
  properties: {
    outcome: { enum: ['pr-open', 'blocked', 'failed'] },
    pr: { type: ['number', 'null'], description: 'the PR number, also for a blocked flip landed through a PR' },
    branch: { type: 'string' },
    worktree: { type: 'string' },
    red_green: { type: 'string', description: 'the pasted RED then GREEN output, verbatim' },
    review_rounds: { type: 'number' },
    reviewer_verdict: { type: 'string', description: 'the last reviewer verdict line, verbatim' },
    security_verdict: { type: ['string', 'null'] },
    premises: { type: 'string', description: 'which item premises were verified against the code, which were stale, and what was done about each' },
    notes_filed: { type: 'array', items: { type: 'string' } },
    question: { type: ['string', 'null'], description: 'the blocking question, verbatim, when outcome is blocked' },
    report: { type: 'string' },
  },
}

const WATCH = {
  type: 'object',
  required: ['word', 'reason', 'pr', 'watch_calls'],
  properties: {
    word: { enum: ['merged', 'failed', 'behind', 'attended', 'held-by', 'timed_out', 'undecidable'] },
    class: { enum: ['gate', 'starved', 'base-red', 'red', '-'] },
    reason: { type: 'string' },
    pr: { type: 'number' },
    head: { type: 'string' },
    watch_calls: { type: 'number' },
    rerun_used: { type: 'boolean' },
    status_done: { enum: ['yes', 'no', 'unknown'] },
    cleanup: { type: 'string' },
    failure: { type: 'string' },
  },
}

const FIX = {
  type: 'object',
  required: ['outcome', 'summary'],
  properties: {
    outcome: { enum: ['pushed', 'blocked', 'gave-up'] },
    summary: { type: 'string', description: 'root cause found, what changed, what was verified; or why this is blocked' },
    question: { type: ['string', 'null'] },
    distinct_attempt: { type: 'boolean', description: 'true when this round tried a root cause no earlier round tried' },
  },
}

// ---------------------------------------------------------------------------
// One dispatcher. agent() resolves to null when the agent is stopped or dies on
// a terminal API error, and THROWS on other failures (milestone-audit.js
// learned that the hard way); a usage limit that the run cannot wait out ends
// as one of the two. Every call goes through here so neither shape can abort
// the loop without a report, and the run stops with a reason instead.
const call = async (prompt, opts) => {
  try {
    const out = await agent(prompt, opts)
    if (out === null || out === undefined) return { ok: false, why: `agent "${opts.label}" returned nothing (stopped, usage limit, or API death)` }
    return { ok: true, value: out }
  } catch (e) {
    return { ok: false, why: `agent "${opts.label}" threw: ${String((e && e.message) || e)}` }
  }
}

// The watcher is a plugin agent, addressable only under its SCOPED name in a
// plugin install and under its bare name in a local checkout — same probe as
// milestone-audit.js, memoized after the first hit.
let watcherType = null
const callWatcher = async (prompt, opts) => {
  const queue = [watcherType, `${PLUGIN_NAME}:merge-watcher`, 'merge-watcher'].filter(Boolean)
  const tried = []
  let last = null
  while (queue.length) {
    const candidate = queue.shift()
    if (tried.includes(candidate)) continue
    tried.push(candidate)
    last = await call(prompt, { ...opts, agentType: candidate })
    if (last.ok || !/agent type .*not found|unknown agent/i.test(last.why)) { if (last.ok) watcherType = candidate; return last }
  }
  return last || { ok: false, why: 'merge-watcher agent not found under any name' }
}

// ---------------------------------------------------------------------------
// Prompts. Every agent gets CLAUDE.md injected, and the project's CLAUDE.md
// names the playbook; the Run core is what a driver reads and the worker brief
// is what an implementer reads. Neither is pasted here — the file is the spec.

const READ_FIRST = `Read CLAUDE.md's "sweap config" block and the playbook it names (docs/agentic-loop-playbook.md unless it says otherwise). Read the playbook from its top to the line \`<!-- run-core:end -->\` — the Run core — in full. Read nothing else of it up front; the Run core's closing table says which section to read when a situation arrives.`

const resumePrompt = () => `${READ_FIRST}

You are the RESUME stage of an unattended run. Report what an earlier run left behind; change nothing. Run, from the primary checkout:
- \`git worktree list\` and, for every worktree that is not the primary, \`git -C <path> status --short | head -20\` and \`git -C <path> log --oneline origin/<base>..HEAD | wc -l\`;
- \`gh pr list --state open --json number,headRefName,title,statusCheckRollup\`;
- \`sweap-merge status\`;
- \`grep -l '^- \\[ \\]' docs/superpowers/plans/*.md\` (a plan with unchecked steps);
- \`gh run list --branch <default branch> --limit 3 --json conclusion,name,status\` — base_red is true when the newest completed run of any workflow on the default branch is red or cancelled.
Map each worktree, PR and plan to the backlog item id it belongs to (the branch name carries the id in lower case with the dot as a dash, e.g. fix/du25-... is DU.25). Return the JSON only.`

const scopePrompt = (ids) => `You are the SCOPE stage of an unattended run. Run \`sweap-frontier\` from the primary checkout (the sweap plugin's bin/ is on PATH; if the command is missing, say so in \`malformed\` and return an empty frontier). It prints the runnable todo items in drain order as JSON. ${ids ? `The run was given this batch, in this order: ${ids.join(', ')}. Return only those of them that the frontier lists as runnable, in the batch's order, and name in \`malformed\` any batch id the frontier does not list (with why, if the item file says: done, blocked, deferred, attended, or a dependency unmet).` : 'Return the frontier as printed, in its order.'} For the FIRST item you return, also run \`sweap-roadmap-lint <backlog dir>/<id>.md\` and put \`pass\` or its failure text in that item's \`lint\`. Do not read the item files beyond that; do not judge the items. Return the JSON only.`

const implementPrompt = (item, resume, prior) => `${READ_FIRST} Then read the playbook between \`<!-- worker-brief:begin -->\` and \`<!-- worker-brief:end -->\`: that brief binds you.

You are the IMPLEMENTER for backlog item ${item.id}, and only that item. You drive it from its item file to an OPEN pull request, then you exit. You do not merge, you do not watch CI, you never run \`sweap-merge\` (a separate watcher does, after you return), never \`gh pr merge\`, never touch \`.github/\`, never commit in the primary checkout, never push to the default branch.

Item file: \`<backlog dir>/${item.id}.md\` — the item file IS the spec (Surface, Interfaces, Out of scope, Acceptance).${item.answeredQuestion ? ` It still carries a \`blocked:\` key: that is the ANSWERED question /unblock left in place, and the answer is in the file. The item is runnable; do not escalate it as blocked.` : ''}${item.lint && item.lint !== 'pass' ? ` The spec gate says: ${item.lint} — if it is mechanical, fix it in your branch; if it is a real ambiguity, this item is blocked (below).` : ''}

Resume state from the start of the run (change nothing you were not told to): ${JSON.stringify(resume)}
If a worktree or an open PR already exists for ${item.id}, RESUME it — read its plan, its diff and its uncommitted files before writing a line, and continue from where it stopped. Never create a second worktree for the same item. If the worktree's test database was dropped, recreate it the way CLAUDE.md says; never discard uncommitted work.

${prior.length ? `Earlier items in this run reported (read for premises that changed under you — a merged item's claims rot within hours, so re-derive any line numbers or surfaces it moved from the code, never from the item file):\n${prior.map((p) => `- ${p.id}: ${p.summary}`).join('\n')}\n` : ''}
Order of work:
1. Pre-flight in the primary checkout: \`git fetch origin && git pull --ff-only\`; \`sweap-roadmap-lint <backlog dir>/${item.id}.md\` must pass.
2. Premises. Grep every file the item names and COUNT every number it states before building on it — every item in the last run had at least one stale premise. Implement what the item is FOR; record each discrepancy under the item's \`## Notes\`; never bend code to a stale premise. An acceptance clause no correct fix can satisfy makes the item blocked (below), not a hack.
3. Worktree (unless resuming): branch \`<fix|feat|test|refactor|chore|docs>/<id lower-cased, dot to dash>-<short-slug>\` from \`origin/<default branch>\`, at the worktree path CLAUDE.md or the playbook names for this project; then the project's install step (CLAUDE.md names it).
4. Plan to \`docs/superpowers/plans/\`, spec to \`docs/superpowers/specs/\`. TDD as the brief says; paste RED and GREEN. Verify with typecheck, lint, the formatter, the unit tests the change touches BY NAME (the e2e command may not run them) and the e2e specs you touched — not the full e2e suite (the brief names the only exceptions, and none applies while a CI job runs on this machine). Flip the item's \`status:\` to \`done\` in its own file on this branch.
5. Before committing, scan your added lines for \`every|all|only|never|both|<a number>\` and cut every claim you cannot check — that class was the blocking finding on nine of ten items last run.
6. Review. Commit locally, then dispatch \`subagent_type: "${PLUGIN_NAME}:reviewer"\` with ONLY the branch diff and the item file. Fix every confirmed finding. A re-review is a NEW dispatch with the new diff. At most 2 review rounds: after the second, cut the claims a remaining finding names rather than opening a third round, and note the remaining findings in your report. If the item carries \`review-dimensions: security\`, ALSO dispatch \`subagent_type: "${PLUGIN_NAME}:security-reviewer"\` — AFTER the standard reviewer has returned, never in parallel against this worktree — and tell it the worktree path, the base and the branch. A confirmed security finding blocks. If it carries \`ui\`, the ui-design skill's hard gates apply to you.
7. Before pushing, sweep the inboxes: any untracked file under the backlog's \`discovered/\` or \`ideas/\` rides along on this branch. Commit in one call. Push in its own call, plainly: \`git push -u origin <branch>\` and nothing else in that command.
8. \`gh pr create\` (never \`--repo\`/\`-R\`); the body ends with the line the playbook's worker brief names for PRs. Then return.

Blocked: when the spec is genuinely ambiguous, a premise is unsatisfiable, or a gate stays red after three DISTINCT root-cause attempts, set the item's \`status: blocked\` with the question verbatim in \`blocked:\` (keep \`## Spec\` and \`## Acceptance\`), land that flip through a normal PR on this branch, and return outcome \`blocked\` with the PR number and the question. Before escalating a symptom, grep the backlog's \`discovered/\` inbox for a prior note on it. Never \`status: attended\`; never guess.

Return the JSON only: outcome, pr, branch, worktree, red_green (verbatim), review_rounds, reviewer_verdict (verbatim), security_verdict, premises, notes_filed, question, report.`

const watchPrompt = (item, impl, previous) => `Watch PR #${impl.pr} for backlog item ${item.id} (branch \`${impl.branch}\`, worktree \`${impl.worktree}\`, base = the repository's default branch) with \`sweap-merge watch\`, exactly as your instructions say: foreground, bounded calls, loop until a terminal word, classify a red, verify after a merge.${previous ? ` Previous rounds on this PR: ${previous}` : ''} Return the report shape only.`

const fixPrompt = (item, impl, watch, rounds) => `${READ_FIRST} Then read the playbook between \`<!-- worker-brief:begin -->\` and \`<!-- worker-brief:end -->\`: that brief binds you.

You are the FIXER for PR #${impl.pr} (backlog item ${item.id}, branch \`${impl.branch}\`, worktree \`${impl.worktree}\`). The merge watcher reported \`failed\` with class \`${watch.class || '-'}\`: ${watch.reason}

Failure evidence (the failing job, tests and decisive log lines):
${watch.failure || '(none captured — collect it yourself: gh pr checks, gh run view <id> --log-failed)'}

${rounds.length ? `Earlier fix rounds on this PR, oldest first — a repeat of any of these is not a new attempt:\n${rounds.map((r, i) => `- round ${i + 1} (${r.outcome}): ${r.summary}`).join('\n')}\n` : ''}
Rules: work only in the worktree; a red check is a finding first — read the log before touching code; find the ROOT CAUSE; never edit, skip or quarantine a test to make it pass; a pre-existing test may change only with evidence of what the un-edited test does against the fix, put to the reviewer by name. Verify the fix at the layer that failed, by name; not the full e2e suite (the brief's exceptions only, and never while a CI job runs on this machine). If the class is \`starved\` (a job cancelled at its timeout with zero failing assertions): verify nothing heavy is running on this machine (\`pgrep -fl 'turbo|playwright|vitest'\` is empty), then re-arm with an EMPTY commit whose message says it re-arms after runner starvation and why; do not touch the diff. Commit in one call; push in its own call: \`git push origin ${impl.branch}\` and nothing else. Return \`pushed\`.
If after this round the same root cause has been tried three distinct ways across rounds, or the spec is the problem: set the item \`status: blocked\` with the question verbatim, commit and push that flip on this branch, and return \`blocked\` with the question. Return the JSON only.`

// ---------------------------------------------------------------------------
// The loop.
const merged = [], blocked = [], needsHuman = [], skipped = [], failed = []
const attempted = new Set()
const priorReports = []
let stopped = null

phase('Resume')
const resumed = await call(resumePrompt(), { label: 'resume', phase: 'Resume', schema: RESUME, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
if (!resumed.ok) return { merged, blocked, needs_human: needsHuman, skipped, failed, stopped: resumed.why }
const resume = resumed.value
if (resume.base_red) {
  // Every PR's rerun is refused while the base is red on the same workflow, and
  // redcheck does not see a push-event red; nothing below can make progress.
  return { merged, blocked, needs_human: needsHuman, skipped, failed, stopped: 'the default branch tip is red: rerun its failed job first (a flaky main stalls every PR)', resume }
}
log(`resume: ${resume.worktrees.length} worktree(s), ${resume.open_prs.length} open PR(s), ${resume.watches.length} armed watch(es)`)

let count = 0
while (count < MAX_ITEMS) {
  const scoped = await call(scopePrompt(IDS), { label: `scope #${count + 1}`, phase: 'Scope', schema: SCOPE, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
  if (!scoped.ok) { stopped = scoped.why; break }
  for (const m of (scoped.value.malformed || [])) if (!skipped.includes(m)) skipped.push(m)
  const item = (scoped.value.frontier || []).find((i) => i && i.id && !attempted.has(i.id))
  if (!item) { log(IDS ? 'batch exhausted' : 'frontier empty'); break }
  attempted.add(item.id)
  log(`item ${item.id} (${count + 1}${Number.isFinite(MAX_ITEMS) ? `/${MAX_ITEMS}` : ''})`)

  const implemented = await call(implementPrompt(item, resume, priorReports), { label: `implement ${item.id}`, phase: 'Implement', schema: IMPLEMENT, model: MODEL, agentType: 'general-purpose' })
  if (!implemented.ok) { stopped = `${item.id}: ${implemented.why}`; break }
  const impl = implemented.value
  priorReports.push({ id: item.id, summary: `${impl.outcome}${impl.pr ? ` PR #${impl.pr}` : ''}; premises: ${impl.premises || '-'}` })
  if (impl.outcome === 'blocked') blocked.push({ id: item.id, pr: impl.pr, question: impl.question })
  if (!impl.pr) {
    if (impl.outcome !== 'blocked') failed.push({ id: item.id, why: impl.report })
    count++
    continue
  }

  // The merge wait. A fresh watcher per round; a fresh fixer per red.
  const rounds = []
  let watch = null
  let previous = ''
  while (true) {
    const watched = await callWatcher(watchPrompt(item, impl, previous), { label: `watch #${impl.pr}`, phase: 'Merge', schema: WATCH })
    if (!watched.ok) { stopped = `${item.id}: ${watched.why}`; break }
    watch = watched.value
    if (watch.word === 'merged') break
    const fixable = watch.word === 'failed' && (watch.class === 'red' || watch.class === 'starved')
    if (!fixable || rounds.length >= MAX_FIX_ROUNDS) break
    const fixed = await call(fixPrompt(item, impl, watch, rounds), { label: `fix ${item.id} #${rounds.length + 1}`, phase: 'Fix', schema: FIX, model: MODEL, agentType: 'general-purpose' })
    if (!fixed.ok) { stopped = `${item.id}: ${fixed.why}`; break }
    rounds.push(fixed.value)
    if (fixed.value.outcome !== 'pushed') { if (fixed.value.outcome === 'blocked') blocked.push({ id: item.id, pr: impl.pr, question: fixed.value.question }); break }
    previous = `${rounds.length} fix round(s) pushed; last: ${fixed.value.summary}`
  }
  if (stopped) break

  const last = rounds[rounds.length - 1]
  if (watch && watch.word === 'merged' && impl.outcome === 'blocked') {
    // The PR was the blocked flip landing, not the item: it is already listed
    // under blocked; the human sees it once.
  } else if (watch && watch.word === 'merged') {
    merged.push({ id: item.id, pr: impl.pr, review_rounds: impl.review_rounds, fix_rounds: rounds.length, status_done: watch.status_done, cleanup: watch.cleanup })
  } else if (watch && watch.word === 'failed' && watch.class === 'base-red') {
    stopped = `${item.id}: PR #${impl.pr} is red on a workflow that is also red on the default branch — rerun main's failed job first`
    needsHuman.push({ id: item.id, pr: impl.pr, word: watch.word, class: watch.class, reason: watch.reason })
    break
  } else if (!(last && last.outcome === 'blocked')) {
    // attended (a real hold), held-by, behind with conflicts, timed_out,
    // undecidable, a gate deny, or a red that outlived three rounds: the PR
    // stays open for a person; the run moves to the next item.
    needsHuman.push({ id: item.id, pr: impl.pr, word: watch ? watch.word : '?', class: watch ? watch.class : '-', reason: watch ? watch.reason : '', fix_rounds: rounds.length, last_failure: watch ? (watch.failure || '') : '' })
  }
  count++
}

return {
  merged,
  blocked,
  needs_human: needsHuman,
  skipped,
  failed,
  stopped,
  attempted: [...attempted],
  next: stopped ? 'relaunch this workflow after the cause is cleared (a usage limit: after the reset; a red base: after its job is green); completed items replay from the journal' : (IDS ? 'batch drained' : 'frontier drained'),
}
