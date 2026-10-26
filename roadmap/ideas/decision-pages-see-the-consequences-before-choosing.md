---
title: Decision pages: see the consequences before choosing
created: 2026-10-24T14:29:06.908Z
---

Problem: blocked questions, direction notes and design choices arrive as text options, so the human's answer is often the recommendation, not an informed choice. Value: a visual page per decision (a Claude artifact; for UI, real side-by-side mockups) showing what each option does, what the user/patient sees, what it costs and how to undo it.

## Refuted 2026-10-24 (workflow wf_89f28593-0c3: 3 investigators, then premise / wrong-fix / cost reviewers per proposal)

- **A, a decision page for every blocked question and direction note — KILLED 3–0.** No answered option in consumer A, consumer B or consumer C was ever reversed, redone or regretted: the recommendation was taken on 21 of 27 questions, and every departure was a UI, taste or domain call that still stands. The three consequences nobody saw coming (FR.2 name, FR.4 48 h dead end, F13.10 follow-up) were unknown to the agent too, so a page in its framing would only have made the miss more convincing. A page that sits next to a recommendation raises acceptance whether the recommendation is right or wrong (Bansal 2021; Gajos & Mamykina 2022), which is the anchoring that killed the blocked-item recommendation field on 09-28. A flip-time page would wait out the 104 h median, and its notification link has nothing to carry it.
- **B, a fixed consequence block in the terminal with the "Recommended" label demoted — KILLED 3–0.** It is prose on every decision (about 9 a week) with no recorded harm to prevent, it repeats /unblock's double-turn simulation, and it contradicts unblock.md's recommended default.
- **What all six reviewers converged on (unrefuted, not built):** (1) about 3–5 lines in unblock.md step 2, which /roadmap Step 0 inherits: when the answer is taken with AskUserQuestion, put each option's existing double-turn simulation into that option's `preview`, written the same way for every option (what the user or patient sees, the cost, how to undo it). `preview` was used 0 times in 37 recent questions. (2) A side-by-side mockup (an Artifact or the real screen) only for UI/taste forks, made on demand in an attended session. That matches where every departure happened and the side-by-side evidence (Tohidi 2006, Dow 2010). Split vote: hiding the recommendation until a provisional pick (Fogliato 2022, Buçinca 2021) had two for and two against. Judge it after about 20 decisions; cut it if nothing changes.

## Rerun 2026-10-25 with the corrected premise (wf_2478a858-86c)

Henrique's correction: "never regretted" measures his feedback, not the clinic users'. It holds, because consumer A has no real users yet (F15 deploy is unbuilt; go-live F15.16 is an attended hand-off not yet done). Of 40 decisions, 14 rest on a clinic-ops or legal assumption no real clinic has checked. On those he departed from the recommendation 5 of 10 times, so the gap is that his guesses are never checked, not that he rubber-stamps.

- **Understand first, recommendation last — KILLED 3–0.** Presentation cannot supply clinic knowledge. "Recommendation last" in the same prompt is not commit-first. The agent's stories can be wrong: the reviewers found the F13.10 "a solo owner is never preselected" scenario misstates F13.10.md:14.
- **Video walkthrough (HyperFrames) — KILLED 3–0.** It technically works (Apache-2.0, `<hyperframes-player>` plays without a render step). But animation loses to static frames for comparing discrete options: Zikmund-Fisher 2012 had 84.8% correct choices with static graphics vs 67.6–75.8% with animated ones, and the meta-analyses give d=0.23–0.37. It also costs about 15–40k tokens per decision and adds a pre-1.0 dependency.
- **Clinic-assumption list — SURVIVED 3–0.** Must include:
  - a per-option "if this is wrong, who notices and when?" tag that feeds it;
  - entries written as plain questions a domain user can answer, each pointing to the file where the answer lives;
  - a reader event: the list is an input to the first hand-off where a real end user touches the product;
  - a one-time backfill of the 14 existing decisions;
  - generic plugin wording, no gate;
  - real commit-first (pick before seeing the recommendation) only on flagged decisions.
- **First step, no sweap change:** take the 14 questions to someone who runs a real clinic before go-live. Judge the list on how many of its entries that person overturns.

## Third round 2026-10-25 (wf_5251bbd3-8a7): two kinds of question

Henrique split the problem in two. Some questions need clinic knowledge to judge. Others need a plainer statement of what is in question. He rejected the "who notices" tag.

- **Clinic questions — SURVIVED 2–1, with changes.** He still decides every question in the session; work never proceeds on the agent's recommendation instead of his answer. An entry is a self-contained question in a clinic owner's words, stating "we assumed X" and pointing to file:line. A different answer comes back through `sweap-note idea` or a direction note; there is no reopen mechanism. The list is read at the go-live hand-off. **Do it by hand first:** backfill the 14, plus F13.10's solo-owner preselect (her exact profile) and the 50-minute "legacy" assumption. Plugin wording only if she overturns at least one.
- **"Explain first" option on every decision — KILLED 3–0.** He never asked for clarification and never picked "Let me think". 5/18 questions already used all 4 option slots. F14.2 already had a 4-step text timeline and he picked 3.4 min later.
- **Background helper agent — KILLED 3–0.** It addresses waiting, which was never the obstacle. No background agent or subagent artifact publish has ever run here.
- **Converged alternative (unrefuted):**
  - Plain-language option labels with no code terms. This is free and covers most of the difficulty: F13.7, F13.9 ×2, FQ.7, F14.3.
  - On demand only (he types "explain" via Other): 3–5 stepped static frames for race/sequence questions, built in the foreground so he can ask follow-ups.
  - A teach-back (he explains it in his own words) before the recommendation is shown.
- **Prototype:** F14.2 explainer https://claude.ai/artifact/KdKUtz4SVVN3KbaQXFFeK2. It tests the text brief against the stepped frames with the same teach-back questions. Success = he passes a teach-back from the frames that he failed from the text.

## Decided and built (2026-10-25): PR #76, 0.39.0

Henrique saw the F14.2 prototype and decided the rest.
- **No teach-back:** "I might have picked it up wrong".
- **Pages on request.** He answers "explain", and every decision question carries a reminder line because he forgets offers otherwise.
- **Each page has a user layer and a technical layer** that he chooses between, with any media.
- **UI choices get their page without asking.**

The build is the `explain` skill. A hostile review of the PR (wf_74699ad8-b84) gave 0 kills in 9 verdicts, and its fixes are applied. The clinic-questions list is still to be done, by hand first.
