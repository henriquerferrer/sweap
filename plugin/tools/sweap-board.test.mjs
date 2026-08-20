import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import http from "node:http";
import { parseFrontmatter, parseList, readConfig, loadItems, refMatchesId, slugify, writeIdea, loadIdeas } from "./sweap-board.lib.mjs";

function fixture(files) {
  const dir = mkdtempSync(join(tmpdir(), "swb-"));
  for (const [rel, content] of Object.entries(files)) {
    const full = join(dir, rel);
    mkdirSync(join(full, ".."), { recursive: true });
    writeFileSync(full, content);
  }
  return dir;
}

test("parseFrontmatter splits a --- block (CRLF tolerant)", () => {
  const { fm, body } = parseFrontmatter("---\r\nid: F1.1\r\nstatus: todo\r\n---\r\n\r\n# body\r\n");
  assert.equal(fm.id, "F1.1");
  assert.equal(fm.status, "todo");
  assert.match(body, /# body/);
});

test("parseFrontmatter returns null fm when absent", () => {
  assert.equal(parseFrontmatter("# no frontmatter\n").fm, null);
});

test("parseList parses inline [a, b]", () => {
  assert.deepEqual(parseList("[F1.1, F3]"), ["F1.1", "F3"]);
  assert.deepEqual(parseList("[]"), []);
  assert.deepEqual(parseList(""), []);
  assert.deepEqual(parseList(undefined), []);
});

test("readConfig reads backlog.file/backlog.dir or defaults", () => {
  const d1 = fixture({ "CLAUDE.md": "## sweap config\nbacklog.file: BACK.md\nbacklog.dir: items/   # c\n" });
  assert.deepEqual(readConfig(d1), { backlogFile: "BACK.md", backlogDir: "items/" });
  const d2 = fixture({ "README.md": "x" });
  assert.deepEqual(readConfig(d2), { backlogFile: "ROADMAP.md", backlogDir: "roadmap/" });
  rmSync(d1, { recursive: true }); rmSync(d2, { recursive: true });
});

test("slugify reduces a title to [a-z0-9-]", () => {
  assert.equal(slugify("Dark mode for the board!"), "dark-mode-for-the-board");
  assert.equal(slugify("  F1.2  retry logic  "), "f1-2-retry-logic");
  assert.equal(slugify("///"), "");
});

test("writeIdea creates roadmap/ideas/<slug>.md with frontmatter; suffixes collisions", () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n" });
  const a = writeIdea(dir, "roadmap/", { title: "Dark mode", body: "for the board page", now: 1785736000000 });
  assert.equal(a.file, join("roadmap/", "ideas", "dark-mode.md"));
  const text = readFileSync(join(dir, a.file), "utf8");
  assert.match(text, /^---\ntitle: Dark mode\ncreated: 2026-08-03T/);
  assert.match(text, /---\n\nfor the board page\n$/);
  const b = writeIdea(dir, "roadmap/", { title: "Dark mode", body: "", now: 1785736000000 });
  assert.equal(b.file, join("roadmap/", "ideas", "dark-mode-2.md"));
  assert.ok(existsSync(join(dir, b.file)));
  rmSync(dir, { recursive: true });
});

test("writeIdea rejects empty and non-sluggable titles; flattens newlines", () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n" });
  assert.throws(() => writeIdea(dir, "roadmap/", { title: "   ", body: "", now: 1 }), /title required/);
  assert.throws(() => writeIdea(dir, "roadmap/", { title: "///", body: "", now: 1 }), /title required/);
  const c = writeIdea(dir, "roadmap/", { title: "two\nlines", body: "", now: 1 });
  assert.match(readFileSync(join(dir, c.file), "utf8"), /^---\ntitle: two lines\n/);
  rmSync(dir, { recursive: true });
});

test("loadItems parses items and flags malformed", () => {
  const dir = fixture({
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: login\nstatus: todo\ndepends_on: [F1.2]\nreview-dimensions: [security]\nlane: auth\n---\n\n## Spec\n- x\n",
    "roadmap/F1.2.md": "---\nid: F1.2\ntitle: db\nstatus: done\ndepends_on: []\n---\n",
    "roadmap/bad.md": "no frontmatter here\n",
    "roadmap/F1.3.md": "---\nid: F9.9\nstatus: todo\n---\n",
  });
  const items = loadItems(dir, "roadmap/");
  const byId = Object.fromEntries(items.map(i => [i.file, i]));
  assert.equal(byId["F1.1.md"].title, "login");
  assert.deepEqual(byId["F1.1.md"].dependsOn, ["F1.2"]);
  assert.equal(byId["F1.1.md"].lane, "auth");
  assert.equal(byId["bad.md"].malformed, true);
  assert.equal(byId["F1.3.md"].malformed, true); // id != filename
  rmSync(dir, { recursive: true });
});

import { isUnblocked, compareItems, deriveBacklog, milestoneOf } from "./sweap-board.lib.mjs";

const mk = (id, status, deps = [], extra = {}) => ({ id, title: id, status, dependsOn: deps, reviewDimensions: [], lane: null, followupOf: null, blocked: null, malformed: false, file: id + ".md", ...extra });

test("milestoneOf strips the last dotted segment (multi-dot aware)", () => {
  assert.equal(milestoneOf("F1.2"), "F1");
  assert.equal(milestoneOf("DS3.4"), "DS3");
  assert.equal(milestoneOf("DS.2.1"), "DS.2");   // dotted milestone id
  assert.equal(milestoneOf("DS.1"), "DS");
});

test("multi-dot ids: DS.2.x group under DS.2 and a dotted-milestone dep resolves", () => {
  const items = [
    mk("DS.2.1", "done"),
    mk("DS.2.2", "done"),
    mk("DS.3.1", "todo", ["DS.2"]),      // depends on the whole DS.2 milestone (all done)
    mk("DS.3.2", "todo", ["DS.2.1"]),    // depends on a specific two-dot item (done)
    mk("DS.3.3", "todo", ["DS.3.1"]),    // depends on a not-yet-done sibling
  ];
  const d = deriveBacklog(items);
  const groups = Object.fromEntries(d.backlog.map((g) => [g.milestone, g.items.map((i) => i.id)]));
  assert.deepEqual(groups["DS.2"], ["DS.2.1", "DS.2.2"]);          // grouped under DS.2, not DS
  assert.deepEqual(groups["DS.3"], ["DS.3.1", "DS.3.2", "DS.3.3"]);
  const frontier = d.frontier.map((i) => i.id);
  assert.ok(frontier.includes("DS.3.1"), "dep on complete milestone DS.2 -> ready");
  assert.ok(frontier.includes("DS.3.2"), "dep on done item DS.2.1 -> ready");
  assert.ok(!frontier.includes("DS.3.3"), "dep on todo DS.3.1 -> not ready");
  assert.ok(d.edges.some((e) => e.from === "DS.2.1" && e.to === "DS.3.2"));  // item edge drawn
});

