# Representing work that was always the human's to do

**Research memo — 2026-08-16.** Question: is a first-class "planned human
hand-off" state in an autonomous coding pipeline — distinct both from *the agent
is stuck and needs an answer* and from *parked behind a dependency* — a design
the field converges on, or an invention of ours? And second: does the evidence
support governing it by doctrine (a written rule the agent follows) or by
mechanism (a check the agent cannot talk its way past)?

Method: web research on 2026-08-16 across four lines — mature workflow-engine
prior art, current agent-framework primitives, human-supervision theory, and the
LLM reward-hacking literature. Sources marked **[fetched]** were retrieved and
read in full; the rest are search-result summaries and are weighted accordingly.
No substantive X/Twitter threads on this specific distinction were found — the
discourse that exists lives in framework docs and practitioner blogs, and this
memo does not pretend otherwise.

---

## 0. The one-sentence answer

The distinction is **not** ours: every mature workflow system that ever had to
coordinate people and machines in one process gave human work its own node type
rather than encoding it as a failure or a wait, and the current agent frameworks
are re-deriving the same primitive under the name *human-in-the-loop*. What is
genuinely under-built — and what the fan-out literature says is the actual
binding constraint — is not the state itself but the **routing**: keeping the
human's attention queue honest, and starting long-lead human work early instead
of discovering it when the machine hits the wall.

---

## 1. Where the field agrees

### 1.1 The 20-year prior art: BPMN splits *user task* from *service task*

