export const meta = {
  name: 'run',
  description: 'Drive runnable backlog items to the default branch one at a time: a fresh implementer per item, a small watcher for the merge wait, a fresh fixer per red',
  whenToUse: 'The run session invokes it instead of driving the per-item loop itself. Pass {ids: [...]} to drain a batch in a given order, {milestone: "F13"} to go on to that milestone\'s items (and any other milestone\'s follow-ups) once the batch is drained, {max_items: n} to bound the run, or nothing to drain the whole frontier in the playbook\'s pick order (follow-ups first, then numeric). It stops at a usage limit, an API death, a red base branch, a self-hosted runner fleet with nobody online (sweap-fleet), or when nothing it may pick is runnable, and returns what merged, what needs a human, and where it stopped. The session then runs /milestone-audit when a milestone completed and records .claude/sweap-run.md.',
  phases: [
    { title: 'Resume', detail: 'what an interrupted run left behind: worktrees, open PRs, armed watches, plans with unchecked steps' },
    { title: 'Scope', detail: 'sweap-frontier before every item — a merge changes what is runnable' },
    { title: 'Implement', detail: 'one fresh implementer per item; it exits when its branch is committed' },
    { title: 'Review', detail: 'a fresh reviewer the script dispatches (and a security reviewer when tagged), a fresh fixer per needs-work, then push and PR' },
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
// Arguments. An object, nothing, or a string: a JSON string is parsed (a model
// launching from a goal sentence has passed its args as a string before —
// consumer A 2026-09-02, milestone-audit; without this a '{"ids": [...]}' string
// would split into garbage ids and the run would end with nothing done), any
// other string is a comma list of ids. A string that looks like JSON but does
// not parse stops the run before the Resume stage, with the text.
const parseArgs = (a) => {
  if (Array.isArray(a)) return { ids: a }
  if (a && typeof a === 'object') return a
  if (typeof a !== 'string') return {}
  const t = a.trim()
  if (!t) return {}
  if (t.startsWith('{') || t.startsWith('[')) { try { return parseArgs(JSON.parse(t)) } catch (e) { return { bad_args: t } } }
  return { ids: t.split(/[,\s]+/).filter(Boolean) }
}
const ARGS = parseArgs(args)
// A bare array (the workflow-authoring reference's own example passes args as
// one) and an ids string ("DV.48, FP.2") are both batches, never a silent bare
// run of the whole frontier.
const RAW_IDS = typeof ARGS.ids === 'string' ? ARGS.ids.split(/[,\s]+/).filter(Boolean) : ARGS.ids
const IDS = Array.isArray(RAW_IDS) && RAW_IDS.length ? RAW_IDS.map(String) : null
const MAX_ITEMS = Number.isFinite(Number(ARGS.max_items)) && Number(ARGS.max_items) > 0 ? Number(ARGS.max_items) : Infinity
// The milestone the run is for. The frontier is backlog-wide (every runnable
// todo item, whatever its milestone): on consumer A on 2026-09-23 a bare launch
// listed F14.1 and five F15 items behind the F13 items, and the run's goal
// named F13. With a milestone, the run picks the batch first, then only that
// milestone's items and the follow-ups of OTHER milestones (the debt the goal
// drains first); a follow-up OF this milestone is the next run's debt (it can
// only exist once this milestone's audit ran) and is never picked FROM THE
// FRONTIER — the batch is trusted as the kickoff computed it.
const MILESTONE = typeof ARGS.milestone === 'string' && ARGS.milestone ? ARGS.milestone : null
// The implementer's model is named, never inherited: a workflow agent otherwise
// runs on the SESSION model, and the session that launches this is usually on
// the strongest tier for planning. Implementation grind is Opus per the
// playbook's "Model policy"; the cost basis of the memo is Opus subagents.
const MODEL = typeof ARGS.model === 'string' && ARGS.model ? ARGS.model : 'opus'
const SMALL_MODEL = typeof ARGS.small_model === 'string' && ARGS.small_model ? ARGS.small_model : 'sonnet'
const MAX_FIX_ROUNDS = 3
// Review rounds are counted apart from CI fix rounds: two reviews, and a
// needs-work after the second is answered by cutting the claims its findings
// name, never by a third round (the worker brief's rule).
const MAX_REVIEW_ROUNDS = 2
const PLUGIN_NAME = 'sweap'

// ---------------------------------------------------------------------------
// Pick order, computed HERE from the frontier the Scope agent returns — the
// script decides, the agent only runs the command. The Scope agent used to be
// asked to apply the batch order and to lint "the first item you return", and
// it could not know which item the script would pick: an item that failed
// without a PR stays first in the frontier but is already in `attempted`.
// milestoneOf mirrors sweap-board.lib.mjs (the script cannot import): the id
// minus its last dot-segment, so `DS.2.1` is milestone `DS.2`, not `DS`.
const milestoneOf = (id) => String(id).replace(/\.[^.]*$/, '')
const allowedFor = (item, milestone) => !milestone ? true : (item.followupOf ? item.followupOf !== milestone : milestoneOf(item.id) === milestone)
const pickOrder = (frontier, ids, milestone) => {
  const listed = (frontier || []).filter((i) => i && i.id).map((i) => ({ ...i, followupOf: i.followupOf || null }))
  const byId = new Map(listed.map((i) => [i.id, i]))
  const batch = ids ? ids.map((id) => byId.get(id)).filter(Boolean) : []
  const rest = (ids && !milestone) ? [] : listed.filter((i) => !(ids && ids.includes(i.id)) && allowedFor(i, milestone))
  return batch.concat(rest)
}

// An open PR for the item means the implementer already finished: the run was
// stopped (a usage wall, a dead fleet) between the PR opening and its merge.
// The item is still `todo` on the base (its flip rides in the PR), so the
// frontier lists it again; re-running an implementer against it would re-review
// the diff and fail `gh pr create` (the PR exists). Go straight to the watcher.
// The item is matched by the Resume agent's mapping OR by the branch name the
// implementer brief prescribes (`<type>/<id lower-cased, dot to dash>-<slug>`),
// anchored at the start so `chore/f13-6-wait-on-f13-20` is F13.6 and `ds-5-3-x`
// is DS.5.3, not DS.5.
const branchTail = (branch) => String(branch || '').toLowerCase().split('/').slice(1).join('/')
const branchIsFor = (branch, id) => {
  const tail = branchTail(branch)
  const base = String(id).toLowerCase().replace(/\./g, '-')
  return tail === base || (tail.startsWith(base + '-') && !/^\d/.test(tail.slice(base.length + 1)))
}
// A branch in the brief's shape names SOME item; when it is not this one, the
// Resume agent's `item` mapping for it is not trusted (a mis-mapped PR would
// send the watcher to another item's PR and record this item as merged).
const carriesAnId = (branch) => /^[a-z]+\d*(-\d+)+(-|$)/.test(branchTail(branch))
const pick = (list, id) => {
  const all = (list || []).filter(Boolean)
  return all.find((p) => branchIsFor(p.branch, id)) || all.find((p) => p.item === id && !carriesAnId(p.branch)) || null
}
const openPrFor = (resume, id) => {
  const pr = pick(resume && resume.open_prs, id)
  if (!pr) return null
  const wt = pick(resume && resume.worktrees, id)
  return { number: pr.number, branch: pr.branch, worktree: wt ? wt.path : '' }
}

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
    fleet: { enum: ['ok', 'fleet-down', 'unknown'], description: 'the verdict sweap-fleet printed' },
    fleet_reason: { type: 'string', description: 'the reason sweap-fleet printed, plus any deprecations entry (a runner version retiring within days)' },
    base: { type: 'string', description: 'the default branch name' },
    backlog_dir: { type: 'string', description: 'the backlog directory CLAUDE.md names (roadmap unless it says otherwise)' },
    notes: { type: 'string' },
  },
}