test("isUnblocked: item dep must be done; bare-milestone dep needs ALL its items done", () => {
  const items = [
    mk("F1.1", "done"),
    mk("F1.2", "done"),
    mk("F1.3", "done", ["F1.1"]),
    mk("F2.1", "todo", ["F1"]),
    mk("F3.1", "todo"),
    mk("F4.1", "todo", ["F3"]),
    mk("F5.1", "todo", ["F9"]),
  ];
  const byId = new Map(items.map((i) => [i.id, i]));
  const byM = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byM.has(m)) byM.set(m, []); byM.get(m).push(i); }
  assert.equal(isUnblocked(byId.get("F1.3"), byId, byM), true);   // item dep on done F1.1
  assert.equal(isUnblocked(byId.get("F2.1"), byId, byM), true);   // milestone F1 fully done
  assert.equal(isUnblocked(byId.get("F4.1"), byId, byM), false);  // milestone F3 has a todo item
  assert.equal(isUnblocked(byId.get("F5.1"), byId, byM), false);  // milestone F9 has no items
});

test("compareItems: debt-first overrides numeric; else numeric id (F1.9 before F1.10)", () => {
  const debt = mk("F1.20", "todo", [], { followupOf: "F1" }); // numerically last, but debt → must lead
  const a = mk("F1.10", "todo"), b = mk("F1.9", "todo"), c = mk("F1.2", "todo");
  const sorted = [a, b, c, debt].sort(compareItems).map((i) => i.id);
  assert.deepEqual(sorted, ["F1.20", "F1.2", "F1.9", "F1.10"]);
});

test("deriveBacklog produces frontier, blocked, grouped backlog, edges", () => {
  const items = [mk("F1.1", "done"), mk("F1.2", "todo", ["F1.1"]), mk("F1.3", "blocked", [], { blocked: "which scope?" }), mk("F1.4", "todo", ["F1.3"])];
  const d = deriveBacklog(items);
  assert.deepEqual(d.frontier.map((i) => i.id), ["F1.2"]);          // F1.4 blocked by non-done F1.3
  assert.deepEqual(d.blocked.map((b) => [b.id, b.question]), [["F1.3", "which scope?"]]);
  assert.equal(d.backlog[0].milestone, "F1");
  assert.equal(d.backlog[0].items.length, 4);
  assert.ok(d.edges.some((e) => e.from === "F1.1" && e.to === "F1.2"));
});

test("deriveBacklog: blocked items carry their boundary count (absent reads as 0)", () => {
  const items = [
    mk("F1.1", "blocked", [], { blocked: "which scope?", carried: 2 }),
    mk("F1.2", "blocked", [], { blocked: "keep it persistent?" }),
  ];
  const d = deriveBacklog(items);
  assert.deepEqual(d.blocked.map((b) => [b.id, b.carried]), [["F1.1", 2], ["F1.2", 0]]);
});

test("loadItems reads carried:, defaulting a missing or junk value to 0", () => {
  const item = (id, extra) => `---\nid: ${id}\ntitle: ${id}\nstatus: blocked\ndepends_on: []\nblocked: "a question"\n${extra}---\n\n# ${id}\n`;
  const dir = fixture({
    "roadmap/F1.1.md": item("F1.1", "carried: 3\n"),
    "roadmap/F1.2.md": item("F1.2", ""),
    "roadmap/F1.3.md": item("F1.3", "carried: soon\n"),
  });
  const byId = new Map(loadItems(dir, "roadmap/").map((i) => [i.id, i]));
  assert.equal(byId.get("F1.1").carried, 3);
  assert.equal(byId.get("F1.2").carried, 0);
  assert.equal(byId.get("F1.3").carried, 0);   // roadmap-lint rejects it; the board must not render NaN
});

test("deriveBacklog: attended items are their own queue, never the frontier or blocked", () => {
  const items = [
    mk("F1.1", "attended", [], { handoff: "create the live Stripe account" }),
    mk("F1.2", "todo", ["F1.1"]),
    mk("F1.3", "blocked", [], { blocked: "which scope?" }),
    mk("F1.4", "todo"),
  ];
  const d = deriveBacklog(items);
  assert.deepEqual(d.frontier.map((i) => i.id), ["F1.4"]);            // F1.1 is not agent work; F1.2 waits on it
  assert.deepEqual(d.blocked.map((b) => b.id), ["F1.3"]);             // a hand-off never pollutes needs-me-now
  assert.deepEqual(d.attended.map((a) => [a.id, a.task, a.ready]), [["F1.1", "create the live Stripe account", true]]);
});

test("deriveBacklog: a hand-off reports what it gates, transitively and through milestone deps", () => {
  const items = [
    mk("F1.1", "attended", [], { handoff: "register the webhook domain" }),
    mk("F1.2", "todo", ["F1.1"]),        // direct
    mk("F1.3", "todo", ["F1.2"]),        // transitive
    mk("F1.4", "done", ["F1.1"]),        // already done -> not gated
    mk("F2.1", "todo", ["F1"]),          // bare-milestone dep expands to F1's items
    mk("F9.1", "todo"),                  // unrelated
  ];
  const d = deriveBacklog(items);
  assert.deepEqual(d.attended[0].gates, ["F1.2", "F1.3", "F2.1"]);
});

test("deriveBacklog: an attended item waiting on a dependency is not ready to pick up", () => {
  const items = [mk("F1.1", "todo"), mk("F1.2", "attended", ["F1.1"], { handoff: "sign the contract" })];
  const d = deriveBacklog(items);
  assert.equal(d.attended[0].ready, false);
});

