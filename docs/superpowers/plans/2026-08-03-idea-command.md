# /idea Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/idea` command to the sweap plugin: a short business-focused brainstorm that writes a properly formatted idea file into the `roadmap/ideas/` inbox via the board lib.

**Architecture:** One new command doc (`plugin/commands/idea.md`) following the existing command pattern; it instructs Claude to brainstorm briefly, then write the file through an inline node snippet importing `readConfig` + `writeIdea` from `sweap-board.lib.mjs` — same format, slug rules, collision suffixes, and create-only guarantee as the board's `POST /ideas`. Plus a one-line playbook update naming `/idea` as a second inbox source.

**Tech Stack:** Markdown command doc; node inline script (built-ins only). Spec: `docs/superpowers/specs/2026-08-03-idea-command-design.md`.

## Global Constraints

- No new dependencies; no changes to any `.mjs` file (the lib is consumed, not modified).
- Capture-scope only: the command must forbid specs/dependencies/milestone placement at capture time (that is `/roadmap`'s job) and must not commit anything.
- The write path is the lib snippet — the command must forbid hand-writing the idea file.
- The snippet below is verified working — transcribe it exactly.
- Commits: conventional style, direct on `main` (repo convention), trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `/idea` command doc + playbook line

**Files:**
- Create: `plugin/commands/idea.md`
- Modify: `plugin/playbook/agentic-loop-playbook.md` (the `roadmap/ideas/` bullet, ~line 94)

**Interfaces:**
- Consumes: `readConfig(projectDir) -> {backlogDir}` and `writeIdea(projectDir, backlogDir, {title, body, now}) -> {file}` from `plugin/tools/sweap-board.lib.mjs` (existing, tested).
- Produces: nothing downstream — leaf task.

- [ ] **Step 1: Create `plugin/commands/idea.md`**

Exact content:

````markdown
---
description: "Capture one idea into the roadmap/ideas/ inbox — short business brainstorm, then a formatted idea file (triaged later by /roadmap)."
argument-hint: "[rough idea text] — optional; you'll be asked if omitted"
---

Capture ONE idea into the project's idea inbox. This is **capture, not
design**: no specs, no dependencies, no milestone placement — all of that is
decided later by `/roadmap` at triage.

1. **Input.** Treat `$ARGUMENTS` as the raw idea. If empty, ask the human
   what the idea is.
2. **Brainstorm — short.** Socratic, ONE question at a time, 2–4 questions
   max: what problem does this solve, for whom, what's the value / why now.
   Stop as soon as the idea is articulable. Do not expand scope, propose
   solutions, or draft specs.
3. **Distill.** A short title (a few plain words) and a 3–6 line body: the
   problem, the value, and any of the human's phrasing worth keeping
   verbatim.
4. **Write the file** through the board lib — same format, slug rules,
   collision handling, and create-only guarantee as the board's Ideas form.
   Do NOT write the file by hand and do NOT edit existing idea files:

   ```bash
   node --input-type=module -e '
   const lib = await import("file://" + process.argv[3]);
   const { backlogDir } = lib.readConfig(process.cwd());
   const out = lib.writeIdea(process.cwd(), backlogDir, { title: process.argv[1], body: process.argv[2], now: Date.now() });
   console.log(out.file);
   ' "<title>" "<body>" "${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.lib.mjs"
   ```

5. **Confirm.** Report the created path (the snippet prints it) and that the
   idea will surface at the next `/roadmap` run.

Do NOT commit anything — idea files stay untracked until `/roadmap` triages
them into a milestone PR.
````

- [ ] **Step 2: Update the playbook bullet**

In `plugin/playbook/agentic-loop-playbook.md`, the `roadmap/ideas/` bullet currently reads:

```markdown
- **`roadmap/ideas/`** — the **idea inbox**: free-form idea files (frontmatter
  `title:` + `created:` only — no id, no status) captured from the sweap-board
  page's Ideas form. Invisible to lint, dep resolution, and the frontier (like
  `archive/`). `/roadmap`'s decide phase surfaces them as read-only context;
  reconcile moves triaged ones to `roadmap/ideas/archive/`.
```

Change only the second sentence-fragment so the sources are "the sweap-board page's Ideas form or the `/idea` command":

```markdown
- **`roadmap/ideas/`** — the **idea inbox**: free-form idea files (frontmatter
  `title:` + `created:` only — no id, no status) captured from the sweap-board
  page's Ideas form or the `/idea` command. Invisible to lint, dep resolution,
  and the frontier (like `archive/`). `/roadmap`'s decide phase surfaces them
  as read-only context; reconcile moves triaged ones to
  `roadmap/ideas/archive/`.
```

- [ ] **Step 3: Smoke-test the snippet exactly as the command doc ships it**

Run (substituting the plugin root path for `${CLAUDE_PLUGIN_ROOT}` since the command runs outside a plugin context here):

```bash
D=$(mktemp -d) && printf '## sweap config\n' > "$D/CLAUDE.md" && cd "$D" && \
node --input-type=module -e '
const lib = await import("file://" + process.argv[3]);
const { backlogDir } = lib.readConfig(process.cwd());
const out = lib.writeIdea(process.cwd(), backlogDir, { title: process.argv[1], body: process.argv[2], now: Date.now() });
console.log(out.file);
' "Smoke test idea" "Problem: X. Value: Y." "~/Documents/sweap/plugin/tools/sweap-board.lib.mjs" && \
cat "$D/roadmap/ideas/smoke-test-idea.md" && cd - && rm -rf "$D"
```

Expected: prints `roadmap/ideas/smoke-test-idea.md`, then the file with `---\ntitle: Smoke test idea\ncreated: <ISO>\n---\n\nProblem: X. Value: Y.`

- [ ] **Step 4: Belt-and-braces suite run**

Run: `node --test plugin/tools/sweap-board.test.mjs` (from `~/Documents/sweap`)
Expected: 33/33 pass (nothing touched, but confirm).

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/idea.md plugin/playbook/agentic-loop-playbook.md
git commit -m "feat(commands): /idea — manual inbox capture via short business brainstorm"
```
