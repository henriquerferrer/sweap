---
name: ui-design
description: Use when building, editing, or reviewing any product-visible UI (routes, components, screens, forms, tables, dashboards). Orchestrates the project's UI process — the project's declared design system (tokens + primitives), the surface contract of cross-screen invariants, a preferred Mobbin archetype seed, a bounded render→critique→fix loop, the a11y + token-reuse + structural hard gates, and the per-milestone UI audit.
---

# UI design process

## Prerequisites (optional)

The `ui` review-dimension uses the Mobbin MCP (`mcp__mobbin__*` tools) for
archetype seeding and comparative reference, when it is available in the
consuming project/session. It is not shipped or required by this plugin. If
it is absent, this skill **degrades gracefully**: the a11y,
structural and interaction-state HARD gates (§6) still run in full — only the
comparative aesthetic ratchet (§5/§8's ensemble critique against references) is
reduced to whatever internal exemplar comparison remains possible.

The repeatable process for producing high-quality UI. It exists because,
undirected, coding agents converge on a generic "AI-slop" aesthetic and invent
one-off values that make screens drift. This skill is the *process*; the
aesthetic itself is the project's own, stated in its surface contract (§2).

## 1. The design system is the source of truth

If the project declares a design system (tokens + primitives), product-visible
UI is built from it, never ad hoc:

- **Tokens** — the project's committed named color/spacing/radius/type tokens
  (e.g. a Tailwind v4 `@theme` block, CSS custom properties, or an equivalent
  theme file). Reference tokens by name (`bg-primary`, `text-surface`); never
  invent raw values.
- **Primitives** — the project's committed UI component library (e.g. shadcn/ui
  components in a `components/ui/` directory). Compose these; do not hand-roll
  buttons, inputs, dialogs, tables, or state components.
- **Never invent values.** No raw hex, no arbitrary utility values
  (`bg-[#3b82f6]`, `p-[13px]`). The "no arbitrary values" lint enforces this and
  is a HARD gate — but only once the project's design system exists (see below).

If the project has not declared a design system yet (no primitive components, no
token theme), establishing a **design-system foundation** is the priority to
build first, and the token-reuse gate only activates once it lands. Work already
in flight is not blocked: build with the loop + a11y below, keep values
consistent and easy to migrate, and adopt tokens/primitives once the design
system ships. Do not treat a not-yet-existing design system as a reason to stop.

**In that state, the aesthetic direction is a human taste call.** There are no
tokens yet, so "personality comes from the project's tokens" (§3) has nothing to
point at — choosing it *is* the work, and it is the paradigm case of a decision
that is not an agent's to make. Author it during `/roadmap`'s decide phase as its
own `status: attended` item with a `handoff:`, like any other taste call; the
existing lint already fails an attended item with no hand-off. Its *Done when* is
token-shaped, never "a session happened": the theme and primitives are committed
(which mechanically activates the no-arbitrary-values gate above) **plus** the
contract's committed-aesthetic line is filled in (§2). No method is prescribed —
gather references or not, as you like. Two constraints: this fires on the state
(no token theme, no primitives), not on a "once per project" count, so a rebrand
is a contract revision under §2's versioning rules rather than a re-run; and
"the human picked this" is never citable as evidence in a UI PR or readable by
`ui-critic`. The citable artifacts are the token file and the contract line.

## 2. The surface contract — what every screen shares

Tokens and primitives make a screen *correct*. They do not make two screens
*match*, and nothing else in this skill used to check that either: every gate
below judges one screen at a time, so a set of screens that each pass every gate
can still be visibly inconsistent with each other. That is not a hypothetical —
it is what a token-gate-only project produces, screen by screen
(`docs/research/2026-08-19-cross-screen-consistency.md`).

The **surface contract** is the project's committed statement of the invariants
that hold across *all* product-visible screens. Typical clauses:

- the shared page shell (header, title, actions slot) every route mounts;
- the container/card width system and grid;
- the control-height scale, and which control types are permitted (a text link
  is not a button);
- sticky regions — app frame, sidenav, toolbars;
- the **navigation model**: which interactions open an overlay/sheet and which
  navigate to a route;
- responsive breakpoints and the expected behaviour at each;
- required state coverage across screens (empty / loading / error);
- the **UI archetype label** for each feature area the milestone touches, taken
  from §3's table — a word, not a reference app and not an image, so that every
  build-time brief queries the archetype the contract assumed instead of
  re-deciding it per screen. The label must name a **structure**
  (`split-view master-detail`, `modal detail`, `tree table`), never a feature
  (`record registry`): the label is literally what gets typed into the Mobbin
  query, and a feature-shaped label re-derives the same near-duplicate cluster
  every time, while a structural one is a claim that can be argued with;
- the project's **designated internal exemplar** — the existing route(s) the
  project commits to as its own aesthetic reference point, named explicitly;
- the project's **committed aesthetic, stated in words** — one line, e.g. "dense
  professional tool, warm neutrals, grotesque display face". §5's distinctiveness
  lens and the `ui-critic` agent both judge "against the project's own committed
  aesthetic"; this clause is what they read. Unwritten, that check compares an
  agent-invented palette against an agent-invented baseline and passes forever.
  `no committed aesthetic yet` is the honest default, exactly as for the exemplar.

The exemplar clause is load-bearing and currently the most commonly missing one.
§3's retrofit exemption, §8's ratchet and the `ui-critic` agent all compare
"against the project's committed internal exemplar" *first*; if nothing names it,
that comparison degrades to the generic taste this whole skill exists to avoid.
Name it even when the answer is unflattering — `no exemplar yet` is a legitimate
value, and it tells the critic to say so rather than invent a baseline.

**`no exemplar yet` is a value that must be closed, not carried.** When the
contract says it, the UI-heavy milestone authors one **exemplar-establishing
item**, sequenced ahead of the invariant items: a single real route, built
through §4's loop against §6's gates, whose *Done when* is that the contract's
exemplar clause names that route by path. This is the same admitted exception as
the "one item builds the mechanism" item — it is the screen every later screen
gets judged against, so it is worth the human looking at it on real data at real
breakpoints. A mock is not a substitute: the defects this subsystem exists to
catch are relationships between two screens and things only real content and real
scroll produce, and an authored artifact cannot surprise you.

The contract lives at a declared path so "point at the record" resolves to a
file: `ui.contract` in the project's `## sweap config` block, defaulting to
`docs/ui/surface-contract.md`.

Three rules govern it:

- **It is decided in the direction loop, never by an implementer mid-item.** The
  contract is authored with the human during `/roadmap`'s decide phase, before
  any screen work in the milestone. A contract settled item-by-item is not a
  contract — whichever item merges first becomes the de facto standard.
- **Every deterministic clause is enforced by a check that ENUMERATES THE ROUTE
  INVENTORY, not the diff.** This is the property that makes the convention
  hold. A lint inspects changed files, so it only ever sees screens someone
  happened to touch; a table-driven test that reads the route manifest and
  asserts *every* route satisfies the clause fails the moment a non-compliant
  route is added — no one has to remember the rule, and no reviewer has to
  notice. A diff-scoped check is not an acceptable implementation of a contract
  clause.
- **Push clauses into token shape wherever they fit.** Control heights, page
  width and card grid expressed as named tokens are already covered by §1's
  no-arbitrary-values lint at no extra cost. Reach for a new structural test
  only for what tokens genuinely cannot express (shell mounting, nav model,
  sticky behaviour, viewport behaviour).

