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
const MANIFEST = JSON.parse(readFileSync(join(HERE, "..", ".claude-plugin", "plugin.json"), "utf8"));
const MARKETPLACE = JSON.parse(readFileSync(join(HERE, "..", "..", ".claude-plugin", "marketplace.json"), "utf8"));

// Option-object literals that name a phase. Matched line-scoped rather than
// brace-balanced because the labels contain `${...}` interpolations; every
// agent() options object in this file is written on one line. If that ever
// changes, this test fails loudly rather than silently passing — which is the
// correct direction for a guard.
const optionObjects = [...SRC.matchAll(/\{[^\n]*phase:\s*'([A-Za-z]+)'[^\n]*\}/g)];

// Which dispatcher a stage went through: the nearest `agentAs('<role>'` or bare
// `agent(` opening before its options object. `agentAs` is what binds a
// constrained agent type; a bare `agent(` with no agentType gets the default
// toolset, which can Write.
const dispatcherFor = (index) => {
  const opens = [...SRC.slice(0, index).matchAll(/\bagentAs\('(\w+)'|\bagent\(/g)];
  const last = opens[opens.length - 1];
  return last ? (last[1] ?? "agent") : null;
};

test("every Find and Refute agent is dispatched through the read-only resolver", () => {
  const constrained = optionObjects.filter(([, phase]) => phase === "Find" || phase === "Refute");
  assert.ok(constrained.length >= 2, "expected at least the finder and refuter dispatches");
  for (const m of constrained) {
    const phase = m[1];
    assert.equal(dispatcherFor(m.index), "reader",
      `a ${phase} agent is not dispatched via agentAs('reader', ...) — a bare agent() call with no agentType gets the default toolset, which can Write: ${m[0]}`);
  }
});

// --- addressability, not string equality ------------------------------------
// The previous version of this file asserted that the dispatched string equalled
// the agent file's `name:` frontmatter. Both sides were the bare name, so it
// passed while every plugin install was broken: a plugin agent is addressable
// only under its SCOPED name (`<plugin>:<agent>`), and consumer A's F11 audit lost
// all eleven finders to `agent type 'audit-reader' not found`. The property is
// "the workflow can address the agent in whatever install it lands in", which
// two strings I wrote cannot demonstrate.
test("the resolver can address the agent in a plugin install AND in a local repo", () => {
  const names = SRC.match(/const AUDIT_AGENTS = \{([^}]*)\}/);
  assert.ok(names, "expected an AUDIT_AGENTS map of role -> bare agent name");
  for (const [file, doc] of [["audit-reader.md", AGENT], ["audit-prover.md", PROVER]]) {
    const bare = doc.match(/^name:\s*(\S+)$/m);
    assert.ok(bare, `${file} must declare a name:`);
    assert.ok(names[1].includes(`'${bare[1]}'`),
      `${file} declares name: ${bare[1]}, which the workflow never tries to address`);
  }
  // A LOCAL definition under .claude/agents/ registers bare...
  assert.match(SRC, /queue = \[[^\n]*,\s*bare\]/, "the bare name must be a candidate — that is how a repo-local .claude/agents/ definition registers");
  // ...and a plugin-shipped one registers under the plugin's namespace, which
  // must be THIS plugin's name (marketplace entry included: the docs say a
  // marketplace may list a plugin under a different name, and that name is what
  // the namespace follows).
  const scoped = SRC.match(/const PLUGIN_NAME = '([^']+)'/);
  assert.ok(scoped, "expected a PLUGIN_NAME for the scoped candidate");
  assert.equal(scoped[1], MANIFEST.name, "the scoped candidate must follow plugin.json's name");
  assert.deepEqual(MARKETPLACE.plugins.map((p) => p.name), [MANIFEST.name],
    "the marketplace lists this plugin under a different name, so the scoped candidate would be wrong");
  assert.match(SRC, /\$\{PLUGIN_NAME\}:\$\{bare\}/, "the scoped candidate must be built from PLUGIN_NAME");
});

