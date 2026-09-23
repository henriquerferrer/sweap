// run.test.mjs — guards the run workflow's WIRING, the way milestone-audit.test.mjs
// guards the audit's read-only property. The script cannot be imported (it runs
// against Workflow-provided globals and has top-level awaits), so these are
// source-level assertions over the properties the design memo
// (docs/research/2026-09-22-run-cost-and-24-7.md) rests on. Each one names the
// defect a refuter demonstrated would return if the line were dropped.
//
// Run: node --test plugin/workflows/run.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = readFileSync(join(HERE, "run.js"), "utf8");
const WATCHER = readFileSync(join(HERE, "..", "agents", "merge-watcher.md"), "utf8");
const SECURITY = readFileSync(join(HERE, "..", "agents", "security-reviewer.md"), "utf8");
const PLAYBOOK = readFileSync(join(HERE, "..", "playbook", "agentic-loop-playbook.md"), "utf8");

const metaLiteral = () => {
  const m = SRC.match(/export const meta = (\{[\s\S]*?\n\})\n/);
  assert.ok(m, "meta block not found");
  return new Function(`return (${m[1]})`)();
};

test("meta is a pure literal whose phases match every phase() and phase: string in the body", () => {
  const meta = metaLiteral();
  assert.equal(meta.name, "run");
  const titles = meta.phases.map((p) => p.title);
  const used = new Set([...SRC.matchAll(/phase\('([A-Za-z]+)'\)/g)].map((m) => m[1]).concat([...SRC.matchAll(/phase:\s*'([A-Za-z]+)'/g)].map((m) => m[1])));
  for (const u of used) assert.ok(titles.includes(u), `phase "${u}" is used but not declared in meta.phases`);
});

