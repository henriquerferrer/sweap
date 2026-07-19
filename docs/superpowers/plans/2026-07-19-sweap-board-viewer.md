# sweap-board Read-Only Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `sweap-board` — a dependency-free Node tool in the sweap plugin that serves a read-only, auto-refreshing local web view of a project's parallel run (frontier / in-flight / merge queue / blocked) plus its backlog and dependency graph.

**Architecture:** Read the spec `docs/superpowers/specs/2026-07-19-sweap-board-viewer-design.md` first — its "Locked decisions" are normative. The tool is one CLI entry (`sweap-board.mjs`) that starts a loopback-only GET-only HTTP server; a pure, injectable-dependency core (`sweap-board.lib.mjs`) computes `/state.json` from item files + injected `git`/`gh` runners; a presentation module (`sweap-board.page.mjs`) returns the self-contained HTML. State is derived from ground truth (item-file status + git worktrees + PRs); the board file contributes annotation only.

**Tech Stack:** Node ≥ 20 ESM (`.mjs`), stdlib only (`node:http`, `node:child_process`, `node:fs`, `node:path`, `node:test`, `node:assert`). No npm dependencies. Verified environment: Node v24.13.1, no `package.json` (so `.mjs` is required for ESM), `gh` present.

## Global Constraints

- **Read-only invariant (spec §"Read-only / safety invariant"):** the tool MUST NOT write any file, mutate the board or item files, or invoke the pipeline. Only read commands (`git worktree list`, `gh pr list`). Server binds `127.0.0.1` only.
- **Zero npm dependencies.** Node stdlib only. All files are ESM `.mjs`.
- **Injectable I/O for testability:** `buildState(projectDir, { git, gh, now })` takes `git`/`gh` as async command-runner functions and `now` as a timestamp, so tests run offline and deterministic (no real subprocess, no wall clock).
- **Graceful degradation is required, not optional:** missing board, missing/failing `gh`, malformed item file, non-git dir must each render a partial view with a note, never crash.
- **Defaults (spec open items, now decided):** default port `7878`; `--open` on by default (`--no-open` disables).
- Commit messages follow repo style (`feat(tools):` / `test(tools):` / `docs:`), present tense, with the repo's Co-Authored-By trailer.
- Run tests with `node --test plugin/tools/`.

## File Structure

- `plugin/tools/sweap-board.lib.mjs` — pure core: frontmatter/config/item parsing, dependency logic, worktree/board/gh parsing, `buildState`. The tested unit. (Tasks 1–3)
- `plugin/tools/sweap-board.page.mjs` — `renderPage()` → the self-contained HTML string (inline CSS + client poll JS). (Task 4)
- `plugin/tools/sweap-board.mjs` — CLI entry + HTTP server + `gh` cache + `--open`. (Task 5)
- `plugin/tools/sweap-board.test.mjs` — `node:test` suite over the lib (and one HTTP smoke test). (Tasks 1–3, 5)
- `plugin/commands/board.md` — optional `/board` launcher. (Task 6)

---

### Task 1: Parsing primitives (frontmatter, config, items)

**Files:**
- Create: `plugin/tools/sweap-board.lib.mjs`
- Create: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Produces: `parseFrontmatter(text) -> { fm: object|null, body: string }`; `parseList(raw) -> string[]` (inline `[a, b]`); `readConfig(projectDir) -> { backlogFile, backlogDir }`; `loadItems(projectDir, backlogDir) -> Item[]` where `Item = { id, title, status, dependsOn: string[], reviewDimensions: string[], lane: string|null, followupOf: string|null, blocked: string|null, malformed: boolean, file: string }`.

- [ ] **Step 1: Write the failing test** (create `plugin/tools/sweap-board.test.mjs`):

```js
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
```

- [ ] **Step 2: Run it, verify it fails** — `node --test plugin/tools/sweap-board.test.mjs`; expected: cannot import `./sweap-board.lib.mjs` (module not found). Paste RED output.

- [ ] **Step 3: Implement the primitives** (create `plugin/tools/sweap-board.lib.mjs`):

