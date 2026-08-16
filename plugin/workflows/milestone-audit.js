export const meta = {
  name: 'milestone-audit',
  description: 'Adversarial cross-feature audit of a merged milestone (finders → refuters → confirmed findings)',
  whenToUse: 'After the last item of a milestone merges, before the next milestone brainstorm. Pass {range: "<base>..<head>", milestone: "F#"} (a bare milestone-id string is also accepted, e.g. "F6") or omit args and let the Scope stage infer the range from the item files at status: done under backlog.dir (roadmap/ by default; backlog.file is the index). The workflow throws if the resolved milestone does not match a requested one — it never silently falls back to auditing whatever merged most recently.',
  phases: [
    { title: 'Scope', detail: 'map the milestone surface (tables, routes, server fns) and resolve audit.lenses' },
    { title: 'Find', detail: 'one finder per lens over the merged whole' },
    { title: 'Refute', detail: 'three read-only refuters per finding; 2 refutations kill' },
    { title: 'Validate', detail: 'sandboxed run of the named experiment, only for findings reading could not settle' },
  ],
}

const FINDINGS = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'file', 'severity', 'claim', 'evidence'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string', description: 'repo-relative path, plus :line when known' },
          severity: { enum: ['critical', 'high', 'medium', 'low'] },
          claim: { type: 'string', description: 'the precise defect claim, falsifiable' },
          evidence: { type: 'string', description: 'code excerpts / reasoning that support the claim' },
        },
      },
    },
  },
}

// THREE-VALUED, deliberately. A binary `refuted` forces a judge that lacks the
// evidence to guess, and the prompt then decides which way it guesses — which is
// how a capability limit ("I can't run this") silently becomes a claim about the
// code ("this isn't a defect"). Binary grading makes guessing strictly better
// than abstaining for the grader (Kalai et al. 2025), and the field's answer for
// this exact shape is a third label: FEVER's SUPPORTED / REFUTED / NOT ENOUGH
// INFO exists because binary was found inadequate for "the evidence doesn't
// settle it". `stands` and `unverifiable` are epistemically opposite — "I read
// it hard and could not break it" vs "I could not look" — and collapsing them
// destroys the routing signal that tells a human which findings need a test run.
const VERDICT = {
  type: 'object',
  required: ['verdict', 'reason'],
  properties: {
    verdict: {
      enum: ['refuted', 'stands', 'unverifiable'],
      description:
        "'refuted' = a positive, code-grounded disproof (cite it). 'stands' = you read it thoroughly and could not break it. 'unverifiable' = reading alone cannot settle this; only running something would.",
    },
    reason: { type: 'string' },
    experiment: {
      type: 'string',
      description:
        "REQUIRED when verdict is 'unverifiable': the specific command or test that would settle the claim. An 'unverifiable' naming no experiment is counted as 'stands', so abstaining is never the cheap way out.",
    },
  },
}

// The Validate stage's verdict — same shape of question, but earned by running
// something rather than by reading, which is the entire point of that stage.
const PROOF = {
  type: 'object',
  required: ['verdict', 'evidence'],
  properties: {
    verdict: { enum: ['refuted', 'confirmed', 'unverifiable'] },
    evidence: { type: 'string', description: 'the command actually run and its actual output, pasted' },
    reason: { type: 'string' },
  },
}

// The audit exists to catch what per-PR review structurally cannot:
// cross-feature interactions, systemic patterns, and plan-level mistakes.
//
// Generic, domain-free default lenses. Projects extend via `audit.lenses` in
// the CLAUDE.md `## sweap config` block (e.g. "default + [x, y]").
// Keys match the playbook's "How this project is configured" listing
// (correctness, authz/security, data-integrity, concurrency/races,
// test-integrity, api-contract) — keep them in sync if either changes.
const DEFAULT_LENSES = [
  { key: 'correctness',    prompt: 'Audit the merged milestone for logic errors: off-by-one, wrong conditionals, unhandled return values, contract mismatches between callers and callees across the milestone surface.' },
  { key: 'authz',          prompt: 'Audit authorization at every server entry point: writes gated by the project permission model; checks that gate the UI but not the server call; roles reaching data they should not.' },
  { key: 'data-integrity', prompt: 'Audit data lifecycle as one system: create/update/archive/delete interactions with search, pagination, and references; uniqueness under concurrent writes; orphaned rows after delete.' },
  { key: 'concurrency',    prompt: 'Audit races and ordering: last-response-wins / stale-write races on the client, non-idempotent handlers, unguarded read-modify-write, request N breaking state set by request N-1.' },
  { key: 'test-integrity', prompt: 'Audit the tests themselves: assertions weakened to pass, tests that never exercise the claimed behavior, skipped/quarantined tests, e2e that asserts nothing observable.' },
  { key: 'api-contract',   prompt: 'Audit public contracts: response shape changes, breaking param changes, error mapping, backward-compat of anything the milestone touched that other features consume.' },
]

