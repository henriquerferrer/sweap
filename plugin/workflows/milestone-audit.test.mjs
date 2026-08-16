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

test("the refuter does not refute a claim merely because it could not run it", () => {
  // Removing Bash makes more claims unreproducible-by-the-refuter. Left alone,
  // "default to refuted=true if unreproducible" would turn the lockdown into a
  // silent kill-switch for exactly the findings that most need a human.
  assert.match(SRC, /refuted=false/, "the refuter prompt must carve out unreproducible-by-reading");
  assert.doesNotMatch(SRC, /uncertain,\s*unreproducible,\s*or already mitigated/, "the old refute-by-default-on-unreproducible wording is back");
});