```js
// sweap-board.lib.mjs — pure, testable core for the read-only board viewer.
// No process/network side effects: buildState() takes injected git/gh runners.
// Reads item files with the same flat-frontmatter contract roadmap-lint enforces.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

export function parseFrontmatter(text) {
  const norm = String(text).replace(/\r\n?/g, "\n");
  const lines = norm.split("\n");
  if (lines[0] !== "---") return { fm: null, body: norm };
  let end = -1;
  for (let i = 1; i < lines.length; i++) if (lines[i] === "---") { end = i; break; }
  if (end === -1) return { fm: null, body: norm };
  const fm = {};
  for (let i = 1; i < end; i++) {
    const m = lines[i].match(/^([A-Za-z0-9_-]+):\s?(.*)$/);
    if (m) fm[m[1]] = m[2].trim();
  }
  return { fm, body: lines.slice(end + 1).join("\n") };
}

export function parseList(raw) {
  if (!raw) return [];
  const inner = String(raw).replace(/^\[/, "").replace(/\]$/, "").trim();
  if (!inner) return [];
  return inner.split(",").map((s) => s.trim()).filter(Boolean);
}

export function readConfig(projectDir) {
  const defaults = { backlogFile: "ROADMAP.md", backlogDir: "roadmap/" };
  let md;
  try { md = readFileSync(join(projectDir, "CLAUDE.md"), "utf8"); } catch { return defaults; }
  const grab = (key) => {
    const m = md.match(new RegExp("^" + key.replace(/\./g, "\\.") + ":\\s*(\\S+)", "m"));
    return m ? m[1] : null;
  };
  const dir = grab("backlog.dir") || defaults.backlogDir;
  return {
    backlogFile: grab("backlog.file") || defaults.backlogFile,
    backlogDir: dir.endsWith("/") ? dir : dir + "/",
  };
}

export function loadItems(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir);
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files.map((f) => {
    const id = f.replace(/\.md$/, "");
    const bad = { id, title: id, status: "unknown", dependsOn: [], reviewDimensions: [], lane: null, followupOf: null, blocked: null, malformed: true, file: f };
    let fm;
    try { fm = parseFrontmatter(readFileSync(join(dir, f), "utf8")).fm; } catch { return bad; }
    if (!fm || !fm.status) return bad;
    return {
      id: fm.id || id,
      title: fm.title || id,
      status: fm.status,
      dependsOn: parseList(fm.depends_on),
      reviewDimensions: parseList(fm["review-dimensions"]),
      lane: fm.lane || null,
      followupOf: fm.followup_of || null,
      blocked: fm.blocked || null,
      malformed: Boolean(fm.id && fm.id !== id),
      file: f,
    };
  });
}
```

- [ ] **Step 4: Run tests, verify green** — `node --test plugin/tools/sweap-board.test.mjs`; expected: all 5 tests pass. Paste GREEN output.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.lib.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): sweap-board parsing primitives (frontmatter/config/items, TDD)"
```

---

### Task 2: Dependency logic + item-only derivation

**Files:**
- Modify: `plugin/tools/sweap-board.lib.mjs`
- Modify: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: `Item[]` from Task 1.
- Produces: `milestoneOf(id) -> string`; `isUnblocked(item, byId, byMilestone) -> boolean`; `compareItems(a, b) -> number` (debt-first, then numeric id order); `deriveBacklog(items) -> { frontier: Item[], blocked: {id,title,question}[], backlog: {milestone,items}[], edges: {from,to}[] }`.

- [ ] **Step 1: Write the failing test** (append to `sweap-board.test.mjs`):

```js
import { isUnblocked, compareItems, deriveBacklog, milestoneOf } from "./sweap-board.lib.mjs";

const mk = (id, status, deps = [], extra = {}) => ({ id, title: id, status, dependsOn: deps, reviewDimensions: [], lane: null, followupOf: null, blocked: null, malformed: false, file: id + ".md", ...extra });

test("milestoneOf takes the segment before the first dot", () => {
  assert.equal(milestoneOf("F1.2"), "F1");
  assert.equal(milestoneOf("DS3.4"), "DS3");
});

test("isUnblocked: item dep must be done; bare-milestone dep needs all its items done", () => {
  const items = [mk("F1.1", "done"), mk("F1.2", "todo", ["F1.1"]), mk("F2.1", "todo", ["F1"]), mk("F2.2", "todo", ["F9"])];
  const byId = new Map(items.map((i) => [i.id, i]));
  const byM = new Map();
  for (const i of items) { const m = milestoneOf(i.id); (byM.get(m) || byM.set(m, []).get(m)).push(i); }
  assert.equal(isUnblocked(items[1], byId, byM), true);   // F1.2 dep F1.1 done
  assert.equal(isUnblocked(items[2], byId, byM), true);   // F2.1 dep milestone F1 (F1.1 done)
  assert.equal(isUnblocked(items[3], byId, byM), false);  // F2.2 dep milestone F9 (no items)
});

