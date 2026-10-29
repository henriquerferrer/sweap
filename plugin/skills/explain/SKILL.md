---
name: explain
description: Build an explainer page for a question the human does not understand, and show visuals before asking. Only when the human is answering in this conversation; never in a subagent, a workflow stage, or a sweap:run implementer, reviewer or fixer. End every decision question you put to the human (a fork with options) with "Not sure what this is about? Answer explain (in Other, or just type it) and I'll build a page that shows it." Use this skill when they answer "explain" or ask what a question is about, and, without being asked, before putting a question whose options differ in something a product user would see: a screen, layout, email or wording on screen, a flow or sequence of steps, or a quantity (a duration, limit, cutoff, rate). Never offer, just show.
---

# Explain a decision

Every decision question put to the human ends with one line reminding them this
exists (see `/unblock` step 2). This skill is what happens when they take it up,
and what happens before a question whose options can be shown.

It exists because a question written for the agent that raised it is often
unreadable to the person who has to answer it: code terms, a race between two
requests, something that never happens. The human then takes the recommended
option because they cannot tell the options apart, and the record says "answered"
when nothing was decided. A page they can look at, at their own pace, at the level
of detail they choose, is the fix.

**Only when the human is answering in this conversation.** Never in a subagent,
a workflow stage, or a `sweap:run` implementer, reviewer or fixer: there is
nobody to look at the page, and the run must not stop for one.

## When to show, unasked

**The trigger, defined once here** (the commands point at it): you are about to
put a question to the human, and its options differ in something a person using
the product would see. Then, without asking first and without offering, put the
options on the page and put the question with the link:

- what they look at: a screen, a layout, a component, wording on screen, an
  email (side-by-side mockups);
- what happens in steps: a flow, a hand-off between people, a race, a state
  that changes (stepped frames, plus an animation when watching helps);
- a quantity that drives the outcome: a duration, a limit, a cutoff, a rate (a
  slider that recomputes what each person sees).

Everything else stays text, ending with the explain line: a pure judgment with
nothing to show ("do we offer refunds at all?"), and options no product user
would see a difference in — infrastructure, CI, dev tooling, cost, effort
estimates, a project with no end user. Describing something is not a trigger;
only a question being put is.

Keep it cheap and never block the question on tooling:

1. reuse what exists first: an earlier section, a screenshot already captured,
   the e2e helpers' captures;
2. start a dev server or Playwright only for a question about a screen, and
   only when the capture is quick;
3. otherwise draw it: a sketch or HTML mockup, marked as a mockup.

Never implement an option in the product to show it. The product's own
components may be used in a throwaway page outside shipped code, never
committed. If superpowers' brainstorming visual companion is already open in
this session, it is the page; do not build a second one.

## One live page per command run

One page per command run (`/roadmap`, `/unblock`, `/handoff`, `/idea`), at one
fixed file path in the scratchpad (for example `explain-<command>.html`): a new
path makes a new URL. Each new visual is a new section on top, earlier ones kept
below, added with the publish's `edits` rather than a rewrite. Screenshots and
videos go in as separate files or assets, never inline base64. An open artifact
tab picks up a republish on its own. Put the link in every question that has a
section, naming the section. After a compaction, reuse the same path and URL if
they are in the summary; otherwise start a new page and say so.

## The page

One section per question, built while it is fresh so they can ask about it. A
visual shown unasked needs only the parts that apply plus the "Still lost?"
drawer below; an "explain" section has these, in this order:

1. **The question in one plain sentence.** What is being decided, in the words
   of someone who uses the product. No identifiers.
2. **What a user experiences** — the default layer. What happens, told as a
   concrete story about one user named by role ("you, the owner", "a customer");
   for a failure, the failure. Show what each person sees on screen.
3. **The technical layer** — present on the page, collapsed or on a separate
   tab, never mixed into the user layer: the mechanism, the code paths with
   `file:line`, the library behaviour, the evidence (a test, a reproduction).
   The human chooses which layer to read; write both so either stands alone.
4. **The story, step by step** when the problem is a sequence (a race, a
   hand-off between actors, a state that changes): one frame per step, a lane
   per actor plus one for the system's stored state, the step that goes wrong
   marked. Stepped frames are the default for sequences: they can be compared
   and revisited.
5. **Each option as "what changes"**: which step or screen it changes, the
   outcome for each person, and the strongest case for and against it (the
   recommended one included), side by side or switchable. Every option at the
   same fidelity, so the drawing does not argue for one.
6. **The recommendation last**, with its reason.
7. **What this page cannot show**: assumptions about the product's real users
   that nobody has checked with one, and the limit that the page holds only what
   the agent knows.

**"Still lost?"** — every section, asked or unasked, ends with a closed
`<details>` drawer holding 0–4 ELI5 cards: one per term in the user layer that a
non-specialist would stop at (why a DNS lookup can answer `127.0.0.1`, what a
browser's same-site check compares). No such term, no drawer. Each card is at
most 80 words, is labelled general background rather than from this project,
and ends with where its analogy breaks. Build it with the body: a few short
cards cost seconds, and the question is never held for anything bigger. When
the section is a sequence, the drawer's last line is "Want to watch it play out?
Answer animate." — the animation is built only on that answer.

## The media, by what the question needs

Use whatever makes the question understandable, within the cheap-first order
above.

- **Real screens**: Playwright screenshots of today's behaviour from the dev
  server or the e2e helpers; captured emails (e.g. a local mail catcher) for
  anything sent. Mark drawn mockups of options that do not exist yet as mockups.
- **Interactive controls** when a quantity drives the outcome (a duration, a
  limit, a rate, a time zone): a slider or input that recomputes what the user
  sees.
- **A short recorded demo** (a Playwright video or trace) when the behaviour
  exists and watching it is clearer than frames.
- **Animated video** (HyperFrames or similar HTML-based video) for a flow over
  time the human wants to watch. Keep the stepped frames on the page as well:
  for comparing options, frames beat animation.
- **UI choices**: the options as side-by-side screens, in the product's own
  components where a throwaway page can use them.

## How to build and hand it over

- Publish it as a private Claude artifact when the Artifact tool is available;
  otherwise write a local HTML file and `open` it, and tell the human to reload
  the tab for each new section (a local file does not refresh itself).
- Every fact on the page comes from the item file, the code or a reproduction,
  in both layers: the technical layer cites it, and the user story points to the
  item line, test or reproduction it rests on. A scenario the agent assumed is
  marked as assumed. When the agent is unsure, the page says so. The one
  exception is the "Still lost?" cards, which are general background: there,
  each claim about the outside world (a CVE, a browser's or router's behaviour)
  carries a link or says "from memory, unverified".
- Then ask the question (again, after "explain"). Answer follow-ups first; do
  not re-ask until they are done reading. Use the same options, unless building
  the page showed one is misdescribed or the premise is moot: then say so,
  correct the options, and redo `/unblock` step 2's classification before
  asking. Never treat the page as the answer.
