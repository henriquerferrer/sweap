# The unit of judgment: why a token-correct app still drifts

**Research memo — 2026-08-19.** Question: consumer A shipped a token gate (DS.1),
widened it app-wide (DS.2), and the app is still visibly inconsistent screen to
screen. Is that a consumer A execution failure, or a structural gap in sweap's UI
process? And if it is structural: what does the evidence say the fix is — a
better rule, a better judge, or a different unit of work?

Method: web research on 2026-08-19 across four lines — project-level design-to-code
benchmarks, the specification-gaming literature, LLM-judge criteria research, and
the VLM-as-judge reliability literature — plus a read of sweap's own
`ui-design` skill and `ui-critic` agent against consumer A's observed symptom list.

**Source discipline.** Every quoted string below was retrieved as raw HTML/PDF
and string-matched before being quoted, per the correction block in
`2026-08-16-planned-human-handoffs.md`. Sources marked **[verified]** were
fetched and grepped; unmarked claims are search-result summaries and are
weighted accordingly. One figure that appeared in an early draft of this
analysis — "32–34% exact agreement on a 5-point scale" for VLM judges — could
**not** be verified in the cited paper and has been struck; §5 uses that
paper's actual, verified finding instead, which is stronger anyway.

No substantive X/Twitter material was found on this specific problem. The
practitioner discourse that exists converges on "commit a design-system file
every prompt must obey" — which is precisely the control consumer A already had
when it drifted. This memo does not pad itself with it.

---

## 0. The one-sentence answer

Every gate sweap owns judges **one screen at a time**, so a set of screens that
each pass every gate can still be mutually inconsistent — the fix is not a
better rule or a better judge but a **second unit of judgment**, a committed
cross-screen contract enforced by checks that enumerate the route inventory
rather than the diff.

## 1. The incident, as evidence

Consumer A's DS.1 shipped the no-arbitrary-values lint; DS.2 retrofitted the app onto
tokens and primitives. Both landed. A human walkthrough of the running app then
produced this list (from the `revisit-and-standardize-the-screens` idea file):

- Settings cards do not share a width — Communications is visibly narrower than
  Message templates directly below it.
- The sidenav does not stick; it scrolls away with the page.
- The org switcher overflows its container and doubles its focus ring.
- Import patients uses a different page-header/shell treatment than Patients or
  Settings.
- Calendar's toolbar mixes control heights; "Agenda view" is a bare underlined
  grey text link standing in for a control.
- "New appointment" is a full-page route where an overlay/sheet is expected.
- Responsive behaviour has never been a milestone goal.

**Not one of these is a token violation.** Every one of them is a statement
about a *relationship between two screens* (or between a screen and an implied
app-wide rule). The token lint is not failing at its job; the defect is outside
its domain, and outside the domain of every other check sweap has.

The diagnosis in the idea file — *"the app is token-correct and still
inconsistent"* — is therefore exactly right, and it is a prediction of the
design rather than a surprise.

## 2. Why per-screen gates structurally cannot see it

Inventory of sweap's UI enforcement, by unit:

| Control | Unit it judges |
|---|---|
| no-arbitrary-values lint | one file |
| axe / keyboard / focus | one screen |
| empty / loading / error state check | one screen |
| Mobbin structural brief | one screen (net-new or redesign) |
| `ui-critic`, all five lenses | one screen, vs. an exemplar |
| Tier-2 UI audit (§7) | the same five lenses, run more times |

There is no artifact anywhere in sweap that states what *all* screens must
share, and therefore no check that could fail when two screens disagree. Even
the `design-system consistency` lens is scoped to token/primitive reuse — it
asks "did this screen reinvent a primitive?", never "is this screen composed
like the others?".

