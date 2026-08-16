// milestone-audit.test.mjs — guards the audit's READ-ONLY property.
//
// Run: node --test plugin/workflows/milestone-audit.test.mjs
//
// The workflow script cannot be imported: it runs against Workflow-provided
// globals (agent/pipeline/parallel/phase/log/args) and has top-level awaits and
// throws. So these are source-level assertions. That is the right level anyway —
// the defect being guarded was not a logic bug but a WIRING gap: `agentType` was
// simply never passed, while three documents asserted the property it would have
// provided. A test that reads the wiring is exactly the guard for that class, and
// it fails loudly for anyone who adds a stage and forgets.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = readFileSync(join(HERE, "milestone-audit.js"), "utf8");
const AGENT = readFileSync(join(HERE, "..", "agents", "audit-reader.md"), "utf8");
const PROVER = readFileSync(join(HERE, "..", "agents", "audit-prover.md"), "utf8");

// Option-object literals that name a phase. Matched line-scoped rather than
// brace-balanced because the labels contain `${...}` interpolations; every
// agent() options object in this file is written on one line. If that ever
// changes, this test fails loudly rather than silently passing — which is the
// correct direction for a guard.
const optionObjects = [...SRC.matchAll(/\{[^\n]*phase:\s*'([A-Za-z]+)'[^\n]*\}/g)];

test("every Find and Refute agent is dispatched as audit-reader", () => {
  const constrained = optionObjects.filter(([, phase]) => phase === "Find" || phase === "Refute");
  assert.ok(constrained.length >= 2, "expected at least the finder and refuter dispatches");
  for (const [obj, phase] of constrained) {
    assert.match(obj, /agentType:\s*'audit-reader'/, `a ${phase} agent runs without agentType: 'audit-reader' — it would get the default toolset, which can Write: ${obj}`);
  }
});

test("audit-reader grants no tool that can modify the repo", () => {
  const tools = AGENT.match(/^tools:\s*(.+)$/m);
  assert.ok(tools, "audit-reader.md must declare a tools: line — without it the agent inherits everything");
  const granted = tools[1].split(",").map((t) => t.trim());
  // Bash is excluded deliberately: `echo > file` writes just as well as Write.
  for (const forbidden of ["Write", "Edit", "NotebookEdit", "Bash"]) {
    assert.ok(!granted.includes(forbidden), `audit-reader must not be granted ${forbidden}`);
  }
  assert.deepEqual(granted, ["Read", "Grep", "Glob"]);
});

test("the agentType string matches the agent definition's name", () => {
  const name = AGENT.match(/^name:\s*(\S+)$/m);
  assert.ok(name, "audit-reader.md must declare a name:");
  assert.equal(name[1], "audit-reader", "a rename here silently un-restricts the workflow's agents");
});

test("finder and refuter prompts also state the constraint in words", () => {
  // The toolset is the mechanism; the sentence is the advisory layer above it,
  // and it is what tells an agent what to do INSTEAD of writing (say so in the
  // answer). Without it the agent hits a tool denial and improvises.
  assert.match(SRC, /const NO_WRITES\s*=/, "expected a shared NO_WRITES clause");
  const uses = SRC.match(/NO_WRITES/g) || [];
  assert.ok(uses.length >= 3, `NO_WRITES should be defined once and appended to both prompts (found ${uses.length} mentions)`);
});

test("the Validate stage is sandboxed and uses the prover, not the reader", () => {
  const validate = optionObjects.filter(([, phase]) => phase === "Validate");
  assert.equal(validate.length, 1, "expected exactly one Validate dispatch");
  assert.match(validate[0][0], /agentType:\s*'audit-prover'/);
  // For an agent that CAN write, containment is about WHERE it writes. Without
  // worktree isolation this stage reintroduces the bug it exists downstream of.
  assert.match(validate[0][0], /isolation:\s*'worktree'/, "the prover must run in a throwaway worktree");
});

