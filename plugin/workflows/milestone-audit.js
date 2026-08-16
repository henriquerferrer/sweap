export const meta = {
  name: 'milestone-audit',
  description: 'Adversarial cross-feature audit of a merged milestone (finders → refuters → confirmed findings)',
  whenToUse: 'After the last item of a milestone merges, before the next milestone brainstorm. Pass {range: "<base>..<head>", milestone: "F#"} (a bare milestone-id string is also accepted, e.g. "F6") or omit args and let the Scope stage infer the range from the item files at status: done under backlog.dir (roadmap/ by default; backlog.file is the index). The workflow throws if the resolved milestone does not match a requested one — it never silently falls back to auditing whatever merged most recently.',
  phases: [
    { title: 'Scope', detail: 'map the milestone surface (tables, routes, server fns) and resolve audit.lenses' },
    { title: 'Find', detail: 'one finder per lens over the merged whole' },
    { title: 'Refute', detail: 'three adversarial refuters per finding; majority kills' },
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

const VERDICT = {
  type: 'object',
  required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean', description: 'true if the claim does NOT hold' },
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
              `Adversarially REFUTE this audit finding about this codebase. Read the code at ${f.file} and its callers/tests yourself. Finding (lens ${lens.key}, severity ${f.severity}): ${f.title}\nClaim: ${f.claim}\nEvidence given: ${f.evidence}\n\nYour job is to prove it wrong BY READING: find the guard/test/permission check the finder missed, or show from the code that the scenario cannot occur. Default to refuted=true if the claim is uncertain or already mitigated. But if it is merely unreproducible-by-reading — i.e. only running something would settle it — return refuted=false and name that experiment in your reason; a finding that survives because it could not be disproved on the page is a correct outcome, and it goes to a human who can run things.` +
                NO_WRITES,
              { label: `refute${i}:${f.title.slice(0, 30)}`, phase: 'Refute', schema: VERDICT, effort: 'high', agentType: 'audit-reader' }
            )
          )
        ).then((verdicts) => {
          const votes = verdicts.filter(Boolean)
          const refuted = votes.filter((v) => v.refuted).length
          // Majority of cast votes kills; lost refuter votes don't count
          // against the finding.
          return { ...f, lens: lens.key, confirmed: refuted < 2 }
        })
      )
    )
)

const all = found.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter((f) => f.confirmed)
const killed = all.length - confirmed.length
log(`${all.length} raw findings, ${killed} refuted, ${confirmed.length} confirmed`)

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
  `workflow_run: <FILL:this run's workflow id>`,
  `journal_sha256: <FILL:shasum -a 256 <transcriptDir>/journal.jsonl>`,
  '---',
  '',
  `# ${scope?.milestone ?? 'milestone'} audit`,
  '',
  ...confirmed.flatMap((f, i) => [
    `### ${i + 1}. ${f.title}`,
    `severity: ${f.severity}`,
    `lens: ${f.lens}`,
    `disposition: <FILL: fix_pr #NN | followup <id> | blocked <id>>`,
    '',
    `file: ${f.file}`,
    '',
    f.claim,
    '',
  ]),
].join('\n')

return {
  milestone: scope?.milestone,
  range: scope?.range,
  confirmed,
  stats: { raw: all.length, refuted: killed, confirmed: confirmed.length },
  record,
}
