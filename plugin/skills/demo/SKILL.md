---
name: demo
description: Film short videos of what a milestone or feature delivered in a web app, so the person who asked for it (a PM, a stakeholder, a domain expert) can watch it without running anything. Each video is a visible cursor clicking through one user flow, with chapter cards and dropdowns shown open. Use when the human runs /sweap:demo, or asks to "film / demo / make videos of / record a tour of" what a milestone (e.g. "F13") or feature shipped, or to re-film an existing tour. Only when the human is in this conversation; never in a subagent, a workflow stage, or a sweap:run implementer, reviewer or fixer.
argument-hint: "[milestone or feature]"
---

# demo: videos of what shipped

Showing someone what you built is part of the job. This skill produces one MP4 per user flow
(about 30–60 s and 1–2 MB). Each is filmed on the project's own e2e harness: a local app with
throwaway data. Each one is checked, then opened for the human to review before they send it
to anyone. The recorder is `sweap-film` (on PATH with the plugin). The on-camera helpers
`tour.ts` and the wrapper `tours.config.example.ts` sit next to this file.

## 1. Is it supported here?

Supported only when ALL of these hold. Otherwise say "demos aren't supported in this project
yet" and name what is missing:
- a Playwright e2e package whose **installed** `@playwright/test` is 1.61 or newer.
  `page.screencast` draws the chapters and overlays, and `sweap-film` checks the installed
  version, not the declared range;
- a way to bring the app up **locally with throwaway data**. Either the config's own
  `webServer` harness does it, or whatever the project's e2e recipe runs (`verify.e2e` in the
  sweap config) does. Never film against staging or production: `tour.ts` refuses any page
  that isn't local;
- `ffmpeg` on PATH.

Native mobile apps (simulators) are not supported yet.

## 2. What did it deliver?

Read the milestone's line in the roadmap, its item titles, and what merged. Sort the items:
- **on screen**: a person sees or does something new;
- **internal**: refactors, infrastructure, tests, plumbing.

Propose the on-screen ones as **user flows**, one per goal a person has ("reset a forgotten
password", "invite a teammate"), never one per item. Give each a line on what is new in it. If
nothing is on screen, say so and stop.

Ask which flows to film (AskUserQuestion, multi-select). A flow whose result is an email (a
reminder, a code) can be filmed: fetch the message off camera through the project's mail
catcher, then show it with `showEmail()`.

## 3. Set up `.tours/` once per project

Create `.tours/` inside the e2e package. It must sit where `@playwright/test` resolves from
`node_modules`. It is a dot folder, so typecheck globs and file walkers skip it.

Keep it out of git **locally**: append `/<path-from-repo-root>/.tours/` to the file that
`git rev-parse --git-path info/exclude` prints. That is correct in worktrees too. Never commit
the folder, and never edit `.gitignore` or any tracked file.

Then:
- copy `tour.ts` in from this skill's folder;
- write `.tours/tours.config.ts` (or `.mjs` for a JavaScript-only package), adapted from
  `tours.config.example.ts`. It covers both kinds of project: one whose config starts the app
  itself, and one where something else starts it. Never name it `playwright.config.*`;
- optionally, add `.tours/env` with KEY=VALUE lines. Use it to pin a separate e2e run id or
  database, or to set the URL variable the project's config demands.

## 4. Write one tour per flow: `.tours/<flow>.tour.ts`

- **Start from the project's existing e2e spec for that flow**, and reuse its fixtures. That is
  what makes a tour work on the first or second run instead of the fifth.
- **Off camera**, before `startTour`: create whatever the flow needs (accounts, records,
  settings) through the project's fixtures or API, quickly. Then go to the page the flow starts
  on, and wait until it is ready.
- **On camera**:
  - call `startTour(page, '<flow>')`;
  - add a `chapter()` card for the flow, and one per step;
  - then do only what a person does:
    - `click`, `type`;
    - `pick` for every native `<select>`, whose popup a recording never shows;
    - `typeDate` for every date input, in the input's locale order;
    - `showEmail`.
- **Navigate by clicking** the app's own links and buttons. Never `page.goto` after
  `startTour`: a jump between screens reads as magic.
- **Wait for content** before the next step, not just for the URL, so loading states don't
  fill the frame.
- Use realistic invented names and data.
- **End on the result**, then call `endTour(page)`.
- **Keep tours** between requests. Re-film an existing one, repair it when a selector breaks,
  and rewrite it only when the flow itself changed. Re-filming an old flow after a later
  milestone is how the viewer sees what changed.

## 5. Film, check, show

Run `sweap-film <e2e-package-dir> [filter]`. It uses one worker and refuses while another
Playwright run is going. For each tour it prints `FILMED <mp4> (<n>s) contact: <png>`.

**Read each contact sheet before showing anything.** Look for:
- jumps between screens;
- frames stuck on a skeleton or spinner;
- a step with no visible cursor movement;
- overlays covering the result.

Fix and re-film. Then `open` the MP4s for the human and ask for notes ("slower here", "show
the list after"), and iterate.

## 6. Hand over

Give the human the MP4 paths; they send them on. Never upload or publish a video anywhere
without asking. When the viewer's notes come back, file them through `/idea` in the viewer's
own words, naming them as the source.