test("the loop is strictly serial: no pipeline()/parallel() over items, a while loop with awaits", () => {
  assert.ok(!/\bpipeline\(/.test(SRC), "pipeline() runs items concurrently (workflow-authoring); the playbook's 'One item at a time' forbids it");
  assert.ok(!/\bparallel\(/.test(SRC), "parallel() is a barrier over concurrent agents; one item in flight, ever");
  assert.match(SRC, /while \(count < MAX_ITEMS\)/);
});

test("every agent() call goes through call(): null and throw both end as a reported stop", () => {
  const bare = [...SRC.matchAll(/await agent\(/g)];
  assert.equal(bare.length, 1, "exactly one direct agent() call, inside call()");
  assert.match(SRC, /const call = async \(prompt, opts\) => \{\s*try \{/);
  assert.match(SRC, /if \(out === null \|\| out === undefined\) return \{ ok: false/);
  assert.match(SRC, /catch \(e\) \{\s*return \{ ok: false/);
  // The loop stops with a reason on every !ok, never continues past a dead agent.
  for (const name of ["resumed", "scoped", "implemented", "watched", "fixed"]) {
    assert.match(SRC, new RegExp(`if \\(!${name}\\.ok\\)`), `${name} is not checked for ok`);
  }
});

test("implementer and fixer name their model and run as general-purpose (the session model is not the cost basis)", () => {
  const impl = SRC.match(/label: `implement \$\{item\.id\}`[^\n]*/)[0];
  const fix = SRC.match(/label: `fix \$\{item\.id\}[^\n]*/)[0];
  for (const line of [impl, fix]) {
    assert.match(line, /model: MODEL/, `no explicit model: ${line}`);
    assert.match(line, /agentType: 'general-purpose'/, `implementer/fixer needs the Agent tool to dispatch the reviewer: ${line}`);
  }
  assert.match(SRC, /const MODEL = [^\n]*'opus'/);
});

test("the merge wait is a separate small agent resolved under its plugin-scoped name", () => {
  assert.match(SRC, /`\$\{PLUGIN_NAME\}:merge-watcher`, 'merge-watcher'/);
  assert.match(SRC, /await callWatcher\(watchPrompt/);
  const watch = SRC.match(/label: `watch #\$\{impl\.pr\}`[^\n]*/)[0];
  assert.ok(!/model:/.test(watch), "the watcher's model comes from its own frontmatter, not the implementer's");
});

test("merge-watcher.md: 1h cache, no write tools, foreground bounded tick, attended re-check, held-by retry", () => {
  const fm = WATCHER.split("---")[1];
  assert.match(fm, /cacheTtl: 1h/, "the watcher is the one agent that idles past 5 minutes on purpose");
  const tools = fm.match(/^tools:\s*(.*)$/m)[1];
  for (const t of ["Write", "Edit", "NotebookEdit", "Agent"]) assert.ok(!tools.split(/[,\s]+/).includes(t), `watcher must not carry ${t}`);
  assert.match(WATCHER, /sweap-merge tick <n> --budget 540/, "tick is the bounded verb that always prints its closing word; watch re-ticks until terminal and can be killed by the Bash timeout with nothing printed");
  assert.match(WATCHER, /`600000`/);
  assert.match(WATCHER, /actions\/runners/, "an attended word is checked against the fleet before it is believed (lane lessons 10 and 17)");
  assert.match(WATCHER, /held-by:<owner>[^\n]*\n?[^|]*sleep 150/);
  assert.match(WATCHER, /never `gh pr merge` by hand/);
});

test("attended and held-by never stop the run; only a dead agent or a red base does", () => {
  // The run-stopping assignments name their causes.
  const stops = [...SRC.matchAll(/stopped = [^\n]+/g)].map((m) => m[0]);
  for (const s of stops) assert.ok(!/attended|held-by/.test(s), `a stop on ${s}`);
  assert.match(SRC, /watch\.class === 'base-red'\) \{\s*stopped =/);
  assert.match(SRC, /needsHuman\.push\(\{ id: item\.id, pr: impl\.pr, word: watch \? watch\.word/);
});

test("the fix loop is bounded and hands every prior round to the next fixer", () => {
  assert.match(SRC, /const MAX_FIX_ROUNDS = 3/);
  assert.match(SRC, /rounds\.length >= MAX_FIX_ROUNDS\) break/);
  assert.match(SRC, /fixPrompt\(item, impl, watch, rounds\)/);
  assert.match(SRC, /Earlier fix rounds on this PR/);
});

test("scope is recomputed before every item and reads the frontier from sweap-frontier", () => {
  const loopBody = SRC.slice(SRC.indexOf("while (count < MAX_ITEMS)"));
  assert.match(loopBody, /scopePrompt\(IDS\)/);
  assert.match(SRC, /Run \\`sweap-frontier\\`/);
  assert.match(SRC, /attempted\.has\(i\.id\)/, "an item that failed without a PR must not be picked again forever");
});

test("the implementer brief binds to the playbook by its markers and never merges", () => {
  assert.match(SRC, /<!-- run-core:end -->/);
  assert.match(SRC, /worker-brief:begin -->\\` and \\`<!-- worker-brief:end -->/);
  assert.match(SRC, /never run \\`sweap-merge\\`/);
  assert.match(SRC, /RESUME it/);
  assert.match(SRC, /At most 2 review rounds/);
  assert.match(SRC, /never in parallel against this worktree/);
  assert.match(PLAYBOOK, /<!-- run-core:end -->/);
  assert.match(PLAYBOOK, /<!-- worker-brief:begin -->/);
});

test("no wall clock or randomness in the script (a relaunch must replay)", () => {
  assert.ok(!/Date\.now\(|new Date\(|Math\.random\(/.test(SRC));
});

test("security-reviewer.md tells the reviewer the skill collects its diff from the primary checkout", () => {
  assert.match(SECURITY, /collects its diff from the primary checkout/);
  assert.match(SECURITY, /git diff <base>\.\.\.HEAD/);
});

test("bin/sweap-frontier is executable and execs the board's frontier subcommand", () => {
  const p = join(HERE, "..", "bin", "sweap-frontier");
  assert.ok(statSync(p).mode & 0o111, "a bin/ wrapper nobody can execute is a launch line that fails");
  assert.match(readFileSync(p, "utf8"), /sweap-board\.mjs" frontier/);
});
