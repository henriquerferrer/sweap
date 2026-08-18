# What rule should an adversarial refuter follow?

**Research memo — 2026-08-18.** Question: sweap's milestone-audit runs three
adversarial refuters per finding, majority-kills. A prompt change on 2026-08-16
(PR #12) dropped the panel's kill rate from 63–73% to 2.7%. What rule *should* a
refuter follow, what do the labs actually do, and what is the minimum change
that makes the number mean something?

Method: two parallel research passes on 2026-08-17/18 — (a) burden of proof and
verdict taxonomy in lab/primary sources, (b) mechanisms of judge distribution
collapse and published countermeasures. **Every quote below was re-fetched as
raw HTML/PDF and string-matched.** That discipline exists because the
2026-08-16 memo in this directory was found to contain quotes the summarising
fetch tool had fabricated; anything unverifiable here is marked **[UNVERIFIED]**
rather than paraphrased into a claim.

---

## 0. The one-sentence answer

**Strictness belongs in a number outside the model, not an adjective inside the
prompt** — every lab source converged on that, and sweap currently has no such
number, which is why one wording change moved the kill rate 25×.

---

## 1. The incident, as evidence

sweap's own data is the highest-quality evidence in this memo, because it is a
near-controlled experiment on the exact pipeline:

| audit | raw | refuted | kill rate | refuter prompt |
|---|---|---|---|---|
| F9 | 54 | 34 | 63% | "default to refuted=true if uncertain" |
| F10 | 45 | 33 | 73% | same |
| **F11** | 36 | **1** | **2.7%** | three-valued verdict (PR #12) |
| F11 **UI axis** | 30 | 12 | **40%** | **unchanged** (`ui-critic`) |

The UI axis is the control: same 3-refuter majority shape, same milestone, same
codebase, untouched prompt — and it held at 40%. That isolates the collapse to
the prompt change rather than to F11 being unusual.

From the run's own journal (`wf_984b61cc-6a2`), across 216 recorded verdicts:

    stands        210
    refuted         6
    unverifiable    0

**Zero.** The third option was never once selected, in a run where refuter prose
bodies openly said *"UNVERIFIED BY READING / I could not run anything."* The
Validate stage (which requires ≥2 `unverifiable` on a finding) was therefore not
merely unused — it was structurally unreachable.

## 2. Why it collapsed — three mechanisms, all pointed the same way

The original diagnosis ("`stands` was the only free option") is incomplete.
Read the shipped rule as a read-only agent sees it:

- `refuted` required *"a positive, code-grounded disproof"* — demanded of an
  agent that **cannot run code**. Near-unearnable by construction.
- `unverifiable` required naming an experiment, and **demoted to `stands`** if
  it didn't.
- `stands` required nothing.

Two costly inlets, one free sink, no outlet. The refuters' prose disclaiming
verification while the schema said `stands` is the taxonomy working as
specified, not a model failure.

**(a) Adding an option perturbs the distribution for non-semantic reasons.**
*LLM Abstention Can Be a Prompt Artifact* ([arXiv:2507.16199](https://arxiv.org/abs/2507.16199))
names this **Abstention Inflation**, and its control is decisive: *"We add
'Unknown' as an extra option… experiments show serious accuracy drops on
True/False Questions (TFQs). **Replacing 'Unknown' with an unrelated random word
produces an identical effect.**"* Their conclusion: it *"is triggered by the
structural presence of an extra option, not by genuine uncertainty."* In their
setup the new option was *cheap* so mass flowed to it; in ours it was
*expensive* so mass fled it. Either way the option scaffold set the
distribution. **Strength: strong (the random-word control).**

**(b) Verifiers over-assign the favourable label, and the usual fixes don't
help.** *Let's Think in Two Steps* ([arXiv:2507.11662](https://arxiv.org/abs/2507.11662)),
13+ models and 28+ scoring designs: *"Agreement bias is pervasive… manifesting
as output distributions skewed toward favorable labels and failure-detection
rates as low as 50%. This bias persists across 28+ scoring templates, including
techniques to mitigate biases in LLM judges… and is **exacerbated when
verification is cast as binary success-or-failure classification**… resilient to
test-time scaling."* Independently, *Beyond Consensus*
([arXiv:2510.11822](https://arxiv.org/abs/2510.11822)) measures *"True Positive
Rate 96%"* against *"True Negative Rate <25%"* — good at confirming, poor at
rejecting — and finds *"ensemble-based methods like majority voting… are not good
enough"*, proposing a **minority veto** instead. **Strength: strong for the
phenomenon; the specific TNR figure is an unrefereed 2025 preprint on a
366-program Python task, not code review.**

**(c) Rare targets destroy detection, with exactly our signature.** Wolfe,
Horowitz & Kenner, *Nature* 435:439–440 ([PMC4224304](https://pmc.ncbi.nlm.nih.gov/articles/PMC4224304/)):
*"50% prevalence produced 7% miss errors… 10% prevalence produced 16% errors,
while at 1% prevalence errors soared to 30%. Errors were primarily 'misses'…
'False alarms'… were vanishingly rare (0.03%)."* The mechanism is a **quitting
threshold** — *"With infrequent targets, observers can successfully say 'no'
almost all of the time"* — which is a refuter that stops hunting because
`stands` is nearly always defensible. Practice does not fix it (4000 trials at
1% still gave 41% misses), and padding with easy targets does not either.
**Strength: strong, but human visual search; the mechanism transfers by
analogy.**

Supporting from survey methodology — Krosnick et al., *POQ* 66:371–403
([PDF](https://gspp.berkeley.edu/assets/uploads/research/pdf/Krosnick_et_al..pdf)):
a respondent inclined to satisfice *"will look for cues in the question
suggesting how to offer a seemingly defensible answer with no thought about the
question at all. A no-opinion response option would constitute just such a
cue."* That is a literal description of a costless `stands`. **Strength: strong
for humans; the transfer to LLMs is analogy — no study directly manipulates
per-label evidence cost in an LLM judge and measures the verdict distribution.
sweap's 63→2.7 is, as far as this research found, a novel data point.**

## 3. What the labs actually do

**None of them put the burden of proof in prose.** All three externalise the
decision boundary:

- **OpenAI `score_model` grader** ([docs](https://platform.openai.com/docs/guides/graders.md)):
  returns `{"result": float, "steps": [...]}` with a separate **`pass_threshold`**
  in the config. The model scores; the *system* cuts. There is no categorical
  verdict for a category to absorb.
- **Anthropic, "Develop tests"** ([docs](https://platform.claude.com/docs/en/test-and-evaluate/develop-tests)):
  *"**Empirical or specific:** For example, instruct the LLM to output only
  'correct' or 'incorrect', or to judge from a scale of 1–5."* and *"**Encourage
  reasoning:** Ask the LLM to reason first before producing an evaluation score,
  and then discard the reasoning."* Binary or 1–5. No three-way-with-escape-hatch.
- **CriticGPT**, *LLM Critics Help Catch LLM Bugs* ([arXiv:2407.00215](https://arxiv.org/abs/2407.00215))
  — the closest published system to this pipeline. *"RL-only CriticGPT is more
  conservative, producing much higher precision critiques at the cost of
  recall"*, fixed with a scalar: *"FSBS lets us navigate tradeoffs between
  comprehensiveness and hallucinations"*, framed *"as analogous to precision and
  recall."* Their critiques also require **quoted code spans** — evidence
  enforced by output format and scored by a reward model, not politely
  requested.

**The lesson, stated as an engineering rule: an anti-false-positive instruction
becomes a conservatism dial you cannot see. Build the dial explicitly.**

For the default-on-uncertainty question specifically, *Why Language Models
Hallucinate* ([arXiv:2509.04664](https://arxiv.org/abs/2509.04664)) proves the
shape: *"Under binary grading, abstaining is strictly sub-optimal. IDK-type
responses are maximally penalized while an overconfident 'best guess' is
optimal."* Their prescription is to state the payoff numerically in the prompt —
*"Answer only if you are > t confident, since mistakes are penalized t/(1 − t)
points, while correct answers receive 1 point, and an answer of 'I don't know'
receives 0 points"* — the way exam boards publish negative marking.

## 4. Both settings were wrong; only one was measured

| | refute-on-uncertainty (F9/F10) | stand-on-uncertainty (F11) |
|---|---|---|
| Correct when | a surviving false finding costs more than a killed true one | a killed true finding costs more |
| Failure mode | rubber-stamp **destroyer**; true positives die silently | rubber-stamp **approver** — the observed 2.7% |
| Detected by | false-kill audits on known-good findings | miss-rate audits on **seeded known-bad findings** |

63–73% was very likely also wrong. It failed in the direction nobody was
measuring, and nothing in F9's or F10's record would have revealed it. **Neither
number is interpretable without a labeled set.**

**Correction to a claim made during PR #12:** the fixed kill threshold of 2 was
defended as clearly right, on the grounds that renormalising to a majority of
cast votes would hand one refuter a veto when the panel is least informed. Under
documented positive bias that reasoning is backwards — *Beyond Consensus*
argues the correct shape is a **minority veto** (~1-of-3), because an agreeable
majority is the failure mode, not the safeguard. **But do not flip it blind:**
the same paper is explicit that *"the choice of this optimal threshold itself
requires a calibration set with ground-truth labels."* Flipping on intuition
re-rolls the dice that produced 63% and 2.7%.

## 5. What to change

**Tier 1 — the shape (high confidence, no calibration needed).**

1. **Delete the three-valued verdict.** Per §2(a) it cannot be fixed by
   re-pricing; the category's structural presence is the problem. `unverifiable`
   stops being a verdict and becomes an **out-of-band ticket** that *suspends* a
   finding for the Validate stage rather than *resolving* it.
2. **Symmetric evidence.** Every verdict cites code — including the "no change"
   one, which must state what it read and what would falsify it. Enforce as a
   **schema violation**, never a demotion (a demotion is a drain into the sink).
   *Strength: principled — Rulers' "traceable evidence" thesis and CriticGPT's
   scored spans support it; no controlled study measures justification-for-every-
   label on verdict distributions.*
3. **Fix the `refuted` bar.** "Positive, code-grounded disproof" is a
   contradiction for a read-only agent. Restate as "cite the code that
   contradicts the claim" — achievable by reading — or accept that a read-only
   refuter can only downgrade confidence and let the empirical gate do the
   killing.
4. **Move strictness out of the prompt.** Refuter emits evidence + a scalar; the
   kill threshold lives in the pipeline as a tunable number, with the payoff
   stated numerically per §3.

**Tier 2 — earn the threshold (the part that actually matters).**

5. **Build a labeled calibration set**: seed known-bad (deliberately spurious)
   and known-good findings into the audit stream. Both research passes
   independently called this the highest-value action. Until it exists, no kill
   rate — 2.7% or 73% — can be called right or wrong. Wolfe's second experiment
   warns against padding with easy seeds: mixed prevalence still left 52% misses
   on the rare class.
6. **Keep the UI axis frozen as a permanent control.** It has already paid for
   itself once by separating a prompt change from a population change.

**Tier 3 — if going further (verified, quantified, more work).**

7. **Criteria before artifact** (self-grounded verification, [2507.11662](https://arxiv.org/abs/2507.11662)):
   have the refuter enumerate what a valid disproof of *this class* of finding
   looks like before it reads the finding. **+25pp failure detection, +14pp
   accuracy** — the strongest single intervention found.
8. **Split attacker from adjudicator.** One agent argues for refutation; a
   different one issues the verdict. Debate results ([2402.06782](https://arxiv.org/abs/2402.06782)):
   **76% (models) / 88% (humans) vs 48% / 60% naive baselines**.
9. **Cross-family verifiers** ([2512.02304](https://arxiv.org/abs/2512.02304)):
   *"verification across model families is more effective than either
   self-verification or verification within the same family."*
10. **Record whether the finding was revised, not just the verdict**
    ([2605.25133](https://arxiv.org/abs/2605.25133)): "accept **and the prover
    never had to change anything**" carried a ~30pp precision gap over the
    verdict alone.

**Do NOT reach for these — verified negatives.**

- **Chain-of-thought before the verdict**: *"CoT can collapse the spread of the
  judgment distribution, often harming performance"* ([2503.03064](https://arxiv.org/abs/2503.03064)),
  and in SGV the verifier generates reasoning that *rationalises* flawed
  behaviour.
- **More refuters / majority voting / test-time scaling**: agreement bias is
  *"resilient to test-time scaling"* and persists under majority voting.
- **Debiasing prompt phrases**: real but +7–11pp ([2604.23178](https://arxiv.org/abs/2604.23178)) —
  nowhere near a 60-point gap.

## 6. Residual risks

1. **The refuter may be out of its depth.** *"On Humanity's Last Exam, weaker
   prover-verifier pairings can collapse or invert the [selection] signal."*
   If so, no prompt fixes it, and the calibration set is how that gets found.
2. **Assigned adversarial stances decay.** Role fidelity measured at **67%
   (Mistral Large) / 39% (Claude Sonnet)** across 60 statements
   ([2604.27228](https://arxiv.org/abs/2604.27228)), with two failure modes —
   abandoning the role, or switching to the opposing stance. A share of those
   210 `stands` may be role abandonment rather than judgment, and abandonment is
   invisible in the verdict. Instrument the stance; don't assume it.
3. **Framing is an attack surface in exactly this domain.** Contextual bias in
   LLM security code review is *"systematic and widespread"* across 6 LLMs
   ([2603.18740](https://arxiv.org/abs/2603.18740)). A refuter asked "can you
   disprove this?" is receiving a frame, and frames dominate content.
4. **Sycophancy is a training-level prior, not a prompt bug**
   ([2310.13548](https://arxiv.org/abs/2310.13548)): humans and preference
   models *"prefer convincingly-written sycophantic responses over correct ones
   a non-negligible fraction of the time."* A confidently-written audit finding
   is precisely that input. Prompt work is fighting upstream.
5. **The finder side is unexamined.** Raw findings went 54 → 45 → 36 across the
   three audits. That may be a smaller milestone surface, or the finders may
   also have been dampened by the read-only clause added in PR #11. One run
   cannot separate those; the next audit's raw count is the first datum.

## 7. Evidence strength, bluntly

| Claim | Strength |
|---|---|
| sweap's own 4-audit dataset + the frozen UI control | **Strongest thing here** |
| Labs externalise strictness rather than prompting it | **Strong** — primary docs, fetched raw |
| Verifiers over-assign the favourable label | **Strong** — multiple quantified sources |
| Adding an option perturbs the distribution non-semantically | **Strong** — the random-word control |
| Costly options shed mass to the cheap one | **Strong for humans**, **analogy for LLMs** — no direct study |
| Low prevalence explodes misses, not false alarms | **Strong**, but human visual search |
| Numeric confidence targets are the right default mechanism | **Strong as argument**, untested as deployed practice |
| Justification-for-every-label restores balance | **Weak** — principled, uncontrolled |
| Adversarial role instructions decay | **Moderate** — first systematic test, n=60, 2 models |