The external literature has arrived at the same gap independently and recently.
**MobileForge** ([arXiv 2607.28645](https://arxiv.org/abs/2607.28645))
**[verified]** was built because *"real mobile products require multiple
screenshots to become a buildable codebase with shared components and working
navigation"*, and existing design-to-code benchmarks *"focus on single-page
generation rather than complete codebases, cannot evaluate cross-page
navigation, and do not measure project-wide maintainability."* Its five axes are
build, navigation, visual fidelity, code maintainability, and efficiency.

Its headline result is the consumer A symptom list restated as a benchmark finding:
*"current models can build mobile-app projects that compile and reach the
correct pages, but interactive navigation remains unreliable and visual fidelity
and maintainability still lag."* Compile-and-route is the part per-screen
correctness gets you. Coherence is the part it does not.

## 3. The retrofit exemption: an escape hatch on the cheap side, self-classified

`ui-design` §2 requires a Mobbin structural brief for net-new and redesign work,
then exempts *"a purely behavior-preserving retrofit"* on the stated reasoning
that it *"inherits the already-proven existing composition."*

Two things went wrong, and only the second is interesting:

1. **The premise was false in DS.2.** The composition being inherited was
   scaffolded output, never approved by anything. The exemption inherited
   nothing.
2. **The trigger is agent-classified and the exempt path is the cheap path.**
   Whether a piece of work is "behavior-preserving retrofit" or "redesign" is
   decided by the same agent that saves the entire Mobbin + composition pass by
   answering "retrofit". Under that incentive the exemption is not an edge case;
   it is the default route, which is what DS.2 demonstrates at app scale.

The correct response is *not* a better-worded exemption.
**Recontextualization** ([arXiv 2512.19027](https://arxiv.org/abs/2512.19027))
**[verified]** opens on exactly this premise — *"Developers often struggle to
specify correct training labels and rewards. Perhaps they don't need to."* — and
its whole contribution is reducing specification gaming *"without improving the
supervision signal."* The transferable lesson at harness level is the shape, not
the training method: when a specification has an exploitable clause, close the
route rather than rewriting the clause. This is also the pipeline's own
established doctrine — every other shortcut in sweap is denied by a script, not
by a sentence.

Mechanically: a retrofit may claim the exemption only when the screen whose
composition it inherits has a recorded brief, or is the designated exemplar.
Otherwise it is a redesign. That is a checkable predicate, not a judgment call.

## 4. The rubric was frozen before contact with the output

`ui-critic`'s five lenses were fixed a priori. Re-read §1's symptom list against
them: mismatched control heights, a non-sticky sidenav, a raw `test@test.com`
leaking into a select, a text link standing in for a button, a route where a
sheet belongs, responsiveness. Almost none is expressible in the five lenses.

Shankar et al., *Who Validates the Validators?* (UIST 2024)
([PDF](https://people.eecs.berkeley.edu/~bjoern/papers/shankar-validators-uist2024.pdf))
**[verified]** names why this is not a drafting error but a category error:

> *"we identify a phenomenon we dub criteria drift: users need criteria to grade
> outputs, but grading outputs helps users define criteria."*

and, more pointedly:

> *"We dub this phenomenon criteria drift, implying that it is impossible to
> completely determine evaluation criteria prior to human judging of LLM
> outputs."*

The human walkthrough was not a process failure to be engineered away — it was
the only mechanism that could have produced these criteria, and the paper says
so. What sweap got wrong is downstream: the criteria it produced landed in a
free-form idea file rather than in the rubric, so nothing durable was learned.
Every finding from a human spot-check should convert **once** into an enumerated
assertion, after which no human ever re-checks it. The human's share of this
work must shrink monotonically; today it is constant.

## 5. Judge design: rank, do not score

sweap's existing choice of comparative/pairwise judging with ties allowed is
correct and should be kept — and the reason is now measured. *VLM Judges Can
Rank but Cannot Score* ([arXiv 2604.25235](https://arxiv.org/abs/2604.25235))
**[verified]** identifies

> *"a failure mode not captured by standard evaluation metrics,
> ranking-scoring decoupling, where judges achieve high ranking correlation
> while producing wide, uninformative intervals, correctly ordering responses
> but failing to assign reliable absolute scores."*

It also finds uncertainty to be *"strongly task-dependent"*, with intervals
covering *"~40% of the score range for aesthetics and natural images"* — i.e.
aesthetic judgment is at the *reliable* end of its range, but the reliability is
in the ordering, not the number.

This has one direct consequence for the new cross-screen lens: dispatch it over
a **set** of screenshots and ask it to *rank deviants against the majority and
the exemplar*, never to score screens individually. Ranking our own screens
against each other is the cheapest reliable thing a VLM judge can do, and it is
precisely the operation that can see "Import doesn't look like Patients".

Note also MobileForge's independent arrival at the same instinct: it proposes an
*"anchor-referenced list-wise visual evaluation protocol to improve visual-judge
reliability"* **[verified]** — anchored, list-wise, comparative.

## 6. What changes in sweap

1. **The surface contract — a second unit of judgment.** A committed project
   artifact declaring what every screen shares: page shell, container/card width
   system, control-height scale, sticky regions, the overlay-vs-route rule,
   breakpoints, state coverage. Decided in the direction loop, not by an
   implementer mid-item.

2. **Enumerate the inventory, not the diff.** This is the load-bearing
   sentence of the whole memo. A lint inspects changed files, so it only ever
   sees the screens someone happened to touch; a table-driven test that reads
   the route manifest and asserts *every* route mounts the shared shell fails the
   moment a non-compliant route is added. Nobody has to remember the convention
   and no reviewer has to notice it. Every deterministic clause of the contract
   is written this way or it does not hold.

3. **Push composition into token shape where possible.** Control heights, page
   width, card grid column as named tokens means the existing no-arbitrary-values
   lint already covers them, at near-zero marginal cost.

4. **Close the retrofit exemption** with the evidence predicate from §3.

5. **A cross-screen critic lens**, dispatched over a set, ranking deviants (§5).

6. **Version the contract; track unpassed screens as debt.** A new route or a
   contract revision produces *visible* debt — the same baseline/debt shape
   `audit-gate.sh` already implements and the pipeline already trusts. Without
   this, the exemplar silently ages out and the next milestone drifts again.

7. **Wire the human's findings back as contract clauses**, per §4 — the
   spot-check is authored as an `attended` hand-off during `/roadmap`'s decide
   phase, and its output is clauses and tests, not prose.

**How this constrains milestone cutting.** The natural cut — one item per screen
— is the same per-screen unit that produced the drift, and re-applying it yields
N individually-plausible screens that still disagree. The correct unit is **one
item per invariant, applied across the whole inventory**: shell, width system,
control conventions, navigation model, sticky frame, responsive pass. Each
touches many files but moves one axis, so its acceptance criterion is a
cross-screen assertion rather than a screenshot. Per-screen polish comes last,
for the genuine residue. "Mobile friendly" and "high end" are dimensions, never
screens.

## 7. Where the mechanism actually lives — the honest layering

This memo argues mechanism over doctrine, and most of what it changes in this
repo is doctrine (skill text). That tension is real and worth stating plainly.

The contract itself cannot live in the plugin: sweap does not know the consuming
project's routes, shell, or breakpoints. What the plugin *can* do mechanically is
require that the mechanism exist in the consumer repo — the structural gate is
part of the `ui` dimension's hard gate, so a UI-heavy milestone that ships
without one is a gate failure the reviewer and the audit both check for, not a
style note. The doctrine's job is to make the mechanism mandatory; the mechanism's
job is to make the convention automatic. Conflating the two layers is how this
class of control gets weakened into advice.

## 8. Residual risks

1. **Over-constraint.** A contract that is too tight makes legitimately unusual
   screens (a full-bleed calendar grid, a sign-in page) fail a gate they should
   not. Mitigation: the contract carries explicit, named exceptions — an
   exception list is fine, an agent-judged exemption is not (§3).
2. **Contract rot.** Version 1 gets written once and never revised, so debt
   accumulates against a stale standard. The versioning in §6.6 makes this
   visible, but nothing forces a revision.
3. **The cross-screen lens is still advisory.** Aesthetic ranking cannot be a
   merge gate for the same reason the existing rubric is not one. It ratchets;
   the structural checks are what actually block.
4. **Sample size of one.** This memo generalizes from a single incident in a
   single consumer repo. The mechanism it proposes is cheap and reversible, which
   is the argument for shipping it before more evidence, not a claim that more
   evidence exists.

## 9. Evidence strength, bluntly

| Claim | Strength |
|---|---|
| consumer A's own symptom list vs. sweap's per-screen control inventory | **Strongest thing here** — direct, first-hand, reproducible |
| Project-level generation fails on cross-page coherence while compiling fine | **Strong** — MobileForge abstract, fetched raw and verified |
| Criteria cannot be fully specified before observing outputs | **Strong** — UIST 2024, PDF fetched, quotes string-matched |
| VLM judges rank reliably but score unreliably | **Strong** — abstract verified; the earlier 32–34% figure is struck as unverifiable |
| Closing the route beats rewriting the clause | **Moderate as applied** — the paper is a training-time method; the harness-level transfer is an argument by shape, not a measured result |
| Inventory-enumerating checks hold conventions better than diff-scoped lints | **Argument, not evidence** — mechanically obvious, untested here |
| One item per invariant beats one item per screen | **Argument** — follows from the diagnosis; no A/B |