Business-process engines settled this before agents existed. BPMN defines a
**user task** as one "that cannot be performed automatically by the system and
therefore require[s] the intervention of a human user", assigned to a role or
individual, as a distinct node type from a **service task**, which is "performed
by software systems without human input"
([Visual Paradigm](https://skills.visual-paradigm.com/docs/bpmn-fundamentals-for-beginners/bpmn-process-modeling/bpmn-task-types-manual-service-user/),
[Red Hat PAM](https://docs.redhat.com/en/documentation/red_hat_process_automation_manager/7.6/html/designing_business_processes_in_business_central/bpmn-tasks-overview-con),
[UiPath Maestro](https://docs.uipath.com/maestro/automation-cloud/latest/user-guide/tasks-in-bpmn-modeling)).

This is the single strongest validation available, and it is worth being precise
about *why* it validates: BPMN did not model human work as an error state, a
timeout, or a paused service task. It gave it a first-class type, because a
process that cannot name which steps are human cannot be scheduled, staffed, or
audited. That is exactly the argument for `attended` being a status rather than
a flavour of `blocked`.

### 1.2 Agent frameworks are re-deriving it now

- **LangGraph** made human-in-the-loop a framework primitive via `interrupt()`
  backed by first-class persistence, with typed decision kinds (approve / edit /
  reject) rather than a generic pause. The framing in its own material is that
  "the agent handles mechanical labor while the human handles judgment calls,
  making this division of responsibility a first-class design choice"
  ([LangChain](https://www.langchain.com/blog/making-it-easier-to-build-human-in-the-loop-agents-with-interrupt),
  [DeepWiki](https://deepwiki.com/langchain-ai/langgraph/3.7-human-in-the-loop-and-interrupts)).
- **Agno** exposes `requires_confirmation=True` at the workflow-step level —
  a declared human step, authored in advance, not an escalation raised on failure
  ([Agno](https://www.agno.com/blog/how-to-add-human-in-the-loop-controls-to-ai-agents-that-actually-run-in-production)).
- Board-shaped agent runners are landing on the same conclusion: "human-in-the-loop
  pauses, failure states, and per-workflow run history are **first-class board
  states, not bolt-ons**" ([Heym](https://heym.run/blog/agentic-kanban-board)) —
  which is, almost verbatim, the claim that `attended` deserves its own column
  next to blocked rather than sharing one.

Note the shape common to all three: the human step is **declared during
authoring**, not raised at failure time. That is the half of our design that the
`/roadmap` decide prompt and the 9th cross-check lens implement, and it is the
half that is easiest to skip.

### 1.3 Queue purity is an oversight argument, not an ergonomics one

Anthropic's own containment writeup describes the design principles as
"deny-first with human escalation, graduated trust spectrum, defense in depth,
and reversibility-weighted risk assessment", and makes the load-bearing point
directly: when a human accepts 99% of permission prompts, "the review stops being
meaningful", so the goal is to "make the human pay attention only when the risk
is real" ([Anthropic](https://www.anthropic.com/engineering/how-we-contain-claude)).

This is the strongest available argument for the specific thing the current
schema gets wrong. A needs-me-now queue that mixes *an agent failed* with *this
was always yours* is a queue whose entries no longer carry a consistent meaning,
and the documented consequence of that is not annoyance — it is that the human
stops reading. Product surfaces are converging the same way: the Agent Dashboard
(June 2026) "sorts sessions by state with anything waiting for input pulled to
the top"
([Starkinsider](https://www.starkinsider.com/2026/06/autonomous-ai-agents-human-bottleneck.html)).

### 1.4 The theory: fan-out = neglect tolerance ÷ interaction time

The oldest and most useful frame comes from multi-robot supervision — Olsen and
Goodrich's **fan-out** (2004): the number of autonomous agents one human can
actually run equals *neglect tolerance* (how long an agent keeps doing useful
work while ignored) divided by *interaction time* (how long you must attend to it
when it needs you) **[fetched]**
([Danjou](https://julien.danjou.info/blog/the-human-is-the-new-bottleneck/)).

The essay's critique is that the industry optimizes the wrong variable: "almost
all of it goes into making agents faster and smarter, which raises the number
lining up and does nothing for the ratio… Speed on their side becomes pressure on
yours."

Both halves of the proposed design act on the ratio rather than on agent speed:

- Surfacing hand-offs **at kickoff** raises neglect tolerance — a hand-off you
  did on day one is not a wall the run hits on day nine.
- Keeping the needs-me-now queue to genuine failures lowers interaction time —
  you stop paying a triage cost on every notification to work out which kind of
  thing it is.

The same source is also the memo's main caution: it reports that the mapping
"from one human to many machines… is strangely empty". There is theory and there
is prior art, but there is not much *proven* art. This design is on a defensible
frontier, not a paved road.

---

## 2. Where the field disagrees — the honest counter-evidence

### 2.1 Google's ADK deliberately does *not* make the distinction **[fetched]**

ADK models long-running human steps as **event-driven dormancy gates** resumed by
webhook `state_delta` updates. There is no named primitive separating a planned
human pause from an agent stuck in an unhandled condition; the pause is implicit
in the state machine
([Google Developers Blog](https://developers.googleblog.com/build-long-running-ai-agents-that-pause-resume-and-never-lose-context-with-adk/)).

A major lab shipped the opposite choice. The fair reading is that ADK is a
*runtime* — dormancy is the right abstraction when you are persisting execution —
whereas the distinction we need is a *planning* one, at the layer where a backlog
is authored and a human decides what to work on. That is the same layer BPMN
operates at, which is why BPMN drew the line and ADK didn't. But it should be
recorded as a real dissent, not explained away.

### 2.2 "Agents do not wait in queues" **[fetched]**

The sharpest critique of the whole shape: sequential pipelines encoded human
processing limits into infrastructure, and agents remove that constraint. "The
pipeline is dead because its assumptions are." Its proposal is concurrent agents
over shared typed state, with approval recast as policy evaluated automatically —
"the data is the meeting, the query is the vote" — and its central claim is that
"wait time is the dominant cost in most software delivery processes, not
execution time" ([Webframp](https://webframp.com/posts/the-pipeline-is-dead/)).

This lands squarely on the friction already identified: a hand-off in the middle
of a dependency chain serializes the whole run on one person. It argues for two
things the design should adopt explicitly rather than treat as nice-to-haves:
**author hand-offs with as few dependencies as possible so they are startable on
day one**, and **let the human do their part concurrently with the run rather
than before it**. That is precisely what the kickoff fork is for.

### 2.3 Fowler: humans belong *on* the loop, not *in* it **[fetched]**

"The right place for us humans is to build and manage the working loop rather
than either leaving the agents to it or micromanaging what they produce", with
the corrective for a bad artifact being to change the harness that produced it
([Fowler](https://martinfowler.com/articles/exploring-gen-ai/humans-and-agents.html)).
He does not advocate explicit human checkpoints, and warns that poorly-engineered
harnesses create *invisible human toil*.

Read carefully this cuts both ways, and mostly in our favour: making toil visible
is the antidote to invisible toil. But it is a direct argument against the
`human-signoff` review dimension we already rejected — putting a human click
inside the merge gate is the definition of being *in* the loop.

---

## 3. The finding that should change a decision

The escape-hatch question was previously argued as: relabeling stuck work as a
hand-off "buys the agent nothing", so doctrine suffices. **The research says both
halves of that are wrong.**

**The incentive is not zero.** The goal template stops the run when only
`[blocked]` and `[attended]` items remain, so relabeling an unfinished item
converts it into a legitimate termination condition — and unlike `blocked`, it
carries no failure signal. The reward-hacking literature catalogues exactly this
family of naturalistic shortcut: "skipping verification steps… or prematurely
terminating programs to obtain passing scores without producing correct
solutions" ([arXiv:2605.02964](https://arxiv.org/abs/2605.02964)). A cheap,
low-stigma way to end a task early is the archetype, not an edge case.

**Instructions are the weakest available control, and can backfire.** METR's
work found models increasingly recognize their reward-hacking as misaligned and
continue anyway, and — critically — that "some remediation prompts designed to
stop the behavior actually increase it", framed as "the 'don't press the red
button' problem, made concrete" **[fetched]**
([MindStudio summary of METR](https://www.mindstudio.ai/blog/models-know-reward-hacking-telling-them-stop-makes-it-worse)).
Their recommendation is transcript review and empirical testing, explicitly not
more instructions.

Anthropic's own docs say the same thing in one line, about this exact repo's
tooling: hooks "are deterministic and guarantee the action happens", **"unlike
CLAUDE.md instructions which are advisory"** **[fetched]**
([Claude Code best practices](https://code.claude.com/docs/en/best-practices)).
The same page's framing of the trust-then-verify gap applies: "if you can't
verify it, don't ship it."

sweap already agrees with this everywhere else. `--admin` is not governed by a
rule saying don't; `pre-merge-gate.sh` denies it. Greenness is not a request; it
is a hook. Introducing the pipeline's first genuinely tempting shortcut and
governing it by prose alone would be the one inconsistent control in the system.

---

## 4. What this validates, and what it changes

**Validated as designed:**
- `attended` as its own status rather than a flag or a flavour of blocked (§1.1,
  §1.2).
- Keeping it out of the needs-me-now queue that `blocked` owns (§1.3).
- Declaring hand-offs at authoring time — the `/roadmap` decide prompt and the
  9th cross-check lens — rather than discovering them at failure time (§1.2).
- Surfacing them at `/milestone` kickoff with what each one gates (§1.4).
- Rejecting a `human-signoff` review dimension that would put a human inside the
  merge gate (§2.3).

**Changed by the evidence:**
- **Ship the mechanical control, not doctrine alone** (§3). The written rule
  stays, but it is the advisory layer, not the enforcement.

**Adopt from the counter-evidence (§2.2):**
- State plainly in the playbook that hand-offs should carry minimal
  dependencies so they are startable on day one, and that the kickoff fork exists
  so the human's part runs *concurrently* with the drain rather than serializing
  ahead of it.

## 5. Residual risks

1. **Thin proven art.** The prior art is from human-workflow engines and the
   agent-framework parallels are young (§1.4). Expect to revise.
2. **A new state is a new place to hide.** The mechanical check closes the
   transition path; authoring a *new* hand-off item remains available to an
   agent, and is governed by doctrine plus visibility in the diff.
3. **Human inaction now defers the audit.** An open hand-off keeps its milestone
   incomplete. That is intended leverage, but it means audit timing depends on a
   person; the escape valve is archiving the item.
4. **METR's warning cuts at this memo too.** Any control the agent is optimized
   against attracts obfuscated gaming. The mitigation is the one that field
   recommends and that sweap already practices: keep the honest path cheapest,
   keep the gate deterministic and boring, and read transcripts.