**Sourcing clauses from design-system documentation (optional, big milestones).**
Published design systems (Material, Fluent, HIG, Polaris, Carbon) state
*conditional rules* — "use a primary-detail layout when viewing details from an
item in a large list on the same page"; "below the mobile breakpoint show one
component at a time with clear back navigation". A rule is invariant-shaped,
which is the unit this section needs and the unit a screenshot can never supply:
from references you infer a rule by counting pixels across n=3, and inference is
where drift enters. So for a large UI milestone, a documentation pass at
contract-authoring time — here, with the human, once — is worth its cost. Three
constraints keep it from becoming another prose artifact:

- **Its only output is numbered contract clauses.** A pass that yields no clause
  yielded nothing; do not write up a summary. A clause reaching the contract
  without its enumerating check is already a failure of the rule above.
- **Every clause traces to a quoted string from a named system's own docs**, with
  the URL. Search-result summaries cite nothing and are the hallucination
  surface — fetch the page.
- **Check the archetype before trusting the material.** Design systems document
  *components*, not product archetypes, and this failure is silent: a "calendar"
  query returns date-picker anatomy, confidently, and you write clauses about
  selectable-date ranges for a screen that is a week grid. If the source
  documents a component that merely shares a noun with your archetype, it is the
  wrong source.

This belongs here and never in §3. §3 is the per-screen build-time brief; a
research pass there means every worker burns one per screen, in its own context,
producing one more presence-checked artifact instead of a checked clause.

**Exceptions are named, never judged.** A screen that legitimately departs from
the contract (a full-bleed calendar grid, a sign-in page) is listed as an
explicit exception in the contract itself. An agent deciding at build time that
its screen is special is not an exception — it is drift.

**Versioning and debt.** The contract carries a version, and the project records
which screens have passed under it. A new route, or a contract revision,
therefore produces *visible* debt rather than silent staleness — the same shape
`audit-gate.sh` already uses for audit debt. Screens carrying contract debt are
the Tier-2 audit's scope (§8).

## 3. Mobbin archetype seed — REQUIRED when available

**Mobbin is REQUIRED whenever it is available.** For any net-new screen OR a
redesign/composition pass, you MUST query Mobbin for the screen's archetype and
extract a structural brief (information architecture, layout, what-appears-where,
controls, state coverage) BEFORE building. The ONLY permitted skip is when Mobbin
is genuinely unavailable/unauthed (e.g. a fresh cloud/headless run) — and then you
MUST record `Mobbin unavailable: <reason>` in the UI report/PR. Silence is not
acceptable. Every UI PR for net-new/redesign work states either the Mobbin
archetype(s) + reference apps consulted (with mobbin.com links), or the
unavailable-note.

**The retrofit exemption is evidence-gated.** A purely behavior-preserving
retrofit (re-skinning existing markup onto tokens/primitives without changing
composition) may skip the brief **only when the composition it inherits was
itself ever approved** — i.e. that screen has a recorded Mobbin brief, or it is
the project's designated internal exemplar. Point at that record in the PR.
Retrofitting onto scaffolded composition inherits nothing, so it is a redesign
and needs a brief like any other. This predicate is deliberately checkable
rather than self-classified: the exempt path is the cheap path, and an
exemption an agent grants itself becomes the default route, not the edge case
(see `docs/research/2026-08-19-cross-screen-consistency.md` §3).