test("deriveBacklog: an attended item with no handoff: still lists, with a placeholder task", () => {
  const d = deriveBacklog([mk("F1.1", "attended")]);
  assert.equal(d.attended[0].task, "(no hand-off recorded)");
});

import { parseWorktrees, ciSummary, buildState } from "./sweap-board.lib.mjs";

test("parseWorktrees reads porcelain output", () => {
  const out = "worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /repo/.wt/a\nHEAD def\nbranch refs/heads/feat-F1.1\n\n";
  const w = parseWorktrees(out);
  assert.equal(w.length, 2);
  assert.equal(w[1].branch, "feat-F1.1");
});

test("ciSummary collapses a statusCheckRollup", () => {
  assert.equal(ciSummary([{ conclusion: "SUCCESS" }, { conclusion: "SUCCESS" }]), "passing");
  assert.equal(ciSummary([{ conclusion: "SUCCESS" }, { conclusion: "FAILURE" }]), "failing");
  assert.equal(ciSummary([{ status: "IN_PROGRESS" }]), "pending");
  assert.equal(ciSummary([]), "unknown");
});

test("buildState: active run links item -> worktree + PR + CI; gh failure degrades", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\nbacklog.dir: roadmap/\n",
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: login\nstatus: todo\ndepends_on: []\n---\n",
    "roadmap/F1.2.md": "---\nid: F1.2\ntitle: db\nstatus: blocked\nblocked: which engine?\ndepends_on: []\n---\n",
    ".claude/sweap-board.md": "F1.1 | review | wt-a@feat-F1.1 | PR #31 | -\n",
  });
  const git = async () => ({ stdout: "worktree /x\nbranch refs/heads/feat-F1.1\n\n", code: 0 });
  const gh = async () => ({ stdout: JSON.stringify([{ number: 31, title: "login", headRefName: "feat-F1.1", state: "OPEN", statusCheckRollup: [{ conclusion: "SUCCESS" }], mergeStateStatus: "CLEAN" }]), code: 0 });
  const s = await buildState(dir, { git, gh, now: 1000 });
  assert.equal(s.run.active, true);
  assert.equal(s.run.prsAvailable, true);
  assert.equal(s.generatedAt, 1000);
  assert.equal(s.inFlight[0].id, "F1.1");
  assert.equal(s.inFlight[0].pr, 31);
  assert.equal(s.inFlight[0].ci, "passing");
  assert.equal(s.inFlight[0].step, "review");
  assert.deepEqual(s.blocked.map((b) => b.id), ["F1.2"]);

  const bad = await buildState(dir, { git, gh: async () => ({ stdout: "", code: 1 }), now: 2 });
  assert.equal(bad.run.prsAvailable, false);
  assert.ok(bad.notes.some((n) => /PR.*unavailable/i.test(n)));
  rmSync(dir, { recursive: true });
});

test("buildState: no board, no worktrees => inactive run, backlog still present", async () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n", "roadmap/F1.1.md": "---\nid: F1.1\ntitle: x\nstatus: todo\ndepends_on: []\n---\n" });
  const s = await buildState(dir, { git: async () => ({ stdout: "worktree /x\nbranch refs/heads/main\n\n", code: 0 }), gh: async () => ({ stdout: "[]", code: 0 }), now: 5 });
  assert.equal(s.run.active, false);
  assert.equal(s.backlog[0].items[0].id, "F1.1");
  rmSync(dir, { recursive: true });
});

test("refMatchesId matches an id only at a token boundary", () => {
  assert.equal(refMatchesId("feat-F1.1", "F1.1"), true);
  assert.equal(refMatchesId("F1.1", "F1.1"), true);
  assert.equal(refMatchesId("feat-F1.1-login", "F1.1"), true);
  assert.equal(refMatchesId("feat-F1.10", "F1.1"), false);   // must NOT match a longer id
  assert.equal(refMatchesId(null, "F1.1"), false);
});

test("buildState: a malformed item file is flagged, not fatal", async () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n", "roadmap/F1.1.md": "no frontmatter here\n" });
  const s = await buildState(dir, { git: async () => ({ stdout: "", code: 0 }), gh: async () => ({ stdout: "[]", code: 0 }), now: 7 });
  assert.equal(s.backlog[0].items[0].malformed, true);
  assert.ok(s.notes.some((n) => /malformed/i.test(n)));
  rmSync(dir, { recursive: true });
});

test("loadIdeas reads the inbox, newest first; missing dir -> []; ignores ideas/archive/", () => {
  const dir = fixture({
    "roadmap/ideas/old-idea.md": "---\ntitle: Old idea\ncreated: 2026-08-01T10:00:00.000Z\n---\n\nx\n",
    "roadmap/ideas/new-idea.md": "---\ntitle: New idea\ncreated: 2026-08-03T10:00:00.000Z\n---\n",
    "roadmap/ideas/archive/done-idea.md": "---\ntitle: Done\ncreated: 2026-07-01T10:00:00.000Z\n---\n",
    "roadmap/ideas/junk.md": "no frontmatter\n",
  });
  const ideas = loadIdeas(dir, "roadmap/");
  assert.deepEqual(ideas.map((i) => i.file), ["new-idea.md", "old-idea.md", "junk.md"]);
  assert.equal(ideas[0].title, "New idea");
  assert.equal(ideas[2].title, "junk");          // falls back to filename
  assert.equal(ideas[2].created, null);
  assert.ok(!ideas.some((i) => i.file === "done-idea.md"), "archive/ must be invisible");
  const empty = fixture({ "CLAUDE.md": "x" });
  assert.deepEqual(loadIdeas(empty, "roadmap/"), []);
  rmSync(empty, { recursive: true });
  rmSync(dir, { recursive: true });
});

test("buildState exposes ideas; ideas never appear in backlog/frontier", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\n",
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: x\nstatus: todo\ndepends_on: []\n---\n",
    "roadmap/ideas/dark-mode.md": "---\ntitle: Dark mode\ncreated: 2026-08-03T10:00:00.000Z\n---\n",
  });
  const s = await buildState(dir, { git: async () => ({ stdout: "", code: 0 }), gh: async () => ({ stdout: "[]", code: 0 }), now: 3 });
  assert.deepEqual(s.ideas.map((i) => i.title), ["Dark mode"]);
  assert.deepEqual(s.backlog.flatMap((g) => g.items.map((i) => i.id)), ["F1.1"], "ideas must not leak into backlog");
  rmSync(dir, { recursive: true });
});