test("compareItems orders debt first, then numeric id (F1.9 before F1.10)", () => {
  const a = mk("F1.10", "todo"), b = mk("F1.9", "todo"), debt = mk("F1.2", "todo", [], { followupOf: "F1" });
  const sorted = [a, b, debt].sort(compareItems).map((i) => i.id);
  assert.deepEqual(sorted, ["F1.2", "F1.9", "F1.10"]);
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
```

- [ ] **Step 2: Run, verify it fails** — `node --test plugin/tools/sweap-board.test.mjs`; expected: import of `isUnblocked`/`compareItems`/`deriveBacklog`/`milestoneOf` fails. Paste RED.

- [ ] **Step 3: Implement** (append to `sweap-board.lib.mjs`):

```js
export const milestoneOf = (id) => String(id).split(".")[0];

export function isUnblocked(item, byId, byMilestone) {
  return item.dependsOn.every((dep) => {
    if (dep.includes(".")) { const d = byId.get(dep); return Boolean(d && d.status === "done"); }
    const items = byMilestone.get(dep) || [];
    return items.length > 0 && items.every((i) => i.status === "done");
  });
}

const numKey = (id) => String(id).split(".").map((s) => { const m = s.match(/\d+/); return m ? parseInt(m[0], 10) : 0; });

export function compareItems(a, b) {
  const ad = a.followupOf ? 0 : 1, bd = b.followupOf ? 0 : 1;
  if (ad !== bd) return ad - bd;
  const ak = numKey(a.id), bk = numKey(b.id);
  for (let i = 0; i < Math.max(ak.length, bk.length); i++) { const d = (ak[i] || 0) - (bk[i] || 0); if (d) return d; }
  return String(a.id).localeCompare(String(b.id));
}

export function deriveBacklog(items) {
  const byId = new Map(items.map((i) => [i.id, i]));
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }

  const frontier = items
    .filter((i) => i.status === "todo" && isUnblocked(i, byId, byMilestone))
    .sort(compareItems);

  const blocked = items.filter((i) => i.status === "blocked").map((i) => ({ id: i.id, title: i.title, question: i.blocked || "(no question recorded)" }));

  const backlog = [...byMilestone.entries()]
    .sort((a, b) => compareItems({ id: a[0] + ".0", followupOf: null }, { id: b[0] + ".0", followupOf: null }))
    .map(([milestone, its]) => ({ milestone, items: [...its].sort(compareItems) }));

  const edges = [];
  for (const i of items) for (const dep of i.dependsOn) if (dep.includes(".") && byId.has(dep)) edges.push({ from: dep, to: i.id });

  return { frontier, blocked, backlog, edges };
}
```

- [ ] **Step 4: Run tests, verify green** — `node --test plugin/tools/sweap-board.test.mjs`; expected all pass. Paste GREEN.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.lib.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): sweap-board dependency logic + backlog derivation (TDD)"
```

---

### Task 3: Run overlay + `buildState`

**Files:**
- Modify: `plugin/tools/sweap-board.lib.mjs`
- Modify: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: Task 1–2 functions; injected `git(args) -> Promise<{stdout,code}>`, `gh(args) -> Promise<{stdout,code}>`, `now: number`.
- Produces: `parseWorktrees(stdout) -> {path,branch}[]`; `parseBoard(text) -> { steps, prByItem, wtByItem, questions }`; `ciSummary(rollup) -> "passing"|"failing"|"pending"|"unknown"`; `async buildState(projectDir, { git, gh, now }) -> State`. `State = { generatedAt, project, run:{active,prsAvailable}, frontier, inFlight, mergeQueue, blocked, backlog, edges, notes:string[] }`.

- [ ] **Step 1: Write the failing test** (append):

```js
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
```

- [ ] **Step 2: Run, verify it fails** — `node --test plugin/tools/sweap-board.test.mjs`; expected import failure for the new exports. Paste RED.

- [ ] **Step 3: Implement** (append to `sweap-board.lib.mjs`):

```js
import { existsSync } from "node:fs";
import { basename } from "node:path";

export function parseWorktrees(stdout) {
  const out = [];
  let cur = null;
  for (const line of String(stdout).split("\n")) {
    if (line.startsWith("worktree ")) { if (cur) out.push(cur); cur = { path: line.slice(9), branch: null }; }
    else if (line.startsWith("branch ") && cur) cur.branch = line.slice(7).replace("refs/heads/", "");
  }
  if (cur) out.push(cur);
  return out;
}

export function parseBoard(text) {
  const ann = { steps: {}, prByItem: {}, wtByItem: {}, questions: {} };
  if (!text) return ann;
  for (const raw of String(text).split("\n")) {
    const parts = raw.split("|").map((s) => s.trim());
    if (parts.length < 2) continue;
    const id = parts[0].replace(/^[-*#\s>]+/, "").trim();
    if (!/^[A-Za-z]+\d/.test(id)) continue;
    if (parts[1]) ann.steps[id] = parts[1];
    const wt = raw.match(/(\S+)@(\S+)/); if (wt) ann.wtByItem[id] = { worktree: wt[1], branch: wt[2] };
    const pr = raw.match(/PR\s*#?(\d+)/i); if (pr) ann.prByItem[id] = parseInt(pr[1], 10);
    const last = parts[parts.length - 1]; if (last && last !== "-") ann.questions[id] = last;
  }
  return ann;
}

export function ciSummary(rollup) {
  if (!Array.isArray(rollup) || rollup.length === 0) return "unknown";
  const states = rollup.map((c) => (c.conclusion || c.status || "").toUpperCase());
  if (states.some((s) => s === "FAILURE" || s === "TIMED_OUT" || s === "CANCELLED" || s === "ERROR")) return "failing";
  if (states.every((s) => s === "SUCCESS" || s === "NEUTRAL" || s === "SKIPPED")) return "passing";
  return "pending";
}

async function readGh(gh, notes) {
  try {
    const { stdout, code } = await gh(["pr", "list", "--json", "number,title,headRefName,state,statusCheckRollup,mergeStateStatus"]);
    if (code !== 0) { notes.push("PR/CI unavailable (gh returned non-zero)"); return null; }
    return JSON.parse(stdout || "[]");
  } catch { notes.push("PR/CI unavailable (gh not runnable)"); return null; }
}

export async function buildState(projectDir, { git, gh, now }) {
  const notes = [];
  const { backlogDir } = readConfig(projectDir);
  const items = loadItems(projectDir, backlogDir);
  if (items.some((i) => i.malformed)) notes.push("one or more item files are malformed (shown flagged)");
  const { frontier, blocked, backlog, edges } = deriveBacklog(items);
  const byId = new Map(items.map((i) => [i.id, i]));

  let worktrees = [];
  try { const g = await git(["worktree", "list", "--porcelain"]); if (g.code === 0) worktrees = parseWorktrees(g.stdout); else notes.push("git worktrees unavailable"); }
  catch { notes.push("git worktrees unavailable"); }

  const prs = await readGh(gh, notes);
  const prsAvailable = prs !== null;

  let boardText = "";
  const boardPath = join(projectDir, ".claude", "sweap-board.md");
  if (existsSync(boardPath)) { try { boardText = readFileSync(boardPath, "utf8"); } catch { /* ignore */ } }
  const ann = parseBoard(boardText);

  const prByRef = new Map((prs || []).map((p) => [p.headRefName, p]));
  const linkPr = (item) => {
    if (ann.prByItem[item.id] != null) return (prs || []).find((p) => p.number === ann.prByItem[item.id]) || { number: ann.prByItem[item.id] };
    const wt = ann.wtByItem[item.id];
    if (wt && prByRef.has(wt.branch)) return prByRef.get(wt.branch);
    for (const p of prs || []) if (p.headRefName.includes(item.id)) return p;
    return null;
  };
  const linkWt = (item) => ann.wtByItem[item.id] || worktrees.find((w) => w.branch && w.branch.includes(item.id)) || null;

  const inFlight = items
    .filter((i) => i.status !== "done" && (ann.wtByItem[i.id] || ann.prByItem[i.id] != null || linkWt(i) || linkPr(i)))
    .map((i) => {
      const wt = linkWt(i); const pr = linkPr(i);
      return { id: i.id, title: i.title, step: ann.steps[i.id] || null, worktree: wt ? (wt.worktree || basename(wt.path || "")) : null, branch: wt ? wt.branch : null, pr: pr ? pr.number : null, ci: pr && pr.statusCheckRollup ? ciSummary(pr.statusCheckRollup) : "unknown" };
    });

  const inFlightPrs = new Set(inFlight.map((f) => f.pr).filter(Boolean));
  const mergeQueue = (prs || []).filter((p) => inFlightPrs.has(p.number)).map((p) => ({ pr: p.number, title: p.title, ci: ciSummary(p.statusCheckRollup), mergeState: p.mergeStateStatus || null }));

  const active = boardText.trim().length > 0 || inFlight.length > 0;
  if (!active) notes.push("no run in flight");

  return { generatedAt: now, project: basename(projectDir), run: { active, prsAvailable }, frontier: frontier.map((i) => ({ id: i.id, title: i.title, lane: i.lane, reviewDimensions: i.reviewDimensions })), inFlight, mergeQueue, blocked, backlog: backlog.map((g) => ({ milestone: g.milestone, items: g.items.map((i) => ({ id: i.id, title: i.title, status: i.status, dependsOn: i.dependsOn, malformed: i.malformed })) })), edges, notes };
}
```

- [ ] **Step 4: Run tests, verify green** — `node --test plugin/tools/sweap-board.test.mjs`; expected all pass. Paste GREEN.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.lib.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): sweap-board run overlay + buildState (worktrees/PRs/board, TDD)"
```

---

### Task 4: The HTML page

**Files:**
- Create: `plugin/tools/sweap-board.page.mjs`
- Modify: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Produces: `renderPage() -> string` — a complete self-contained HTML document (inline CSS + client poll JS). No server-side state is injected; the page fetches `/state.json` itself. The client patches these container ids: `#frontier`, `#inflight`, `#mergequeue`, `#blocked`, `#backlog`, `#graph`, `#updated`, `#notes`, `#project`.

