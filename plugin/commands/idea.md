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