test("buildState: a hand-off surfaces in attended with its gated items, not in-flight", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\n",
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: Stripe account\nstatus: attended\ndepends_on: []\nhandoff: create the live account\n---\n\n## Hand-off\n- steps\n",
    "roadmap/F1.2.md": "---\nid: F1.2\ntitle: checkout\nstatus: todo\ndepends_on: [F1.1]\n---\n",
  });
  // A worktree/branch naming the hand-off must NOT drag it into the in-flight
  // column: /handoff's status-flip PR is human work, not a dispatched worker.
  const git = async () => ({ stdout: "worktree /x/F1.1\nbranch refs/heads/handoff-F1.1\n\n", code: 0 });
  const s = await buildState(dir, { git, gh: async () => ({ stdout: "[]", code: 0 }), now: 4 });
  assert.deepEqual(s.attended.map((a) => [a.id, a.gates]), [["F1.1", ["F1.2"]]]);
  assert.deepEqual(s.inFlight.map((i) => i.id), []);
  assert.deepEqual(s.frontier.map((i) => i.id), [], "F1.2 waits on the hand-off");
  assert.deepEqual(s.blocked, []);
  rmSync(dir, { recursive: true });
});

import { renderPage } from "./sweap-board.page.mjs";

test("renderPage returns a self-contained HTML doc with the poll targets", () => {
  const html = renderPage();
  assert.match(html, /<!doctype html>/i);
  for (const id of ["frontier", "inflight", "mergequeue", "attended", "blocked", "backlog", "graph", "updated", "notes", "project"]) {
    assert.ok(html.includes(`id="${id}"`), `missing #${id}`);
  }
  assert.match(html, /\/state\.json/);           // client polls the endpoint
  assert.ok(!/https?:\/\//.test(html.replace(/https?:\/\/[^"']*w3\.org[^"']*/g, "")), "no external asset URLs");
  assert.match(html, /prefers-color-scheme/);    // theme-aware
});

import { createServer } from "./sweap-board.mjs";

test("createServer serves / and /state.json (loopback smoke test)", async () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n", "roadmap/F1.1.md": "---\nid: F1.1\ntitle: x\nstatus: todo\ndepends_on: []\n---\n" });
  const srv = createServer({ projectDir: dir, git: async () => ({ stdout: "", code: 0 }), gh: async () => ({ stdout: "[]", code: 0 }) });
  await new Promise((res) => srv.listen(0, "127.0.0.1", res));
  const port = srv.address().port;
  const html = await fetch(`http://127.0.0.1:${port}/`).then((r) => r.text());
  assert.match(html, /<!doctype html>/i);
  const state = await fetch(`http://127.0.0.1:${port}/state.json`).then((r) => r.json());
  assert.equal(state.backlog[0].items[0].id, "F1.1");
  assert.equal(state.run.active, false);
  await new Promise((res) => srv.close(res));
  rmSync(dir, { recursive: true });
});

async function ideaServer(files) {
  const dir = fixture(files);
  const srv = createServer({ projectDir: dir, git: async () => ({ stdout: "", code: 0 }), gh: async () => ({ stdout: "[]", code: 0 }) });
  await new Promise((res) => srv.listen(0, "127.0.0.1", res));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const close = async () => { await new Promise((res) => srv.close(res)); rmSync(dir, { recursive: true }); };
  return { dir, base, close };
}

test("POST /ideas creates the file and returns 201 {file}; state.json picks it up", async () => {
  const { dir, base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const r = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "Dark mode", body: "please" }) });
  assert.equal(r.status, 201);
  const { file } = await r.json();
  assert.equal(file, join("roadmap/", "ideas", "dark-mode.md"));
  assert.match(readFileSync(join(dir, file), "utf8"), /^---\ntitle: Dark mode\n/);
  const state = await fetch(`${base}/state.json`).then((x) => x.json());
  assert.deepEqual(state.ideas.map((i) => i.title), ["Dark mode"]);
  await close();
});

test("POST /ideas: 400 on missing title and on invalid JSON", async () => {
  const { base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const r1 = await fetch(`${base}/ideas`, { method: "POST", body: JSON.stringify({ title: "  " }) });
  assert.equal(r1.status, 400);
  const r2 = await fetch(`${base}/ideas`, { method: "POST", body: "not json{" });
  assert.equal(r2.status, 400);
  await close();
});

test("non-GET stays 405 everywhere except /ideas", async () => {
  const { base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const r1 = await fetch(`${base}/state.json`, { method: "POST", body: "{}" });
  assert.equal(r1.status, 405);
  const r2 = await fetch(`${base}/ideas`, { method: "DELETE" });
  assert.equal(r2.status, 405);
  await close();
});

test("createServer caches gh across rapid /state.json requests", async () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n", "roadmap/F1.1.md": "---\nid: F1.1\ntitle: x\nstatus: todo\ndepends_on: []\n---\n" });
  let ghCalls = 0;
  const gh = async () => { ghCalls++; return { stdout: "[]", code: 0 }; };
  const srv = createServer({ projectDir: dir, git: async () => ({ stdout: "", code: 0 }), gh });
  await new Promise((res) => srv.listen(0, "127.0.0.1", res));
  const port = srv.address().port;
  await fetch(`http://127.0.0.1:${port}/state.json`).then((r) => r.json());
  await fetch(`http://127.0.0.1:${port}/state.json`).then((r) => r.json());
  assert.equal(ghCalls, 1);
  await new Promise((res) => srv.close(res));
  rmSync(dir, { recursive: true });
});

test("buildState: in-flight item is not in frontier; blocked item is not in-flight", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\nbacklog.dir: roadmap/\n",
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: login\nstatus: todo\ndepends_on: []\n---\n",
    "roadmap/F1.2.md": "---\nid: F1.2\ntitle: ready\nstatus: todo\ndepends_on: []\n---\n",
    "roadmap/F1.3.md": "---\nid: F1.3\ntitle: stuck\nstatus: blocked\nblocked: which db?\ndepends_on: []\n---\n",
    ".claude/sweap-board.md": "F1.1 | review | wt-a@feat-F1.1 | PR #31 | -\nF1.3 | blocked | wt-c@feat-F1.3 | PR #33 | which db?\n",
  });
  const git = async () => ({ stdout: "worktree /a\nbranch refs/heads/feat-F1.1\n\nworktree /c\nbranch refs/heads/feat-F1.3\n\n", code: 0 });
  const gh = async () => ({ stdout: JSON.stringify([
    { number: 31, title: "login", headRefName: "feat-F1.1", state: "OPEN", statusCheckRollup: [{ conclusion: "SUCCESS" }], mergeStateStatus: "CLEAN" },
    { number: 33, title: "stuck", headRefName: "feat-F1.3", state: "OPEN", statusCheckRollup: [{ conclusion: "FAILURE" }], mergeStateStatus: "BLOCKED" },
  ]), code: 0 });
  const s = await buildState(dir, { git, gh, now: 9 });
  const frontierIds = s.frontier.map((i) => i.id);
  const inFlightIds = s.inFlight.map((i) => i.id);
  assert.ok(!frontierIds.includes("F1.1"), "in-flight F1.1 must NOT be in frontier");
  assert.ok(frontierIds.includes("F1.2"), "un-dispatched F1.2 stays in frontier");
  assert.ok(inFlightIds.includes("F1.1"));
  assert.ok(!inFlightIds.includes("F1.3"), "blocked F1.3 must NOT be in-flight");
  assert.deepEqual(s.blocked.map((b) => b.id), ["F1.3"]);
  rmSync(dir, { recursive: true });
});

