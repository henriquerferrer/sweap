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
  for (const name of ["resumed", "scoped", "implemented", "watched", "fixed", "published", "rev", "fix", "sec"]) {
    assert.match(SRC, new RegExp(`if \\(!${name}\\.ok\\)`), `${name} is not checked for ok`);
  }
});

test("implementer and fixer name their model and run as general-purpose (the session model is not the cost basis)", () => {
  const impl = SRC.match(/label: `implement \$\{item\.id\}`[^\n]*/)[0];
  const fix = SRC.match(/label: `fix \$\{item\.id\}[^\n]*/)[0];
  for (const line of [impl, fix]) {
    assert.match(line, /model: MODEL/, `no explicit model: ${line}`);
    assert.match(line, /agentType: 'general-purpose'/, `implementer/fixer run as general-purpose: ${line}`);
  }
  assert.match(SRC, /const MODEL = [^\n]*'opus'/);
});

test("the merge wait is a separate small agent resolved under its plugin-scoped name", () => {
  assert.match(SRC, /\[pluginTypes\[name\], `\$\{PLUGIN_NAME\}:\$\{name\}`, name\]/);
  assert.match(SRC, /const callWatcher = \(prompt, opts\) => callPlugin\('merge-watcher', prompt, opts\)/);
  assert.match(SRC, /await callWatcher\(watchPrompt/);
  const watch = SRC.match(/label: `watch #\$\{impl\.pr\}`[^\n]*/)[0];
  assert.ok(!/model:/.test(watch), "the watcher's model comes from its own frontmatter, not the implementer's");
});

test("merge-watcher.md: 1h cache, no write tools, foreground bounded tick, attended re-check, held-by retry", () => {
  const fm = WATCHER.split("---")[1];
  assert.match(fm, /cacheTtl: 1h/, "the watcher is the one agent that idles past 5 minutes on purpose");
  const tools = fm.match(/^tools:\s*(.*)$/m)[1];
  for (const t of ["Write", "Edit", "NotebookEdit", "Agent"]) assert.ok(!tools.split(/[,\s]+/).includes(t), `watcher must not carry ${t}`);
  assert.match(WATCHER, /sweap-merge tick <PR number from your dispatch> --budget 540/, "tick is the bounded verb that always prints its closing word; watch re-ticks until terminal and can be killed by the Bash timeout with nothing printed");
  assert.ok(!/<n>/.test(WATCHER), "a bare <n> placeholder was copied literally as `tick 1` on ~23 of 27 dispatches on a consumer (2026-09-23..25)");
  assert.match(WATCHER, /`600000`/);
  assert.match(WATCHER, /actions\/runners/, "an attended word is checked against the fleet before it is believed (lane lessons 10 and 17)");
  assert.match(WATCHER, /held-by:<owner>[^\n]*\n?[^|]*sleep 150/);
  assert.match(WATCHER, /never `gh pr merge` by hand/);
});

test("attended and held-by never stop the run; a dead agent, a red base or a dead fleet does", () => {
  assert.match(SRC, /class: \{ enum: \['gate', 'starved', 'base-red', 'red', 'fleet-down', '-'\] \}/, "structured output rejects a class outside the enum: the watcher's fleet-down would never reach the script");
  const branch = SRC.match(/watch\.class === 'fleet-down'\) \{([\s\S]*?)break\n/);
  assert.ok(branch, "a timed_out/fleet-down watch stops the run");
  assert.match(branch[1], /stopped = /);
  assert.ok(!/needsHuman\.push/.test(branch[1]), "the PR is not the human's: it resumes on relaunch; listing it would make the record say awaiting-human for a runner outage");
  const gate = SRC.match(/if \(resume\.fleet === 'fleet-down'\) \{([\s\S]*?)\n\}/);
  assert.ok(gate && /return \{/.test(gate[1]), "the Resume stage stops the run before any implementer when sweap-fleet says fleet-down");
  assert.ok(SRC.indexOf("resume.fleet === 'fleet-down'") < SRC.indexOf("while (count < MAX_ITEMS)"));
  assert.match(SRC, /sweap-merge tick \$\{impl\.pr\} --budget 540/, "the dispatch names the PR number: two watchers read the brief's <n> placeholder literally and ticked PR #1 (a consumer, 2026-09-24)");
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

test("scope is recomputed before every item and reads the frontier from sweap-frontier; the script picks, the agent does not", () => {
  const loopBody = SRC.slice(SRC.indexOf("while (count < MAX_ITEMS)"));
  assert.match(loopBody, /scopePrompt\(\)/, "the batch is not in the prompt: the agent cannot know which item the script will pick (attempted is script state)");
  assert.match(SRC, /Run \\`sweap-frontier\\`/);
  assert.match(SRC, /do not filter, reorder or judge the items/);
  assert.ok(!/const scopePrompt = [^\n]*lint/.test(SRC), "Scope no longer lints 'the first item you return' — it could not know which one that is; the implementer's step 1 lints");
  assert.match(loopBody, /pickOrder\(scoped\.value\.frontier, IDS, MILESTONE\)\.find\(\(i\) => !attempted\.has\(i\.id\)\)/);
  assert.match(SRC, /attempted\.has\(i\.id\)/, "an item that failed without a PR must not be picked again forever");
  assert.match(SRC, /skipped: IDS \? IDS\.filter\(\(id\) => !attempted\.has\(id\)\) : \[\]/, "skipped is derived from what was never picked, not accumulated from a per-scope 'not runnable yet' list (an item runnable only after a dependency merged used to be reported both merged and skipped)");
  assert.ok(!/replay from the journal/.test(SRC), "a relaunch is fresh: a journal resume would replay the first launch's Resume result and hand the next implementer stale worktree/PR state");
});

// The pick-order helpers are pure; evaluate them out of the source.
const helpers = () => {
  const one = (name) => { const m = SRC.match(new RegExp(`const ${name} = [^\\n]*\\n`)); assert.ok(m, `${name} not found`); return m[0]; };
  const block = SRC.match(/const pickOrder = [\s\S]*?\n\}\n/);
  assert.ok(block, "pickOrder not found");
  return new Function(`${one("milestoneOf")}${one("allowedFor")}${block[0]}; return { milestoneOf, allowedFor, pickOrder }`)();
};

test("allowedFor: this milestone's items and OTHER milestones' follow-ups; never this milestone's follow-ups, never a deeper id that merely shares the prefix", () => {
  const { milestoneOf, allowedFor } = helpers();
  assert.equal(milestoneOf("DS.2.1"), "DS.2");
  assert.equal(milestoneOf("F13.4"), "F13");
  const t = (id, followupOf, M) => allowedFor({ id, followupOf }, M);
  assert.equal(t("F13.1", null, "F13"), true);
  assert.equal(t("F14.1", null, "F13"), false, "a consumer, 2026-09-23: a bare launch listed F14.1 and five F15 items for an F13 run");
  assert.equal(t("FP.2", "F12", "F13"), true, "debt of an earlier milestone is drained first");
  assert.equal(t("DV.48", "DV", "F13"), true, "a follow-up family keyed by followup_of alone (no milestone prefix) is still debt");
  assert.equal(t("F13.28", "F13", "F13"), false, "a follow-up OF this milestone is the next run's debt; the goal stops on it");
  assert.equal(t("DS.2.1", null, "DS"), false, "startsWith would admit milestone DS.2 into a DS run");
  assert.equal(t("DS.1", null, "DS"), true);
  assert.equal(t("F14.1", null, null), true, "no milestone: the whole frontier, as before");
});

test("pickOrder: the batch first in batch order, then the milestone frontier; ids alone stay a batch; nothing alone stays the frontier", () => {
  const { pickOrder } = helpers();
  const frontier = [
    { id: "FP.2", followupOf: "F12" }, { id: "FP.7", followupOf: "F12" }, { id: "DV.48", followupOf: "DV" },
    { id: "F13.1" }, { id: "F14.1", followupOf: null },
  ];
  const ids = (r) => r.map((i) => i.id);
  assert.deepEqual(ids(pickOrder(frontier, ["DV.48", "FP.7", "FP.2", "FP.99"], "F13")), ["DV.48", "FP.7", "FP.2", "F13.1"], "the kickoff's drain order wins over the frontier's, and a batch id the frontier does not list is simply absent this scope");
  assert.deepEqual(ids(pickOrder(frontier, ["DV.48", "FP.7"], null)), ["DV.48", "FP.7"], "ids without a milestone: the batch and nothing else");
  assert.deepEqual(ids(pickOrder(frontier, null, "F13")), ["FP.2", "FP.7", "DV.48", "F13.1"]);
  assert.deepEqual(ids(pickOrder(frontier, null, null)), ["FP.2", "FP.7", "DV.48", "F13.1", "F14.1"]);
  assert.deepEqual(ids(pickOrder(null, ["FP.2"], "F13")), []);
  assert.equal(pickOrder([{ id: "F13.1" }], null, "F13")[0].followupOf, null, "an omitted followupOf reads as null, never as 'some other milestone'");
});


test("the implementer brief binds to the playbook by its markers and never merges", () => {
  assert.match(SRC, /<!-- run-core:end -->/);
  assert.match(SRC, /worker-brief:begin -->\\` and \\`<!-- worker-brief:end -->/);
  assert.match(SRC, /never run \\`sweap-merge\\`/);
  assert.match(SRC, /RESUME it/);
  assert.match(SRC, /Never dispatch an agent, never start the code-review or security-review skill, and never leave anything running in the background/, "a consumer run (2026-09-25): the implementer's own review forked into the background and forced its return — four items failed, two PRs went unreviewed");
  assert.ok(!/subagent_type: "\$\{PLUGIN_NAME\}:reviewer"/.test(SRC), "the implementer no longer dispatches the reviewer; the script does");
  assert.match(PLAYBOOK, /Under `\/sweap:run` you do not review, push or open the PR/, "the worker brief must not tell a run implementer to review, or the fork comes back");
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

test("args: an object, a JSON string (parsed), a comma list, or nothing; a JSON-looking string that does not parse stops the run", () => {
  const block = SRC.match(/const parseArgs = [\s\S]*?\n\}\n/);
  assert.ok(block, "parseArgs not found");
  const parseArgs = new Function(`${block[0]}; return parseArgs`)();
  assert.deepEqual(parseArgs({ ids: ["A"], milestone: "F13" }), { ids: ["A"], milestone: "F13" });
  assert.deepEqual(parseArgs('{"ids": ["DV.48", "FP.2"], "milestone": "F13"}'), { ids: ["DV.48", "FP.2"], milestone: "F13" }, "a model launching from a goal sentence has passed a JSON string before (a consumer, 2026-09-02); it must not become garbage ids");
  assert.deepEqual(parseArgs("DV.48, FP.2"), { ids: ["DV.48", "FP.2"] });
  assert.deepEqual(parseArgs(["DV.48", "FP.2"]), { ids: ["DV.48", "FP.2"] }, "a bare array is a batch (the workflow-authoring reference passes args that way), never a silent whole-frontier run");
  assert.deepEqual(parseArgs('["DV.48"]'), { ids: ["DV.48"] });
  assert.match(SRC, /const RAW_IDS = typeof ARGS\.ids === 'string' \? ARGS\.ids\.split/, "{ids: 'DV.48, FP.2'} is a batch too");
  assert.match(SRC, /if \(scoped\.value\.command_missing\) \{ stopped = /, "a missing sweap-frontier stops the run; an empty frontier for that reason must never read as drained (the goal would audit on nothing)");
  assert.deepEqual(parseArgs(undefined), {});
  assert.deepEqual(parseArgs("  "), {});
  assert.equal(parseArgs('{"ids": [').bad_args, '{"ids": [');
  assert.match(SRC, /if \(ARGS\.bad_args\) return \{[^\n]*stopped: `args was a string that is not valid JSON/);
  assert.match(SRC, /const MILESTONE = typeof ARGS\.milestone === 'string'/);
});

// The open-PR skip is pure and lives in the script.
const prHelpers = () => {
  const one = (re) => { const m = SRC.match(re); assert.ok(m, `helper not found: ${re}`); return m[0]; };
  const src = one(/const branchTail = [^\n]*\n/) + one(/const branchIsFor = [\s\S]*?\n\}\n/) + one(/const carriesAnId = [^\n]*\n/) + one(/const pick = [\s\S]*?\n\}\n/) + one(/const openPrFor = [\s\S]*?\n\}\n/);
  return new Function(`${src}; return { branchIsFor, openPrFor }`)();
};

test("branchIsFor: the brief's branch shape, anchored at the start, dot-depth safe", () => {
  const { branchIsFor } = prHelpers();
  assert.equal(branchIsFor("feat/f13-4-unrestricted-hours", "F13.4"), true);
  assert.equal(branchIsFor("chore/f13-6-wait-on-f13-20", "F13.6"), true);
  assert.equal(branchIsFor("chore/f13-6-wait-on-f13-20", "F13.20"), false, "a later mention of another id does not claim the branch");
  assert.equal(branchIsFor("fix/ds-5-3-x", "DS.5.3"), true);
  assert.equal(branchIsFor("fix/ds-5-3-x", "DS.5"), false, "DS.5's prefix is a prefix of DS.5.3's branch");
  assert.equal(branchIsFor("fix/fp-26-refusal-session-epoch", "FP.26"), true);
  assert.equal(branchIsFor("main", "F13.4"), false);
  assert.equal(branchIsFor("feat/F13-4-Hours", "F13.4"), true, "case-insensitive");
  assert.equal(branchIsFor("feat/f13-4", "F13.4"), true, "no slug");
});

test("openPrFor: an open PR for the item (by the Resume mapping or by branch) sends the item straight to the watcher, with its worktree", () => {
  const { openPrFor } = prHelpers();
  const resume = { open_prs: [{ number: 407, branch: "feat/f13-4-unrestricted-hours", item: "" }, { number: 408, branch: "feat/f13-5-service-duration", item: "F13.5" }], worktrees: [{ path: "/wt/f13-4", branch: "feat/f13-4-unrestricted-hours", item: "" }] };
  assert.deepEqual(openPrFor(resume, "F13.4"), { number: 407, branch: "feat/f13-4-unrestricted-hours", worktree: "/wt/f13-4" });
  assert.deepEqual(openPrFor(resume, "F13.5"), { number: 408, branch: "feat/f13-5-service-duration", worktree: "" });
  assert.equal(openPrFor(resume, "F13.6"), null);
  const mis = { open_prs: [{ number: 420, branch: "chore/f13-20-rekey", item: "F13.2" }], worktrees: [] };
  assert.equal(openPrFor(mis, "F13.2"), null, "a mis-mapped item field does not steer the watcher to another item's PR: the branch names F13.20");
  assert.equal(openPrFor(mis, "F13.20").number, 420);
  assert.equal(openPrFor({ open_prs: [{ number: 7, branch: "hotfix/typo", item: "F13.2" }] }, "F13.2").number, 7, "a branch outside the shape falls back to the mapping");
  assert.equal(openPrFor({}, "F13.6"), null);
  assert.match(SRC, /const already = openPrFor\(resume, item\.id\)/);
  assert.match(SRC, /watch\.word === 'merged' && watch\.status_done === 'no'\)/, "a PR that merged without the item reading done is a person's to read, never recorded as merged — resumed or published by the script");
  assert.match(SRC, /const wtOf = \(impl\) => impl\.worktree \|\|/, "a resumed PR with no known worktree tells the watcher and the fixer to add one, never to use the primary checkout");
});


// ---------------------------------------------------------------------------
// The review stage, driven end to end with stub agents: the script runs as the
// Workflow runtime runs it (an async body over agent/phase/log/args), and each
// stub answers by label. These pin the ORDER and the outcomes, which a
// source-level regex cannot.
const AsyncFn = Object.getPrototypeOf(async function () {}).constructor;
const simulate = async (over = {}, frontierItem = { id: "F1.1", followupOf: null, reviewDimensions: [] }) => {
  const calls = [];
  const agent = async (prompt, opts) => {
    calls.push({ label: opts.label, agentType: opts.agentType, prompt });
    const k = opts.label.split(" ")[0];
    const n = calls.filter((c) => c.label.split(" ")[0] === k).length;
    if (over[k]) { const v = over[k](n, opts); if (v instanceof Error) throw v; if (v !== undefined) return v; }
    switch (k) {
      case "resume": return { worktrees: [], open_prs: [], watches: [], plans_unchecked: [], notes: "", fleet: "ok", base: "trunk", backlog_dir: "backlog" };
      case "scope": return { frontier: n === 1 ? [frontierItem] : [] };
      case "implement": return { outcome: "committed", pr: null, branch: "feat/f1-1-x", worktree: "/wt/f1-1", red_green: "r/g", report: "done" };
      case "review": return { verdict: "approve", findings: [], files_reviewed: ["a.ts"], verdict_line: "Verdict: approve" };
      case "flip": return { outcome: "pr-open", pr: 77, branch: "chore/f1-1-blocked", worktree: "/wt/f1-1-blocked", report: "ok" };
      case "publish": return { outcome: "pr-open", pr: 42, report: "ok" };
      case "watch": { const pr = Number(opts.label.split("#")[1]); return { word: "merged", reason: "merged", pr, watch_calls: 1, status_done: pr === 77 ? "no" : "yes", cleanup: "clean" }; }
    }
    throw new Error(`unexpected agent ${opts.label}`);
  };
  const out = await new AsyncFn("agent", "phase", "log", "args", SRC.replace(/^export const meta/m, "const meta"))(agent, () => {}, () => {}, { ids: ["F1.1"] });
  return { out, labels: calls.map((c) => c.label), calls };
};
const needsWork = () => ({ verdict: "needs-work", findings: [{ file: "a.ts:1", what: "off by one", kind: "other" }], files_reviewed: ["a.ts"], verdict_line: "Verdict: needs-work" });

test("review stage: the SCRIPT awaits the reviewer before anything is pushed, and the reviewer is the plugin agent", async () => {
  const { out, labels, calls } = await simulate();
  assert.deepEqual(labels, ["resume", "scope #1", "implement F1.1", "review F1.1 #1", "publish F1.1", "watch #42", "scope #2"]);
  assert.equal(calls.find((c) => c.label === "review F1.1 #1").agentType, "sweap:reviewer");
  const rp = calls.find((c) => c.label === "review F1.1 #1").prompt;
  assert.match(rp, /\/wt\/f1-1/, "the reviewer runs from the primary checkout: it must be told the worktree");
  assert.match(rp, /origin\/trunk\.\.\.HEAD/, "the base the Resume stage read, never a <default branch> placeholder");
  assert.match(rp, /`backlog\/F1\.1\.md`/);
  assert.equal(out.merged[0].review_rounds, 1);
});

test("review stage: needs-work → fresh fixer → re-review with the earlier findings; at most two review rounds", async () => {
  const { out, labels, calls } = await simulate({ review: needsWork, "review-fix": () => ({ outcome: "committed", summary: "cut the claim" }) });
  assert.deepEqual(labels.slice(2, 8), ["implement F1.1", "review F1.1 #1", "review-fix F1.1 #1", "review F1.1 #2", "review-fix F1.1 #2", "publish F1.1"]);
  assert.match(calls.find((c) => c.label === "review F1.1 #2").prompt, /a\.ts:1: off by one/);
  assert.match(calls.find((c) => c.label === "review-fix F1.1 #2").prompt, /This is the LAST round/);
  assert.match(calls.find((c) => c.label === "publish F1.1").prompt, /cut the claim/, "what the last round left is stated in the PR");
  assert.equal(out.merged[0].review_rounds, 2);
});

test("review stage: a dead reviewer stops the run with nothing pushed; a blocked fixer never publishes", async () => {
  const dead = await simulate({ review: () => null });
  assert.ok(!dead.labels.some((l) => l.startsWith("publish")));
  assert.match(dead.out.stopped, /review F1\.1 #1/);
  const blocked = await simulate({ review: needsWork, "review-fix": () => ({ outcome: "blocked", summary: "s", question: "Which clinic wins?" }) });
  assert.ok(!blocked.labels.some((l) => l.startsWith("publish")), "the reviewed-but-blocked code is never pushed");
  assert.deepEqual(blocked.labels.slice(-3), ["flip F1.1", "watch #77", "scope #2"], "the blocked flip lands in a PR of its own and is watched to merge");
  assert.deepEqual(blocked.out.blocked, [{ id: "F1.1", pr: 77, question: "Which clinic wins?" }]);
  assert.deepEqual(blocked.out.merged, [], "a merged flip is not a merged item");
  assert.deepEqual(blocked.out.needs_human, [], "…and is listed once, under blocked");
  assert.match(blocked.calls.find((c) => c.label === "flip F1.1").prompt, /-b chore\/f1-1-blocked origin\/trunk/, "the flip branches off the default branch: no unreviewed code rides along");
});

test("security: tagged items get the security reviewer after the reviewer; a finding still blocking after one fix stays unpushed for a person", async () => {
  const sec = { id: "F1.1", followupOf: null, reviewDimensions: ["security"] };
  const clear = await simulate({ security: () => ({ verdict: "clear", findings: [], files_reviewed: ["api.ts"], verdict_line: "Security verdict: clear" }) }, sec);
  assert.deepEqual(clear.labels.slice(3, 6), ["review F1.1 #1", "security F1.1 #1", "publish F1.1"]);
  const blocking = await simulate({ security: () => ({ verdict: "blocking", findings: [{ file: "api.ts:3", what: "reads another org's rows", kind: "security" }], files_reviewed: ["api.ts"], verdict_line: "Security verdict: blocking" }), "security-fix": () => ({ outcome: "committed", summary: "tried" }) }, sec);
  assert.ok(!blocking.labels.some((l) => l.startsWith("publish")), "a blocking security verdict is never pushed");
  assert.equal(blocking.out.blocked[0].pr, 77, "an open security finding becomes a blocked flip, so the frontier stops re-picking it and /unblock accepts it");
  assert.match(blocking.out.blocked[0].question, /api\.ts:3/);
  const nodiff = await simulate({ security: () => ({ verdict: "no-diff", findings: [], files_reviewed: [], verdict_line: "" }) }, sec);
  assert.ok(!nodiff.labels.some((l) => l.startsWith("publish")), "no diff collected is not a clear (DV.47, FP.1)");
});

test("a watcher report about another PR is not a word about this one (the `tick 1` slip)", async () => {
  const once = await simulate({ watch: (n) => (n === 1 ? { word: "merged", reason: "merged", pr: 1, watch_calls: 1 } : undefined) });
  assert.equal(once.labels.filter((l) => l.startsWith("watch")).length, 2, "re-dispatched once, naming the right PR");
  assert.match(once.calls.filter((c) => c.label.startsWith("watch"))[1].prompt, /sweap-merge tick 42/);
  assert.equal(once.out.merged.length, 1);
  const always = await simulate({ watch: () => ({ word: "merged", reason: "merged", pr: 1, watch_calls: 1 }) });
  assert.equal(always.out.merged.length, 0, "PR #1 merging never records this item as merged");
  assert.equal(always.out.needs_human[0].word, "undecidable");
});

test("the implementer's blocked outcome lands a flip PR off the default branch; an empty diff or a missing worktree is never reviewed as approved", async () => {
  const impBlocked = await simulate({ implement: () => ({ outcome: "blocked", pr: null, branch: "feat/f1-1-x", worktree: "/wt/f1-1", red_green: "", question: "Q?", report: "r" }) });
  assert.deepEqual(impBlocked.labels.slice(2), ["implement F1.1", "flip F1.1", "watch #77", "scope #2"]);
  assert.deepEqual(impBlocked.out.blocked, [{ id: "F1.1", pr: 77, question: "Q?" }]);
  const empty = await simulate({ review: () => ({ verdict: "approve", findings: [], files_reviewed: [], verdict_line: "Verdict: approve" }) });
  assert.ok(!empty.labels.some((l) => l.startsWith("publish")), "an approve over no files is the empty-diff trap");
  assert.match(empty.out.failed[0].why, /no diff/);
  const rel = await simulate({ implement: () => ({ outcome: "committed", pr: null, branch: "feat/f1-1-x", worktree: "", red_green: "", report: "r" }) });
  assert.ok(!rel.labels.some((l) => l.startsWith("review")), "with no worktree path the reviewer would diff the primary checkout: main against main");
  assert.equal(rel.out.failed.length, 1);
});

test("an acceptance or security finding still open after two review rounds is never cut: the item goes blocked, unpushed", async () => {
  for (const kind of ["acceptance", "security"]) {
    const r = await simulate({ review: () => ({ verdict: "needs-work", findings: [{ file: "reminders.ts:40", what: "closest reminder does not win on low credit", kind }], files_reviewed: ["reminders.ts"], verdict_line: "Verdict: needs-work" }), "review-fix": () => ({ outcome: "committed", summary: "tried" }) });
    assert.deepEqual(r.labels.slice(3, 7), ["review F1.1 #1", "review-fix F1.1 #1", "review F1.1 #2", "flip F1.1"], `${kind}: no cutting round, no publish`);
    assert.ok(!r.labels.some((l) => l.startsWith("publish")));
    assert.match(r.out.blocked[0].question, new RegExp(`\\[${kind}\\] reminders\\.ts:40`));
    assert.deepEqual(r.out.merged, []);
  }
  assert.match(SRC, /Never close an \\`acceptance\\` or \\`security\\` finding by cutting a claim/, "the round-1 fixer may not cut one either");
});

// ---------------------------------------------------------------------------
// Review depth (a consumer run, 2026-09-27): the reviewer ran at the session's
// medium effort and its doubts went to an Advisory string nothing read.
test("the reviewer runs at high effort, named, never inherited from the session", () => {
  const line = SRC.match(/callPlugin\('reviewer',[^\n]*/)[0];
  assert.match(line, /effort: HUNT_EFFORT/);
});

const cand = (scope, what = "focus lands on the page after close") => ({ file: "patients.tsx:963", what, scope });
test("an approve's [diff] candidates get one fixer round to reproduce or dismiss, then a second review only if code changed", async () => {
  const changed = await simulate({ review: (n) => (n === 1 ? { verdict: "approve", findings: [], files_reviewed: ["a.ts"], candidates: [cand("diff")], verdict_line: "Verdict: approve" } : undefined), "review-fix": () => ({ outcome: "committed", changed: true, summary: "reproduced with a test, fixed" }) });
  assert.deepEqual(changed.labels.slice(3, 7), ["review F1.1 #1", "review-fix F1.1 #1", "review F1.1 #2", "publish F1.1"]);
  const fp = changed.calls.find((c) => c.label === "review-fix F1.1 #1").prompt;
  assert.match(fp, /returned no confirmed finding/);
  assert.match(fp, /UNCONFIRMED candidates[\s\S]*patients\.tsx:963/);
  assert.match(fp, /Never cut a claim, edit the item's acceptance or weaken a test for a candidate/);
  const dismissed = await simulate({ review: (n) => (n === 1 ? { verdict: "approve", findings: [], files_reviewed: ["a.ts"], candidates: [cand("diff")], verdict_line: "Verdict: approve" } : undefined), "review-fix": () => ({ outcome: "committed", changed: false, summary: "dismissed: the listener is gated" }) });
  assert.deepEqual(dismissed.labels.slice(3, 6), ["review F1.1 #1", "review-fix F1.1 #1", "publish F1.1"], "nothing changed, nothing to re-review");
});

test("candidates never block an item and never reach the uncuttable path; later rounds' ones only reach the PR body", async () => {
  const r = await simulate({ review: (n) => (n === 1 ? needsWork() : { verdict: "needs-work", findings: [{ file: "a.ts:2", what: "still off", kind: "other" }], files_reviewed: ["a.ts"], candidates: [cand("diff", "maybe a race")], verdict_line: "Verdict: needs-work" }), "review-fix": () => ({ outcome: "committed", changed: true, summary: "cut it" }) });
  assert.ok(r.labels.includes("publish F1.1"));
  assert.deepEqual(r.out.blocked, []);
  assert.match(r.calls.find((c) => c.label === "publish F1.1").prompt, /Unconfirmed candidates from the last round, not acted on: patients\.tsx:963: maybe a race/);
  assert.ok(!/maybe a race/.test(r.calls.find((c) => c.label === "review-fix F1.1 #2").prompt), "a round-2 candidate is not handed to the last fixer (it would be cut)");
});

test("[pre-existing] candidates are filed as discovered notes, on the published and on the blocked path, never given to the fixer", async () => {
  const pub = await simulate({ review: () => ({ verdict: "approve", findings: [], files_reviewed: ["a.ts"], candidates: [cand("pre-existing", "the empty-panel Reset unmounts under focus")], verdict_line: "Verdict: approve" }) });
  assert.ok(!pub.labels.some((l) => l.startsWith("review-fix")), "not this item's work");
  assert.match(pub.calls.find((c) => c.label === "publish F1.1").prompt, /cd \/wt\/f1-1 && sweap-note discovered '<a one-line title>' gap F1\.1[\s\S]*commit the new files[\s\S]*never changes your outcome[\s\S]*empty-panel Reset/);
  const blk = await simulate({ review: (n) => ({ ...needsWork(), findings: [{ file: "x.ts", what: "clause 3 unmet", kind: "acceptance" }], candidates: n === 1 ? [cand("pre-existing", "old listener")] : [] }), "review-fix": () => ({ outcome: "committed", changed: true, summary: "tried" }) });
  const flip = blk.calls.find((c) => c.label === "flip F1.1").prompt;
  assert.match(flip, /-blocked worktree[\s\S]*sweap-note discovered[\s\S]*chore\/f1-1-blocked[\s\S]*old listener/, "committed on the flip branch, so it reaches main");
  assert.ok(flip.indexOf("sweap-note") > flip.indexOf("Commit only that file"), "notes are filed after the flip commit, before the push");
  assert.equal((flip.match(/old listener/g) || []).length, 1, "a note re-raised by round 2 is filed once");
});

// The /goal condition is judged by a small model with no thinking, as ONE
// predicate over the whole text (a consumer, 2026-09-27: it agreed "NOTHING IS
// RUNNABLE is met", then refused 13 times because the preamble named the audit).
test("every goal template is a list of success states, the How is outside the check, and each cites a word the workflow really returns", () => {
  const MS = readFileSync(join(HERE, "..", "commands", "milestone.md"), "utf8");
  const goals = [...MS.matchAll(/```\n(\/goal [\s\S]*?)```/g)].map((m) => m[1]);
  assert.equal(goals.length, 3, "milestone+debt, hand-offs outstanding, debt-only");
  for (const raw of goals) {
    const g = raw.replace(/\s+/g, " ");
    assert.match(g, /^\/goal This goal is MET when ANY ONE of these is shown in the conversation:/);
    assert.match(g, /How \(instructions, NOT part of the check\):/);
    assert.match(g, /the human typed a message asking you to stop/);
    assert.match(g, /with no item under failed/);
    assert.match(g, /relaunch it fresh once/);
    assert.match(g, /"Ending the run"/);
    assert.ok(!/Stop when|stop, not a completion|below\)/.test(g), "the old grammar made the stop clauses exceptions to an audit precondition");
    const word = g.match(/returned "([a-zA-Z<> ]+drained)"/)[1];
    const shape = word.replace("<MILESTONE>", "${MILESTONE}");
    assert.ok(SRC.includes(g.includes('"milestone":') ? `\`${shape}\`` : `'${shape}'`), `the goal cites "${word}"; run.js must return exactly that for this template's args`);
  }
  assert.match(goals[0].replace(/\s+/g, " "), /\(B\) to \(E\) are successful ends of this run, not failures, and none of them needs the audit/);
});

test("a candidate never blocks or fails an approved item, whatever the fixer answers", async () => {
  const approveWith = (n) => (n === 1 ? { verdict: "approve", findings: [], files_reviewed: ["a.ts"], candidates: [cand("diff")], verdict_line: "Verdict: approve" } : undefined);
  for (const answer of [{ outcome: "gave-up", changed: false, summary: "could not reproduce" }, { outcome: "blocked", changed: false, summary: "s", question: "is this intended?" }]) {
    const r = await simulate({ review: approveWith, "review-fix": () => answer });
    assert.ok(r.labels.includes("publish F1.1"), `${answer.outcome} on a candidate still publishes the approved branch`);
    assert.deepEqual([r.out.blocked, r.out.failed], [[], []]);
    assert.match(r.calls.find((c) => c.label === "publish F1.1").prompt, /as the fixer answered them/);
  }
});

test("after an approve, the candidate fix gets a review scoped to its commits and a fix round after it, never an unanswerable last round", async () => {
  const r = await simulate({
    review: (n) => (n === 1 ? { verdict: "approve", findings: [], files_reviewed: ["a.ts"], candidates: [cand("diff")], verdict_line: "Verdict: approve" }
      : n === 2 ? { verdict: "needs-work", findings: [{ file: "a.ts:9", what: "the new guard breaks clause 2", kind: "acceptance" }], files_reviewed: ["a.ts"], verdict_line: "Verdict: needs-work" } : undefined),
    "review-fix": () => ({ outcome: "committed", changed: true, summary: "fixed" }),
  });
  assert.deepEqual(r.labels.slice(3, 9), ["review F1.1 #1", "review-fix F1.1 #1", "review F1.1 #2", "review-fix F1.1 #2", "review F1.1 #3", "publish F1.1"]);
  assert.match(r.calls.find((c) => c.label === "review F1.1 #2").prompt, /Round 1 APPROVED this branch[\s\S]*Review ONLY the commits it added/);
  assert.deepEqual(r.out.blocked, []);
});

test("a drained run that left failed items says so in the same line the goal cites", () => {
  assert.match(SRC, /\$\{failed\.length \? ` with \$\{failed\.length\} failed — relaunch fresh once to retry them` : ''\}/);
});

test("every agent call names its effort: the hunters at xhigh, everything else at high, nothing inherited or below high", () => {
  const sites = [...SRC.matchAll(/(?:call|callPlugin|callWatcher)\([^\n]*\{ label:[^\n]*/g)].map((m) => m[0]);
  assert.ok(sites.length >= 11);
  for (const site of sites) assert.match(site, /effort: (HUNT_EFFORT|EFFORT)\b/, `no named effort: ${site.slice(0, 80)}`);
  const hunters = sites.filter((s) => /HUNT_EFFORT/.test(s)).map((s) => s.match(/callPlugin\('([a-z-]+)'/)?.[1]);
  assert.deepEqual(hunters.sort(), ["reviewer", "security-reviewer"]);
  assert.match(SRC, /const HUNT_EFFORT = EFFORTS\.includes\(ARGS\.effort\) \? ARGS\.effort : 'xhigh'/);
  assert.match(SRC, /const EFFORT = 'high'/);
  const AUDIT = readFileSync(join(HERE, "milestone-audit.js"), "utf8");
  assert.match(AUDIT, /effort: \{ find: 'xhigh', refute: 'high', prove: 'xhigh' \}/);
  for (const m of AUDIT.matchAll(/\{ label: [^\n]*/g)) assert.match(m[0], /effort/, `audit agent without effort: ${m[0].slice(0, 60)}`);
});
