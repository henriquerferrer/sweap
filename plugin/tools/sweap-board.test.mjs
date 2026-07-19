import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseFrontmatter, parseList, readConfig, loadItems } from "./sweap-board.lib.mjs";

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

test("milestoneOf takes the segment before the first dot", () => {
  assert.equal(milestoneOf("F1.2"), "F1");
  assert.equal(milestoneOf("DS3.4"), "DS3");
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