test("POST /ideas: a traversal-shaped title is slugified, not path-joined; file stays inside ideas/", async () => {
  const { dir, base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const r = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "../../etc/passwd" }) });
  assert.equal(r.status, 201);
  const { file } = await r.json();
  assert.match(file, /^roadmap\/ideas\/etc-passwd(-\d+)?\.md$/);
  assert.ok(existsSync(join(dir, file)), "file must exist inside the ideas dir");
  assert.ok(!existsSync(join(dir, "etc", "passwd")), "no file must land outside the ideas dir");
  await close();
});

test("POST /ideas: rejects a spoofed Host or Origin (CSRF/DNS-rebinding guard); normal loopback POST still 201", async () => {
  const { base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const port = new URL(base).port;

  // Node's fetch ignores a caller-supplied Host header, so drive a raw
  // http.request to actually send a spoofed Host to the loopback server.
  const rawPost = (headers) => new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: "/ideas", method: "POST", headers: { "content-type": "application/json", ...headers } }, (res) => {
      let body = ""; res.on("data", (c) => (body += c)); res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.on("error", reject);
    req.end(JSON.stringify({ title: "spoofed host" }));
  });
  const badHost = await rawPost({ host: "evil.example" });
  assert.equal(badHost.status, 403);

  const badOrigin = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json", origin: "https://evil.example" }, body: JSON.stringify({ title: "spoofed origin" }) });
  assert.equal(badOrigin.status, 403);

  const ok = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "legit idea" }) });
  assert.equal(ok.status, 201);
  await close();
});

test("POST /ideas: a 1000-char title still 201s with a truncated (<=130 char) filename", async () => {
  const { base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const title = "a".repeat(1000);
  const r = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title }) });
  assert.equal(r.status, 201);
  const { file } = await r.json();
  assert.ok(basename(file).length <= 130, `basename too long: ${basename(file).length}`);
  await close();
});

test("POST /ideas: a multibyte title round-trips intact through the utf8 body read", async () => {
  const { dir, base, close } = await ideaServer({ "CLAUDE.md": "## sweap config\n" });
  const r = await fetch(`${base}/ideas`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "café idea" }) });
  assert.equal(r.status, 201);
  const { file } = await r.json();
  const text = readFileSync(join(dir, file), "utf8");
  assert.match(text, /^---\ntitle: café idea\n/);
  await close();
});