- [ ] **Step 1: Write the failing test** (append):

```js
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
```

- [ ] **Step 2: Run, verify it fails** — `node --test plugin/tools/sweap-board.test.mjs`; expected import failure for `renderPage`. Paste RED.

- [ ] **Step 3: Implement** (create `plugin/tools/sweap-board.page.mjs`). The client JS is embedded as a template string; keep all assets inline (CSP-clean even locally):

```js
// sweap-board.page.mjs — the self-contained viewer page. renderPage() returns a
// full HTML document; the client polls /state.json and patches the DOM. No
// frameworks, no external assets.
export function renderPage() {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>sweap board</title>
<style>
  :root { --bg:#fff; --fg:#1a1a1a; --muted:#666; --line:#e3e3e3; --card:#f7f7f8; --ok:#1a7f37; --warn:#9a6700; --bad:#cf222e; --accent:#0969da; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8b949e; --line:#30363d; --card:#161b22; --ok:#3fb950; --warn:#d29922; --bad:#f85149; --accent:#58a6ff; } }
  * { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  header { display:flex; align-items:baseline; gap:12px; padding:12px 16px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--bg); }
  header h1 { font-size:15px; margin:0; font-weight:600; } #project { color:var(--accent); } #updated { color:var(--muted); font-size:12px; margin-left:auto; }
  main { padding:16px; max-width:1200px; margin:0 auto; } section { margin-bottom:22px; }
  h2 { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 8px; }
  .cols { display:grid; grid-template-columns:repeat(auto-fit,minmax(210px,1fr)); gap:12px; }
  .col { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px; min-height:44px; overflow-x:auto; }
  .item { padding:6px 8px; border:1px solid var(--line); border-radius:6px; margin-bottom:6px; background:var(--bg); }
  .item b { font-weight:600; } .meta { color:var(--muted); font-size:12px; }
  .blocked .item { border-color:var(--bad); } .blocked .q { color:var(--bad); }
  .badge { display:inline-block; font-size:11px; padding:1px 6px; border-radius:10px; border:1px solid var(--line); }
  .ci-passing { color:var(--ok); border-color:var(--ok); } .ci-failing { color:var(--bad); border-color:var(--bad); } .ci-pending,.ci-unknown { color:var(--warn); border-color:var(--warn); }
  .st-done { color:var(--ok); } .st-todo { color:var(--fg); } .st-blocked { color:var(--bad); } .st-deferred { color:var(--muted); } .malformed { color:var(--bad); font-style:italic; }
  #notes { color:var(--warn); font-size:12px; } #notes span { margin-right:12px; }
  .ms { margin-bottom:10px; } .ms h3 { font-size:13px; margin:0 0 4px; }
  svg { max-width:100%; height:auto; } .empty { color:var(--muted); font-size:12px; }
</style></head>
<body>
<header><h1>sweap <span id="project">…</span></h1><span id="notes"></span><span id="updated"></span></header>
<main>
  <section><h2>Live run</h2>
    <div class="cols">
      <div><h2>Frontier (ready)</h2><div class="col" id="frontier"></div></div>
      <div><h2>In-flight</h2><div class="col" id="inflight"></div></div>
      <div><h2>Merge queue</h2><div class="col" id="mergequeue"></div></div>
      <div class="blocked"><h2>⛔ Blocked — needs you</h2><div class="col" id="blocked"></div></div>
    </div>
  </section>
  <section><h2>Backlog</h2><div id="backlog"></div></section>
  <section><h2>Dependencies</h2><div id="graph"></div></section>
</main>
<script>
const esc = (s) => String(s==null?"":s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const empty = (el, msg) => { el.innerHTML = '<div class="empty">'+esc(msg)+'</div>'; };
function renderList(el, arr, fn, msg) { if (!arr || !arr.length) return empty(el, msg); el.innerHTML = arr.map(fn).join(""); }
function draw(s) {
  document.getElementById("project").textContent = s.project || "";
  const ago = Math.max(0, Math.round((Date.now() - s.generatedAt)/1000));
  document.getElementById("updated").textContent = "updated " + ago + "s ago" + (s.run.active ? "" : " · no run in flight");
  document.getElementById("notes").innerHTML = (s.notes||[]).map(n => '<span>⚠ '+esc(n)+'</span>').join("");
  renderList(document.getElementById("frontier"), s.frontier, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+(i.lane?' <span class="meta">lane:'+esc(i.lane)+'</span>':'')+'</div>', "nothing ready");
  renderList(document.getElementById("inflight"), s.inFlight, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+'<div class="meta">'+esc(i.step||"working")+(i.branch?' · '+esc(i.branch):'')+(i.pr?' · PR #'+i.pr:'')+' <span class="badge ci-'+esc(i.ci)+'">'+esc(i.ci)+'</span></div></div>', "nothing in flight");
  renderList(document.getElementById("mergequeue"), s.mergeQueue, q => '<div class="item">PR #'+q.pr+' '+esc(q.title)+' <span class="badge ci-'+esc(q.ci)+'">'+esc(q.ci)+'</span></div>', "queue empty");
  renderList(document.getElementById("blocked"), s.blocked, b => '<div class="item"><b>'+esc(b.id)+'</b> '+esc(b.title)+'<div class="q">'+esc(b.question)+'</div></div>', "none blocked 🎉");
  document.getElementById("backlog").innerHTML = (s.backlog||[]).map(g => '<div class="ms"><h3>'+esc(g.milestone)+'</h3>'+g.items.map(i => '<div class="item'+(i.malformed?' malformed':'')+'"><span class="st-'+esc(i.status)+'">●</span> <b>'+esc(i.id)+'</b> '+esc(i.title)+' <span class="meta">'+esc(i.status)+(i.dependsOn&&i.dependsOn.length?' · deps: '+i.dependsOn.map(esc).join(", "):'')+'</span></div>').join("")+'</div>').join("") || '<div class="empty">no items</div>';
  document.getElementById("graph").innerHTML = graphSvg(s);
}
function graphSvg(s) {
  const items = (s.backlog||[]).flatMap(g => g.items);
  if (!items.length) return '<div class="empty">no items</div>';
  const depth = new Map(); const byId = new Map(items.map(i => [i.id, i]));
  const d = (id, seen) => { if (depth.has(id)) return depth.get(id); if (seen.has(id)) return 0; seen.add(id); const it = byId.get(id); const dd = it && it.dependsOn.length ? 1 + Math.max(0, ...it.dependsOn.filter(x=>byId.has(x)).map(x => d(x, seen))) : 0; depth.set(id, dd); return dd; };
  items.forEach(i => d(i.id, new Set()));
  const cols = new Map(); items.forEach(i => { const k = depth.get(i.id)||0; if (!cols.has(k)) cols.set(k, []); cols.get(k).push(i.id); });
  const CW=170, RH=30, PAD=16; const pos = new Map(); let maxRows=0;
  [...cols.keys()].sort((a,b)=>a-b).forEach((k,ci) => { cols.get(k).forEach((id,ri) => pos.set(id, { x: PAD+ci*CW, y: PAD+ri*RH })); maxRows=Math.max(maxRows, cols.get(k).length); });
  const W = PAD*2 + (cols.size||1)*CW, H = PAD*2 + Math.max(1,maxRows)*RH;
  const line = (e) => { const a=pos.get(e.from), b=pos.get(e.to); if(!a||!b) return ""; return '<line x1="'+(a.x+120)+'" y1="'+(a.y+9)+'" x2="'+b.x+'" y2="'+(b.y+9)+'" stroke="var(--line)"/>'; };
  const node = (id) => { const p=pos.get(id), it=byId.get(id); return '<g><rect x="'+p.x+'" y="'+p.y+'" width="120" height="18" rx="4" fill="var(--card)" stroke="var(--line)"/><text x="'+(p.x+6)+'" y="'+(p.y+13)+'" font-size="11" fill="var(--fg)">'+esc(id)+' '+esc((it.status||"")[0]||"")+'</text></g>'; };
  return '<svg viewBox="0 0 '+W+' '+H+'" width="'+W+'">'+(s.edges||[]).map(line).join("")+items.map(i=>node(i.id)).join("")+'</svg>';
}
async function tick() { try { const r = await fetch("/state.json", {cache:"no-store"}); draw(await r.json()); } catch (e) { document.getElementById("updated").textContent = "disconnected"; } }
tick(); setInterval(tick, 3000);
</script>
</body></html>`;
}
```

- [ ] **Step 4: Run tests, verify green** — `node --test plugin/tools/sweap-board.test.mjs`; expected all pass. Paste GREEN. (The `w3.org` allowance in the test covers the optional `lang`/doctype; there are no external asset URLs.)

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.page.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): sweap-board self-contained viewer page (TDD)"
```

