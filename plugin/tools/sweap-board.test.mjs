import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

import { renderPage } from "./sweap-board.page.mjs";

test("renderPage returns a self-contained HTML doc with the poll targets", () => {
  const html = renderPage();
  assert.match(html, /<!doctype html>/i);
  for (const id of ["frontier", "inflight", "mergequeue", "blocked", "backlog", "graph", "updated", "notes", "project"]) {
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