test("renderPage includes the Ideas capture form and list", () => {
  const html = renderPage();
  for (const id of ["idea-form", "idea-title", "idea-body", "idea-msg", "ideas"]) {
    assert.ok(html.includes(`id="${id}"`), `missing #${id}`);
  }
  assert.match(html, /fetch\("\/ideas"/);       // the form posts to the endpoint
  assert.ok(!/https?:\/\//.test(html.replace(/https?:\/\/[^"']*w3\.org[^"']*/g, "")), "still no external asset URLs");
});

// --- the running-milestone card -------------------------------------------------
import { parseMilestoneIndex, readMilestoneIndex, readRunFile, classifyAudit, buildMilestoneCard } from "./sweap-board.lib.mjs";

test("parseMilestoneIndex reads goals under a milestones heading, tags the sketch section", () => {
  const idx = parseMilestoneIndex([
    "# ROADMAP (index)",
    "",
    "Direction-level view only — items live one file each under `roadmap/`.",
    "- this bullet is prose, not a milestone",
    "",
    "## Milestones (priority order)",
    "",
    "- F1 — merge-queue hardening",
    "* DS.2: the data layer",
    "- F1 — a duplicate that must not win",
    "",
    "## Later milestones (sketch, not yet specced)",
    "- F9 – someday",
  ].join("\n"));
  assert.deepEqual(idx, [
    { id: "F1", goal: "merge-queue hardening", sketch: false },
    { id: "DS.2", goal: "the data layer", sketch: false },
    { id: "F9", goal: "someday", sketch: true },
  ]);
});

test("parseMilestoneIndex: index order is the PRIORITY order, not the id order", () => {
  const idx = parseMilestoneIndex("## Milestones\n- F7 — urgent\n- F2 — later\n");
  assert.deepEqual(idx.map((m) => m.id), ["F7", "F2"]);
});

test("readMilestoneIndex reads backlog.file; a missing index is empty, never fatal", () => {
  const dir = fixture({ "ROADMAP.md": "## Milestones\n- F1 — login\n" });
  assert.deepEqual(readMilestoneIndex(dir, "ROADMAP.md"), [{ id: "F1", goal: "login", sketch: false }]);
  assert.deepEqual(readMilestoneIndex(dir, "NOPE.md"), []);
  rmSync(dir, { recursive: true });
});

test("readRunFile parses .claude/sweap-run.md; absent or milestone-less reads as null", () => {
  const dir = fixture({
    ".claude/sweap-run.md": "---\nmilestone: F4\nshape: milestone+debt\nscope: [F3.9, F3.11]\nturns: 160\nstarted: 2026-08-20T09:14:00Z\ndeferred_handoffs: [F4.8]\n---\n",
  });
  assert.deepEqual(readRunFile(dir), {
    milestone: "F4", shape: "milestone+debt", scope: ["F3.9", "F3.11"],
    turns: 160, started: "2026-08-20T09:14:00Z", deferredHandoffs: ["F4.8"],
  });
  const none = fixture({ ".claude/sweap-run.md": "---\nturns: 160\n---\n" });
  assert.equal(readRunFile(none), null);
  const missing = fixture({ "CLAUDE.md": "x" });
  assert.equal(readRunFile(missing), null);
  rmSync(dir, { recursive: true }); rmSync(none, { recursive: true }); rmSync(missing, { recursive: true });
});

test("readRunFile: a junk turns: value reads as null, never NaN on the card", () => {
  const dir = fixture({ ".claude/sweap-run.md": "---\nmilestone: F4\nturns: soon\n---\n" });
  assert.equal(readRunFile(dir).turns, null);
  rmSync(dir, { recursive: true });
});

test("classifyAudit sorts audit-gate --check lines by their documented prefixes", () => {
  const out = [
    "FAIL: milestone F3 is complete but has no audit record (roadmap/audits/F3.md) — run /milestone-audit for it",
    "FAIL: record roadmap/audits/F2.md: raw (3) != refuted (1) + confirmed (1)",
    "FAIL: hand-off F4.8: status: attended was introduced by abc123 but the item file was added by def456 — ...",
    "DEFERRED: milestone F5 becomes complete in the state under review, so its audit cannot have run yet ...",
    "STALE: record roadmap/audits/F1.md predates the sweap_format 1 record contract ...",
    "AGING: blocked F4.3 — carried 2 milestone boundaries: \"which db?…\"",
  ].join("\n");
  const c = classifyAudit(out, 1);
  assert.deepEqual(c.debt, ["F3", "F2"]);
  assert.deepEqual(c.deferred, ["F5"]);
  assert.deepEqual(c.integrity, ["F4.8"]);
  assert.deepEqual(c.stale, ["F1"]);
  assert.equal(c.unknown, false);
});

test("classifyAudit: clean exit is clean; an unreadable non-zero exit is unknown, never clean", () => {
  const ok = classifyAudit("", 0);
  assert.deepEqual([ok.debt, ok.deferred, ok.unknown], [[], [], false]);
  assert.equal(classifyAudit("usage: audit-gate.sh --check | --files <path>...", 2).unknown, true);
  assert.equal(classifyAudit("", 1).unknown, true);
});

// Card fixtures: derive the queues exactly as buildState does, so the card is
// tested against the same shapes it is fed in production.
const card = (items, { index = [], runFile = null, inFlight = [], audit = null } = {}) => {
  const d = deriveBacklog(items);
  return buildMilestoneCard({ items, index, runFile, inFlight, frontier: d.frontier, attended: d.attended, blocked: d.blocked, audit });
};

test("buildMilestoneCard: with nothing in flight it names the NEXT runnable milestone and says so", () => {
  const items = [mk("F1.1", "done"), mk("F2.1", "todo"), mk("F3.1", "todo", ["F2.1"])];
  const c = card(items, { index: [{ id: "F1", goal: "a", sketch: false }, { id: "F2", goal: "merge-queue hardening", sketch: false }] });
  assert.equal(c.id, "F2");
  assert.equal(c.state, "next");
  assert.equal(c.source, "derived");
  assert.equal(c.goal, "merge-queue hardening");
});

test("buildMilestoneCard: an in-flight item makes the run RUNNING and names its milestone", () => {
  const items = [mk("F2.1", "todo"), mk("F2.2", "todo")];
  const c = card(items, { inFlight: [{ id: "F2.1", title: "F2.1", step: "review", pr: 31, ci: "passing" }] });
  assert.equal(c.state, "running");
  assert.equal(c.source, "in-flight");
  assert.equal(c.inFlight[0].scope, "milestone");
  assert.deepEqual(c.ready.map((r) => r.id), ["F2.2"]);   // in-flight is not also "next ready"
});

test("buildMilestoneCard: a follow-up in flight never names the milestone — the run is F4, not F3", () => {
  const items = [
    mk("F3.9", "todo", [], { followupOf: "F3" }),
    mk("F4.1", "todo"),
  ];
  const c = card(items, { inFlight: [{ id: "F3.9", title: "F3.9", ci: "unknown" }] });
  assert.equal(c.id, "F4");
  assert.equal(c.state, "running");            // a debt drain IS a run
  assert.equal(c.inFlight[0].scope, "debt");
  assert.deepEqual(c.debt.map((d) => d.id), ["F3.9"]);
});

test("buildMilestoneCard: the run file outranks inference, and carries the shape inference cannot know", () => {
  const items = [mk("F4.1", "todo"), mk("F5.1", "todo")];
  const runFile = { milestone: "F5", shape: "hand-offs-outstanding", scope: [], turns: 160, started: "2026-08-20T09:14:00Z", deferredHandoffs: ["F5.2"] };
  const c = card(items, { runFile, inFlight: [{ id: "F4.1", title: "F4.1", ci: "unknown" }] });
  assert.equal(c.id, "F5");
  assert.equal(c.source, "run-file");
  assert.equal(c.shape, "hand-offs-outstanding");
  assert.deepEqual(c.deferredHandoffs, ["F5.2"]);
  assert.equal(c.inFlight[0].scope, "other");   // F4.1 is still shown, tagged as elsewhere
});

test("buildMilestoneCard: a run file whose milestone is finished is litter — fall back to inference", () => {
  const items = [mk("F4.1", "done"), mk("F5.1", "todo")];
  const runFile = { milestone: "F4", shape: "milestone+debt", scope: [], turns: null, started: null, deferredHandoffs: [] };
  const c = card(items, { runFile });
  assert.equal(c.id, "F5");
  assert.equal(c.source, "derived");
});

test("buildMilestoneCard: counts, ready, hand-offs and blocked are scoped to the milestone", () => {
  const items = [
    mk("F2.1", "done"), mk("F2.2", "done"), mk("F2.3", "todo"),
    mk("F2.4", "blocked", [], { blocked: "which db?", carried: 2 }),
    mk("F2.5", "attended", [], { handoff: "rotate the deploy key" }),
    mk("F2.6", "deferred"),
    mk("F3.1", "todo"), mk("F3.2", "blocked", [], { blocked: "elsewhere" }),
  ];
  const c = card(items, { index: [{ id: "F2", goal: "g", sketch: false }, { id: "F3", goal: "h", sketch: false }] });
  assert.equal(c.id, "F2");
  assert.deepEqual(c.counts, { total: 6, done: 2, todo: 1, blocked: 1, attended: 1, deferred: 1, other: 0 });
  assert.deepEqual(c.ready.map((r) => r.id), ["F2.3"]);
  assert.deepEqual(c.handoffs.map((h) => h.id), ["F2.5"]);
  assert.deepEqual(c.blocked.map((b) => [b.id, b.carried]), [["F2.4", 2]]);
});

test("buildMilestoneCard audit: this milestone's debt beats another's; another's still shows as blocking", () => {
  const items = [mk("F2.1", "todo")];
  const base = { debt: [], deferred: [], stale: [], integrity: [], unknown: false };
  assert.equal(card(items, { audit: { ...base, debt: ["F2"] } }).audit.state, "debt");
  const other = card(items, { audit: { ...base, debt: ["F1"] } }).audit;
  assert.equal(other.state, "blocked-by-debt");
  assert.match(other.detail, /F1/);
  assert.equal(card(items, { audit: { ...base, deferred: ["F2"] } }).audit.state, "deferred");
  assert.equal(card(items, { audit: base }).audit.state, "clean");
  assert.equal(card(items, { audit: { ...base, unknown: true } }).audit.state, "unknown");
  assert.equal(card(items, {}).audit.state, "unknown");   // no runner injected
});

test("buildMilestoneCard audit: an open hand-off means the audit is NOT DUE, not clean", () => {
  const items = [mk("F2.1", "todo"), mk("F2.2", "attended", [], { handoff: "sign it" })];
  const base = { debt: [], deferred: [], stale: [], integrity: [], unknown: false };
  const a = card(items, { audit: base }).audit;
  assert.equal(a.state, "not-due");
  assert.match(a.detail, /hand-off/);
  // ...and it holds with no gate output at all, since it is derivable from items.
  assert.equal(card(items, {}).audit.state, "not-due");
  // ...but a gate that FAILED outranks it: an open hand-off says nothing about
  // whether an older milestone's missing record is about to deny every merge.
  const dark = card(items, { audit: { ...base, unknown: true } }).audit;
  assert.equal(dark.state, "unknown");
  assert.match(dark.detail, /did not run here .* hand-off/);
});

test("buildMilestoneCard: no items, or nothing runnable anywhere, yields no card", () => {
  assert.equal(card([]), null);
  assert.equal(card([mk("F1.1", "done")]), null);
});

test("buildState: exposes the milestone card and folds the audit runner's verdict in", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\nbacklog.dir: roadmap/\nbacklog.file: ROADMAP.md\n",
    "ROADMAP.md": "## Milestones (priority order)\n- F1 — login and session\n",
    "roadmap/F1.1.md": "---\nid: F1.1\ntitle: login\nstatus: todo\ndepends_on: []\n---\n",
    ".claude/sweap-run.md": "---\nmilestone: F1\nshape: milestone+debt\nturns: 160\n---\n",
  });
  const git = async () => ({ stdout: "", code: 0 });
  const gh = async () => ({ stdout: "[]", code: 0 });
  const audit = async () => ({ stdout: "FAIL: milestone F0 is complete but has no audit record (roadmap/audits/F0.md) — run /milestone-audit for it", code: 1 });
  const s = await buildState(dir, { git, gh, audit, now: 1 });
  assert.equal(s.milestone.id, "F1");
  assert.equal(s.milestone.goal, "login and session");
  assert.equal(s.milestone.source, "run-file");
  assert.equal(s.milestone.shape, "milestone+debt");
  assert.equal(s.milestone.audit.state, "blocked-by-debt");

  // A gate that cannot run degrades to unknown + a note, exactly like gh does.
  const dead = await buildState(dir, { git, gh, audit: async () => { throw new Error("no bash"); }, now: 2 });
  assert.equal(dead.milestone.audit.state, "unknown");
  assert.ok(dead.notes.some((n) => /audit status unavailable/i.test(n)));

  // No runner at all: no card audit verdict, and no note either — nothing failed.
  const off = await buildState(dir, { git, gh, now: 3 });
  assert.equal(off.milestone.audit.state, "unknown");
  assert.ok(!off.notes.some((n) => /audit status/i.test(n)));
  rmSync(dir, { recursive: true });
});

