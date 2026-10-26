# F14 attribution — part A: email verification code, expiry, resend (findings 1, 3, 5, 6, 9, 10, 12, 14, 17, 18, 26)

Range b1aea23..30ad190; record `roadmap/audits/F14.md`. Evidence: git blame at 30ad190, PR #470 comments and
body (gh), the run journal and subagent transcripts in
`~/Documents/consumer-a-f14-transcripts/74329441-9ea5-4951-9308-f813828caf43/subagents/workflows/`
(wf_0f4baffc-bdb = first F14.2 attempt, flipped blocked as #467; wf_73294554-61c = the attempt that became #470,
also F14.3 #473), CI e2e logs of every CI run 2026-10-02..10-10.

**Plugin version:** every F14.2 / F14.3 agent ran sweap **0.37.1**: 59 cache paths in wf_0f4baffc-bdb, 29 in
wf_73294554-61c, none of any other version. So these PRs had the R1 script-stage review (0.35.0), the 0.36.0 effort and
reproduce-or-dismiss change, and the 0.37.0 hunt angles at xhigh.

## Grouping

**D1** = 1, 3, 5, 6, 9, 14, 17 (better-auth's table-wide sweep of expired rows turns OTP_EXPIRED into INVALID_OTP; the e2e test races it) ·
**D2** = 10, 18 (resend refused when the browser has a session) ·
**D3** = 12 (a resend replaces the live code; no per-address bound) ·
**D4** = 26 (resend racing an in-flight wrong-code verify)

All four come from **PR #470 (F14.2, 64a5b61)**. None was raised as a finding by any review layer. Only D3 had a
neighbouring candidate, and the fixer dismissed it, correctly, as the spec's recorded non-goal.

---

## D1 — expired code answered as a wrong code (findings 1, 3, 5, 6, 9, 14, 17)

**Introducing PR.** #470. Class **(d), relied on better-auth 1.6.23 behaviour, inside one PR.** Blame at 30ad190:
- the emailOTP plugin config (`auth.ts:1295-1301`, `allowedAttempts`, `expiresIn`) is 64a5b618 (#470);
- `verify-email.tsx` REFUSALS, which map OTP_EXPIRED to "This code has expired", are 64a5b618;
- the e2e test `f14-2-email-verification.public.spec.ts:176-205` is entirely 64a5b618.

The library behaviour: `internal-adapter.mjs` `findVerificationValue` deletes every `verification` row with
`expiresAt < now` unless `verification.disableCleanup` is set. `atomicVerifyOTP` throws OTP_EXPIRED only when
`existing` is non-null.

Later PRs did not cause the defect but are connected to it:
- **#473 (F14.3, landed second)** wrote the `verification: { storeIdentifier }` block at `auth.ts:485-490`, the line
  the audit cites (blame e36d295c). That block is the natural place for `disableCleanup`.
- #473 also added forgot-password, one more endpoint that triggers the sweep. Another user's verify triggers it on #470
  alone (audit proof 1, case C; proof 3, G2), so #473 is not needed for the defect.
- `retries: process.env.CI ? 1 : 0` predates the range (c72eb0c, 2026-06-27).

**CI reviewer (#470): MISSED.** It looked at the exact spot and called it sound.
- Round 1 says: "I could not fetch the better-auth 1.6.23 source from this runner (no network, no `node_modules`), so I
  checked behaviour against what the PR's tests assert".
- Round 2 (approve) says of the racy test: "The e2e expiry update uses `now() AT TIME ZONE 'UTC'`, which is correct for
  the `timestamp` … `expires_at` column."
- Verdicts: round 1 `Findings: important=1 nit=3 / Verdict: needs-work` (the name residue, finding 2); round 2
  `Findings: important=0 nit=1 / Verdict: approve`.

**In-session reviewers: MISSED by every agent.**
- `review F14.2 #1` (agent-a32a3e7c6455bb814, wf_73294554-61c): approve, no findings, 5 candidates, none about expiry.
  It read `atomicVerifyOTP` (L51, L36), which holds the `existing && existing.expiresAt < now → OTP_EXPIRED` branch.
  It did not open `findVerificationValue`. Its acceptance walk calls the clause covered: "Wrong, fourth-attempt and
  expired codes; single use: each has its own vitest, and the expired case is also checked in Playwright" (L230).
- `security F14.2 #1` (agent-a8da9eb79e1789294): "clear", no findings. It also read `atomicVerifyOTP` (L45).
- First attempt (wf_0f4baffc-bdb), `review F14.2 #1` (agent-a16a5c53019df388f, L190): the same acceptance walk, "Wrong,
  fourth-attempt and expired codes: vitest and Playwright".
- **The sweep code was in four agents' context and no agent connected it to OTP_EXPIRED:**
  - the first F14.2 implementer (agent-a1a71a40fec1321b5 L100-101, `sed -n 573,700p internal-adapter.mjs`, read for
    disabledPaths and consumeVerificationValue);
  - `review F14.3 #1` (agent-a45fc46c41729a55b L68);
  - `security F14.3 #1` (agent-a5de1b61b17518ccf L56).

  The F14.3 reviewers were reviewing the very `verification:` block where `disableCleanup` belongs.

**Where the catch went.** Nothing was caught before merge. The symptom was later filed by the **F14.5 implementer**
(e3c2e15f, wf_c7090936-df8, agent-acd07471d695d8c51, L393-L415). It ran `--repeat-each 8`, found the test failing "3 of
8 on an unmodified copy of main 8b7cb9a", and filed it as a `kind: gap` note, "Not diagnosed"
(`roadmap/discovered/archive/the-expired-code-e2e-test-fails-about-three-runs-in-eight-on-main-d6eed7.md`, created
2026-10-09). The audit (#483) promoted it to FR.1. F14.5 (#482) merged with the flake known and unfixed; the note says
"CI retries once … so it passes there".

**Tests.**
- Vitest "an expired code is refused with its own error" sends one request at a time on a per-worker database, so the
  sweep never runs between ageing and submit. It cannot see the race (finding 5).
- The e2e test covers the path and does fail. It ages its own row on the database shared by 4 workers, and any other
  worker's verify, sign-up or forgot-password sweeps the row first. On PR #470's own CI it passed first time (job
  110825860906, "✓ 353 … (2.5s)").
- **Measured across CI:** the test ran in 8 PR runs from 10-02 to 10-10. Push runs on main skip e2e. One run, FQ.16
  (run 37860797735, 2026-10-08), logged "✘ 354 … an expired one is refused differently" and passed on retry. It
  **passes only through `retries: 1`**.
- Locally the audit measured 4 failures in 8 and 4 in 20 at 4 workers, 0 serial, and 0 with `disableCleanup`.

**Single-PR catchable?** **Only with cross-file context.** The diff never shows the sweep: it sits in better-auth's
`internal-adapter.mjs`. The CI reviewer has no node_modules. The in-session reviewers did, and read the function that
calls it.

---

## D2 — "Send a new code" refused when the browser holds a session (findings 10, 18)

**Introducing PR.** #470. Class **(a)+(d)**. `verify-email.tsx:146-171` `onResend` and its comment ("the server answers
alike for an address that is waiting for a code and one that is not") are blame 64a5b618. The code assumes the no-session
branch of better-auth's core `/send-verification-email` (`email-verification.mjs:95-121`): with a session, line 118
throws EMAIL_MISMATCH and line 119 throws EMAIL_ALREADY_VERIFIED, and no code is sent. `sign-up` and `verify-email`
neither redirect nor sign out a signed-in visitor. #481 (F14.4) changed only the callbackURL and footer of
verify-email.tsx (blame 8b7cb9a8 at 130-137 and 180-200), not the resend.

**CI reviewer (#470): MISSED.** It called the exact behaviour sound: "Resend answers `{status:true}` for every address"
(round 1, Checked and sound > Enumeration). No session case is considered.

**In-session reviewers: MISSED.** All three had the exact throwing lines in context:
- `review F14.2 #1` (a32a3e, L59, the email-verification.mjs dump containing EMAIL_MISMATCH);
- `security F14.2 #1` (a8da9e, L54);
- the first-attempt reviewer (a16a5c, L100-104, an explicit `grep … EMAIL_ALREADY_VERIFIED … session`).

None raised the signed-in case. The security reviewer's verdict line describes only the session-less contract: "Codes
are only sent to unverified addresses: the core resend skips verified ones". The closest neighbour is the first-attempt
reviewer's `[diff]` advisory: "Someone who already has a verified account and signs up again lands on 'We sent a code…',
gets nothing from resend, and is only offered 'Sign up again'" (a16a5c L190). That is the signed-OUT dead end. #470
answered it with the Sign-in footer link.

**Where the catch went.** No catch.

**Tests.**
- `verify-email.test.tsx` mocks `sendVerificationEmail` to resolve `{status:true}`.
- The handler vitest "a resend reaches only an unverified address" calls without a cookie.
- The e2e resend click happens on a page with no session.

No test carries a session into resend.

**Single-PR catchable?** **Only with cross-file context.** The diff calls `authClient.sendVerificationEmail`; the
session branch is in better-auth's `email-verification.mjs`, which every in-session reviewer had open.

---

## D3 — a resend replaces the live code, unbounded per address (finding 12)

**Introducing PR.** #470. Class **(d)**: emailOTP's resend mints a new code that supersedes the old one, a superseded
code counts as a wrong attempt, and better-auth's rate limit is `ip|path` only. The decision is recorded in
`roadmap/F14.2.md` (lines 101-107): "Non-goal, recorded with its risk: no application-level throttle on
`resend-verification`. Henrique deferred it explicitly … Revisit it in F15". The audit itself parked 12 in `FR.10` as
"F14.2's recorded non-goal". **This is an accepted risk, not a leak.**

**CI reviewer (#470): MISSED.** It wrote only "Resend answers `{status:true}` for every address" and has no remark on
code replacement.

**In-session reviewer: NEAR.** Same harm, different vector. `review F14.2 #1` round-1 candidate 1 (scope `diff`;
journal wf_73294554-61c line 8):
> "/email-otp/verify-email … gives away whether an address has an unverified account … The same calls also let any
> anonymous caller burn the owner's pending code."

That is third-party invalidation by wrong guesses, not by resends.

**Where the catch went.** The candidate was a **round-1 candidate dismissed by the fixer** (`review-fix F14.2 #1`,
agent-a7121842191757fbe; journal line 10):
> "the behaviour is real, but it is dismissed as a defect, with evidence … a per-address throttle is its recorded
> non-goal."

The dismissal is recorded in F14.2.md Notes (lines 238-246) as "The same calls let anyone spend a pending code; the
owner gets a new one by resending".
- **The evidence is half right.** The non-goal is real.
- **"The owner gets a new one by resending" is the remedy finding 12 defeats:** a third party can resend too, and each
  resend supersedes the owner's code.
- No round 2 ran, because round 1 was an approve and the fixer committed for candidate 3 under outcome `blocked`. The PR
  body carries the dismissal.

**Tests.** No test has a third party resend for someone else's address. The vitest checks single-use and the attempt
count only.

**Single-PR catchable?** **Only with cross-file context** (emailOTP's resend and verify semantics). It is also a
spec-level non-goal, so a catch would not have been fixed.

---

## D4 — resend landing during an in-flight wrong-code verify (finding 26)

**Introducing PR.** #470. Class **(d)+(a)**. The client side: `verify-email.tsx` guards submit (`submittingRef`, lines
102-103) and resend (`resendingRef`, lines 147-148) independently, so both can be in flight (blame 64a5b618). The server
side is better-auth's `atomicVerifyOTP`: it consumes the latest row, deletes every row for the identifier, and on a wrong
code re-creates the OLD value with attempts+1, with no transaction around the resend's insert.

**CI reviewer (#470): MISSED.** No remark on concurrent submit and resend.

**In-session reviewers: MISSED.** They looked at the exact function: `atomicVerifyOTP` was read by
- `review F14.2 #1` (a32a3e L51);
- `security F14.2 #1` (a8da9e L45);
- `review-fix F14.2 #1` (a71218 L34);
- the first-attempt reviewer (a16a5c L130, an explicit `grep -n "runWithTransaction"` plus `atomicVerifyOTP -A30`).

Better-auth's own comment in that dump says "When the submitted code is wrong the record is recreated with the same
value". No agent asked what a concurrent insert does to that. The 0.37.0 hunt angle "Late and repeated work …
check-then-act without a guard" was in the brief.

**Where the catch went.** No catch.

**Tests.** No test runs submit and resend concurrently. The jsdom test mocks both calls.

**Single-PR catchable?** **No.** The interleaving lives inside better-auth's verify. A reviewer could only suspect it from
the library source, and proving it took a forced interleaving against real Postgres (audit proof 26).

---

## Observations

1. **The 0.35-0.37 mechanisms worked as designed on #470 and still caught none of these four.** Round 1 raised 5
   candidates. The fixer reproduced and fixed one (candidate 3, commit 869fcef), escalated one, and dismissed two with
   evidence. None of the candidates was D1-D4. In this group the leak is not the hand-off: **the reviewers never saw the
   bugs.**
2. **Every defect lives in better-auth behaviour one call below the diff.**
   - The CI reviewer cannot see it: it states that it has no node_modules and judges library behaviour "by the PR's
     tests". It then called two of the defective spots sound ("Resend answers {status:true} for every address"; the
     e2e expiry UPDATE is "correct").
   - The in-session reviewers had the exact library lines in context: the sweep in 4 agents, EMAIL_MISMATCH in 3,
     atomicVerifyOTP in 4. They read for the security question they were asked (pre-hijack, enumeration) and walked
     acceptance 5 to a test without asking whether that test could flake.
3. **The flake signal existed before the audit but went to a note.** `retries: 1` hid the D1 test's failures: 1 failed
   attempt in 8 PR runs. Locally it fails about 3 to 4 times in 8. The F14.5 implementer measured it, filed a
   `kind: gap` note "Not diagnosed", and #482 merged on top of it. Triage did not park it: the audit promoted it to FR.1
   the same day. Still, a known-red test on main had no route to a fix inside the run.
4. **A side effect on #470 that is not one of these findings.** `review-fix F14.2 #1` returned `outcome: blocked` with
   `changed: true` (a committed code fix plus an escalation question). Under the round-1 approve path, run.js treats
   anything but `committed && changed` as a dismissal and breaks the loop. So:
   - **the blocked question was silently dropped**; only the CI reviewer's needs-work forced it into a note (1816c1);
   - commit 869fcef got no scoped re-review, only the later security pass.

   This belongs to finding 2's attribution, but it is a mechanism leak in the new review stage.
5. **D3 is a recorded, accepted non-goal.** The fixer's dismissal cites it correctly. Its secondary claim, "the owner
   gets a new one by resending", is exactly what finding 12 shows can be defeated.
