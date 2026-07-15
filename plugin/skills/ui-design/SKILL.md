---
name: ui-design
description: Use when building, editing, or reviewing any product-visible UI (routes, components, screens, forms, tables, dashboards). Orchestrates the project's UI process — the project's declared design system (tokens + primitives), a preferred Mobbin archetype seed, a bounded render→critique→fix loop, the a11y + token-reuse hard gate, and the per-milestone UI audit. Composes frontend-design and ui-ux-pro-max for aesthetic craft; do not duplicate them.
---

# UI design process

## Prerequisites (optional)

The `ui` review-dimension composes the `frontend-design` and `ui-ux-pro-max`
skills for aesthetic craft, and the Mobbin MCP (`mcp__mobbin__*` tools) for
archetype seeding and comparative reference, when those are available in the
consuming project/session. None of them are shipped or required by this
plugin. If they are absent, this skill **degrades gracefully**: the a11y and
interaction-state HARD gates (§5) still run in full — only the comparative
aesthetic ratchet (§4/§7's ensemble critique against references) is reduced to
whatever internal exemplar comparison remains possible.

The repeatable process for producing high-quality UI. It exists because,
undirected, coding agents converge on a generic "AI-slop" aesthetic and invent
one-off values that make screens drift. This skill is the *process*; it
**composes** the `frontend-design` and `ui-ux-pro-max` skills for generic
aesthetic *craft* — load those for typography/color/motion technique, and do not
restate their content here.

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

## 2. Mobbin archetype seed — REQUIRED when available

**Mobbin is REQUIRED whenever it is available.** For any net-new screen OR a
redesign/composition pass, you MUST query Mobbin for the screen's archetype and
extract a structural brief (information architecture, layout, what-appears-where,
controls, state coverage) BEFORE building. The ONLY permitted skip is when Mobbin
is genuinely unavailable/unauthed (e.g. a fresh cloud/headless run) — and then you
MUST record `Mobbin unavailable: <reason>` in the UI report/PR. Silence is not
acceptable. A purely **behavior-preserving retrofit** (re-skinning existing markup
onto tokens/primitives without changing composition) is exempt — it inherits the
already-proven existing composition. Every UI PR for net-new/redesign work states
either the Mobbin archetype(s) + reference apps consulted (with mobbin.com links),
or the unavailable-note.

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
| Empty/loading/error | state sections | Mobbin `search_sections` for those states |

Mobbin's `search_flows` / `search_screens` / `search_sections` map onto this.
The only permitted skip remains the unavailable/unauthed case above — record the
`Mobbin unavailable: <reason>` note and continue.

## 3. Tier-1 build loop (every UI item, bounded ~2–3 cycles)

1. Build the screen on tokens + primitives, informed by the structural brief.
2. **Render the real running screen** and screenshot it (claude-in-chrome or the
   Playwright/webapp-testing tools) — visual grounding is mandatory; never
   self-critique from the code alone.
3. Critique the screenshot against the multi-dimensional rubric (§4).
4. Fix and re-render. Stop after ~2–3 cycles (diminishing returns) or when the
   rubric dimensions are clean.

## 4. Multi-dimensional rubric

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
- **Accessibility** — labels, roles, contrast, focus management.

## 5. Deterministic hard gate (blocks the PR)

These are objective and DO block:

- axe accessibility scan clean.
- Keyboard/focus reachability + required empty/loading/error states present.
- The "no arbitrary values" lint (no raw hex / arbitrary utility values in
  components) — **this check activates once the project's design system has
  shipped** (it lints against the declared tokens/primitives). Before the design
  system exists, there is nothing to enforce reuse against, so this specific
  check does not apply and UI work already in flight is not retroactively
  blocked; the a11y and interaction checks above still apply.

Anything the exploratory Tier-1 loop finds that should stay fixed becomes a new
deterministic Playwright/axe test.

## 6. Enforcement split

- **Gate (blocks):** the deterministic checks in §5.
- **Ratchet (advisory, mandatory to RUN):** the §4 aesthetic/rubric verdict.
  Findings are address-or-justify → roadmap follow-up, never an auto-block (the
  VLM judge is only ~69.5% human-aligned and can mode-collapse).
- **Mobbin brief presence (mandatory):** the Mobbin brief (or the `Mobbin
  unavailable:` note per §2) must appear in every net-new/redesign UI PR; the
  reviewer checks for its presence.

## 7. Tier-2 UI audit (per UI-heavy milestone boundary)

Runs once at a UI-heavy milestone boundary, alongside the code `milestone-audit`
— see the playbook's "Review dimensions" and "Milestone audit" sections. Structure:

- **Independent, anonymized critics** — one per rubric lens — run independently
  with no cross-talk. This is an ensemble, NOT a debate: do not have critics try
  to persuade each other (consensus-seeking debate degrades accuracy).
- **Comparative/pairwise judging** (ties allowed): structural lenses judge the
  built screen *against* references — the project's committed **internal exemplar
  first**, Mobbin references second when available. The distinctiveness lens
  judges against the project's own aesthetic, not the reference.
- **Independent refutation, majority-survives** — each finding faces an
  independent skeptic; only majority-surviving findings are confirmed.
- **Triage → auto-fold:** confirmed findings sort into the three buckets and
  become `FX.*` items that auto-fold into the next `/milestone` run. Aesthetic
  findings = ratchet/roadmap; a11y findings carry gate weight.

## 8. Human spot-check

Automated judges are a ratchet, not ground truth — visual excellence is still
human-judged. The human remains the final spot-check on visual polish; flag
notable aesthetic calls for them rather than assuming the VLM verdict is final.
