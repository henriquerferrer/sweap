export const meta = {
  name: 'milestone-audit',
  description: 'Adversarial cross-feature audit of a merged milestone (finders → refuters → confirmed findings)',
  whenToUse: 'After the last item of a milestone merges, before the next milestone brainstorm. Pass {range: "<base>..<head>", milestone: "F#"} (a bare milestone-id string is also accepted, e.g. "F6") or omit args and let the Scope stage infer the range from the item files at status: done under backlog.dir (roadmap/ by default; backlog.file is the index). The workflow throws if the resolved milestone does not match a requested one — it never silently falls back to auditing whatever merged most recently.',
  phases: [
    { title: 'Scope', detail: 'map the milestone surface (tables, routes, server fns) and resolve audit.lenses' },
    { title: 'Find', detail: 'one finder per lens over the merged whole' },
    { title: 'Refute', detail: 'three read-only refuters per finding; each cites code and scores, the pipeline cuts' },
    { title: 'Validate', detail: 'sandboxed run of an experiment a refuter ticketed, only for findings reading could not settle' },
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

// ONE SCALAR, NOT A TAXONOMY.
//
// Design memo: docs/research/2026-08-18-refuter-verdict-design.md. Every quote
// below was re-fetched as raw HTML and string-matched, per that memo's header.
//
// History, because the numbers are the argument. This was a boolean until
// 2026-08-16, when it became refuted/stands/unverifiable — and the panel's kill
// rate fell from 63-73% to 2.7% (1 of 36) on the next audit. The control that
// makes that causal: a parallel UI-critic axis, same 3-refuter majority shape,
// same milestone, same codebase, UNCHANGED prompt, held at 40% in that same run.
// Across 216 recorded verdicts the split was 210 stands / 6 refuted / 0
// unverifiable — the third label never once selected, in a run whose refuter
// prose openly said "UNVERIFIED BY READING / I could not run anything". The
// Validate stage below (which required >=2 `unverifiable` on a finding) was
// therefore not merely unused, it was structurally unreachable.
//
// The diagnosis is NOT "the wrong three labels". It is that a categorical
// verdict puts the decision boundary inside the model, where one adjective
// moves it 25x and nobody can see the dial. Read the shipped rule as a
// read-only agent saw it: `refuted` demanded "a positive, code-grounded
// disproof" from an agent that cannot run code; `unverifiable` demanded a named
// experiment and was DEMOTED to `stands` without one; `stands` demanded
// nothing. Two costly inlets, one free sink. Mass went where the shape sent it,
// which is the taxonomy working as specified rather than a model failure — and
// adding an option perturbs the distribution for non-semantic reasons in the
// first place: arXiv:2507.16199 names that Abstention Inflation and controls for
// it decisively — "Replacing \"Unknown\" with an unrelated random word produces
// an identical effect."
//
// So the refuter emits EVIDENCE and a SCALAR, and the PIPELINE cuts. That is
// what the labs actually ship: OpenAI's `score_model` grader returns
// `{"result": float, "steps": ReasoningStep[]}` and carries a separate
// `pass_threshold` in the grader config — the model scores, the system cuts,
// and there is no categorical verdict for a category to absorb. `unverifiable` does not come
// back as a label; it comes back as `experiment`, an OUT-OF-BAND ticket that
// SUSPENDS a finding for the Validate stage instead of resolving it. Being off
// the scoring axis entirely is the point: a ticket cannot take probability mass
// from a score the way a third label takes it from the other two.
const REFUTATION = {
  type: 'object',
  // SYMMETRIC EVIDENCE. This list does not branch on which way the score
  // points: the answer that leaves the finding alone cites code on exactly the
  // same terms as the answer that kills it. Under-pricing one direction is what
  // built the sink, and the enforcement is a SCHEMA VIOLATION (the model is
  // made to retry until the fields are there) — never a demotion. A demotion is
  // a drain into whichever label is cheapest, i.e. the mechanism this change
  // exists to delete, wearing a different hat.
  required: ['read', 'evidence', 'falsifier', 'confidence'],
  properties: {
    read: {
      type: 'string',
      description: 'the code you actually opened, as repo-relative path:line spans (callers and tests included)',
    },
    evidence: {
      type: 'string',
      description:
        'the code that bears on the claim, quoted. Contradicting it: cite the guard, check, test or control flow that does. Failing to contradict it: cite what you read that did not. Required either way.',
    },
    falsifier: {
      type: 'string',
      description: 'the concrete observation that would move your score in the other direction',
    },
    confidence: {
      type: 'number',
      minimum: 0,
      maximum: 1,
      description: 'your probability, 0 to 1, that this finding is WRONG. The pipeline, not you, decides what that number kills.',
    },
    experiment: {
      type: 'string',
      description:
        'OUT-OF-BAND TICKET, optional and NOT a verdict: the exact command or test that would settle what reading cannot. Filing it never substitutes for your score, and never resolves the finding — it routes the finding to an agent that can run things.',
    },
  },
}

// The Validate stage's verdict — same shape of question, but earned by running
// something rather than by reading, which is the entire point of that stage.
//
// Deliberately still categorical, and deliberately still three-valued, unlike
// the refuter's above. The objection to a label is that it lets a capability
// limit masquerade as a judgment about the code; here the agent HAS the
// capability, its answer is backed by a pasted command and its actual output,
// and 'unverifiable' means "I tried to run it and something blocked me" — a
// fact it earned rather than a bucket it fell into. Nothing routes onward from
// this stage either, so there is no downstream gate for a third label to
// starve. If this ever stops being terminal, revisit it.
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
// If you add a stage here, dispatch it through `agentAs` too (which is what
// binds an agent type that cannot write), or say plainly in the docs that it is
// not read-only. Never restore an unrestricted agent behind a prose
// promise. (Scope, above, genuinely needs Bash for `git log` and is therefore
// NOT mechanically constrained — that limit is documented, not hidden.)
const NO_WRITES =
  `\n\nYou are read-only: you have Read, Grep and Glob, and no way to run or write anything. ` +
  `This audit reads merged code in someone's live checkout, so a file you create is one they find later and cannot attribute to anybody. ` +
  `If a claim can only be settled by running something, say so in your answer rather than approximating it — never report an experiment you did not perform.`

// AGENT TYPES ARE ADDRESSED, NOT NAMED — and the two are not the same string.
// A plugin-shipped agent registers under its PLUGIN-SCOPED name: the docs are
// explicit that "Agents appear in the @-mention typeahead under their scoped
// name, such as `my-plugin:code-reviewer`, once the plugin is enabled". The same
// file dropped into a repo's own `.claude/agents/` registers BARE. This workflow
// dispatched the bare name unconditionally, so it worked in sweap's own checkout
// and was broken for every plugin install — consumer A's F11 audit lost all eleven
// finder agents to `agent type 'audit-reader' not found. Available agents: ...
// sweap:audit-reader, ...` and only completed because the session hand-patched
// its own copy of this script.
//
// So resolve, don't assume. Try the scoped name, then the bare one — and if the
// runtime rejects both, read the list it printed and take it at its word. That
// last step is what makes this survive a rename: the namespace is the plugin's
// `name` (or the marketplace entry's, when a marketplace lists it under a
// different one), which this script cannot read from disk, but the error message
// names every agent that DOES exist.
//
// The one thing this must never do is fall back to no agentType at all. Every
// candidate here ends in `audit-reader`/`audit-prover`; an unresolvable agent is
// a thrown error, not a dispatch with the default toolset — that toolset can
// Write, and this whole containment design exists because a refuter once did.
const PLUGIN_NAME = 'sweap'
const AUDIT_AGENTS = { reader: 'audit-reader', prover: 'audit-prover' }
const resolvedAgentType = {}

const agentAs = async (role, prompt, opts) => {
  const bare = AUDIT_AGENTS[role]
  const queue = [resolvedAgentType[role], `${PLUGIN_NAME}:${bare}`, bare].filter(Boolean)
  const tried = []
  while (queue.length) {
    const candidate = queue.shift()
    if (tried.includes(candidate)) continue
    tried.push(candidate)
    try {
      const out = await agent(prompt, { ...opts, agentType: candidate })
      // Memoized so the whole run pays the probe at most once per role.
      resolvedAgentType[role] = candidate
      return out
    } catch (e) {
      const msg = String((e && e.message) || e)
      // Only a LOOKUP failure is worth another candidate. Anything else (an API
      // error, a schema rejection) is this dispatch's real failure and must
      // surface as itself rather than being retried under a different name.
      if (!/agent type .*not found/i.test(msg) && !/unknown agent/i.test(msg)) throw e
      const offered = msg.split(/available agents:/i)[1]
      for (const raw of (offered || '').split(/[,\s]+/)) {
        const n = raw.trim().replace(/^[`'"]+|[.`'"]+$/g, '')
        if (n === bare || n.endsWith(`:${bare}`)) queue.push(n)
      }
    }
  }
  throw new Error(
    `milestone-audit: no agent type resolves to '${bare}' (tried: ${tried.join(', ')}). ` +
      `The audit's read-only containment is that agent, so this run cannot continue without it — ` +
      `check that the sweap plugin is enabled, or that ${bare}.md exists in this repo's .claude/agents/.`
  )
}

// TALLY-START — everything between these markers is EXTRACTED and evaluated by
// milestone-audit.test.mjs. A Workflow script runs against injected globals with
// no module access, so it cannot be imported and this cannot be a shared file;
// extraction is how the arithmetic gets real behavioural coverage instead of a
// grep. Keep the markers, keep the block self-contained (it must reference
// nothing defined outside them), and keep `tally` pure.

// THE TUNABLES — the two numbers that decide whether a finding lives, kept
// here, in the pipeline, where they can be read and changed. This is the whole
// point of the redesign: an anti-false-positive instruction inside a prompt is
// a conservatism dial you cannot see, and sweap has the receipts for what an
// invisible dial does (63% -> 2.7% on one wording change).
//
//   refutedAt  — the score cut. A refuter's confidence must be STRICTLY
//                greater than this to count as a refutation, which is the
//                form the confidence-target literature states it in: "Answer
//                only if you are > t confident, since mistakes are penalized
//                t/(1-t) points, while correct answers receive 1 point, and an
//                answer of \"I don't know\" receives 0 points" (arXiv:2509.04664),
//                whose own worked values are "t = 0.5 (penalty 1), t = 0.75
//                (penalty 2), and t = 0.9 (penalty 9)". 0.5 is the NEUTRAL
//                point and is chosen for exactly that reason: it is the only
//                value that asserts nothing about the relative cost of a wrong
//                kill versus a wrong pass. Any other value is such an
//                assertion, and we have no labeled set to make it with. Note
//                that the cut is not new — it was always there, spelled out in
//                adjectives inside the prompt. It is only now visible.
//   killVotes  — refutations needed to kill, out of REFUTER_SEATS.length.
//                FIXED at 2, never renormalised to "a majority of votes cast":
//                renormalising lets two lost votes promote the third refuter to
//                a majority of one, handing a single voter a veto exactly when
//                the panel is least informed (the PR #8 bug in a new costume).
//                Deliberately NOT retuned by this change, though there is a
//                real argument that it should fall to 1: under documented
//                positive bias an agreeable majority is the failure mode rather
//                than the safeguard, and the paper making that argument
//                proposes a minority veto. The same paper is why we did not
//                act on it — "the choice of this optimal threshold ... itself
//                requires a calibration set with ground-truth labels"
//                (arXiv:2510.11822). Flipping it on intuition would just
//                re-roll the dice that produced 63% and 2.7%. Building that
//                labeled set (seeded known-bad and known-good findings) is the
//                next piece of work; this line is the one it will edit.
//   proofTickets — out-of-band tickets needed to route a finding to the
//                empirical gate. 1, because a ticket no longer competes with a
//                verdict for probability mass: it costs a named command and
//                buys the refuter nothing on the score, so the >=2 bar that
//                once priced abstention is now just a way to keep the gate
//                unreachable.
const TUNING = {
  refutedAt: 0.5,
  killVotes: 2,
  proofTickets: 1,
}

const tally = (refutations, tuning) => {
  const t = tuning || TUNING
  const votes = (refutations || []).filter(Boolean)
  // A vote with no usable score is a LOST vote, not a refutation and not a
  // defence — excluded from the numerator with the threshold left where it is.
  // That is the learning-with-rejection result (an abstaining voter leaves the
  // covered set) and the Nitzan-Paroush one (a voter at p~=0.5 carries weight
  // zero, not a vote in either direction).
  const scored = votes.filter((v) => Number.isFinite(v.confidence))
  // Strictly greater: "answer only if you are > t confident".
  const refuted = scored.filter((v) => v.confidence > t.refutedAt).length
  // Deliberately NOT filtered on whether the evidence fields are populated.
  // Dropping an under-evidenced vote here would be a demotion, and a demotion
  // is a drain into the cheapest outcome — the exact failure being deleted. The
  // schema is the enforcement; this function is arithmetic.
  const tickets = votes.map((v) => String(v.experiment ?? '').trim()).filter(Boolean)
  const killed = refuted >= t.killVotes
  // A killed finding is not worth a sandbox; a ticket suspends a SURVIVING one.
  const needsProof = !killed && tickets.length >= t.proofTickets
  return {
    confirmed: !killed,
    refutedVotes: refuted,
    // How many refuters actually cast a usable score. Zero means the panel
    // never ran on this finding, which survives the arithmetic below looking
    // exactly like "three adversaries read it and could not break it".
    scored: scored.length,
    needsProof,
    experiment: tickets[0] ?? null,
  }
}
// TALLY-END

// Three seats, so "majority kills" is a real vote: with 2 refuters, one
// uncertain dissenter silently killed true positives (review finding, PR #8).
// The panel size and the kill threshold are separate numbers on purpose —
// TUNING.killVotes is the one that decides, this is only how many opinions it
// decides over.
const REFUTER_SEATS = [1, 2, 3]

// The payoff, computed from the cut rather than restated next to it, so tuning
// TUNING.refutedAt cannot leave the prompt quoting a stale price. t/(1-t) per
// arXiv:2509.04664; at the neutral t = 0.5 this is exactly 1.
const WRONG_CALL_PENALTY = Number((TUNING.refutedAt / (1 - TUNING.refutedAt)).toFixed(2))

const found = await pipeline(
  LENSES,
  (lens) =>
    agentAs('reader',
      `${lens.prompt}\n\nMilestone scope (from a prior mapping agent):\n${scopeSummary}\n\nRead the actual code before claiming anything. Only report findings you can support with specific code evidence. No style nits — defects only.` +
        NO_WRITES,
      { label: `find:${lens.key}`, phase: 'Find', schema: FINDINGS, effort: 'high' }
    ).then((result) => {
      // A finder that produced NOTHING is not a clean lens, and the difference
      // is invisible one line later (`result?.findings ?? []` flattens both to
      // an empty list). Throw so the pipeline records this lens as lost.
      if (!result || !Array.isArray(result.findings)) {
        throw new Error(`milestone-audit: the ${lens.key} finder returned no result`)
      }
      return result
    }),
  (result, lens) =>
    parallel(
      (result?.findings ?? []).map((f) => () =>
        parallel(
          REFUTER_SEATS.map((i) => () =>
            agentAs('reader',
              `Adversarially test this audit finding about this codebase. Read the code at ${f.file} and its callers and tests yourself before you answer.\n\n` +
                `Finding (lens ${lens.key}, severity ${f.severity}): ${f.title}\nClaim: ${f.claim}\nEvidence given: ${f.evidence}\n\n` +
                `Answer with all four of these, every time:\n` +
                `- read: the repo-relative path:line spans you actually opened.\n` +
                `- evidence: the code that bears on the claim, quoted. If you can contradict the claim, cite the guard, check, test or control flow that contradicts it. If you cannot, cite what you read that FAILED to contradict it. Both directions cost the same: an answer citing no code is rejected outright, whichever way it points.\n` +
                `- falsifier: the concrete observation that would move your score the other way.\n` +
                `- confidence: your probability, 0 to 1, that this finding is WRONG.\n\n` +
                `What "contradict" means here: it is a READING standard, not a running standard. Cite code showing the defect is already handled, cannot be reached, or was misread — you have no way to execute anything, so no answer of yours is expected to rest on an execution, and you must not hold your score down merely because you could not run a proof.\n\n` +
                `How your number is used, exactly: this finding dies if ${TUNING.killVotes} of the ${REFUTER_SEATS.length} independent refuters score above ${TUNING.refutedAt}. So score above ${TUNING.refutedAt} when you judge it more likely than not that the finding is wrong, and at or below it when you do not. You are graded per call: a correct call earns 1 point and an incorrect one costs ${WRONG_CALL_PENALTY} (the t/(1-t) rule at t = ${TUNING.refutedAt}). There is no answer that scores 0 — you cannot decline to score, and the field below is not a way to.\n\n` +
                `If, and only if, reading genuinely cannot settle this, ALSO fill 'experiment' with the exact command or test that would. That is a ticket, not a verdict: it does not replace your score (score anyway, on what you did manage to read), and it does not resolve the finding — it routes it to an agent that can actually run things. Name a command; "write a test for it" is not a ticket.` +
                NO_WRITES,
              { label: `refute${i}:${f.title.slice(0, 30)}`, phase: 'Refute', schema: REFUTATION, effort: 'high' }
            )
          )
        ).then((refutations) => ({ ...f, lens: lens.key, ...tally(refutations, TUNING) }))
      )
      // Tagged with its lens rather than left as a bare array, so "which lenses
      // reported" below is read off the results themselves. Deriving it by
      // POSITION would make the record's lens list depend on `pipeline`
      // preserving input order — true today, and not a property worth betting a
      // coverage claim on.
    ).then((findings) => ({ lens: lens.key, findings }))
)

// A LENS THAT DID NOT REPORT IS NOT A CLEAN LENS. `found` carries a null where
// a finder threw or was lost, and without this the two collapse into the same
// empty list one line down — which is how a run whose finders ALL failed
// produced a well-formed, gate-passing record saying the milestone was clean
// (consumer A F11: eleven finder agents died on an unresolvable agent type and the
// record would have read 0/0/0). Fail at the source, where the failure is still
// visible and attributable, rather than emitting an audit-shaped artifact that
// says nothing happened and nothing was wrong in the same breath.
const reported = found.filter(Boolean)
const reporting = reported.map((r) => r.lens)
const lost = LENSES.map((l) => l.key).filter((k) => !reporting.includes(k))
if (!reporting.length) {
  throw new Error(
    `milestone-audit: every finder failed (${LENSES.length} lens(es): ${LENSES.map((l) => l.key).join(', ')}) — ` +
      `no lens reported, so this run has no evidence about ${scope?.milestone ?? 'the milestone'} at all. ` +
      `Refusing to return an empty audit: a 0-finding record from a run that never ran reads exactly like a clean milestone.`
  )
}
if (lost.length) log(`⚠ ${lost.length} of ${LENSES.length} lenses did not report and are NOT in this record: ${lost.join(', ')}`)

const all = reported.flatMap((r) => r.findings ?? []).filter(Boolean)

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
// CONDITIONALLY dispatched: only surviving findings a refuter actually
// TICKETED pay for a worktree (~200-500ms + a checkout each). Auditing 30
// findings with 3 refuters each would otherwise mean 90 sandboxes to salvage a
// handful of verdicts. Cheap read-only panel first, empirical gate only where
// it is the deciding factor — the stage-gated shape the literature converged
// on. The routing rule used to be ">=2 of 3 abstained", which combined with a
// verdict nobody ever selected made this stage unreachable: 0 dispatches in a
// 36-finding run whose refuters said in prose that they could not verify. A
// ticket is off the scoring axis now, so one is enough (TUNING.proofTickets).
const pending = all.filter((f) => f.needsProof)
if (pending.length) log(`${pending.length} finding(s) reading could not settle — running the named experiments in sandboxes`)
const proofs = await parallel(
  pending.map((f) => () =>
    agentAs('prover',
      `A read-only refuter ticketed this audit finding as unsettleable by reading: it needs something RUN. You have a throwaway git worktree — use it.\n\n` +
        `Finding (lens ${f.lens}, severity ${f.severity}): ${f.title}\nFile: ${f.file}\nClaim: ${f.claim}\nEvidence given: ${f.evidence}\n\n` +
        `The experiment the ticket named:\n${f.experiment || '(none named — design the smallest decisive experiment yourself)'}\n\n` +
        `Run it. Paste the exact command and its exact output as your evidence. Return 'refuted' if the claim does not hold, 'confirmed' if it does, or 'unverifiable' if you genuinely could not run a decisive experiment (say what blocked you). Never report a result you did not observe.`,
      { label: `prove:${f.title.slice(0, 30)}`, phase: 'Validate', schema: PROOF, effort: 'high', isolation: 'worktree' }
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
// UNVERIFIED covers both ways a finding can survive without ever being checked:
// the panel could not settle it by reading and the sandbox did not either, or —
// the failure mode that produced this line — no refuter scored it at all.
const isUnverified = (f) => f.scored === 0 || (f.needsProof && f.proven !== 'confirmed')
const unverified = confirmed.filter(isUnverified)
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
  // The lens set that RAN, not the one that was configured. A lost lens listed
  // here is a coverage claim the run cannot support.
  `lenses: [${reporting.join(', ')}]`,
  // Affirmative evidence that the audit did work, which `raw: 0` alone is not:
  // 0 == 0 + 0 satisfies every arithmetic check in audit-gate.sh. Emitted
  // always; the gate demands it when `raw` is 0 (purely additive, so records
  // written before this key existed still validate and sweap_format is
  // unchanged — the same move `axes:` and `unverified:` made).
  `finders_reporting: ${reporting.length}`,
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
    const unproven = isUnverified(f)
    return [
      `### ${i + 1}. ${f.title}`,
      `severity: ${f.severity}`,
      `lens: ${f.lens}`,
      ...(unproven
        ? [
            f.scored === 0
              ? `status: UNVERIFIED — no refuter returned a usable score on this finding; the panel did not run`
              : `status: UNVERIFIED — a refuter could not settle this by reading${f.proven === 'unverifiable' ? ' and the sandboxed run could not either' : ''}`,
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
  // `finders_reporting` rides in stats because the playbook requires stats to be
  // quoted verbatim in the run summary — which is where a human reading "0
  // confirmed" needs to see how many lenses actually looked.
  stats: {
    raw: all.length,
    refuted: killed,
    confirmed: confirmed.length,
    unverified: unverified.length,
    finders_reporting: reporting.length,
  },
  record,
}
