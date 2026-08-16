# The blocked queue is a queue, and nothing drains it

**Research memo — 2026-08-16.** Question: should `/roadmap` open by working the
blocked queue — surfacing unanswered `[blocked]` items, offering to answer or
brainstorm them, and only then brainstorming the next milestone? And second: how
much of that work can the agent legitimately do *for* the human before asking?

Method: local evidence from `consumer-a` (the pipeline's only real consumer), then
web research on 2026-08-16 across four lines — mixed-initiative HCI, the
2025–2026 clarifying-question literature, agent-framework HITL primitives, and
the closed-loop-communication literature from patient safety, which is the only
field that has studied *pending questions that nobody answers* at scale.

**Sourcing discipline.** Following the correction notice on
`2026-08-16-planned-human-handoffs.md`: sources marked **[verified]** were
fetched and read firsthand (PDFs read page-by-page, not via summarising fetch),
and only those are quoted. Everything else is a search-result summary, is
labelled as such, and carries no quotes. Two lines of enquiry — Karpathy's
autonomy slider, and the RAID-log convention — returned only secondary blogs and
vendor pages; they are noted as practitioner convention and nothing is built on
them.

---

## 0. The one-sentence answer

Yes — and the reason is sharper than "we forget": `[blocked]` is the only state
in the pipeline that is *surfaced everywhere and drained nowhere*, so the right
fix is not a reminder but a **closing event at the milestone boundary**, with the
agent preparing every question and answering none of the ones that are actually
direction calls.

---

## 1. The local evidence: five questions outlived a milestone

`consumer-a` has six open `[blocked]` items. Every one of them is an audit follow-up
(`followup_of:` set), and every one is a well-framed binary with stated options —
these are not badly-written questions.

| item | asked | milestones authored + drained since | age at 2026-08-16 |
|---|---|---|---|
| `FJ.6` | 2026-08-09 | F9, F10 | 7 days, **2 boundaries** |
| `FJ.7` | 2026-08-11 | F10 | 5 days, 1 boundary |
| `FJ.8` | 2026-08-11 | F10 | 5 days, 1 boundary |
| `FK.9` | 2026-08-11 | F10 | 5 days, 1 boundary |
| `FK.10` | 2026-08-11 | F10 | 5 days, 1 boundary |
| `FM.6` | 2026-08-16 | — | same day |

So five of six questions survived at least one full authoring-and-draining cycle
without being asked. That is the finding: the queue does not leak occasionally,
it leaks *structurally*, once per milestone.

**Why, mechanically.** The playbook surfaces `[blocked]` in three places — the
end-of-run summary, the board's `⛔ Blocked` column, and the loop's stop
condition — all of which are **read-only displays**. The one place a direction
call is actually *taken*, `/roadmap`'s brainstorm, scans for

> unblocked `status: todo` item files with `followup_of:` set

— that is, pending *fixes*. `[blocked]` is excluded by construction. And
`/handoff` closes the symmetry explicitly:

> A `[blocked]` item is a *question* awaiting a `> ANSWER:` line, not a hand-off;
> answer it in the item file instead.

`[attended]` got a command that walks it and closes the loop. `[blocked]` got a
sentence telling you to go edit a file by hand. The asymmetry is the bug.

One item, `FL.1`, *did* close — and it closed because the world moved (fixed
upstream in sweap PR #9), not because anyone answered it. That distinction turns
out to be the load-bearing one for the design; see §4.

---

## 2. Mixed-initiative HCI: the boundary is the right moment, and it needs a deadline

Horvitz, *Principles of Mixed-Initiative User Interfaces*, CHI '99
**[verified — PDF read firsthand]**. Three of the twelve critical factors are
directly on point:

> (3) Considering the status of a user's attention in the timing of services.
> … Agents should employ models of the attention of users and consider the costs
> and benefits of deferring action to a time when action will be less
> distracting.

> (5) Employing dialog to resolve key uncertainties. If a system is uncertain
> about a user's intentions, it should be able to engage in an efficient dialog
> with the user, considering the costs of potentially bothering him needlessly.

> (7) Minimizing the cost of poor guesses about action and timing. Designs for
> services and alerts should be undertaken with an eye to minimizing the cost of
> poor guesses, including appropriate timing out and natural gestures for
> rejecting attempts at service.

The paper also frames the agent's move as a **three-way** choice, not two — from
its description of LookOut's decision:

> the system decides to either (1) do nothing but simply wait for continued
> direct manipulation of Outlook or manual invocation of LookOut, (2) to engage
> the user in a dialog about his or her intentions with regards to providing a
> service, or (3) to go ahead and attempt to provide its service

That maps exactly onto what a blocked item needs at a boundary: *let it ride*,
*ask now*, or *take the default and record it*. Today sweap only ever does the
first.

And on what happens when the question is asked but not answered — LookOut

> will pose a question, wait patiently for a response, and then make a
> respectful, apologetic gesture and evaporate. The amount of time the system
> waits before timing out is a function of the inferred probability that a user
> desires the service.

An unanswered question **times out**. In sweap it waits forever. Horvitz's
related **bounded deferral** work (Horvitz, Apacible & Subramani, 2005) is the
same idea generalised — *search-summary only, not fetched*: defer an alert while
the user is busy, but commit to relaying it before a message-specific deadline.
The milestone boundary is the natural low-cost interruption point; what's missing
is the deadline.

Practitioner project-management convention (RAID logs — *vendor blogs only, low
weight*) independently converges on the same three fields for an open question:
a named owner, a due date, and an escalation when the date slips.

---

## 3. Patient safety: this exact failure mode, quantified

The closest studied analogue is not a software one. **Test results pending at
discharge (TPAD)**: a clinician orders a test, the patient is discharged before it
returns, and the answer arrives with nobody clearly on the hook for it. *All
figures below are search-result summaries of the systematic-review literature
(Whitehead et al. 2018, J. Hosp. Med.; Dalal et al.; the BMC HSR rapid review) —
not fetched firsthand, so treat the numbers as indicative.*

- Up to ~16% of ED and ~23% of inpatient discharges have pending results.
- 30–40% of those return **actionable** results — a change of management is
  warranted — often unknown to the treating physician.
- Reported non-follow-up rates span **6.8%–62%** for lab tests.
- The barrier reviewers name first: *ambiguity over who is responsible for
  following up*.
- What actually works: reliable **documentation** of what is pending at the
  transition, plus a **notification at the moment the result finalises** — i.e.
  an explicit closing event tied to the transition, not a standing list.

Every structural feature transfers. The milestone boundary is the discharge. The
blocked question is the pending result. Ownership is ambiguous ("the human,
sometime"). And the intervention the evidence supports is precisely the one
sweap lacks: a *closing event at the transition*, not more visibility.

**The counterweight, from the same field.** Alert fatigue — *search-summary
only*: clinical-decision-support override rates of **49%–96%** are reported
across the literature, and in one DDI study **88.2% of very-severe alerts were
overridden**. A queue that is dumped wholesale at a boundary gets satisficed, and
the severe items get overridden alongside the trivial ones. This is the hazard in
the naïve version of the proposal ("show all six, ask them all"): it converts a
forgetting problem into a rubber-stamping problem, and rubber-stamping is worse
because it leaves a record that says the question was answered.

---

## 4. The clarifying-question literature: prepare, don't pre-answer

This is where the proposal's "check if there are answers for blocked items" step
needs the most care, because the 2025–2026 literature says the failure mode runs
in the *opposite* direction from the one we're worried about.

Su & Cardie, *Knowing but Not Showing: LLMs Recognize Ambiguity but Rarely Ask
Clarifying Questions*, arXiv:2605.25284, 24 May 2026
**[verified — PDF read firsthand]**:

> We find a clear gap between recognition and behavior: models often identify
> ambiguity when prompted to judge it, yet in the QA setting they overwhelmingly
> default to direct answers. Retrieved context further widens this gap by
> improving answerability while making models even less likely to ask clarifying
> questions.

And on the mechanism:

> even when models recognize that a query is ambiguous in this explicit judgment
> setting, they do not reveal that uncertainty unless they are asked to

Read that against the proposed step. "Check whether the blocked questions can be
answered from the repo" *is* the retrieved-context condition, applied to
questions an agent has already flagged as needing a human. The predicted result
is not that the agent fails to find answers — it is that it finds them too
readily, and silently resolves taste calls that were escalated for a reason.
This is the same shortcut pressure the hand-offs memo identified for
`attended`, arriving through a different door.

The corresponding positive result gives the discriminator. Zhang, Knox & Choi,
*Modeling Future Conversation Turns to Teach LLMs to Ask Clarifying Questions*,
ICLR 2025 **[verified — PDF read firsthand]**:

> we assign preference labels by simulating their expected outcomes in future
> turns. This allows LLMs to learn to ask clarifying questions when it can
> generate responses that are tailored to each user interpretation in future
> turns.

> We further demonstrate that our method can be used to train models to
> judiciously determine when to ask clarifying questions, directly answering the
> question when clarification is unnecessary.

The transferable idea is the **double-turn test**: judge a question by simulating
both answers and looking at what each produces downstream. If both branches yield
the same item file, the question was never a direction call and should not be on
the human's queue. If they diverge, it is genuine and must be asked. This is a
test the agent can run mechanically on each blocked item at the boundary — and
critically, it decides *whether to ask*, never *what the answer is*.

Related work in the same line, *search-summaries only*: Ask-before-Plan
(arXiv:2406.12639), Active Task Disambiguation (Kobalczyk et al. 2025), and
Structured-Uncertainty-guided Clarification (arXiv:2511.08798), which scores
candidate questions by expected value of perfect information against a cost model
for asking. The EVPI framing is the same economics as Horvitz's §2 threshold, 26
years later.

---

## 5. Framework prior art: durable pause is table stakes; draining it is not

LangGraph's `interrupt` **[verified — LangChain blog fetched]** is the mainstream
primitive:

> You can use this in much the same way as `input`: `response = interrupt("Your
> question here")`

and the pause is durable —

> can be resumed many months later, on a different machine, etc.

Worth recording honestly: the "Agent Inbox" framing — a single queue of every
pending interrupt across threads — is **not** on that page, and I did not verify
it elsewhere. So the claim frameworks have converged on a *drain* UI is
unsupported; what they have converged on is a durable *hold*. Which is exactly
sweap's position: the hold works fine, and nothing drains it.

OpenAI's *A practical guide to building agents* (*search-summary only*) names two
triggers for human intervention — exceeding failure thresholds, and high-risk or
irreversible actions. Both are triggers for *entering* the human's queue. Neither
addresses what happens when the queue is not worked. That gap in the vendor
guidance is consistent across sources and is why §3's evidence comes from
medicine.

---

## 6. What the evidence supports

1. **Hook it to `/roadmap`, as a pre-flight step before the brainstorm** — not
   inside it. The boundary is the low-cost interruption point (§2), and it is the
   one moment a direction call is already being taken and new work already being
   scoped. Keeping it a separate step avoids answering five accumulated questions
   in the anchoring shadow of the new milestone's narrative.

2. **Soft gate, not hard.** The adjacent audit-debt check is a hard stop because
   audit debt is never legitimately deferrable. A direction call *is* — the cost
   of deferring is real but bounded. So: surface, offer, and record the skip with
   its cost. Do not block authoring.

3. **The agent prepares every question and answers none of the direction calls**
   (§4). Split them mechanically rather than by judgement:
   - *Premise invalidated* — the world moved and the question is moot, evidenced
     by a diff or a shipped item (the `FL.1` shape). The agent may propose
     closing it, with the evidence; the human confirms.
   - *Direction call* — taste, scope, policy, cross-milestone IA. The agent may
     restate it, recommend a default with rationale, and say what changes either
     way. It may never resolve it.
   - Run the double-turn test to decide which questions are even worth the
     human's queue: simulate both answers; identical downstream item ⇒ not a
     question, close it with the default recorded.

4. **Give the queue a deadline, and make surviving a boundary visible.** Extend
   the existing note convention — a blocked item that outlives a boundary gets
   `> **CARRIED (YYYY-MM-DD):** unanswered through <milestone>` in `## Notes`,
   the same way deferred items get `> **UNBLOCKED:**`. After two carries it stops
   being a question: the agent takes its recommended default, records it as an
   answer with provenance, and flips the item to `todo`. A decision with a
   visible default beats an open question forever (§2, §3), and the carry-notes
   make the escalation legible in the diff rather than in someone's memory.

5. **Keep the ask small.** Alert-fatigue evidence (§3) says a six-item dump gets
   satisficed. Rank by what the answer unblocks and ask the top ones properly,
   one at a time, in the Socratic style `/roadmap` already uses. The rest carry
   with a note.

6. **The conversion already exists — don't invent state.** An answered item flips
   `blocked → todo` with the `> ANSWER:` line, at which point it is an ordinary
   frontier candidate for `/milestone`, exactly like an audit follow-up. Nothing
   new is needed to "pick it up in the next milestone"; the queue just has to be
   drained before the frontier is computed.

7. **Give it a command: `/unblock`, sibling to `/handoff`.** `/handoff <id>` walks
   one attended item and closes the loop through a gated PR; `/unblock [id]`
   should walk one blocked item and do the same. `/roadmap`'s pre-flight then
   stays thin — it triages the queue and offers `/unblock` — and the human gets a
   way to drain the queue *outside* a boundary too. This also removes the
   embarrassment in `/handoff`'s own text, which currently tells the human to go
   edit a YAML field by hand.

## 7. What the evidence does *not* support

- **Letting the agent brainstorm answers to direction calls as a matter of
  course.** §4 is a direct warning. Preparation with a recommended default is
  supported; open-ended "let's brainstorm what the answer might be" invites the
  model to talk itself out of asking. If the human explicitly asks to brainstorm
  one, that is a different thing — it is the human choosing to think out loud, and
  the answer is still theirs.
- **A hard gate.** Nothing in the evidence base says an unanswered direction call
  should block new work. It says it should not be *silent*.
- **More surfacing.** sweap already surfaces blocked items in three places and it
  changed nothing. The intervention that works in §3 is a closing event, not
  another list.

---

## Sources

**Verified (fetched and read firsthand):**
- Horvitz, *Principles of Mixed-Initiative User Interfaces*, CHI '99 — https://erichorvitz.com/chi99horvitz.pdf
- Su & Cardie, *Knowing but Not Showing: LLMs Recognize Ambiguity but Rarely Ask Clarifying Questions*, arXiv:2605.25284 — https://arxiv.org/pdf/2605.25284
- Zhang, Knox & Choi, *Modeling Future Conversation Turns to Teach LLMs to Ask Clarifying Questions*, ICLR 2025 — https://proceedings.iclr.cc/paper_files/paper/2025/file/97e2df4bb8b2f1913657344a693166a2-Paper-Conference.pdf
- LangChain, *Making it easier to build human-in-the-loop agents with interrupt* — https://www.langchain.com/blog/making-it-easier-to-build-human-in-the-loop-agents-with-interrupt

**Search-result summaries only (not quoted, weighted accordingly):**
- Horvitz, Apacible & Subramani, *Balancing Awareness and Interruption: Investigation of Notification Deferral Policies*, UM 2005 — https://link.springer.com/chapter/10.1007/11527886_59 · https://erichorvitz.com/bdef_studies.htm
- Whitehead et al., *Interventions to Improve Follow-Up of Laboratory Test Results Pending at Discharge: A Systematic Review*, J. Hosp. Med. 2018 — https://pmc.ncbi.nlm.nih.gov/articles/PMC9491200/
- *Closing the loop on test results to reduce communication failures: a rapid review* — https://link.springer.com/article/10.1186/s12913-020-05737-x
- *Appropriateness of Overridden Alerts in CPOE: Systematic Review*, JMIR Med Inform 2020 — https://medinform.jmir.org/2020/7/e15653
- Felisberto et al., *Override rate of drug-drug interaction alerts in CDSS: brief systematic review and meta-analysis* — https://journals.sagepub.com/doi/10.1177/14604582241263242
- OpenAI, *A practical guide to building agents* — https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/
- Zhang et al., *Ask-before-Plan: Proactive Language Agents for Real-World Planning* — https://arxiv.org/pdf/2406.12639
- *Structured Uncertainty guided Clarification for LLM Agents*, arXiv:2511.08798 — https://arxiv.org/html/2511.08798
- Reinertsen, *The Principles of Product Development Flow* (queues as the dominant waste in development) — https://en.wikipedia.org/wiki/Cost_of_delay