Query Mobbin by **UI archetype**, not by domain ("the app's industry"). Map the
feature to the best-in-class example of that archetype anywhere, and extract a
*structural brief* — layout skeleton, information hierarchy, interaction model,
and state coverage (empty/loading/error) — **not** surface aesthetic (font/color/
personality come from the project's tokens).

| feature area | UI archetype | reference targets |
|---|---|---|
| Scheduling / calendar | schedulable time-grid + booking flow | Cal.com, Calendly, booking apps |
| Billing / invoices | invoice/receipt + line-item detail | Stripe, QuickBooks, Wave, Ramp |
| Record / entity registry | filterable data-table + detail panel | Linear, Attio, Notion databases |
| Ops dashboard | metric tiles + utilization viz | Vercel/Stripe dashboards, analytics tools |
| Empty/loading/error | in-app states along a journey | Mobbin `search_flows`, query phrased as a journey |

`search_screens` (always `mode: "deep"`) retrieves one screen; `search_flows`
retrieves a 7–9 screen SEQUENCE, which is why state coverage comes from flows —
the empty, filtered and terminal frames only exist inside a journey. Phrase it as
one ("finding a record in a large list by filtering and then opening its
details"), not as a screen. **`search_sections` is a marketing-website index**
(About / Pricing / Footer — its results carry `site_name`, and it takes no
`platform`); it is for landing surfaces only, never for in-app states.
The only permitted skip remains the unavailable/unauthed case above — record the
`Mobbin unavailable: <reason>` note and continue.

**Query once per structural hypothesis; diversity is author-supplied.** Mobbin
scores candidates by similarity to the structure you described, so ONE query
returns one structure wearing several brand skins — that is the retriever working
correctly, not a defect. To see genuinely different structures you must already
hold the competing hypotheses and spend one query on each ("clicking a record
opens a centered modal over a dimmed background" / "a row expands inline to
reveal nested child rows" / "records as a kanban board of draggable cards"), then
record in the brief which structures you queried and rejected. Three levers that
look like diversity controls and are not: **negations are ignored** (describe
what you want positively — "no split pane" returns split panes), and
`exclude_screen_ids` de-dupes IDs rather than structures, so it walks sideways
within the same apps; `mode: "standard"` is noisier, not broader.

**Where the surface contract records an archetype label for the feature area
(§2), the query uses that label.** A brief that departs from it says why in the
UI PR. This keeps the archetype a decision made once with the human rather than
re-derived per screen — but the per-screen brief and its `mobbin.com` links
remain the evidence, and the retrofit exemption's per-screen predicate above is
unchanged: a contract label is not a recorded brief for any screen.

## 4. Tier-1 build loop (every UI item, bounded ~2–3 cycles)

1. Build the screen on tokens + primitives and the surface contract, informed by
   the structural brief.
2. **Render the real running screen** and screenshot it (claude-in-chrome or the
   Playwright/webapp-testing tools) — visual grounding is mandatory; never
   self-critique from the code alone.
3. Critique the screenshot against the multi-dimensional rubric (§5).
4. Fix and re-render. Stop after ~2–3 cycles (diminishing returns) or when the
   rubric dimensions are clean.

## 5. Multi-dimensional rubric

Score each dimension separately — do not collapse to a single number (single
scores align poorly with human judgment):

- **Visual distinctiveness** — distinct from the generic AI center (not Inter,
  not purple-on-white); judged against the project's committed aesthetic, NOT
  similarity to any reference.
- **Hierarchy & density** — appropriate for the product's use context (e.g. a
  professional daily-use tool).
- **Interaction & state coverage** — empty, loading, error states present;
  keyboard and focus order correct.
- **Design-system consistency** — tokens + primitives reused, no drift.
- **Cross-screen consistency** — does this screen compose like the others?
  Judged over a **set** of screens, never one alone (§8), and reported as a
  ranking of deviants rather than a per-screen score: VLM judges order reliably
  but do not assign reliable absolute scores
  ([arXiv 2604.25235](https://arxiv.org/abs/2604.25235)).
- **Accessibility** — labels, roles, contrast, focus management.

## 6. Deterministic hard gate (blocks the PR)

These are objective and DO block:

- axe accessibility scan clean.
- Keyboard/focus reachability + required empty/loading/error states present.
- The "no arbitrary values" lint (no raw hex / arbitrary utility values in
  components) — **this check activates once the project's design system has
  shipped** (it lints against the declared tokens/primitives). Before the design
  system exists, there is nothing to enforce reuse against, so this specific
  check does not apply and UI work already in flight is not retroactively
  blocked; the a11y and interaction checks above still apply.
- **The structural contract checks (§2)** — the inventory-enumerating assertions
  for the contract's deterministic clauses, plus the per-route viewport pass
  (no horizontal scroll and a clean axe run at the project's smallest declared
  breakpoint). These activate once the surface contract has shipped, on the same
  terms as the token lint. A UI-heavy milestone that ships screens without
  installing the contract's checks is a **gate failure**, not a style note: the
  plugin cannot hold cross-screen conventions on the consuming project's behalf,
  so requiring the mechanism to exist is the only leverage it has.

Anything the exploratory Tier-1 loop finds that should stay fixed becomes a new
deterministic Playwright/axe test.

## 7. Enforcement split

- **Gate (blocks):** the deterministic checks in §6.
- **Ratchet (advisory, mandatory to RUN):** the §5 aesthetic/rubric verdict.
  Findings are address-or-justify → roadmap follow-up, never an auto-block (the
  VLM judge is only ~69.5% human-aligned and can mode-collapse).
- **Mobbin brief presence (mandatory):** the Mobbin brief, the recorded
  exemption evidence, or the `Mobbin unavailable:` note per §3 must appear in
  every net-new/redesign UI PR; the reviewer checks for its presence.

## 8. Tier-2 UI audit (per UI-heavy milestone boundary)

Runs once at a UI-heavy milestone boundary, alongside the code `milestone-audit`
— see the playbook's "Review dimensions" and "Milestone audit" sections. Structure:

- **Scoped to the inventory, not the milestone's diff.** The audit's subject is
  every product-visible route carrying contract debt (§2) — screens never passed
  under the current contract version, not merely the screens this milestone
  touched. Auditing only the diff is what lets an untouched screen drift
  indefinitely.
- **Independent, anonymized critics** — one per rubric lens — run independently
  with no cross-talk. This is an ensemble, NOT a debate: do not have critics try
  to persuade each other (consensus-seeking debate degrades accuracy).
- **Comparative/pairwise judging** (ties allowed): structural lenses judge the
  built screen *against* references — the project's committed **internal exemplar
  first**, Mobbin references second when available. The distinctiveness lens
  judges against the project's own aesthetic, not the reference.
- **The cross-screen lens is dispatched over a set**, receiving many of the
  project's own screens at once and ranking which deviate from the majority and
  the exemplar. Never ask it for per-screen scores.
- **Independent refutation, majority-survives** — each finding faces an
  independent skeptic; only majority-surviving findings are confirmed.
- **Triage → auto-fold:** confirmed findings sort into the three buckets and
  become `FX.*` items that auto-fold into the next `/milestone` run. Aesthetic
  findings = ratchet/roadmap; a11y findings carry gate weight.

## 9. Human spot-check

Automated judges are a ratchet, not ground truth — visual excellence is still
human-judged. The human remains the final spot-check on visual polish; flag
notable aesthetic calls for them rather than assuming the VLM verdict is final.

**Author it as work, not as a hope.** A UI-heavy milestone's spot-check is a
taste call, so it is authored during `/roadmap`'s decide phase as its own
`status: attended` item with a `handoff:` task (the playbook's "Attended
items"), dependency-free so it runs concurrently with the agents' drain. A
spot-check nobody scheduled is the failure mode `attended` exists to prevent.

**Its output is contract clauses and tests, not prose.** Criteria cannot be
fully specified before someone looks at real output — this is a measured
phenomenon, not a drafting failure ([Shankar et al., UIST
2024](https://people.eecs.berkeley.edu/~bjoern/papers/shankar-validators-uist2024.pdf)),
so the walkthrough is the only thing that can produce some of these criteria.
Each finding converts **once** into a contract clause plus its
inventory-enumerating check, after which no human re-checks it. Findings left as
prose in an idea file teach the pipeline nothing and will be rediscovered by
hand next milestone.