test("buildState: a hand-off provenance FAIL surfaces as a note — no audit discharges it", async () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n", "roadmap/F1.1.md": "---\nid: F1.1\ntitle: x\nstatus: todo\ndepends_on: []\n---\n" });
  const s = await buildState(dir, {
    git: async () => ({ stdout: "", code: 0 }),
    gh: async () => ({ stdout: "[]", code: 0 }),
    audit: async () => ({ stdout: "FAIL: hand-off F1.2: status: attended was introduced by abc but the item file was added by def — ...", code: 1 }),
    now: 4,
  });
  assert.ok(s.notes.some((n) => /hand-off F1\.2 was transitioned into/.test(n)));
  rmSync(dir, { recursive: true });
});

test("renderPage mounts the running-milestone card and can mark it in the backlog", () => {
  const html = renderPage();
  assert.match(html, /id="milestone"/);
  assert.match(html, /Running milestone/);
  assert.match(html, /milestoneCard\(s\.milestone\)/);
  assert.match(html, /ms\.running/);
});

// --- what the consumer A run exposed (2026-08-20) -----------------------------------
// Run live against consumer A mid-milestone, the card rendered NOTHING. Three
// separate defects, two of them older than the card; each test below is one of
// them, written against the shapes that repo actually produces.
import { parseBoard, dotless, dotlessOwners, refMatchesLoosely } from "./sweap-board.lib.mjs";