const SCOPE = {
  type: 'object',
  required: ['frontier'],
  properties: {
    frontier: { type: 'array', items: { type: 'object', required: ['id', 'followupOf'], properties: {
      id: { type: 'string' }, followupOf: { type: ['string', 'null'], description: 'the followupOf value as printed, null when absent' }, reviewDimensions: { type: 'array', items: { type: 'string' } },
      answeredQuestion: { type: ['string', 'null'] } } } },
    malformed: { type: 'array', items: { type: 'string' }, description: 'the malformed list as printed (item files whose id and filename disagree)' },
    command_missing: { type: 'boolean', description: 'true when sweap-frontier is not on PATH or did not run; the frontier is then empty for that reason, not because nothing is runnable' },
  },
}

const IMPLEMENT = {
  type: 'object',
  required: ['outcome', 'pr', 'branch', 'worktree', 'red_green', 'report'],
  properties: {
    outcome: { enum: ['committed', 'blocked', 'failed'] },
    pr: { type: ['number', 'null'], description: 'null when committed; the PR number of a blocked flip landed through a PR' },
    branch: { type: 'string' },
    worktree: { type: 'string', description: 'the absolute path of the worktree the branch is checked out in' },
    red_green: { type: 'string', description: 'the pasted RED then GREEN output, verbatim' },
    premises: { type: 'string', description: 'which item premises were verified against the code, which were stale, and what was done about each' },
    notes_filed: { type: 'array', items: { type: 'string' } },
    question: { type: ['string', 'null'], description: 'the blocking question, verbatim, when outcome is blocked' },
    report: { type: 'string' },
  },
}

const FINDINGS = { type: 'array', items: { type: 'object', required: ['file', 'what', 'kind'], properties: {
  file: { type: 'string', description: 'path, with :line when there is one' }, what: { type: 'string', description: 'what is wrong and why it matters' },
  kind: { enum: ['acceptance', 'security', 'other'], description: 'acceptance: the diff fails an acceptance clause of the item; security: access control, tenant isolation, data exposure, session or credential handling; other: everything else' } } } }
// A confirmed finding of these kinds is never cut to make an item "done": it is
// fixed and re-reviewed, or it becomes a question for a person (consumer A F13.13
// merged done with acceptance clause 6 unmet, cut after round two).
const UNCUTTABLE = new Set(['acceptance', 'security'])

const REVIEW = {
  type: 'object',
  required: ['verdict', 'findings', 'files_reviewed', 'verdict_line'],
  properties: {
    verdict: { enum: ['approve', 'needs-work'] },
    files_reviewed: { type: 'array', items: { type: 'string' }, description: 'the files the diff touches, as reviewed; empty when no diff could be collected' },
    findings: { ...FINDINGS, description: 'confirmed blocking findings only; empty on approve' },
    advisory: { type: 'string' },
    verdict_line: { type: 'string', description: 'the required final line, verbatim: "Verdict: approve" or "Verdict: needs-work"' },
  },
}

