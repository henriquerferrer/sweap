# /idea command — design

**Date:** 2026-08-03
**Status:** approved

## Goal

A manual companion to the board's Ideas form: `/idea [rough idea text]` runs a
short business-focused brainstorm, then writes a properly formatted idea file
into the `roadmap/ideas/` inbox — same format, same slug rules, same
create-only guarantee as the board's `POST /ideas`.

## Command

New file `plugin/commands/idea.md`, following the existing command-doc pattern
(frontmatter `description` + `argument-hint`, body instructions).

Flow the command prescribes:

1. **Input.** Treat `$ARGUMENTS` as the raw idea; if empty, ask for it.
2. **Brainstorm — short.** Socratic, ONE question at a time, 2–4 questions
   max: what problem, for whom, what value / why now. Stop as soon as the
   idea is articulable. Explicitly capture-scope only: no specs, no
   dependencies, no milestone placement — that is `/roadmap`'s job at triage.
3. **Distill.** A short title (a few words) plus a 3–6 line body: the
   problem, the value, and any of the human's notes worth keeping verbatim.
4. **Write** via the lib (below), then confirm the created path to the human.

## File writing — reuse the lib

The command writes through an inline node snippet that imports `readConfig`
and `writeIdea` from `${CLAUDE_PLUGIN_ROOT}/tools/sweap-board.lib.mjs`
(file:// URL import, `--input-type=module`), resolving `backlogDir` from the
project's `CLAUDE.md` and passing `{title, body, now: Date.now()}`. This
gives `/idea` byte-identical file format, slug alphabet, collision suffixes,
and the create-only `wx` write the board has — one writer implementation, two
entry points.

Rejected: hand-writing the file per a format description in the command doc
(drifts when the format evolves); a dedicated CLI tool (YAGNI).

## Git behavior

No commit. Like board-captured ideas, the file sits untracked until
`/roadmap` triages it (archived ideas land in the milestone PR).

## Doc touch

The playbook's `roadmap/ideas/` bullet gains the `/idea` command as a second
source, next to the board's Ideas form.

## Testing

The snippet reuses lib functions already covered by
`plugin/tools/sweap-board.test.mjs`. The implementation plan includes a
manual smoke step: run the snippet against a temp project, confirm the file
lands in `roadmap/ideas/` and `loadIdeas` returns it.

## Out of scope

Editing or archiving ideas from `/idea`; any change to the board server,
page, or lib; milestone/dependency assignment at capture time.
