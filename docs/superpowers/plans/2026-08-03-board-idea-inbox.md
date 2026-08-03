# sweap-board Idea Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add create-only idea capture to the sweap-board viewer: a `POST /ideas` endpoint writing `roadmap/ideas/<slug>.md` files, an Ideas panel on the page, and doc edits wiring the inbox into `/roadmap` triage.

**Architecture:** The board server stays read-only against all pipeline state; its single write capability is creating new uniquely-named files under `<backlogDir>/ideas/` (a subdir invisible to `loadItems`, roadmap-lint, and dep resolution — same pattern as `roadmap/archive/`). Pure/fs helpers (`slugify`, `writeIdea`, `loadIdeas`) live in `sweap-board.lib.mjs`; the HTTP route lives in `sweap-board.mjs`; the form/panel lives in `sweap-board.page.mjs`. Triage integration is doc-only: `/roadmap`'s decide phase surfaces the inbox, reconcile archives triaged ideas.

**Tech Stack:** Node built-ins only (`node:http`, `node:fs`, `node:path`, `node:test`). No dependencies, no frameworks. Spec: `docs/superpowers/specs/2026-08-03-board-idea-inbox-design.md`.

## Global Constraints

- **No new dependencies.** Node built-ins only, `.mjs` ES modules.
- **Loopback + create-only:** the server binds `127.0.0.1` only; the ONLY non-GET route is `POST /ideas`; every other non-GET request must still get `405` with body `read-only`. The server never modifies or deletes any file.
- **Idea file format** (flat frontmatter, matching the repo's contract): `---\ntitle: <title>\ncreated: <ISO timestamp>\n---\n\n<body>\n`.
- **Slug alphabet:** `[a-z0-9-]` only — title lowercased, every other run of chars collapsed to a single `-`, edge dashes trimmed. Collisions get `-2`, `-3`, … suffixes.
- **Tests:** `node:test` style matching the existing file. Run with: `node --test plugin/tools/sweap-board.test.mjs` (from the repo root, `~/Documents/sweap`).
- **Page:** self-contained (no external asset URLs), theme-aware, escape all user strings with the existing `esc()`.
- **Commits:** conventional style used in this repo, e.g. `feat(tools): …`, `docs(…): …`. Commit directly on `main` (repo convention).

---

### Task 1: `slugify` + `writeIdea` in the lib

**Files:**
- Modify: `plugin/tools/sweap-board.lib.mjs` (imports at top; new functions after `readConfig`, ~line 45)
- Test: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: existing `join` from `node:path` (already imported in lib).
- Produces: `slugify(title) -> string`; `writeIdea(projectDir, backlogDir, {title, body, now}) -> {file}` where `file` is relative to the project dir (e.g. `"roadmap/ideas/dark-mode.md"`), `now` is epoch ms, and it throws `Error("title required")` on empty/whitespace/no-alphanumeric titles. Task 3's route calls `writeIdea` and maps `/title required/` errors to 400.

- [ ] **Step 1: Write the failing tests**

Append to `plugin/tools/sweap-board.test.mjs` (the `fixture` helper and `rmSync`/`join` imports already exist at the top of the file):

```js
import { slugify, writeIdea } from "./sweap-board.lib.mjs";
import { readFileSync, existsSync } from "node:fs";

test("slugify reduces a title to [a-z0-9-]", () => {
  assert.equal(slugify("Dark mode for the board!"), "dark-mode-for-the-board");
  assert.equal(slugify("  F1.2  retry logic  "), "f1-2-retry-logic");
  assert.equal(slugify("///"), "");
});

test("writeIdea creates roadmap/ideas/<slug>.md with frontmatter; suffixes collisions", () => {
  const dir = fixture({ "CLAUDE.md": "## sweap config\n" });
  const a = writeIdea(dir, "roadmap/", { title: "Dark mode", body: "for the board page", now: 1754200000000 });
  assert.equal(a.file, join("roadmap/", "ideas", "dark-mode.md"));
  const text = readFileSync(join(dir, a.file), "utf8");
  assert.match(text, /^---\ntitle: Dark mode\ncreated: 2026-08-03T/);
  assert.match(text, /---\n\nfor the board page\n$/);
  const b = writeIdea(dir, "roadmap/", { title: "Dark mode", body: "", now: 1754200000000 });
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
```

Note: `readFileSync` is not yet imported in the test file — add it in the import line shown above (alongside `existsSync`). If a name collides with an existing import, reuse the existing one instead of re-importing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: FAIL — `slugify`/`writeIdea` are not exported ("does not provide an export named 'slugify'").

- [ ] **Step 3: Implement `slugify` and `writeIdea` in the lib**

In `plugin/tools/sweap-board.lib.mjs`, extend the fs import at the top:

```js
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
```

Add after `readConfig` (~line 45):

```js
// Idea inbox: the board's ONLY write capability. Create-only — new uniquely
// named files under <backlogDir>/ideas/, a subdir loadItems/lint/dep
// resolution never read (same reason roadmap/archive/ is invisible).
export const slugify = (title) =>
  String(title).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

export function writeIdea(projectDir, backlogDir, { title, body = "", now }) {
  const t = String(title || "").replace(/\s+/g, " ").trim();
  const slug = slugify(t);
  if (!t || !slug) throw new Error("title required");
  const dir = join(projectDir, backlogDir, "ideas");
  mkdirSync(dir, { recursive: true });
  let file = slug + ".md";
  for (let n = 2; existsSync(join(dir, file)); n++) file = `${slug}-${n}.md`;
  const content = `---\ntitle: ${t}\ncreated: ${new Date(now).toISOString()}\n---\n\n${String(body || "").trim()}\n`;
  writeFileSync(join(dir, file), content, { flag: "wx" });
  return { file: join(backlogDir, "ideas", file) };
}
```

(`existsSync` is already imported in the lib. The `wx` flag makes the write itself fail rather than overwrite if a file appears between the exists-check and the write.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: ALL PASS (new tests plus every pre-existing test).

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.lib.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): slugify + writeIdea — create-only idea files under roadmap/ideas/"
```

---

### Task 2: `loadIdeas` + `ideas` in `state.json`

**Files:**
- Modify: `plugin/tools/sweap-board.lib.mjs` (new function after `writeIdea`; two-line change in `buildState`, ~line 169–215)
- Test: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: `parseFrontmatter` (existing), `writeIdea` file format from Task 1.
- Produces: `loadIdeas(projectDir, backlogDir) -> [{file, title, created}]` (newest `created` first; `file` is the bare filename, e.g. `"dark-mode.md"`); `buildState()` result gains a top-level `ideas` array of exactly those objects. Task 4's page renders `s.ideas`.

- [ ] **Step 1: Write the failing tests**

Append to `plugin/tools/sweap-board.test.mjs`:

```js
import { loadIdeas } from "./sweap-board.lib.mjs";

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: FAIL — no export named `loadIdeas`.

- [ ] **Step 3: Implement `loadIdeas` and wire it into `buildState`**

In `plugin/tools/sweap-board.lib.mjs`, add after `writeIdea`:

```js
export function loadIdeas(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir, "ideas");
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files
    .map((f) => {
      let fm = null;
      try { fm = parseFrontmatter(readFileSync(join(dir, f), "utf8")).fm; } catch { /* unreadable: fall through */ }
      return { file: f, title: (fm && fm.title) || f.replace(/\.md$/, ""), created: (fm && fm.created) || null };
    })
    .sort((a, b) => String(b.created || "").localeCompare(String(a.created || "")) || a.file.localeCompare(b.file));
}
```

(`readdirSync` is non-recursive, and the `archive` directory entry has no `.md` suffix, so `ideas/archive/` is skipped without any special-casing.)

In `buildState` (same file), add one line after `const items = loadItems(projectDir, backlogDir);`:

```js
  const ideas = loadIdeas(projectDir, backlogDir);
```

and add `ideas,` to the returned object (the big `return { generatedAt: now, … }` literal at the end of `buildState`) — e.g. right after `blocked,`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.lib.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): loadIdeas — idea inbox in state.json (archive/ invisible)"
```

---

### Task 3: `POST /ideas` route on the server

**Files:**
- Modify: `plugin/tools/sweap-board.mjs` (import line ~6; request handler inside `createServer`, ~line 22–34)
- Test: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: `writeIdea`, `readConfig` from the lib (Task 1).
- Produces: `POST /ideas` accepting JSON `{title, body}` → `201` + JSON `{file}` (project-relative path); `400` on invalid JSON or missing/empty/non-sluggable title; `500` on fs failure; `413` + destroyed socket past 64 KiB. Every other non-GET request still → `405 read-only`. Task 4's form posts to this route.

- [ ] **Step 1: Write the failing tests**

Append to `plugin/tools/sweap-board.test.mjs` (a `listen` helper keeps the three tests flat; `createServer` is already imported higher up):

```js
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: FAIL — the POSTs get `405` (current global non-GET guard), so the 201/400 assertions fail. The third test may already pass; that's fine.