---

### Task 5: Server + CLI

**Files:**
- Create: `plugin/tools/sweap-board.mjs`
- Modify: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: `buildState` (lib), `renderPage` (page).
- Produces: executable entry `node sweap-board.mjs [serve] [--port N] [--no-open] [--project DIR]`. Real `git`/`gh` runners via `execFile`; a ~15s `gh` cache. Exports `createServer({ projectDir, ghCacheMs }) -> http.Server` for the smoke test (no `listen` side effect until the test calls it on port 0).

- [ ] **Step 1: Write the failing test** (append):

```js
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
```

- [ ] **Step 2: Run, verify it fails** — `node --test plugin/tools/sweap-board.test.mjs`; expected import failure for `createServer`. Paste RED.

- [ ] **Step 3: Implement** (create `plugin/tools/sweap-board.mjs`):

```js
#!/usr/bin/env node
// sweap-board.mjs — loopback-only, read-only viewer server + CLI.
// Reads state; NEVER writes files, mutates the board, or invokes the pipeline.
import http from "node:http";
import { execFile } from "node:child_process";
import { buildState } from "./sweap-board.lib.mjs";
import { renderPage } from "./sweap-board.page.mjs";

const run = (cmd) => (args) => new Promise((resolve) => {
  execFile(cmd, args, { maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => resolve({ stdout: stdout || "", code: err ? (err.code || 1) : 0 }));
});

export function createServer({ projectDir, git = run("git"), gh = run("gh"), ghCacheMs = 15000 }) {
  let ghCache = { at: 0, promise: null };
  const cachedGh = (args) => {
    const now = Date.now();
    if (!ghCache.promise || now - ghCache.at > ghCacheMs) { ghCache = { at: now, promise: gh(args) }; }
    return ghCache.promise;
  };
  const PAGE = renderPage();
  return http.createServer(async (req, res) => {
    if (req.method !== "GET") { res.writeHead(405); return res.end("read-only"); }
    try {
      if (req.url === "/" || req.url.startsWith("/index")) { res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return res.end(PAGE); }
      if (req.url.startsWith("/state.json")) {
        const state = await buildState(projectDir, { git, gh: cachedGh, now: Date.now() });
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        return res.end(JSON.stringify(state));
      }
      res.writeHead(404); res.end("not found");
    } catch (e) { res.writeHead(500); res.end("error: " + e.message); }
  });
}

function parseArgs(argv) {
  const a = { port: 7878, open: true, projectDir: process.cwd() };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === "--port") a.port = parseInt(argv[++i], 10);
    else if (v === "--no-open") a.open = false;
    else if (v === "--project") a.projectDir = argv[++i];
  }
  return a;
}

async function listenWithFallback(srv, port, host, tries = 10) {
  for (let p = port; p < port + tries; p++) {
    const ok = await new Promise((res) => { srv.once("error", (e) => { if (e.code === "EADDRINUSE") res(false); else throw e; }); srv.listen(p, host, () => res(true)); });
    if (ok) return p;
  }
  throw new Error(`no free port in ${port}..${port + tries}`);
}

function openBrowser(url) {
  const cmd = process.platform === "darwin" ? "open" : process.platform === "win32" ? "explorer" : "xdg-open";
  execFile(cmd, [url], () => {});
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const args = parseArgs(process.argv.slice(2).filter((a) => a !== "serve"));
  const srv = createServer({ projectDir: args.projectDir });
  const port = await listenWithFallback(srv, args.port, "127.0.0.1");
  const url = `http://127.0.0.1:${port}/`;
  process.stdout.write(`sweap-board: ${url}  (project: ${args.projectDir})\nread-only — Ctrl-C to stop\n`);
  if (args.open) openBrowser(url);
}
```

- [ ] **Step 4: Run the full suite, verify green** — `node --test plugin/tools/`; expected: every test across all files passes. Paste GREEN. Then a real manual smoke (from a project that has a `roadmap/`): `node plugin/tools/sweap-board.mjs --project . --no-open &` then `curl -s localhost:7878/state.json | head -c 200`; confirm JSON, then `kill %1`.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): sweap-board loopback server + CLI (gh cache, port fallback, --open)"
```