test("audit-prover may write and run, but only ever inside its own worktree", () => {
  const tools = PROVER.match(/^tools:\s*(.+)$/m);
  assert.ok(tools, "audit-prover.md must declare a tools: line");
  const granted = tools[1].split(",").map((t) => t.trim());
  assert.ok(granted.includes("Bash") && granted.includes("Write"), "the prover exists to run experiments; it needs both");
  // Worktree isolation relocates the default working directory — it is not a
  // jail, so an absolute path escapes it. That rule has to live in the agent's
  // own instructions, because nothing else enforces it.
  assert.match(PROVER, /absolute path/i, "audit-prover must forbid absolute paths explicitly");
  assert.match(PROVER, /[Nn]ever commit/, "audit-prover must forbid committing from its worktree");
});

test("a three-valued verdict, and 'refuted' is never where uncertainty goes", () => {
  assert.match(SRC, /enum:\s*\['refuted',\s*'stands',\s*'unverifiable'\]/, "the refuter verdict must be three-valued");
  assert.doesNotMatch(SRC, /refuted:\s*\{\s*type:\s*'boolean'/, "the binary verdict is back — it forces a guess from a judge with no evidence");
  assert.doesNotMatch(SRC, /Default to refuted=true/, "refute-by-default-on-uncertainty is back");
  assert.match(SRC, /not about the code/, "the prompt must say that inability to verify is a fact about tools, not about the code");
});

// --- the vote arithmetic, extracted and actually executed --------------------
// A Workflow script runs against injected globals with no module access, so it
// cannot be imported and the tally cannot live in a shared file. Extracting the
// marked pure function and evaluating it is how the arithmetic gets real
// behavioural coverage instead of a grep over its source.
const tallySrc = SRC.match(/\/\/ TALLY-START[\s\S]*?\n(const tally = [\s\S]*?\n\})\n\/\/ TALLY-END/);
assert.ok(tallySrc, "could not extract the TALLY block — keep the markers around a single pure `const tally = ...`");
const tally = new Function(`${tallySrc[1]}; return tally;`)();

const vote = (verdict, experiment) => ({ verdict, reason: "r", ...(experiment ? { experiment } : {}) });
const REF = vote("refuted"), STANDS = vote("stands");
const ABS = vote("unverifiable", "pnpm test foo");
const SHRUG = vote("unverifiable");

test("tally: two refutations kill; one does not", () => {
  assert.equal(tally([REF, REF, STANDS]).confirmed, false);
  assert.equal(tally([REF, STANDS, STANDS]).confirmed, true);
});

test("tally: abstentions never count as refutations, and never lower the bar", () => {
  // The bug this guards: renormalising to "a majority of votes cast" would make
  // one refuter a majority once two abstain, handing a single voter a veto
  // exactly when the panel knows least.
  assert.equal(tally([REF, ABS, ABS]).confirmed, true, "1 refutation must not kill, however many abstained");
  assert.equal(tally([ABS, ABS, ABS]).confirmed, true);
  // A LOST vote (null) is treated identically to an abstention.
  assert.equal(tally([REF, null, null]).confirmed, true);
});

test("tally: a mostly-abstaining panel routes to the empirical gate, a mostly-reading one does not", () => {
  assert.equal(tally([ABS, ABS, STANDS]).needsProof, true);
  assert.equal(tally([ABS, STANDS, STANDS]).needsProof, false, "one abstention against two real reads is not a stalemate");
  assert.equal(tally([REF, REF, ABS]).needsProof, false, "a killed finding is not worth a sandbox");
  assert.equal(tally([ABS, ABS, STANDS]).experiment, "pnpm test foo", "the named experiment must reach the prover");
});

test("tally: an abstention naming no experiment is demoted, so abstaining is not free", () => {
  assert.equal(tally([SHRUG, SHRUG, STANDS]).needsProof, false, "shrugs must not buy a sandboxed run");
  assert.equal(tally([SHRUG, SHRUG, SHRUG]).confirmed, true);
});