test("parseBoard reads a real markdown table — pipe-edged rows, dotted ids, dash cells", () => {
  const ann = parseBoard([
    "| item | status | worktree@branch | PR | blocked question |",
    "|---|---|---|---|---|",
    "| DS.5.1 | **MERGED #163** (891933a) | — | #163 | — |",
    "| FN.3 | worker active | `fn3-status-guards` | — | — |",
    "| FJ.7+FJ.8 | PR open, CI running | `fj7-fj8-focus` | — | — |",
    "| track A (`communications`) | track B (everything else) |",
    "| FN.1 → FN.2 → FN.3 | DS.5.1 → FJ.6 |",
  ].join("\n"));
  // Dotted ids parse at all — `[A-Za-z]+\d` rejected every one of consumer A's ids.
  assert.deepEqual(Object.keys(ann.steps), ["DS.5.1", "FN.3"]);
  assert.equal(ann.steps["FN.3"], "worker active");
  // An em-dash cell is markdown for "nothing", not a blocked question.
  assert.deepEqual(ann.questions, {});
  // The header, the rule row, a lane table and a multi-id cell are all not items.
  assert.ok(!("item" in ann.steps));
  assert.ok(!Object.keys(ann.steps).some((k) => /\+|→/.test(k)));
});

test("parseBoard still reads the documented one-line form", () => {
  const ann = parseBoard("F1.1 | review | wt-a@feat-F1.1 | PR #31 | which db?\n");
  assert.equal(ann.steps["F1.1"], "review");
  assert.equal(ann.prByItem["F1.1"], 31);
  assert.deepEqual(ann.wtByItem["F1.1"], { worktree: "wt-a", branch: "feat-F1.1" });
  assert.equal(ann.questions["F1.1"], "which db?");
});

test("refMatchesLoosely matches a dotless branch, but only for an id that owns the key", () => {
  const owner = dotlessOwners([mk("FN.1", "todo"), mk("FN.3", "todo"), mk("FN.10", "todo")]);
  assert.equal(dotless("FN.3"), "fn3");
  assert.equal(refMatchesLoosely("fn3-status-guards", "FN.3", owner), true);
  assert.equal(refMatchesLoosely("fn10-message-tables", "FN.10", owner), true);
  assert.equal(refMatchesLoosely("fn10-message-tables", "FN.1", owner), false);  // token boundary holds
  // F1.3 and F13 collapse to the same dotless key — a wrong link is worse than none.
  const ambiguous = dotlessOwners([mk("F1.3", "todo"), mk("F13.1", "todo"), mk("F13", "todo")]);
  assert.equal(refMatchesLoosely("f13-something", "F1.3", ambiguous), false);
});

test("buildState links an item to its PR by dotless branch, and failing that by title", async () => {
  const dir = fixture({
    "CLAUDE.md": "## sweap config\n",
    "roadmap/FN.3.md": "---\nid: FN.3\ntitle: send-path claims\nstatus: todo\ndepends_on: []\nfollowup_of: F11\n---\n",
    "roadmap/FN.9.md": "---\nid: FN.9\ntitle: table shape\nstatus: todo\ndepends_on: []\nfollowup_of: F11\n---\n",
  });
  const git = async () => ({ stdout: "worktree /w\nbranch refs/heads/fn3-status-guards\n\n", code: 0 });
  const gh = async () => ({ stdout: JSON.stringify([
    { number: 170, title: "fix(reminders): FN.3 — every send-path write takes a claim", headRefName: "fn3-status-guards", state: "OPEN", statusCheckRollup: [{ conclusion: "SUCCESS" }] },
    { number: 172, title: "FN.9 — one shape for the two message tables", headRefName: "message-table-shape", state: "OPEN", statusCheckRollup: [{ status: "IN_PROGRESS" }] },
  ]), code: 0 });
  const s = await buildState(dir, { git, gh, now: 1 });
  const by = new Map(s.inFlight.map((i) => [i.id, i]));
  assert.equal(by.get("FN.3").pr, 170);                  // dotless branch match
  assert.equal(by.get("FN.3").branch, "fn3-status-guards");
  assert.equal(by.get("FN.9").pr, 172);                  // title match, branch resembles nothing
  rmSync(dir, { recursive: true });
});

test("buildMilestoneCard: an audit-follow-up FAMILY is never named as the milestone", () => {
  // FN groups 12 items under "FN", but FN is a family keyed by followup_of: F11.
  const items = [
    mk("FN.3", "todo", [], { followupOf: "F11" }),
    mk("FN.10", "todo", [], { followupOf: "F11" }),
    mk("F11.1", "done"),
    mk("DS.5.1", "done"), mk("DS.5.3", "attended", [], { handoff: "sign off the conventions" }),
    mk("DS.5.4", "todo", ["DS.5.3"]), mk("DS.5.5", "todo", ["DS.5.3"]),
  ];
  const c = card(items, {
    index: [{ id: "F11", goal: "communications", sketch: false }, { id: "DS.5", goal: "screen standardization", sketch: false }],
    inFlight: [{ id: "FN.3", title: "x", ci: "passing" }, { id: "FN.10", title: "y", ci: "pending" }],
  });
  assert.equal(c.id, "DS.5");            // never "FN"
  assert.equal(c.goal, "screen standardization");
  assert.equal(c.state, "running");      // a debt drain IS a run
  assert.equal(c.source, "gated");       // every DS.5 item waits on DS.5.3
  assert.deepEqual(c.inFlight.map((i) => i.scope), ["debt", "debt"]);
  assert.deepEqual(c.ready, []);
  assert.deepEqual(c.handoffs.map((h) => h.id), ["DS.5.3"]);
  assert.deepEqual(c.debt.map((d) => d.id), ["FN.3", "FN.10"]);
});

test("buildMilestoneCard: a milestone gated entirely by a hand-off still runs — nothing ready is not nothing to show", () => {
  const items = [mk("F2.1", "attended", [], { handoff: "rotate the key" }), mk("F2.2", "todo", ["F2.1"])];
  const c = card(items);
  assert.equal(c.id, "F2");
  assert.equal(c.source, "gated");
  assert.equal(c.state, "next");         // nothing in flight, so it is not claimed as running
  assert.equal(c.audit.state, "not-due");
});