- [ ] **Step 3: Implement the route**

In `plugin/tools/sweap-board.mjs`, extend the lib import (line ~6):

```js
import { buildState, readConfig, writeIdea } from "./sweap-board.lib.mjs";
```

Inside `createServer`'s request handler, insert the POST branch **before** the existing `if (req.method !== "GET")` guard:

```js
    if (req.method === "POST" && req.url === "/ideas") {
      let raw = "";
      req.on("data", (c) => { raw += c; if (raw.length > 64 * 1024) { res.writeHead(413); res.end("too large"); req.destroy(); } });
      req.on("end", () => {
        if (res.writableEnded) return;
        let parsed;
        try { parsed = JSON.parse(raw || "{}"); } catch { res.writeHead(400); return res.end("invalid JSON"); }
        try {
          const { backlogDir } = readConfig(projectDir);
          const { file } = writeIdea(projectDir, backlogDir, { title: parsed.title, body: parsed.body, now: Date.now() });
          res.writeHead(201, { "content-type": "application/json" });
          res.end(JSON.stringify({ file }));
        } catch (e) {
          res.writeHead(/title required/.test(e.message) ? 400 : 500);
          res.end("error: " + e.message);
        }
      });
      return;
    }
```

Also update the CLI startup line (line ~71) so the terminal banner states the real contract:

```js
  process.stdout.write(`sweap-board: ${url}  (project: ${args.projectDir})\nread-only (writes only new idea files under the roadmap ideas/ inbox) — Ctrl-C to stop\n`);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add plugin/tools/sweap-board.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): POST /ideas — create-only idea capture (405 preserved elsewhere)"
```

---

### Task 4: Ideas panel on the page

**Files:**
- Modify: `plugin/tools/sweap-board.page.mjs` (CSS block ~line 27; HTML `<main>` ~line 40–42; script ~line 44–74)
- Test: `plugin/tools/sweap-board.test.mjs`

**Interfaces:**
- Consumes: `s.ideas` from `state.json` (Task 2), `POST /ideas` (Task 3), existing `esc`, `renderList`, `tick` in the page script.
- Produces: DOM ids `idea-form`, `idea-title`, `idea-body`, `idea-msg`, `ideas` (Task 4 is a leaf — nothing later depends on it).

- [ ] **Step 1: Write the failing test**

Append to `plugin/tools/sweap-board.test.mjs`:

```js
test("renderPage includes the Ideas capture form and list", () => {
  const html = renderPage();
  for (const id of ["idea-form", "idea-title", "idea-body", "idea-msg", "ideas"]) {
    assert.ok(html.includes(`id="${id}"`), `missing #${id}`);
  }
  assert.match(html, /fetch\("\/ideas"/);       // the form posts to the endpoint
  assert.ok(!/https?:\/\//.test(html.replace(/https?:\/\/[^"']*w3\.org[^"']*/g, "")), "still no external asset URLs");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: FAIL — `missing #idea-form`.

- [ ] **Step 3: Implement the panel**

In `plugin/tools/sweap-board.page.mjs`:

Add to the `<style>` block (before `</style>`):

```css
  #idea-form { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:8px; }
  #idea-form input, #idea-form textarea { background:var(--bg); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:6px 8px; font:inherit; }
  #idea-title { flex:1 1 220px; } #idea-body { flex:1 1 100%; min-height:52px; resize:vertical; }
  #idea-form button { background:var(--accent); color:#fff; border:0; border-radius:6px; padding:6px 14px; font:inherit; cursor:pointer; }
  #idea-msg { font-size:12px; color:var(--bad); align-self:center; }
```

Add a section inside `<main>`, between the Backlog and Dependencies sections:

```html
  <section><h2>Ideas (inbox — triaged by /roadmap)</h2>
    <form id="idea-form">
      <input id="idea-title" placeholder="idea title" maxlength="200" required/>
      <button type="submit">Capture</button><span id="idea-msg"></span>
      <textarea id="idea-body" placeholder="details (optional)"></textarea>
    </form>
    <div class="col" id="ideas"></div>
  </section>
```

Add to `draw(s)` (alongside the other `renderList` calls):

```js
  renderList(document.getElementById("ideas"), s.ideas, i => '<div class="item"><b>'+esc(i.title)+'</b> <span class="meta">'+esc(i.file)+(i.created?' · '+esc(i.created.slice(0,10)):'')+'</span></div>', "inbox empty");
```

Add to the `<script>` block, after the `tick(); setInterval(tick, 3000);` lines:

```js
document.getElementById("idea-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = document.getElementById("idea-msg");
  const title = document.getElementById("idea-title").value.trim();
  if (!title) return;
  try {
    const r = await fetch("/ideas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title, body: document.getElementById("idea-body").value }) });
    if (r.ok) { e.target.reset(); msg.textContent = ""; tick(); }
    else { msg.textContent = "capture failed: " + await r.text(); }
  } catch { msg.textContent = "capture failed: server unreachable"; }
});
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test plugin/tools/sweap-board.test.mjs`
Expected: ALL PASS.

- [ ] **Step 5: Eyeball it once in a real browser**

Run: `node plugin/tools/sweap-board.mjs --project ~/Documents/sweap --no-open` then open the printed URL. Submit a test idea; confirm it appears in the Ideas list within a poll cycle (≤3 s) and renders sanely in both light and dark mode. Then delete the test file it created (it lands at `roadmap/ideas/<slug>.md` under the project dir) and Ctrl-C the server.

- [ ] **Step 6: Commit**

```bash
git add plugin/tools/sweap-board.page.mjs plugin/tools/sweap-board.test.mjs
git commit -m "feat(tools): Ideas panel — capture form + inbox list on the board page"
```

---

### Task 5: Doc edits — `/board` contract, `/roadmap` triage, playbook

**Files:**
- Modify: `plugin/commands/board.md` (the closing paragraph, lines 12–17)
- Modify: `plugin/commands/roadmap.md` (step 1 "Decide" and step 3 "Reconcile")
- Modify: `plugin/playbook/agentic-loop-playbook.md` (backlog-format bullet list, ~line 79, next to the `roadmap/archive/` bullet)

**Interfaces:**
- Consumes: the mechanics shipped in Tasks 1–4 (`POST /ideas`, `roadmap/ideas/`, `ideas/archive/`).
- Produces: nothing downstream — docs only.

- [ ] **Step 1: Update `plugin/commands/board.md`**

Replace the final paragraph (currently "It binds to `127.0.0.1` only … Stop it with Ctrl-C.") with:

```markdown
It binds to `127.0.0.1` only, serves a live page (frontier / in-flight / merge
queue / blocked, plus the backlog, dependency graph, and the idea inbox), and
refreshes itself by polling. It is **read-only against all pipeline state** —
item files, `git worktree list`, `gh pr list`, and `.claude/sweap-board.md`
(annotation only). Its ONLY write is create-only idea capture: the Ideas form
writes *new* files under `<backlog.dir>ideas/` (triaged later by `/roadmap`).
It never edits or deletes anything and never touches items, the board, or the
pipeline, so it is safe to leave running during an autonomous coordinator run.
Stop it with Ctrl-C.
```

- [ ] **Step 2: Update `plugin/commands/roadmap.md`**

In step **1. Decide**, directly after the sentence about surfacing audit follow-ups (ends "…isn't authored blind to pending fixes on the same surface."), add:

```markdown
Likewise surface the **idea inbox** (`<backlog.dir>ideas/*.md`, if any) as
read-only context — ideas captured from the board awaiting triage. Fold the
relevant ones into the brainstorm; do not copy them into items verbatim.
```

In step **3. Reconcile**, after "write one item file per drafted item under `backlog.dir`," add:

```markdown
move every triaged idea file from `<backlog.dir>ideas/` to
`<backlog.dir>ideas/archive/` (provenance preserved, inbox drained — untriaged
ideas stay put),
```

- [ ] **Step 3: Update the playbook backlog-format section**

In `plugin/playbook/agentic-loop-playbook.md`, add a bullet directly after the `roadmap/archive/` bullet (~line 79):

```markdown
- **`roadmap/ideas/`** — the **idea inbox**: free-form idea files (frontmatter
  `title:` + `created:` only — no id, no status) captured from the sweap-board
  page's Ideas form. Invisible to lint, dep resolution, and the frontier (like
  `archive/`). `/roadmap`'s decide phase surfaces them as read-only context;
  reconcile moves triaged ones to `roadmap/ideas/archive/`.
```

- [ ] **Step 4: Verify nothing broke**

Run: `node --test plugin/tools/sweap-board.test.mjs` (docs shouldn't affect tests — belt and braces) and re-read the three edited files for coherence with their surrounding text.

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/board.md plugin/commands/roadmap.md plugin/playbook/agentic-loop-playbook.md
git commit -m "docs(plugin): idea inbox — board write contract, /roadmap triage, playbook ideas/ subdir"
```