// Schema for the Scope stage's lens-resolution agent (below). It reads
// `audit.lenses` from the consuming project's `## sweap config` block in
// CLAUDE.md and reports how to build this run's lens set:
//   - absent, or the literal string 'default'  -> mode 'default': use
//     DEFAULT_LENSES only.
//   - 'default + [x, y, ...]'                  -> mode 'default-plus': use
//     DEFAULT_LENSES PLUS a project-authored lens stub for each named extra
//     (x, y, ...), each drafted by this Scope agent from the milestone
//     surface — never removes the defaults.
//   - an explicit list with no 'default' token -> mode 'explicit': use ONLY
//     the named lenses (drafted the same way); the generic defaults are
//     skipped entirely for this run.
const LENS_CONFIG = {
  type: 'object',
  required: ['mode'],
  properties: {
    mode: { enum: ['default', 'default-plus', 'explicit'] },
    lenses: {
      type: 'array',
      description: 'Extra/explicit lens stubs. Empty for mode "default". Populated for "default-plus" (appended to DEFAULT_LENSES) and "explicit" (used in place of DEFAULT_LENSES).',
      items: {
        type: 'object',
        required: ['key', 'prompt'],
        properties: {
          key: { type: 'string' },
          prompt: { type: 'string', description: 'a concrete audit instruction for this lens, drafted from the milestone surface and the project code — not a generic placeholder' },
        },
      },
    },
  },
}

// Loose-equality helper for milestone ids: an LLM-formatted scope response
// can drift ("Milestone F6", trailing whitespace, case) without actually
// naming a different milestone. Trim, case-fold, and strip a leading
// "milestone " label before comparing — genuinely different ids still
// compare unequal.
const normalizeMilestoneId = (id) =>
  typeof id === 'string' ? id.trim().toLowerCase().replace(/^milestone\s+/, '') : id