const SECURITY = {
  type: 'object',
  required: ['verdict', 'findings', 'files_reviewed', 'verdict_line'],
  properties: {
    verdict: { enum: ['clear', 'blocking', 'no-diff'], description: 'no-diff when no diff could be collected: that is not a clear' },
    findings: FINDINGS,
    files_reviewed: { type: 'array', items: { type: 'string' }, description: 'the files the diff touches, as reviewed' },
    verdict_line: { type: 'string' },
  },
}

const REVIEW_FIX = {
  type: 'object',
  required: ['outcome', 'summary'],
  properties: {
    outcome: { enum: ['committed', 'blocked', 'gave-up'] },
    summary: { type: 'string', description: 'per finding: fixed (how), cut (which claim), or disputed (the evidence)' },
    question: { type: ['string', 'null'], description: 'when blocked: the spec question a finding exposed, verbatim' },
  },
}

const PUBLISH = {
  type: 'object',
  required: ['outcome', 'pr', 'report'],
  properties: {
    outcome: { enum: ['pr-open', 'failed'] },
    pr: { type: ['number', 'null'] },
    branch: { type: 'string', description: 'the branch the PR is from (the flip stage names its own)' },
    worktree: { type: 'string' },
    report: { type: 'string' },
  },
}

const WATCH = {
  type: 'object',
  required: ['word', 'reason', 'pr', 'watch_calls'],
  properties: {
    word: { enum: ['merged', 'failed', 'behind', 'attended', 'held-by', 'timed_out', 'undecidable'] },
    class: { enum: ['gate', 'starved', 'base-red', 'red', 'fleet-down', '-'] },
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

// The watcher and the reviewers are plugin agents, addressable only under their
// SCOPED name in a plugin install and under their bare name in a local checkout
// — same probe as milestone-audit.js, memoized per agent after the first hit.
const pluginTypes = {}
const callPlugin = async (name, prompt, opts) => {
  const queue = [pluginTypes[name], `${PLUGIN_NAME}:${name}`, name].filter(Boolean)
  const tried = []
  let last = null
  while (queue.length) {
    const candidate = queue.shift()
    if (tried.includes(candidate)) continue
    tried.push(candidate)
    last = await call(prompt, { ...opts, agentType: candidate })
    if (last.ok || !/agent type .*not found|unknown agent/i.test(last.why)) { if (last.ok) pluginTypes[name] = candidate; return last }
  }
  return last || { ok: false, why: `${name} agent not found under any name` }
}
const callWatcher = (prompt, opts) => callPlugin('merge-watcher', prompt, opts)

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
- \`gh run list --branch <default branch> --limit 3 --json conclusion,name,status\` — base_red is true when the newest completed run of any workflow on the default branch is red or cancelled;
- \`sweap-fleet\` (on PATH with the plugin's bin/; if the command does not exist, fleet is \`unknown\` and say so; it EXITS 1 on fleet-down — that is the verdict, read the JSON) — copy its \`verdict\` into \`fleet\` and its \`reason\` (plus any \`deprecations\` entry) into \`fleet_reason\`.
Report the default branch name in \`base\` (\`gh repo view --json defaultBranchRef -q .defaultBranchRef.name\`) and the backlog directory CLAUDE.md's sweap config names in \`backlog_dir\`.
Map each worktree, PR and plan to the backlog item id it belongs to (the branch name carries the id in lower case with the dot as a dash, e.g. fix/du25-... is DU.25). Return the JSON only.`

const scopePrompt = () => `You are the SCOPE stage of an unattended run. Run \`sweap-frontier\` from the primary checkout (the sweap plugin's bin/ is on PATH; if the command is missing or fails, set \`command_missing\` true and return an empty frontier). It prints the runnable todo items in drain order as JSON. Return the frontier as printed, in its order, with each item's followupOf (null when it has none), and the malformed list as printed. Do not read the item files; do not filter, reorder or judge the items — the run decides what to pick. Return the JSON only.`

const implementPrompt = (item, resume, prior) => `${READ_FIRST} Then read the playbook between \`<!-- worker-brief:begin -->\` and \`<!-- worker-brief:end -->\`: that brief binds you.

You are the IMPLEMENTER for backlog item ${item.id}, and only that item. You drive it from its item file to a COMMITTED branch in its worktree, then you exit. You do not review, push, open the PR, merge or watch CI: after you return the run dispatches a fresh reviewer against your branch, a fixer per finding, and a watcher. You never run \`sweap-merge\`, never \`gh pr merge\`, never touch \`.github/\`, never commit in the primary checkout, never push to the default branch. Never dispatch an agent, never start the code-review or security-review skill, and never leave anything running in the background: whatever outlives your return is delivered to nobody, or wakes a second copy of you that writes into a branch the run is already reviewing (consumer A F13, 2026-09-25: four items came back failed and two PRs opened unreviewed this way).

Item file: \`<backlog dir>/${item.id}.md\` — the item file IS the spec (Surface, Interfaces, Out of scope, Acceptance).${item.answeredQuestion ? ` It still carries a \`blocked:\` key: that is the ANSWERED question /unblock left in place, and the answer is in the file. The item is runnable; do not escalate it as blocked.` : ''}

Resume state from the start of the run (change nothing you were not told to): ${JSON.stringify(resume)}
If a worktree already exists for ${item.id}, RESUME it — read its plan, its diff and its uncommitted files before writing a line, and continue from where it stopped; a branch that is already built and committed is simply returned as \`committed\`. Never create a second worktree for the same item. If the worktree's test database was dropped, recreate it the way CLAUDE.md says; never discard uncommitted work.

${prior.length ? `Earlier items in this run reported (read for premises that changed under you — a merged item's claims rot within hours, so re-derive any line numbers or surfaces it moved from the code, never from the item file):\n${prior.map((p) => `- ${p.id}: ${p.summary}`).join('\n')}\n` : ''}
Order of work:
1. Pre-flight in the primary checkout: \`git fetch origin && git pull --ff-only\`; \`sweap-roadmap-lint <backlog dir>/${item.id}.md\` must pass — if it fails on something mechanical, fix it in your branch; if it fails on a real ambiguity, this item is blocked (below).
2. Premises. Grep every file the item names and COUNT every number it states before building on it — every item in the last run had at least one stale premise. Implement what the item is FOR; record each discrepancy under the item's \`## Notes\`; never bend code to a stale premise. An acceptance clause no correct fix can satisfy makes the item blocked (below), not a hack.
3. Worktree (unless resuming): branch \`<fix|feat|test|refactor|chore|docs>/<id lower-cased, dot to dash>-<short-slug>\` from \`origin/<default branch>\`, at the worktree path CLAUDE.md or the playbook names for this project; then the project's install step (CLAUDE.md names it).
4. Plan to \`docs/superpowers/plans/\`, spec to \`docs/superpowers/specs/\`. TDD as the brief says; paste RED and GREEN. Verify with typecheck, lint, the formatter, the unit tests the change touches BY NAME (the e2e command may not run them) and the e2e specs you touched — not the full e2e suite (the brief names the only exceptions, and none applies while a CI job runs on this machine). Flip the item's \`status:\` to \`done\` in its own file on this branch.
5. Before committing, scan your added lines for \`every|all|only|never|both|<a number>\` and cut every claim you cannot check — that class was the blocking finding on nine of ten items last run.
6. If the item carries \`review-dimensions: ui\`, the ui-design skill's hard gates apply to you.
7. Sweep the inboxes: any untracked file under the backlog's \`discovered/\` or \`ideas/\` rides along on this branch. Commit in one call; \`git status --short\` must then print nothing (the reviewer sees only what is committed). Do not push. Return outcome \`committed\` with the worktree's absolute path.

Blocked: when the spec is genuinely ambiguous, a premise is unsatisfiable, or a gate stays red after three DISTINCT root-cause attempts, commit what you built so far on your branch and return outcome \`blocked\` with the question verbatim and \`pr\` null. Do not edit the item's status and do not push: the run lands the flip in a PR of its own, off the default branch, so no unreviewed code rides along. Before escalating a symptom, grep the backlog's \`discovered/\` inbox for a prior note on it. Never \`status: attended\`; never guess.

Return the JSON only: outcome, pr, branch, worktree, red_green (verbatim), premises, notes_filed, question, report.`

const wtOf = (impl) => impl.worktree || `(none known — before any git operation on this branch run \`git worktree add <the path CLAUDE.md or the playbook names for this project> ${impl.branch}\`; never use the primary checkout)`
const watchPrompt = (item, impl, previous) => `Watch PR #${impl.pr} for backlog item ${item.id} (branch \`${impl.branch}\`, worktree ${wtOf(impl)}, base = the repository's default branch) exactly as your instructions say: foreground, bounded calls of \`sweap-merge tick ${impl.pr} --budget 540\`, loop until a terminal word, classify a red (and a queued timeout against an empty fleet), verify after a merge.${previous ? ` Previous rounds on this PR: ${previous}` : ''} Return the report shape only.`

// The review stage. The reviewers run from the primary checkout (a workflow
// agent's cwd), so every prompt names the worktree, and the base and backlog
// directory as the Resume stage read them — never a placeholder (a watcher's
// `<n>` was copied literally as PR #1).
const CTX = { base: '<default branch>', backlog: '<backlog dir>' }
const slug = (id) => String(id).toLowerCase().replace(/\./g, '-')
const where = (item, impl) => `branch \`${impl.branch}\`, worktree \`${impl.worktree}\`, base \`origin/${CTX.base}\` (run \`git -C ${impl.worktree} fetch origin\` first; the diff is \`git -C ${impl.worktree} diff origin/${CTX.base}...HEAD\`). The item file is \`${CTX.backlog}/${item.id}.md\` INSIDE the worktree. Read every file at its worktree path, never the primary checkout's copy (the primary checkout is the default branch, and may carry uncommitted files that are not this item's)`
const reviewPrompt = (item, impl, rounds) => `Review backlog item ${item.id}: ${where(item, impl)}. Your input is ONLY that diff and the item file with the plan/spec the diff adds under docs/superpowers/. Run anything you run inside the worktree, and leave it as you found it.
${rounds.length ? `This is review round ${rounds.length + 1}: the branch changed since round ${rounds.length}; judge the diff as it is now, and say for each earlier finding whether it is closed.\nEarlier findings:\n${rounds.map((r, i) => r.findings.map((f) => `- round ${i + 1}: ${f.file}: ${f.what}`).join('\n')).join('\n')}\n` : ''}Report exactly as your instructions say, then return the JSON only: verdict, findings (confirmed blocking ones only), files_reviewed, advisory, verdict_line.`

const securityPrompt = (item, impl) => `Security-review backlog item ${item.id} (tagged \`review-dimensions: security\`): ${where(item, impl)}. Take that diff (and its \`--stat\`) yourself before anything else, then run the security-review skill; if its own diff collection comes back empty, apply its method by hand to the diff you took. No diff collected is the verdict \`no-diff\`, never \`clear\`. Leave the worktree as you found it. Return the JSON only: verdict, findings, files_reviewed, verdict_line.`

const reviewFixPrompt = (item, impl, findings, source, last) => `${READ_FIRST} Then read the playbook between \`<!-- worker-brief:begin -->\` and \`<!-- worker-brief:end -->\`: that brief binds you.

You are the REVIEW FIXER for backlog item ${item.id}: ${where(item, impl)}. The ${source} returned these confirmed findings:
${findings.map((f) => `- ${f.file}: ${f.what}`).join('\n')}

Work only in the worktree. For each finding: reproduce it first (a failing test, or the command that shows it); fix the root cause; or, if the evidence says it is wrong, record why — never weaken a test to close one. Never close an \`acceptance\` or \`security\` finding by cutting a claim, editing the item's acceptance, or recording it as a note: fix it, or show with evidence it is not real (the next reviewer judges that). ${last ? 'This is the LAST round, and none of these findings is an acceptance or security one: for any you cannot fix, cut the claim it names (in code, comments or the item Notes) rather than leave it standing, and list what remains. ' : ''}Verify at the layer each finding names, by name. Commit in one call; \`git status --short\` must then print nothing. Do not push, do not open a PR, never dispatch an agent or start a review skill, and leave nothing running in the background. If a finding shows the SPEC itself is wrong or ambiguous, return \`blocked\` with the question verbatim instead of guessing. Return the JSON only.`

const publishPrompt = (item, impl, review) => `Publish backlog item ${item.id}'s reviewed branch: ${where(item, impl)}.
1. Push in its own call, plainly: \`git -C ${impl.worktree} push -u origin ${impl.branch}\` and nothing else in that command.
2. If \`gh pr view ${impl.branch} --json number,state\` shows an OPEN PR for the branch, that is the PR: return its number. Otherwise, from the worktree, \`gh pr create\` (never \`--repo\`/\`-R\`): the title is the branch's first commit subject; the body summarises the change from \`git log\` and the diff stat, then states the review record below verbatim, and ends with the line the playbook's worker brief names for PRs.
Review record: ${review}
Return the JSON only: outcome \`pr-open\` with the PR number, or \`failed\` with what refused.`

// Every blocked outcome — the implementer's, a review fixer's, a security
// finding one fix round did not close — lands the same way: a flip-only PR off
// the default branch, so the item reads blocked (the frontier stops listing it,
// the goal can stop, /unblock accepts it) and no unreviewed code rides along.
// The item's work branch stays in its worktree for the resume after /unblock.
const flipPrompt = (item, question) => `Land a BLOCKED flip for backlog item ${item.id}, and nothing else. From the primary checkout: \`git fetch origin\`, then \`git worktree add <the worktree path CLAUDE.md or the playbook names for this project>-blocked -b chore/${slug(item.id)}-blocked origin/${CTX.base}\`. In that worktree edit ONLY \`${CTX.backlog}/${item.id}.md\`: \`status: blocked\` and a \`blocked:\` key holding the question below verbatim; keep every other key and section. Commit only that file (one call). Push in its own call, plainly: \`git push -u origin chore/${slug(item.id)}-blocked\`. Then \`gh pr create\` (never \`--repo\`/\`-R\`) titled \`chore(${item.id}): blocked — <the question, shortened>\`, the body stating the question verbatim and ending with the line the playbook's worker brief names for PRs. Never touch the item's work branch or its worktree.
Question: ${question}
Return the JSON only: outcome \`pr-open\` with the PR number, branch and worktree; or \`failed\` with what refused.`

// Review → fix → review, then security when tagged. A dead reviewer or fixer
// stops the run like any dead agent: nothing here is pushed without a verdict.
const reviewStage = async (item, impl) => {
  const rounds = []
  let lastFix = null
  for (let r = 1; r <= MAX_REVIEW_ROUNDS; r++) {
    const rev = await callPlugin('reviewer', reviewPrompt(item, impl, rounds), { label: `review ${item.id} #${r}`, phase: 'Review', schema: REVIEW, model: MODEL })
    if (!rev.ok) return { stop: `${item.id}: ${rev.why}` }
    // An approve over no files is the empty-diff trap (the security reviewer
    // fell in it twice, DV.47 and FP.1): a verdict about nothing.
    if (!(rev.value.files_reviewed || []).length) return { failed: 'the reviewer collected no diff — not a verdict' }
    rounds.push(rev.value)
    if (rev.value.verdict === 'approve') break
    const hard = rev.value.findings.filter((f) => UNCUTTABLE.has(f.kind))
    if (r === MAX_REVIEW_ROUNDS && hard.length) return { blocked: `After ${r} review rounds these confirmed findings are still open, and an acceptance or security finding is never cut (branch ${impl.branch}, unpushed, in ${impl.worktree}): ${hard.map((f) => `[${f.kind}] ${f.file}: ${f.what}`).join('; ')}. Say how to fix them, or change the item's acceptance, then /unblock.` }
    const fix = await call(reviewFixPrompt(item, impl, rev.value.findings, 'reviewer', r === MAX_REVIEW_ROUNDS), { label: `review-fix ${item.id} #${r}`, phase: 'Review', schema: REVIEW_FIX, model: MODEL, agentType: 'general-purpose' })
    if (!fix.ok) return { stop: `${item.id}: ${fix.why}` }
    lastFix = fix.value
    if (fix.value.outcome === 'blocked') return { blocked: fix.value.question || fix.value.summary }
    if (fix.value.outcome !== 'committed') return { failed: `review fixer gave up: ${fix.value.summary}` }
  }
  let security = null
  if ((item.reviewDimensions || []).includes('security')) {
    // A hard gate: one fix round and one re-check; a finding still open is the
    // human's, through a blocked flip.
    const check = async (r) => callPlugin('security-reviewer', securityPrompt(item, impl), { label: `security ${item.id} #${r}`, phase: 'Review', schema: SECURITY, model: MODEL })
    let sec = await check(1)
    if (!sec.ok) return { stop: `${item.id}: ${sec.why}` }
    if (sec.value.verdict === 'blocking') {
      const fix = await call(reviewFixPrompt(item, impl, sec.value.findings, 'security reviewer', false), { label: `security-fix ${item.id}`, phase: 'Review', schema: REVIEW_FIX, model: MODEL, agentType: 'general-purpose' })
      if (!fix.ok) return { stop: `${item.id}: ${fix.why}` }
      if (fix.value.outcome === 'committed') { sec = await check(2); if (!sec.ok) return { stop: `${item.id}: ${sec.why}` } }
    }
    security = sec.value
    if (security.verdict === 'no-diff') return { failed: 'the security reviewer collected no diff — not a verdict' }
    if (security.verdict === 'blocking') return { blocked: `A confirmed security finding is still open after one fix round (branch ${impl.branch}, unpushed, in ${impl.worktree}): ${security.findings.map((f) => `${f.file}: ${f.what}`).join('; ')}. Fix it or record why the risk is accepted, then /unblock.` }
  }
  const lastRev = rounds[rounds.length - 1]
  const remaining = lastRev.verdict === 'needs-work' && lastFix ? ` Remaining after the last round (answered by its fixer): ${lastFix.summary}` : ''
  return { ok: true, review_rounds: rounds.length, record: `${rounds.length} review round(s); last: ${lastRev.verdict_line}.${security ? ` ${security.verdict_line}.` : ''}${remaining}` }
}

const fixPrompt = (item, impl, watch, rounds) => `${READ_FIRST} Then read the playbook between \`<!-- worker-brief:begin -->\` and \`<!-- worker-brief:end -->\`: that brief binds you.

You are the FIXER for PR #${impl.pr} (backlog item ${item.id}, branch \`${impl.branch}\`, worktree ${wtOf(impl)}). The merge watcher reported \`failed\` with class \`${watch.class || '-'}\`: ${watch.reason}

Failure evidence (the failing job, tests and decisive log lines):
${watch.failure || '(none captured — collect it yourself: gh pr checks, gh run view <id> --log-failed)'}

${rounds.length ? `Earlier fix rounds on this PR, oldest first — a repeat of any of these is not a new attempt:\n${rounds.map((r, i) => `- round ${i + 1} (${r.outcome}): ${r.summary}`).join('\n')}\n` : ''}
Rules: work only in the worktree; a red check is a finding first — read the log before touching code; find the ROOT CAUSE; never edit, skip or quarantine a test to make it pass; a pre-existing test may change only with evidence of what the un-edited test does against the fix, put to the reviewer by name. Verify the fix at the layer that failed, by name; not the full e2e suite (the brief's exceptions only, and never while a CI job runs on this machine). If the class is \`starved\` (a job cancelled at its timeout with zero failing assertions): verify nothing heavy is running on this machine (\`pgrep -fl 'turbo|playwright|vitest'\` is empty), then re-arm with an EMPTY commit whose message says it re-arms after runner starvation and why; do not touch the diff. Commit in one call; push in its own call: \`git push origin ${impl.branch}\` and nothing else. Return \`pushed\`.
If after this round the same root cause has been tried three distinct ways across rounds, or the spec is the problem: set the item \`status: blocked\` with the question verbatim, commit and push that flip on this branch, and return \`blocked\` with the question. Return the JSON only.`

// ---------------------------------------------------------------------------
// The loop.
const merged = [], blocked = [], needsHuman = [], failed = [], malformed = []
const attempted = new Set()
const priorReports = []
let stopped = null
if (ARGS.bad_args) return { merged, blocked, needs_human: needsHuman, skipped: [], failed, stopped: `args was a string that is not valid JSON — pass an object: ${ARGS.bad_args.slice(0, 200)}` }

phase('Resume')
const resumed = await call(resumePrompt(), { label: 'resume', phase: 'Resume', schema: RESUME, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
if (!resumed.ok) return { merged, blocked, needs_human: needsHuman, skipped: IDS || [], failed, stopped: resumed.why }
const resume = resumed.value
if (resume.base_red) {
  // Every PR's rerun is refused while the base is red on the same workflow, and
  // redcheck does not see a push-event red; nothing below can make progress.
  return { merged, blocked, needs_human: needsHuman, skipped: IDS || [], failed, stopped: 'the default branch tip is red: rerun its failed job first (a flaky main stalls every PR)', resume }
}
if (resume.fleet === 'fleet-down') {
  // Nobody is there to run the jobs. An implementer would open a PR that
  // cannot test and the watcher would time out 99 minutes later — per item,
  // for as long as the fleet is down (consumer A 2026-09-24: three items).
  return { merged, blocked, needs_human: needsHuman, skipped: IDS || [], failed, stopped: `the self-hosted runner fleet cannot run CI: ${resume.fleet_reason || 'sweap-fleet says fleet-down'} — bring the runners back (sweap-fleet prints ok), then relaunch`, resume }
}
if (resume.base) CTX.base = resume.base
if (resume.backlog_dir) CTX.backlog = resume.backlog_dir
log(`resume: ${resume.worktrees.length} worktree(s), ${resume.open_prs.length} open PR(s), ${resume.watches.length} armed watch(es)${resume.fleet && resume.fleet !== 'ok' ? `, fleet ${resume.fleet}` : ''}`)

let count = 0
while (count < MAX_ITEMS) {
  const scoped = await call(scopePrompt(), { label: `scope #${count + 1}`, phase: 'Scope', schema: SCOPE, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
  if (!scoped.ok) { stopped = scoped.why; break }
  // An empty frontier because the command did not run is not "drained": the
  // goal would send the session to the milestone audit on nothing.
  if (scoped.value.command_missing) { stopped = 'sweap-frontier is not on PATH or failed (is the sweap plugin enabled for this project?)'; break }
  for (const m of (scoped.value.malformed || [])) if (!malformed.includes(m)) malformed.push(m)
  const item = pickOrder(scoped.value.frontier, IDS, MILESTONE).find((i) => !attempted.has(i.id))
  if (!item) { log(MILESTONE ? `nothing runnable for ${MILESTONE}${IDS ? ' or in the batch' : ''}` : (IDS ? 'batch exhausted' : 'frontier empty')); break }
  attempted.add(item.id)
  log(`item ${item.id} (${count + 1}${Number.isFinite(MAX_ITEMS) ? `/${MAX_ITEMS}` : ''})`)

  let impl
  const already = openPrFor(resume, item.id)
  if (already) {
    log(`item ${item.id}: PR #${already.number} is already open — straight to the watcher`)
    impl = { outcome: 'pr-open', pr: already.number, branch: already.branch, worktree: already.worktree, resumed: true, red_green: '', review_rounds: null, report: `resumed open PR #${already.number}` }
  } else {
    const implemented = await call(implementPrompt(item, resume, priorReports), { label: `implement ${item.id}`, phase: 'Implement', schema: IMPLEMENT, model: MODEL, agentType: 'general-purpose' })
    if (!implemented.ok) { stopped = `${item.id}: ${implemented.why}`; break }
    impl = implemented.value
  }
  priorReports.push({ id: item.id, summary: `${impl.outcome}${impl.pr ? ` PR #${impl.pr}` : ''}; premises: ${impl.premises || '-'}` })
  let question = impl.outcome === 'blocked' ? (impl.question || impl.report) : null
  if (impl.outcome === 'committed') {
    // The script awaits the review the implementer used to dispatch itself and
    // could not (consumer A F13: four items failed with finished work, two PRs
    // opened unreviewed — the Agent tool comes and goes inside a workflow agent
    // and the code-review fallback forks into the background).
    if (!/^\//.test(impl.worktree || '') || !impl.branch) { failed.push({ id: item.id, why: `committed without an absolute worktree path and a branch (${impl.worktree || '-'}, ${impl.branch || '-'}): nothing to review` }); count++; continue }
    const reviewed = await reviewStage(item, impl)
    if (reviewed.stop) { stopped = reviewed.stop; break }
    if (reviewed.failed) { failed.push({ id: item.id, why: `${reviewed.failed} (branch ${impl.branch} committed, unpushed, in ${impl.worktree})` }); count++; continue }
    if (reviewed.blocked) question = reviewed.blocked
    else {
      const published = await call(publishPrompt(item, impl, reviewed.record), { label: `publish ${item.id}`, phase: 'Review', schema: PUBLISH, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
      if (!published.ok) { stopped = `${item.id}: ${published.why}`; break }
      if (published.value.outcome !== 'pr-open' || !published.value.pr) { failed.push({ id: item.id, why: `reviewed but not published: ${published.value.report}` }); count++; continue }
      impl = { ...impl, outcome: 'pr-open', pr: published.value.pr, review_rounds: reviewed.review_rounds }
    }
  }
  if (question !== null) {
    let pr = impl.outcome === 'blocked' ? impl.pr : null
    if (!pr) {
      const flipped = await call(flipPrompt(item, question), { label: `flip ${item.id}`, phase: 'Review', schema: PUBLISH, model: SMALL_MODEL, effort: 'low', agentType: 'general-purpose' })
      if (!flipped.ok) { stopped = `${item.id}: ${flipped.why}`; break }
      if (flipped.value.outcome === 'pr-open' && flipped.value.pr) { pr = flipped.value.pr; impl = { outcome: 'blocked', pr, branch: flipped.value.branch || `chore/${slug(item.id)}-blocked`, worktree: flipped.value.worktree || '' } }
      else question = `${question} (the blocked flip did not land: ${flipped.value.report})`
    }
    blocked.push({ id: item.id, pr, question })
    if (!pr) { count++; continue }
  }
  if (!impl.pr) {
    if (impl.outcome !== 'blocked') failed.push({ id: item.id, why: impl.report })
    count++
    continue
  }

  // The merge wait. A fresh watcher per round; a fresh fixer per red.
  const rounds = []
  let watch = null
  let previous = ''
  let watchMismatch = 0
  while (true) {
    const watched = await callWatcher(watchPrompt(item, impl, previous), { label: `watch #${impl.pr}`, phase: 'Merge', schema: WATCH })
    if (!watched.ok) { stopped = `${item.id}: ${watched.why}`; break }
    watch = watched.value
    // A report about another PR is no word about this one (`tick 1` answered
    // `merged` for PR #1 on ~23 of 27 consumer A dispatches, 2026-09-23..25).
    if (watch.pr !== impl.pr) {
      if (watchMismatch++) { watch = { ...watch, word: 'undecidable', class: '-', reason: `the watcher reported PR #${watch.pr}, not PR #${impl.pr}, twice` }; break }
      previous = `${previous ? previous + ' ' : ''}Your last report was about PR #${watch.pr}; this dispatch is PR #${impl.pr} — tick exactly \`sweap-merge tick ${impl.pr}\`.`
      continue
    }
    if (watch.word === 'merged') break
    const fixable = watch.word === 'failed' && (watch.class === 'red' || watch.class === 'starved')
    if (!fixable || rounds.length >= MAX_FIX_ROUNDS) break
    const fixed = await call(fixPrompt(item, impl, watch, rounds), { label: `fix ${item.id} #${rounds.length + 1}`, phase: 'Fix', schema: FIX, model: MODEL, agentType: 'general-purpose' })
    if (!fixed.ok) { stopped = `${item.id}: ${fixed.why}`; break }
    rounds.push(fixed.value)
    if (fixed.value.outcome !== 'pushed') { if (fixed.value.outcome === 'blocked') blocked.push({ id: item.id, pr: impl.pr, question: fixed.value.question }); break }
    previous = `${rounds.length} fix round(s) pushed; last: ${fixed.value.summary}`
    watchMismatch = 0
  }
  if (stopped) break

  const last = rounds[rounds.length - 1]
  if (watch && watch.word === 'merged' && impl.outcome === 'blocked') {
    // The PR was the blocked flip landing, not the item: it is already listed
    // under blocked; the human sees it once.
  } else if (watch && watch.word === 'merged' && watch.status_done === 'no') {
    // Merged without the item reading done on the base: a resumed PR's blocked
    // flip, or a flip an implementer forgot or a fixer's cut dropped. Either way
    // not "merged", and not a guess at "blocked": a person reads the item file
    // (a forgotten flip would otherwise get a fresh implementer against a
    // merged PR on the next relaunch).
    needsHuman.push({ id: item.id, pr: impl.pr, word: 'merged', class: '-', reason: 'merged without the item reading done on the base: a blocked flip, or a forgotten flip — read the item file' })
  } else if (watch && watch.word === 'merged') {
    merged.push({ id: item.id, pr: impl.pr, review_rounds: impl.review_rounds, fix_rounds: rounds.length, status_done: watch.status_done, cleanup: watch.cleanup })
  } else if (watch && watch.word === 'failed' && watch.class === 'base-red') {
    stopped = `${item.id}: PR #${impl.pr} is red on a workflow that is also red on the default branch — rerun main's failed job first`
    needsHuman.push({ id: item.id, pr: impl.pr, word: watch.word, class: watch.class, reason: watch.reason })
    break
  } else if (watch && watch.word === 'timed_out' && watch.class === 'fleet-down') {
    // The queue is not slow, it is unattended: no online runner carries the
    // labels the queued jobs need. The PR is fine and resumes on relaunch (see
    // openPrFor); the run is simply not over, so nobody is listed as owing it.
    stopped = `${item.id}: PR #${impl.pr} is queued and no online runner can take it — ${watch.reason}; bring the self-hosted fleet back (sweap-fleet prints ok), then relaunch`
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
  // Batch ids the run never attempted: not runnable at any scope it ran (done,
  // blocked, deferred, attended, a dependency unmet, unknown to the frontier)
  // — or, when `stopped` is set, simply not reached before the stop.
  skipped: IDS ? IDS.filter((id) => !attempted.has(id)) : [],
  malformed,
  failed,
  stopped,
  attempted: [...attempted],
  // A relaunch is a FRESH launch, not a journal resume: the frontier is live,
  // so merged items are not picked again, and the Resume stage must run live
  // to see what the stop left behind (a resumed run would replay the first
  // launch's Resume result and hand the next implementer stale state).
  next: stopped ? 'relaunch this workflow fresh, with the same arguments, after the cause is cleared and verified gone (a usage limit: after the reset; a red base: after its job is green; a dead fleet: after sweap-fleet prints ok)' : (MILESTONE ? `batch and ${MILESTONE} frontier drained` : (IDS ? 'batch drained' : 'frontier drained')),
}
