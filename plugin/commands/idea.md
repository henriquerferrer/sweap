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

5. **Land it.** An idea that exists only in the working tree is not captured,
   it is exposed: `git clean`, a re-clone or a dead disk loses it, and no other
   machine can see it. So the inbox goes to `origin` like everything else.
   - **If nothing else is in flight**, flush it yourself: worktree, commit
     EVERY pending file under `<backlog.dir>ideas/` AND `<backlog.dir>discovered/`
     (not just the one you just wrote — one PR drains both inboxes, including
     anything the board's Ideas form or a stopped session left there), open
     `chore(backlog): capture <n> idea(s) / note(s)`, merge on green, run
     end-of-run hygiene. This PR is never backlog-advancing — `audit-gate.sh`
     classifies both inbox subdirs as non-item — so it lands even during audit
     debt, and it rides the roadmap-only CI lane, so it is cheap.
   - **If you are mid-feature**, do NOT interrupt that work with a second PR.
     Leave the file and say so plainly: the next gated PR this session opens
     carries it (the playbook's sweep rule, End-of-run hygiene).
6. **Confirm.** Report the created path (the snippet prints it), where it
   landed (PR number, or "riding on the next PR"), and that it surfaces at the
   next `/roadmap` run.

Never EDIT an existing idea file and never write one by hand — `writeIdea` is
create-only and owns the format. Committing one is not editing it.