test("an unresolvable agent type is a thrown error, never an unconstrained dispatch", () => {
  // Falling back to no agentType would silently restore the default toolset —
  // the exact regression the read-only lockdown exists to prevent. Every
  // candidate must end in one of the audit agents' names.
  const resolver = SRC.slice(SRC.indexOf("const agentAs ="), SRC.indexOf("// TALLY-START"));
  assert.match(resolver, /throw new Error\(/, "exhausting the candidates must throw");
  assert.doesNotMatch(resolver, /agentType:\s*(undefined|null|''|""|)\s*[,}]/, "the resolver must never dispatch without an agent type");
  assert.match(resolver, /n === bare \|\| n\.endsWith\(`:\$\{bare\}`\)/,
    "a name harvested from the runtime's error must still be one of the audit agents");
});

test("the resolver learns the real name from what the runtime says it has", () => {
  // Robustness to a rename this script cannot see: it has no filesystem access,
  // so it cannot read plugin.json, but the not-found error lists every agent
  // that does exist. Simulated here against the verbatim message from the F11
  // run that exposed the bug.
  const resolverSrc = SRC.slice(SRC.indexOf("const PLUGIN_NAME ="), SRC.indexOf("// TALLY-START"));
  const REAL = "acme-fork:audit-reader";
  const calls = [];
  const agent = async (_prompt, opts) => {
    calls.push(opts.agentType);
    if (opts.agentType !== REAL) {
      throw new Error(`agent type '${opts.agentType}' not found. Available agents: claude, Explore, general-purpose, ${REAL}, acme-fork:audit-prover, acme-fork:reviewer`);
    }
    return { findings: [] };
  };
  const agentAs = new Function("agent", `${resolverSrc}; return agentAs;`)(agent);
  return agentAs("reader", "p", { label: "l" }).then((out) => {
    assert.deepEqual(out, { findings: [] });
    assert.equal(calls[calls.length - 1], REAL, "the resolver must land on the name the runtime offered");
    assert.ok(calls.every((c) => c && c.endsWith("audit-reader")), `it must never try an unrelated agent type: ${calls}`);
  });
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

test("a lens that did not report is never counted as a clean lens", () => {
  // An audit whose finders all die produces raw: 0 — which passes every
  // arithmetic check in audit-gate.sh and reads as a clean milestone. The
  // workflow must fail at the source instead of emitting that artifact.
  assert.match(SRC, /if \(!reporting\.length\) \{[\s\S]*?throw new Error/, "the workflow must throw when no lens reported");
  assert.match(SRC, /lenses: \[\$\{reporting\.join/, "the record must list the lenses that RAN, not the ones configured");
  assert.match(SRC, /\.then\(\(findings\) => \(\{ lens: lens\.key, findings \}\)\)/,
    "which lenses reported must be read off the results, not inferred from array position");
  assert.match(SRC, /finders_reporting: \$\{reporting\.length\}/, "the record must carry affirmative evidence that finders ran");
  assert.match(SRC, /throw new Error\(`milestone-audit: the \$\{lens\.key\} finder returned no result`\)/,
    "a finder returning nothing must throw, so the pipeline records that lens as lost rather than empty");
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
  assert.equal(dispatcherFor(validate[0].index), "prover", "the Validate stage must resolve the prover, not the reader");
  // For an agent that CAN write, containment is about WHERE it writes. Without
  // worktree isolation this stage reintroduces the bug it exists downstream of.
  assert.match(validate[0][0], /isolation:\s*'worktree'/, "the prover must run in a throwaway worktree");
});

test("audit-reader's restriction is declared in depth, not once", () => {
  // `tools:` alone is a definition-time restriction, and Claude Code's docs are
  // explicit that omitting it inherits EVERY tool without erroring — so a botched
  // edit fails wide open. disallowedTools is applied first and survives that;
  // audit-agent-guard.sh then denies at the moment of the call regardless.
  for (const t of ["Write", "Edit", "NotebookEdit", "Bash"]) {
    assert.match(AGENT, new RegExp(`^disallowedTools:.*\\b${t}\\b`, "m"), `disallowedTools must include ${t}`);
  }
});

test("a high unverified ratio is called out, not left as a number to divide", () => {
  assert.match(SRC, /unverified\.length \* 2 >= confirmed\.length/, "expected a ratio check on the unverified count");
  assert.match(SRC, /PROVISIONAL/, "the warning must say what to do with the list, not just report a number");
});

test("the record separates 'the panel did not run' from 'reading could not settle it'", () => {
  // The 2026-09-02 run: `confirmed: 31`, `unverified: 26`, while the account
  // was out of capacity. One key cannot say which kind of 26 that was —
  // `unverified` merges a finding no refuter scored (the panel died) with a
  // finding reading could not settle and the sandbox did not either (a real,
  // expected audit outcome). Only the first is an alarm about the RUN.
  assert.match(SRC, /const unscored = confirmed\.filter\(\(f\) => f\.scored === 0\)/,
    "unscored must be derived from the panel's own vote count, never from `unverified` — deriving it from the merged key reproduces the merge");
  assert.match(SRC, /const isUnverified = \(f\) => f\.scored === 0 \|\| \(f\.needsProof/,
    "`unverified` must keep BOTH causes: splitting the alarm out does not narrow the older key, which records already carry");
  // Additive, exactly like `unverified:` and `axes:` before it: a subset of
  // `confirmed`, emitted ONLY when non-zero, so `raw = refuted + confirmed`
  // still holds in audit-gate.sh and old records keep validating.
  assert.match(SRC, /\.\.\.\(unscored\.length \? \[`unscored: \$\{unscored\.length\}`\] : \[\]\)/,
    "unscored: must be emitted only when non-zero");
  assert.match(SRC, /\.\.\.\(unverified\.length \? \[`unverified: \$\{unverified\.length\}`\] : \[\]\)/,
    "unverified: must be left exactly as it was");
  assert.match(SRC, /const SWEAP_FORMAT = 1\b/,
    "a purely additive key must not bump sweap_format — bumping it without hooks/audit-gate.sh is the skew that contract exists to prevent");
  const fm = SRC.slice(SRC.indexOf("const record = ["), SRC.indexOf("workflow_run:"));
  assert.ok(fm.indexOf("unverified: ") < fm.indexOf("unscored: "),
    "the two counts must sit adjacent in the frontmatter — a reader compares them or the split bought nothing");
  // `unscored` is a SUBSET of `confirmed`, never a fourth bucket: the gate's
  // arithmetic is `raw == refuted + confirmed`, and a key that participated in
  // it would break every record written before it existed.
  assert.match(SRC, /`raw: \$\{all\.length\}`/);
  assert.match(SRC, /`refuted: \$\{killed\}`/);
  assert.match(SRC, /`confirmed: \$\{confirmed\.length\}`/);
  assert.match(SRC, /const unscored = confirmed\.filter/,
    "unscored must be filtered out of `confirmed`, so it can never disturb raw = refuted + confirmed");
});

test("the run does not try to detect a dead panel from inside itself", () => {
  // An in-run circuit breaker was built for this incident and removed after a
  // hostile review executed it. Do not rebuild it without reading the paragraph
  // above `const unscored`. Three reasons, all reproduced: there is no point in
  // the script that is after the LAST dispatch, so a panel dying in Validate
  // skipped the throw and assembled a record anyway; "consecutive nulls" is
  // meaningless over a concurrent fan-out where a dead subagent returns in
  // milliseconds and a live refuter takes minutes, so it fired on healthy runs
  // and coin-flipped on the outage; and an outage delivered as a THROW never
  // reached the counters at all, because `agentAs` re-throws and `parallel`
  // swallows it to null.
  //
  // The property that replaced it: detection at the gate, on the finished
  // record. This test is the guard on that decision — a re-introduced breaker
  // fails here and has to argue with the comment before it can ship.
  assert.doesNotMatch(SRC, /panelIsDead|deadPanelAfter|consecutiveEmptyDispatches/,
    "an in-run dead-panel breaker is back; it was removed as unplaceable, unsound under concurrency, and blind to thrown outages");
  assert.doesNotMatch(SRC, /let\s+\w*[Ee]mptyDispatches/, "module-level dispatch counters do not survive a resume and do not mean anything under a fan-out");
  assert.match(SRC, /from inside the script a dead panel and a slow one are\n\/\/ not distinguishable in time/,
    "the file must record WHY in-run detection was abandoned, or it gets rebuilt");
  // The one guard that does abort a run stays exactly as it was.
  assert.match(SRC, /if \(!reporting\.length\) \{\n\s*throw new Error\(/,
    "the no-lens guard is the workflow's only abort and must be untouched");
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

test("the refuter verdict is a scalar, not a taxonomy", () => {
  // The regression this guards is measured: a categorical verdict took the kill
  // rate from 63-73% to 2.7% on one prompt change, while a frozen UI axis in the
  // same run held at 40%. Any re-introduction of a label the refuter picks from
  // puts the decision boundary back inside the model.
  assert.doesNotMatch(SRC, /enum:\s*\['refuted',\s*'stands',\s*'unverifiable'\]/, "the three-valued refuter verdict is back");
  assert.doesNotMatch(SRC, /refuted:\s*\{\s*type:\s*'boolean'/, "the binary verdict is back — it forces a guess from a judge with no evidence");
  assert.doesNotMatch(SRC, /Default to refuted=true/, "refute-by-default-on-uncertainty is back");
  const refutation = SRC.match(/const REFUTATION = \{[\s\S]*?\n\}/);
  assert.ok(refutation, "expected a REFUTATION schema for the refuter");
  assert.match(refutation[0], /confidence:\s*\{[\s\S]*?type:\s*'number'/, "the refuter must emit a scalar");
  assert.match(refutation[0], /minimum:\s*0[\s\S]*?maximum:\s*1/, "the scalar must be bounded 0..1");
  assert.doesNotMatch(refutation[0], /enum:/, "no enum may reappear on the refuter's output");
});

test("evidence is required symmetrically, for every answer", () => {
  // The sink was built by pricing the directions differently: two costly inlets
  // (a disproof, a named experiment) and one that required nothing. A required
  // list that does not branch on the score is what keeps that from re-forming.
  const refutation = SRC.match(/const REFUTATION = \{[\s\S]*?\n\}/)[0];
  const required = refutation.match(/required:\s*\[([^\]]*)\]/);
  assert.ok(required, "REFUTATION must declare a required list");
  const keys = required[1].split(",").map((k) => k.trim().replace(/'/g, ""));
  assert.deepEqual(keys.sort(), ["confidence", "evidence", "falsifier", "read"].sort(),
    "every answer must cite what it read, the code it found, what would falsify it, and a score");
  // Enforcement must be the schema (which forces a retry), never a demotion:
  // a demotion is a drain into whichever answer is cheapest, i.e. the bug.
  assert.match(SRC, /never a demotion|not a demotion|never as a demotion/i,
    "the file must say plainly that under-evidenced answers are a schema violation, not a demotion");
});

test("the refuted bar is reachable by reading, not by running", () => {
  // The shipped bar demanded "a positive, code-grounded disproof" from an agent
  // with no ability to run code — unearnable by construction.
  assert.doesNotMatch(SRC, /positive, code-grounded disproof/, "the unearnable refutation bar is back");
  assert.match(SRC, /READING standard, not a running standard/,
    "the prompt must tell the refuter that contradicting the claim is a reading standard");
});

test("the out-of-band ticket is not a verdict and cannot replace the score", () => {
  assert.match(SRC, /OUT-OF-BAND TICKET/, "expected the experiment field to be labelled as a ticket");
  assert.match(SRC, /it does not replace your score/, "the prompt must say the ticket does not substitute for scoring");
  // The old shape demoted an experiment-less abstention to 'stands'. Nothing may
  // demote on the ticket now, because it no longer competes with the score.
  assert.doesNotMatch(SRC, /counted as 'stands'/, "the abstention demotion is back");
});

test("strictness lives in the pipeline as named, tunable numbers", () => {
  assert.match(SRC, /const TUNING = \{/, "the cut must be a pipeline value, not an adjective in a prompt");
  // Stated numerically to the refuter, per the confidence-target prescription,
  // and INTERPOLATED so tuning the number cannot leave the prompt quoting a
  // stale price.
  assert.match(SRC, /\$\{TUNING\.refutedAt\}/, "the prompt must interpolate the live cut, not restate it");
  assert.match(SRC, /\$\{TUNING\.killVotes\}/, "the prompt must interpolate the live kill threshold");
  assert.match(SRC, /\$\{WRONG_CALL_PENALTY\}/, "the prompt must state the payoff numerically");
  assert.match(SRC, /t\/\(1-t\)/, "the payoff must be traceable to the rule it comes from");
});

// --- the vote arithmetic, extracted and actually executed --------------------
// A Workflow script runs against injected globals with no module access, so it
// cannot be imported and the tally cannot live in a shared file. Extracting the
// marked block and evaluating it is how the arithmetic gets real behavioural
// coverage instead of a grep over its source. The WHOLE block is extracted (not
// just the function), because the tunables it defaults to are part of the
// behaviour under test.
const tallySrc = SRC.match(/\/\/ TALLY-START[\s\S]*?\n([\s\S]*?)\n\/\/ TALLY-END/);
assert.ok(tallySrc, "could not extract the TALLY block — keep the markers around the tunables and a single pure `tally`");
const { tally, TUNING } = new Function(`${tallySrc[1]}; return { tally, TUNING };`)();

test("the shipped tuning is the documented one", () => {
  // The kill threshold is deliberately NOT retuned by the scalar change: the
  // literature says the optimal threshold needs a calibration set with
  // ground-truth labels, and picking one without it just re-rolls the dice that
  // produced 63% and 2.7%. This assertion is here to be edited BY that work.
  assert.equal(TUNING.killVotes, 2, "the kill threshold moved without a calibration set");
  // 0.5 is the neutral cut — the only value that asserts nothing about the
  // relative cost of a wrong kill versus a wrong pass.
  assert.equal(TUNING.refutedAt, 0.5);
  assert.equal(TUNING.proofTickets, 1);
  // Enumerated, so a tunable added without the comment that justifies it fails
  // here rather than shipping as an unexplained number.
  assert.deepEqual(Object.keys(TUNING).sort(), ["effort", "killVotes", "proofTickets", "refutedAt"], "a new tunable must be named here and stamped into the record (see the effort test)");
});

// A refuter's answer: evidence fields plus a score, and optionally a ticket.
const vote = (confidence, experiment) => ({
  read: "src/x.ts:1-20",
  evidence: "src/x.ts:14 guards it",
  falsifier: "a caller that skips the guard",
  confidence,
  ...(experiment ? { experiment } : {}),
});
const REF = vote(0.9), STANDS = vote(0.1);
const TICKET = vote(0.2, "pnpm test foo");

test("tally: two refutations kill; one does not", () => {
  assert.equal(tally([REF, REF, STANDS]).confirmed, false);
  assert.equal(tally([REF, STANDS, STANDS]).confirmed, true);
});

test("tally: the cut is strictly greater than the threshold", () => {
  // "Answer only if you are > t confident" — a score sitting exactly on the cut
  // is not a refutation, in either the prompt's telling or the arithmetic's.
  const ON_THE_CUT = vote(TUNING.refutedAt);
  assert.equal(tally([ON_THE_CUT, ON_THE_CUT, ON_THE_CUT]).refutedVotes, 0);
  const JUST_OVER = vote(TUNING.refutedAt + 0.01);
  assert.equal(tally([JUST_OVER, JUST_OVER, STANDS]).confirmed, false);
});

test("tally: a lost or unscored vote never counts as a refutation and never lowers the bar", () => {
  // The bug this guards: renormalising to "a majority of votes cast" would make
  // one refuter a majority once two are lost, handing a single voter a veto
  // exactly when the panel knows least.
  assert.equal(tally([REF, null, null]).confirmed, true, "1 refutation must not kill, however many were lost");
  assert.equal(tally([REF, { read: "x", evidence: "y", falsifier: "z" }, {}]).confirmed, true, "a scoreless answer is a lost vote, not a refutation");
  assert.equal(tally([REF, vote("high"), vote(NaN)]).confirmed, true, "a non-numeric score is a lost vote");
});

test("tally: the ticket suspends a surviving finding, and never resolves one", () => {
  assert.equal(tally([TICKET, STANDS, STANDS]).needsProof, true, "one ticket routes to the empirical gate");
  assert.equal(tally([TICKET, STANDS, STANDS]).experiment, "pnpm test foo", "the named experiment must reach the prover");
  assert.equal(tally([TICKET, STANDS, STANDS]).confirmed, true, "a ticket must not kill a finding");
  assert.equal(tally([STANDS, STANDS, STANDS]).needsProof, false, "nothing to run when nobody ticketed");
  assert.equal(tally([REF, REF, TICKET]).needsProof, false, "a killed finding is not worth a sandbox");
});

test("tally: a ticket carries no weight on the score", () => {
  // The old shape made abstention a THIRD VERDICT, so filing one was a way of
  // not scoring — and it was demoted to 'stands' when no experiment was named,
  // which drained mass into the free option. Now the two axes are independent:
  // a ticketing refuter still scores, and its score counts exactly as much.
  const TICKETED_REFUTATION = vote(0.9, "pnpm test foo");
  const t = tally([TICKETED_REFUTATION, REF, STANDS]);
  assert.equal(t.confirmed, false, "a refuter that also ticketed still casts a full refutation");
  assert.equal(t.needsProof, false);
  // A ticket with no command is simply not a ticket — nothing to demote.
  assert.equal(tally([vote(0.1, "   "), STANDS, STANDS]).needsProof, false);
});

test("tally: the thresholds are parameters, not constants baked into the arithmetic", () => {
  // Tier 2 (a labeled calibration set) is what earns a different threshold. Its
  // edit must be one number, so this asserts the number is actually plumbed.
  const minorityVeto = { ...TUNING, killVotes: 1 };
  assert.equal(tally([REF, STANDS, STANDS], minorityVeto).confirmed, false, "killVotes must be honoured");
  const strict = { ...TUNING, refutedAt: 0.95 };
  assert.equal(tally([REF, REF, REF], strict).confirmed, true, "refutedAt must be honoured");
  const patient = { ...TUNING, proofTickets: 2 };
  assert.equal(tally([TICKET, STANDS, STANDS], patient).needsProof, false, "proofTickets must be honoured");
});

test("tally: `scored: 0` is the panel not running, and it is a different fact from `needsProof`", () => {
  // Why `unscored` had to become its own key. These two findings are both
  // `unverified`, and nothing else about them is alike: one is an audit result
  // (reading ran out, a ticket was filed, the sandbox is the next step), the
  // other is an outage wearing the first one's clothes.
  const deadPanel = tally([null, null, null]);
  assert.equal(deadPanel.confirmed, true, "a finding no refuter scored SURVIVES the arithmetic — that is exactly the hazard, and why it needs its own count");
  assert.equal(deadPanel.scored, 0);
  assert.equal(deadPanel.needsProof, false, "a dead panel files no tickets, so the needsProof half of `unverified` never sees it");
  const unsettled = tally([TICKET, STANDS, STANDS]);
  assert.equal(unsettled.scored, 3, "reading-could-not-settle is a FULLY scored finding");
  assert.equal(unsettled.needsProof, true);
});

test("tally: `scored` counts usable scores, so every shape of dead panel reaches `unscored`", () => {
  // The incident arrived in more than one costume, and `unscored` has to see
  // all of them: a subagent that returned null (an API error the harness gave
  // up on), a refuter whose dispatch THREW (`parallel` swallows it to the same
  // null), and an answer that came back without a usable number. The breaker
  // that was removed only ever saw the first. This is the count that does not
  // care which one it was.
  for (const deadPanel of [
    [null, null, null],
    [undefined, null, undefined],
    [{ read: "x", evidence: "y", falsifier: "z" }, {}, null],
    [vote("high"), vote(NaN), null],
  ]) {
    const t = tally(deadPanel);
    assert.equal(t.scored, 0, `no usable score in ${JSON.stringify(deadPanel)}, so scored must be 0`);
    assert.equal(t.confirmed, true, "and it still survives — which is precisely why the record has to say so");
  }
  // One real score is not a dead panel, however thin the evidence around it.
  assert.equal(tally([STANDS, null, null]).scored, 1, "a single usable score means the panel ran, badly — not that it never ran");
});

test("a range end that is not an immutable commit id is refused before the panel is paid for", () => {
  // The record is assembled from this string verbatim, so a ref here reaches
  // audit-gate.sh, where it makes every done-flip an ancestor of the range and
  // the coverage claim unfalsifiable.
  assert.match(SRC, /rangeEnds/, "expected the range to be split and checked")
  assert.match(SRC, /\^\[0-9a-f\]\{40\}\$/, "expected a full-SHA test on each end")
  const guard = SRC.indexOf("rangeEnds")
  const record = SRC.indexOf("const record = [")
  const finders = SRC.indexOf("const found = await pipeline(")
  assert.ok(guard > 0 && guard < finders, "the guard must run BEFORE the finders, not at record time")
  assert.ok(guard < record, "and certainly before the record is assembled")
  assert.match(SRC, /never a ref such as HEAD, a branch name or a tag/,
    "the SCOPE schema must ask for SHAs, so the guard is a backstop and not the only signal")
})

// --- Validate: proofs reach the record ------------------------------------------
// The F12 audit (2026-09-12, wf_880c48cf-167) dispatched 26 provers, every one
// returned an execution-backed verdict, and the record showed 26 UNVERIFIED with
// no evidence. Cause, measured with a probe workflow: a value returned through
// parallel() is a CLONE — `{ finding: f, proof }` came back with
// `wrapper.finding !== f` — so the loop wrote the verdict onto the clone and the
// record read the original. The block is applied by index and evaluated here
// against a structuredClone'd result array, the same shape the harness hands back.
const proofsSrc = SRC.match(/\/\/ PROOFS-START[\s\S]*?\n([\s\S]*?)\n\/\/ PROOFS-END/);
assert.ok(proofsSrc, "could not extract the PROOFS block — keep the markers around a single pure `applyProofs`");
const { applyProofs } = new Function(`${proofsSrc[1]}; return { applyProofs };`)();

const pendingFixture = () => [
  { title: "a", confirmed: true, needsProof: true, scored: 3 },
  { title: "b", confirmed: true, needsProof: true, scored: 3 },
  { title: "c", confirmed: true, needsProof: true, scored: 3 },
  { title: "d", confirmed: true, needsProof: true, scored: 3 },
];

test("prover verdicts are applied to the ORIGINAL findings even when the results come back cloned", () => {
  const pending = pendingFixture();
  const returned = structuredClone([
    { verdict: "confirmed", evidence: "$ just test x\n1 passed" },
    { verdict: "refuted", evidence: "$ just test y\nthe guard fires" },
    { verdict: "unverifiable", evidence: "needs live credentials" },
    null,
  ]);
  applyProofs(pending, returned);
  assert.equal(pending[0].proven, "confirmed");
  assert.equal(pending[0].confirmed, true);
  assert.equal(pending[0].proofEvidence, "$ just test x\n1 passed");
  assert.equal(pending[1].proven, "refuted");
  assert.equal(pending[1].confirmed, false, "an execution-backed refutation kills the finding");
  assert.equal(pending[2].proven, "unverifiable");
  assert.equal(pending[2].confirmed, true);
  assert.equal(pending[3].proven, "lost", "a null slot is a LOST validator, distinct from one that ran and could not settle");
  assert.equal(pending[3].confirmed, true, "losing the validator never kills and never verifies");
  assert.equal(pending[3].proofEvidence, null);
});

test("the Validate dispatch carries no object identity through parallel()", () => {
  const validate = SRC.slice(SRC.indexOf("const proofs = await parallel("), SRC.indexOf("// PROOFS-START"));
  assert.doesNotMatch(validate, /\.then\(\s*\(\w+\)\s*=>\s*\(\{\s*finding/,
    "wrapping the finding in the thunk's return value is the exact bug: the wrapper comes back cloned and the write lands on the clone");
  assert.match(SRC, /applyProofs\(pending, proofs\)/, "the block must be applied to `pending`, the same array the record is built from");
  assert.match(SRC, /const pending = all\.filter\(\(f\) => f\.needsProof\)/, "`pending` must be a filter over `all`, so its elements ARE the record's objects");
});

test("a lost sandboxed run is named in the record, apart from one that ran and could not settle", () => {
  assert.match(SRC, /f\.proven === 'lost' \? ' and the sandboxed run was lost/,
    "the record must tell a validator that never answered from one that answered `unverifiable`");
  const unverifiedRule = SRC.match(/const isUnverified = \(f\) => (.+)/);
  assert.ok(unverifiedRule);
  assert.match(unverifiedRule[1], /f\.proven !== 'confirmed'/, "`lost` and `unverifiable` must both count as unverified — only an execution-backed `confirmed` clears it");
});

test("the record writes the reading/running join down where it accumulates", () => {
  // Per block: how the panel voted and what execution said. Per record: how many
  // experiments were dispatched and how each ended. These are the labeled rows a
  // future recalibration of TUNING needs, grown from real records — and
  // `proofs_lost:` is the number the gate reads.
  assert.match(SRC, /`refuted_votes: \$\{f\.refutedVotes \?\? 0\}\/\$\{f\.scored \?\? 0\}`/, "each block must carry the panel's vote ratio");
  assert.match(SRC, /`proven: \$\{f\.proven \?\? 'none'\}`/, "each block must carry the execution verdict, or 'none' when nothing was ticketed");
  const fm = SRC.slice(SRC.indexOf("`finders_reporting: ${reporting.length}`"), SRC.indexOf("`workflow_run: <FILL"));
  assert.match(fm, /\.\.\.\(pending\.length\s*\?/, "the join keys are emitted only when the Validate stage ran");
  for (const k of ["proofs_dispatched", "proof_confirmed", "proof_refuted", "proof_unverifiable"]) {
    assert.match(fm, new RegExp("`" + k + ": "), `frontmatter must carry ${k}:`);
  }
  assert.match(fm, /\.\.\.\(proofCount\('lost'\) \? \[`proofs_lost: /, "`proofs_lost:` is emitted only when non-zero, like `unscored:` — presence is the signal the gate keys on");
  assert.match(SRC, /proofs_lost: proofCount\('lost'\),/, "stats must carry proofs_lost too, so the run summary cannot say '26 unverified' without saying whether the experiments were read");
});

test("a lost experiment is logged with the ⚠ shape and names the gate key", () => {
  assert.match(SRC, /if \(proofCount\('lost'\)\) \{\s*\n\s*log\(\s*\n\s*`⚠ /, "lost provers get the same loud shape as an unscored panel");
  assert.match(SRC, /proofs_lost_accepted/, "the log must name the discharge key so the operator knows the two honest exits");
});

test("effort is a named tunable stamped into the record, not a literal at the dispatch sites", () => {
  assert.deepEqual(TUNING.effort, { find: "high", refute: "high", prove: "high" }, "the shipped regime is high on every stage; change it only with a labeled comparison");
  const code = SRC.split("\n").filter((l) => !l.trimStart().startsWith("//")).join("\n");
  assert.doesNotMatch(code, /effort: 'high'/, "no dispatch may hard-code effort — the record could not say which regime produced its rows");
  for (const stage of ["find", "refute", "prove"]) {
    assert.match(SRC, new RegExp("effort: TUNING\\.effort\\." + stage), `the ${stage} dispatch must read TUNING.effort.${stage}`);
    assert.match(SRC, new RegExp("`" + stage + "_effort: \\$\\{TUNING\\.effort\\." + stage + "\\}`"), `frontmatter must stamp ${stage}_effort:`);
  }
});