// args is either an object {range, milestone}, a bare string (treated as the
// requested milestone id, e.g. "F6"), or absent/null. A bare string that
// LOOKS like it embeds a range (contains ".." or the word "range") or looks
// like a serialized object/array (starts with "{" or "[") is almost
// certainly a caller that meant to pass {range: "...", milestone: "..."} as
// an object and stringified it by mistake — silently falling back to "most
// recently completed milestone" in that case is exactly how a 2026-07 run
// audited the prior milestone (DS.4) and reported the newly-shipped one (F6)
// clean. Fail loudly instead of guessing.
if (typeof args === 'string' && /\.\.|range|^\s*[[{]/i.test(args)) {
  throw new Error(
    `milestone-audit: pass args as an object {range: "...", milestone: "F#"} — got a string: ${JSON.stringify(args)}`
  )
}

const requestedMilestone = typeof args === 'string' ? args : (args?.milestone ?? null)
const range = typeof args === 'string' ? null : (args?.range ?? null)
const milestone = requestedMilestone ?? 'the most recently completed milestone'

const SCOPE = {
  type: 'object',
  required: ['milestone', 'range', 'summary'],
  properties: {
    milestone: { type: 'string', description: 'the milestone id actually resolved, e.g. "F6"' },
    range: { type: 'string', description: 'the resolved commit range, "<base>..<head>"' },
    summary: {
      type: 'string',
      description: 'the prose surface map: changed files grouped by area (db schema/migrations, server fns, routes, tests), new tables, new permission actions, and the acceptance criteria copied from its item files',
    },
  },
}

phase('Scope')
const scope = await agent(
  `In this repo, determine the merged commit range and surface for ${milestone}.` +
    (range ? ` Use the range ${range}.` : ` Infer the range from the milestone's item files at status: done (their merge PR links) and git log --oneline --merges.`) +
    ` Return: the milestone id you actually resolved, the range, and a summary covering the list of changed files grouped by area (db schema/migrations, server fns, routes, tests), new tables, new permission actions, and the milestone's acceptance criteria copied from its item files.`,
  { label: 'scope', phase: 'Scope', schema: SCOPE }
)

if (requestedMilestone && normalizeMilestoneId(scope?.milestone) !== normalizeMilestoneId(requestedMilestone)) {
  throw new Error(
    `milestone-audit: requested milestone "${requestedMilestone}" but the Scope stage resolved "${scope?.milestone}" — refusing to audit the wrong milestone.`
  )
}

log(`scope resolved: milestone=${scope?.milestone} range=${scope?.range}`)

const scopeHeader = `Milestone ${scope?.milestone} (range ${scope?.range}):\n`
const scopeSummary = scopeHeader + (scope?.summary ?? '')

const lensConfig = await agent(
  `Read the '## sweap config' block in this project's CLAUDE.md and find the 'audit.lenses' key.\n` +
    ` - If the key is absent, or set to the literal string 'default': return mode 'default' and an empty lenses array.\n` +
    ` - If set to 'default + [x, y, ...]': return mode 'default-plus'; for each named extra (x, y, ...) draft a lens {key, prompt} — a concrete audit instruction for that domain concern, grounded in this project's actual code/specs and the milestone scope below (not a generic placeholder).\n` +
    ` - If set to an explicit list with no 'default' token: return mode 'explicit' and draft a lens {key, prompt} for each named entry the same way — these REPLACE the generic defaults for this run.\n\n` +
    `Milestone scope (from a prior mapping agent):\n${scopeSummary}`,
  { label: 'lens-config', phase: 'Scope', schema: LENS_CONFIG }
)

const LENSES = (() => {
  const extra = lensConfig?.lenses ?? []
  if (lensConfig?.mode === 'default-plus') return [...DEFAULT_LENSES, ...extra]
  if (lensConfig?.mode === 'explicit') return extra.length ? extra : DEFAULT_LENSES
  return DEFAULT_LENSES
})()

// READ-ONLY IS A TOOLSET, NOT A SENTENCE. Every Find/Refute agent runs as
// `audit-reader` (agents/audit-reader.md: Read, Grep, Glob — no Write, no Edit,
// no Bash). Before this, the audit was documented read-only in the playbook and
// in commands/milestone-audit.md, but both of those are addressed to the CALLING
// SESSION: the finders and refuters never see them, their prompts said nothing
// about writing, and they ran with the default workflow toolset. A refuter in a
// consumer repo duly wrote `zz-refute-error-slot.test.tsx` into the human's
// primary checkout to settle a claim empirically (2026-08-16) — doing exactly
// what "or show the scenario cannot occur" invited, with the tools it was handed.
// If you add a stage here, give it an agentType too, or say plainly in the docs
// that it is not read-only. Never restore an unrestricted agent behind a prose
// promise. (Scope, above, genuinely needs Bash for `git log` and is therefore
// NOT mechanically constrained — that limit is documented, not hidden.)
const NO_WRITES =
  `\n\nYou are read-only: you have Read, Grep and Glob, and no way to run or write anything. ` +
  `This audit reads merged code in someone's live checkout, so a file you create is one they find later and cannot attribute to anybody. ` +
  `If a claim can only be settled by running something, say so in your answer rather than approximating it — never report an experiment you did not perform.`

// TALLY-START — the vote arithmetic, kept as one pure function between these
// markers because milestone-audit.test.mjs EXTRACTS and evaluates it. A Workflow
// script runs against injected globals with no module access, so it cannot be
// imported and this cannot be a shared file; extraction is how the arithmetic
// gets real behavioural coverage instead of a grep. Keep the markers, keep it
// pure, and keep it free of closure references.
const tally = (verdicts) => {
  const votes = (verdicts || []).filter(Boolean)
  // An abstention naming no experiment is not an abstention, it is a shrug —
  // and if shrugging counted, it would be the cheapest move on the board.
  // Demote it to 'stands' so abstaining keeps a price (the same forcing function
  // that makes a finder state why its own candidate might not be real).
  const verdictOf = (v) =>
    v.verdict === 'unverifiable' && !String(v.experiment ?? '').trim() ? 'stands' : v.verdict
  const refuted = votes.filter((v) => verdictOf(v) === 'refuted').length
  const abstained = votes.filter((v) => verdictOf(v) === 'unverifiable')
  // FIXED threshold of 2 — never renormalised to "a majority of votes cast".
  // Renormalising would let two abstentions promote the third refuter to a
  // majority of one, handing a single voter a veto exactly when the panel is
  // least informed: the PR #8 bug in a new costume. Abstentions and LOST votes
  // are handled identically — excluded from the numerator, threshold unchanged.
  // That is the learning-with-rejection result (an abstaining voter leaves the
  // covered set) and the Nitzan-Paroush one (a voter at p≈0.5 carries weight
  // zero, not a vote in either direction).
  const killed = refuted >= 2
  // Reading ran out only when the panel MOSTLY abstained. One abstention against
  // two substantive reads is not a stalemate and is not worth a sandbox.
  const needsProof = !killed && abstained.length >= 2
  return {
    confirmed: !killed,
    needsProof,
    experiment: abstained.find((v) => String(v.experiment ?? '').trim())?.experiment ?? null,
  }
}
// TALLY-END

const found = await pipeline(
  LENSES,
  (lens) =>
    agent(
      `${lens.prompt}\n\nMilestone scope (from a prior mapping agent):\n${scopeSummary}\n\nRead the actual code before claiming anything. Only report findings you can support with specific code evidence. No style nits — defects only.` +
        NO_WRITES,
      { label: `find:${lens.key}`, phase: 'Find', schema: FINDINGS, effort: 'high', agentType: 'audit-reader' }
    ),
  (result, lens) =>
    parallel(
      (result?.findings ?? []).map((f) => () =>
        parallel(
          // 3 refuters so "majority kills" is a real vote: a finding dies only
          // when >=2 of 3 refute it. With 2 refuters, one uncertain dissenter
          // silently killed true positives (review finding, PR #8).
          [1, 2, 3].map((i) => () =>
            agent(
              `Adversarially REFUTE this audit finding about this codebase. Read the code at ${f.file} and its callers/tests yourself. Finding (lens ${lens.key}, severity ${f.severity}): ${f.title}\nClaim: ${f.claim}\nEvidence given: ${f.evidence}\n\nReturn exactly one of three verdicts.\n` +
                `- 'refuted' — you found a POSITIVE, code-grounded disproof: the guard/test/permission check the finder missed, or code showing the scenario cannot occur. Cite it (path:line). Refuting requires evidence; it is not the default and it is not where uncertainty goes.\n` +
                `- 'stands' — you read it thoroughly, including callers and tests, and could not break it.\n` +
                `- 'unverifiable' — reading alone cannot settle this; only running something would. Name that exact command or test in the 'experiment' field. An 'unverifiable' with no experiment named is counted as 'stands', so do not use it as a shrug.\n\n` +
                `Do NOT return 'refuted' because you are unsure. "I cannot verify this" is a fact about your tools, not about the code, and turning it into a refutation is how a real defect gets killed by a capability limit.` +
                NO_WRITES,
              { label: `refute${i}:${f.title.slice(0, 30)}`, phase: 'Refute', schema: VERDICT, effort: 'high', agentType: 'audit-reader' }
            )
          )
        ).then((verdicts) => ({ ...f, lens: lens.key, ...tally(verdicts) }))
      )
    )
)

const all = found.filter(Boolean).flat().filter(Boolean)

// --- Validate: the empirical gate, spent only where reading ran out ------------
// Adversarial reasoning catches reasoning errors; it does not catch empirical
// ones. In the closest published system to this one, ten agents including a
// senior arbiter unanimously confirmed a padding-oracle finding by reasoning,
// and one fresh instance that compiled the code and ran three tests killed it —
// "one test killed what 80+ agents' reasoning could not". Restricting the
// refuters to read-only (the containment fix) deleted that gate; this stage
// gives it back WITHOUT giving anyone write access to the user's checkout.
//
// `isolation: 'worktree'` is the containment: a fresh git worktree per agent,
// auto-removed if unchanged, so a test file written where an agent naturally
// writes one lands in a throwaway copy instead of the human's tree. Be honest
// about its strength — it relocates the DEFAULT working directory, it is not a
// jail. An absolute path still escapes it, which is why audit-prover.md makes
// relative-paths-only a hard rule. The failure this contains was accidental,
// not adversarial, and that is the threat it is sized for.
//
// CONDITIONALLY dispatched: only findings whose refuter panel MOSTLY abstained
// pay for a worktree (~200-500ms + a checkout each). Auditing 30 findings with
// 3 refuters each would otherwise mean 90 sandboxes to salvage a handful of
// verdicts. Cheap read-only panel first, empirical gate only where it is the
// deciding factor — the stage-gated shape the literature converged on.
const pending = all.filter((f) => f.needsProof)
if (pending.length) log(`${pending.length} finding(s) reading could not settle — running the named experiments in sandboxes`)
const proofs = await parallel(
  pending.map((f) => () =>
    agent(
      `A read-only refuter panel could not settle this audit finding: the verdict needs something RUN. You have a throwaway git worktree — use it.\n\n` +
        `Finding (lens ${f.lens}, severity ${f.severity}): ${f.title}\nFile: ${f.file}\nClaim: ${f.claim}\nEvidence given: ${f.evidence}\n\n` +
        `The experiment the panel said would settle it:\n${f.experiment || '(none named — design the smallest decisive experiment yourself)'}\n\n` +
        `Run it. Paste the exact command and its exact output as your evidence. Return 'refuted' if the claim does not hold, 'confirmed' if it does, or 'unverifiable' if you genuinely could not run a decisive experiment (say what blocked you). Never report a result you did not observe.`,
      { label: `prove:${f.title.slice(0, 30)}`, phase: 'Validate', schema: PROOF, effort: 'high', agentType: 'audit-prover', isolation: 'worktree' }
    ).then((p) => ({ finding: f, proof: p }))
  )
)
for (const r of proofs.filter(Boolean)) {
  const f = r.finding
  const v = r.proof?.verdict
  // A LOST validator leaves the finding exactly as the panel left it: surviving
  // but unproven. Losing the empirical gate must never silently upgrade a
  // finding to "verified", and must never kill it either.
  if (v === 'refuted') { f.confirmed = false; f.proven = 'refuted' }
  else if (v === 'confirmed') { f.proven = 'confirmed' }
  else { f.proven = 'unverifiable' }
  f.proofEvidence = r.proof?.evidence ?? null
}

const confirmed = all.filter((f) => f.confirmed)
const killed = all.length - confirmed.length
// A finding that survived only because nobody could check it is NOT "confirmed
// by adversarial review", and a record that counts it as one overclaims: it
// says three adversaries failed to refute when in fact three adversaries never
// looked. Tracked as a SUBSET of confirmed so the record's
// `raw = refuted + confirmed` arithmetic (audit-gate.sh) is untouched — the
// same purely-additive move `axes:` used, no sweap_format bump.
const unverified = confirmed.filter((f) => f.needsProof && f.proven !== 'confirmed')
log(
  `${all.length} raw findings, ${killed} refuted, ${confirmed.length} confirmed` +
    (unverified.length ? ` (${unverified.length} of them UNVERIFIED — reading could not settle them and the sandboxed run did not either)` : '')
)
// Say it loudly when most of the "confirmed" list was never actually checked.
// A bare count is easy to skim past, and separating unverified from confirmed
// achieves nothing if the reader has to do the division themselves. A high ratio
// is a finding ABOUT THE AUDIT — the reading tier was out of its depth on this
// surface — and it needs reading BEFORE the list is trusted, not after.
if (confirmed.length && unverified.length * 2 >= confirmed.length) {
  log(
    `⚠ ${unverified.length} of ${confirmed.length} confirmed findings are UNVERIFIED — nothing ` +
      `disproved them and nothing demonstrated them. Treat this list as PROVISIONAL: the panel ` +
      `could not check most of what it passed through. Triage the unverified ones as coverage ` +
      `gaps (bucket 2 — write the named experiment), not as established defects.`
  )
}

const order = { critical: 0, high: 1, medium: 2, low: 3 }
confirmed.sort((a, b) => order[a.severity] - order[b.severity])

// --- the audit record, pre-assembled -------------------------------------------
// The record is a MECHANICAL transcription of everything above: milestone,
// range, lens set, stats, one block per confirmed finding. Asking the calling
// session to compose it from a format spec buried in prose is how F9's record
// landed as pure prose in a consumer repo (2026-08-11) — a drift-prone step at
// the very end of a long, expensive run. So emit it here, already conformant to
// audit-gate.sh's format contract, and leave exactly the holes a machine cannot
// fill: the two <FILL:...> markers (journal digest, disposition per finding).
// The session's job becomes transcribe-and-fill, which audit-gate.sh --check can
// then verify. Keep `sweap_format` in lockstep with RECORD_FORMAT in
// hooks/audit-gate.sh — bumping one without the other is the skew this whole
// change exists to prevent.
const SWEAP_FORMAT = 1
const [rangeBase = '<FILL:range_base>', rangeHead = '<FILL:range_head>'] = String(scope?.range ?? '').split('..')
const lensMode = lensConfig?.mode === 'default-plus' ? 'default-plus' : lensConfig?.mode === 'explicit' ? 'explicit' : 'default'
const record = [
  '---',
  `sweap_format: ${SWEAP_FORMAT}`,
  `milestone: ${scope?.milestone ?? '<FILL:milestone>'}`,
  `range_base: ${rangeBase}`,
  `range_head: ${rangeHead}`,
  `lens_mode: ${lensMode}`,
  `lenses: [${LENSES.map((l) => l.key).join(', ')}]`,
  `raw: ${all.length}`,
  `refuted: ${killed}`,
  `confirmed: ${confirmed.length}`,
  // Optional, additive, and a SUBSET of `confirmed` — so `raw = refuted +
  // confirmed` still holds and audit-gate.sh needs no change (same move as
  // `axes:`). Emitted only when non-zero: a record that silently counts
  // never-checked findings as adversarially-confirmed is a record that
  // overclaims its own evidence.
  ...(unverified.length ? [`unverified: ${unverified.length}`] : []),
  `workflow_run: <FILL:this run's workflow id>`,
  `journal_sha256: <FILL:shasum -a 256 <transcriptDir>/journal.jsonl>`,
  '---',
  '',
  `# ${scope?.milestone ?? 'milestone'} audit`,
  '',
  ...confirmed.flatMap((f, i) => {
    // An unverified finding is a TEST-COVERAGE GAP, not an established defect:
    // nothing disproved it and nothing demonstrated it. Saying so in the block
    // (and steering its disposition to a follow-up item that writes the missing
    // test) keeps the confirmed list honest about what it is claiming.
    const unproven = f.needsProof && f.proven !== 'confirmed'
    return [
      `### ${i + 1}. ${f.title}`,
      `severity: ${f.severity}`,
      `lens: ${f.lens}`,
      ...(unproven
        ? [
            `status: UNVERIFIED — the refuter panel could not settle this by reading${f.proven === 'unverifiable' ? ' and the sandboxed run could not either' : ''}`,
            `experiment: ${f.experiment || '(none named)'}`,
            `disposition: <FILL: followup <id> — an item that writes the experiment above; use fix_pr/blocked only if you have verified it yourself>`,
          ]
        : [`disposition: <FILL: fix_pr #NN | followup <id> | blocked <id>>`]),
      '',
      `file: ${f.file}`,
      '',
      f.claim,
      '',
      ...(f.proofEvidence ? [`Sandboxed run:`, '', '```', f.proofEvidence, '```', ''] : []),
    ]
  }),
].join('\n')

return {
  milestone: scope?.milestone,
  range: scope?.range,
  confirmed,
  // `unverified` is a subset of `confirmed`, surfaced separately so the calling
  // session can triage it as what it is — a coverage gap needing an experiment,
  // not an established defect. The playbook's summary requirement quotes
  // `stats` verbatim, so the number travels into the run summary too.
  unverified,
  stats: { raw: all.length, refuted: killed, confirmed: confirmed.length, unverified: unverified.length },
  record,
}