---

### Task 6: `/board` launcher command + docs

**Files:**
- Create: `plugin/commands/board.md`
- Modify: `plugin/playbook/agentic-loop-playbook.md` (one line in the mechanisms/kickoff area)

**Interfaces:** none (documentation surface).

- [ ] **Step 1: Create `plugin/commands/board.md`**:

```markdown
---
description: Launch the read-only sweap-board viewer for this project (live run + backlog + deps).
argument-hint: "[--port N] [--no-open] — defaults: 7878, opens the browser"
---

Start the **read-only** board viewer for the current project:

\`\`\`bash
node "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.mjs" --project "$PWD" $ARGUMENTS
\`\`\`

It binds to `127.0.0.1` only, serves a live page (frontier / in-flight / merge
queue / blocked, plus the backlog and dependency graph), and refreshes itself by
polling. It **only reads** — item files, `git worktree list`, `gh pr list`, and
`.claude/sweap-board.md` (annotation only). It never writes anything, never
touches the board or the pipeline, so it is safe to leave running during an
autonomous coordinator run. Stop it with Ctrl-C.
```

- [ ] **Step 2: Add one pointer line to the playbook mechanisms table** — in `plugin/playbook/agentic-loop-playbook.md`, in the "Claude Code mechanisms available" table, add a row after the `claude --continue` row:

```markdown
| `/board` (read-only viewer) | Local loopback page showing the live run (frontier/in-flight/merge-queue/blocked) + backlog + dep graph; derives state from item files + git + PRs, never writes | User runs; safe during autonomous runs |
```

- [ ] **Step 3: Verify** — `node --check` is N/A for markdown; confirm the command file resolves the tool path: `test -f plugin/tools/sweap-board.mjs && grep -q 'sweap-board.mjs' plugin/commands/board.md && echo ok`.

- [ ] **Step 4: Commit**

```bash
git add plugin/commands/board.md plugin/playbook/agentic-loop-playbook.md
git commit -m "feat(commands): /board launcher for the read-only viewer + playbook pointer"
```

---

## Final verification (after all tasks)

- [ ] `node --test plugin/tools/` — entire suite green (paste the summary line).
- [ ] Manual: from this repo's worktree (no `roadmap/` here) run `node plugin/tools/sweap-board.mjs --project . --no-open`, curl `/state.json`, confirm it returns valid JSON with `run.active:false` and a `"no run in flight"`-style note (graceful no-backlog/no-run path), then stop it.
- [ ] Confirm the read-only invariant by inspection: grep the tool for any write (`writeFile`, `>`, `gh pr merge`, `git commit`) — there must be none: `grep -nE "writeFile|appendFile|mkdir|gh (pr merge|pr create|pr close)|git (commit|push|worktree add)" plugin/tools/*.mjs` returns nothing.
