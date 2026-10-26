# F14 attribution — findings 2, 4, 11, 16, 20, 21, 22, 23, 25, 27

Range b1aea23..30ad190. Evidence: git blame at 30ad190, PR diffs/bodies/comments (gh), transcripts in
`~/Documents/consumer-a-f14-transcripts/` (session 74329441 for #466/#470/#473, e3c2e15f for #482).
Plugin version in both run workflows: **sweap 0.37.1** (90 cache-path hits in 74329441, all 0.37.1; the
wf_c7090936 agents in e3c2e15f are 14×0.37.1). So all PRs below ran the 0.35.0 review stage and 0.36.0 reviewer.
Reviewer thinking is redacted; verdicts rest on structured outputs and tool calls.

## Duplicate grouping

- **D1 name residue** = 2 + 21
- **D2 rate_limit.key no unique index** = 4
- **D3 send-seam brand bypass by spread-override** = 11
- **D4 sign-in straddling a reset keeps its session** = 16 + 27
- **D5 migration 0059 re-run verifies unproven accounts** = 20 + 23
- **D6 unverified accounts never expire** = 22
- **D7 APP_URL unvalidated, defaults to localhost** = 25

7 distinct defects from 10 findings.

---

## D1 — first registrant's display name survives the owner's verify (2, 21)

**Introducing PR:** #470 (F14.2), commit 64a5b61. `apps/web/src/lib/auth.ts:431` `beforeEmailVerification`
blames entirely to 64a5b618. **Class (a)**, wholly inside #470 — but scoped by the /unblock answer #469
(a14b3e5), which fixed the contract as "entering the code also sets the password … a duplicate sign-up still
replaces nothing and sends no mail". The answer never mentions the name; the residue follows from it.

**CI reviewer — CAUGHT (round 1, needs-work), then approved once recorded.**
- Round 1 (2026-10-02T11:46Z): "**A reproduced account-takeover residue is dropped without the escalation the
  PR says it made.** … The profile fields the first sign-up chose stay … `user.name` was still 'Mallory' …
  Consumer A has no UI to change a name". Fix asked: "a discovered note or a blocked follow-up item".
  `Findings: important=1 nit=3` / `Verdict: needs-work`.
- Round 2 (12:07Z, at 1b68ea1): "The round-1 finding is resolved … records it in two places" (note 1816c1 + Notes).
  `Findings: important=0 nit=1` / `Verdict: approve`.

**In-session reviewer — CAUGHT.** wf_73294554-61c `review F14.2 #1`
(`subagents/workflows/wf_73294554-61c/agent-a32a3e7c6455bb814.jsonl` L230–231): verdict approve, `findings: []`,
candidate `[diff]` auth.ts:340: "beforeEmailVerification resets only the password. Profile fields the first,
unproven sign-up chose (the display name) survive … the verified account keeps the attacker's chosen name".
Security reviewer (agent-a8da9eb79e1789294, L116): `clear`, nothing on the name.
(The pre-answer round in wf_0f4baffc — agent-a16a5c53019df388f — found the password half as a `security`
finding, which became the #467 blocked flip → #469 answer. That is the correct path working.)

**Where the catch went: round-1 candidate → fixer reproduced it and returned `blocked` → the script dropped the
block.** `review-fix F14.2 #1` (agent-a7121842191757fbe L208, journal line 11): `"outcome": "blocked",
"changed": true, "question": "F14.2: entering the code sets the password, but the display name stays whatever
the first, unproven sign-up chose … Which do you want? (a)…(d)"`. Because the reviewer had *approved*, run.js
(0.37.1 script L421–426) treats it as a candidate-only round: "anything but a committed change is a dismissal,
and the approve stands" → `break`. No blocked flip; the journal goes straight to `security F14.2 #1` →
`publish F14.2`. The question survived only as prose in the PR body ("Recorded for a human" was added later; the
first body said "Returned as the blocked question", which was false). Side effect: the same fixer had committed
869fcef (candidate 3's real fix), and because `outcome` was not `committed`, that commit got no after-approve
review round either (only the security reviewer and CI saw it). This branch is unchanged in sweap 0.38.1
(`plugin/workflows/run.js:426`).
The **CI reviewer** caught the drop and forced the fix agent (`fix F14.2 #1`, agent-a958097ccdfed1ef4) to file
`roadmap/discovered/after-f14-2-…-1816c1.md` — **`kind: direction`**. That note was never triaged: only 64a5b61
ever touched it, triage #476 (2026-10-09) does not read `direction` notes, and it is **still in the inbox at
HEAD**. The audit re-found the defect independently (FR.2, later unblocked 2026-10-10 as option (b), profile
screen); the audit's "Deduplication against the discovered inbox" section does **not** list 1816c1, and FR.2 does
not reference it — same leak shape as F13's findings 15/19.

**Tests:** `auth-email-verification.test.ts` "pre-hijack closed" asserts owner password 200 / attacker password
401 only. The audit's one-line addition (`expect(row.name).toBe('Ana Lima')`) fails on it. The spec's acceptance
named only the password, so the test faithfully tested the spec.

**Single-PR catchable:** yes — every reviewer layer did catch it from the diff; it was a decision, not a detection, failure.

---

## D2 — rate_limit.key has no unique index (4)

**Introducing PR:** pre-existing. `apps/web/src/db/tenant-schema.ts:137-144` blames to 9cd5a54 (#20, FA.3,
2026-07-05). **Class (c) + (d)**: better-auth 1.6.23's database limiter declares `rateLimit.key` `unique: true`
(`@better-auth/core/dist/db/get-tables.mjs:20-22`) and relies on it; consumer A's hand-written schema omits it.
F14 made it load-bearing: #466 (F14.1) switched the bucket key to `cf-connecting-ip`, and #470's spec defers a
per-address resend throttle because "the built-in per-IP limits at least work" (`roadmap/F14.2.md:106`).

**CI reviewer — MISSED** on #466: "**Rate-limit key.** `advanced.ipAddress.ipAddressHeaders: ['cf-connecting-ip']`
replaces the client-appendable `x-forwarded-for`. `auth-client-ip.test.ts` proves … two clients get two buckets"
(`Findings: important=0 nit=4`, approve). Nothing on #470 about the limiter's atomicity.

**In-session — MISSED.** `security F14.1 #1` (wf_0f4baffc agent-a64e7646b2f692310): "The rate-limit IP change is a
fix: better-auth now reads cf-connecting-ip …". `review F14.1 #1` (agent-a99078b0f4747ddbd L83) grepped
`rateLimit` config in auth.ts, no candidate on storage. F14.2 reviewers: no remark.

**Where the catch went:** n/a. (A sibling note, `…incrementone-is-not-a-compare-and-set…-23b277`, exists in the
inbox per the audit's dedup section; not filed by these PRs.)

**Tests:** `auth-client-ip.test.ts` sends requests sequentially; e2e sets `BETTER_AUTH_DISABLE_RATE_LIMIT`. No
concurrent burst anywhere, which is the only way to see the duplicate rows.

**Single-PR catchable:** only-with-cross-file-context — needs the 2026-07 schema plus better-auth's adapter schema; nothing in the #466 diff shows it.

---

## D3 — send seam's brand survives a spread-override (11)

**Introducing PR:** #482 (F14.5). `apps/web/src/lib/email.ts:1,7-13,25` blame to 30ad190a; the claim
("An object literal with `html` in it is a type error") is in the same lines. **Class (a).**

**CI reviewer — CAUGHT, as an advisory, twice; approved each time.**
- Round 1: "**A registered call site can still replace the HTML after the spread** (`packages/emails/src/mail.ts:34-40`,
  e.g. `apps/web/src/lib/auth.ts:390`). `sendEmail({ ...email, html: '<p>…</p>', to, sender: 'auth' })` typechecks
  … It also passes `senderViolations`". `Findings: important=0 nit=2` / approve.
- Round 2: same remark ("Nothing in the tree does this, and it takes deliberate code"). `important=0 nit=4` / approve.
- Round 3 (19:04Z): the remark is gone; it lists the spread call sites as sound. `important=0 nit=4` / approve.

**In-session — MISSED (NEAR).** wf_c7090936-df8 (session e3c2e15f, 0.37.1): `review F14.5 #1`
(agent-ab52da0fbf828f42c) hunted exactly this guarantee's bypasses — alias import, by-reference maker, shell-id
reuse, rules without planted faults — but not spread-override. `review F14.5 #2` (agent-a583336c21a11e034) added
string-key access. Neither touches the brand surviving an override. `review-fix F14.5 #1` (agent-a44541459870c80ec):
"All four candidates reproduced and were fixed in commit 2647ecc" — the R1 mechanism worked fully on what was found.

**Where the catch went:** nowhere. A CI advisory in an approve is not acted on by the run (fixers only run on a red),
and no note was filed (no `roadmap/discovered` note mentions spread/override). The audit re-found it; triage parked it
in FR.10: "a check on a check — no file does it".

**Tests:** `packages/emails/src/inventory.test.ts` planted faults cover alias/by-reference/re-export/casts, not
spread-plus-override; tsc refuses only a bare literal.

**Single-PR catchable:** yes — the CI reviewer did it from the diff alone.

---

## D4 — a sign-in straddling a password reset keeps its session (16, 27)

**Introducing PR:** #473 (F14.3). `auth.ts:372` `revokeSessionsOnPasswordReset: true` blames to e36d295c.
**Class (d)**: better-auth 1.6.23's reset (updatePassword → onPasswordReset → deleteUserSessions) and sign-in
(read hash → verify → createSession) have no ordering; #473 relied on the revoke being a point-in-time delete.
The session.create.before hook (#470) re-reads only emailVerified.

**CI reviewer — MISSED** (both rounds approve, `important=0 nit=3` / `nit=5`). It looked at revocation:
"Single use, superseded links, expiry and session revocation are each asserted …"; "A failed clear is now caught,
so `revokeSessionsOnPasswordReset` still runs".

**In-session — NEAR.** `review F14.3 #1` (wf_73294554 agent-a45fc46c41729a55b) raised the neighbour on the very
sequence: "Partial write if the cleanup fails. better-auth runs updatePassword, then `onPasswordReset`
(clearResetTokens), then `deleteUserSessions`" — reproduced and fixed by `review-fix F14.3 #1`
(agent-a450f017a855010d3, commit 905417a). Round 2 (agent-acff792152587caee): approve, no race. Security
(agent-a5de1b61b17518ccf L85): "revokeSessionsOnPasswordReset: true deletes the user's sessions … a revoked
session cannot keep working from a cache" — clear. No concurrency candidate anywhere (grep for
concurren|race|in-flight|straddl over all five F14.3 agents: none outside the timing/partial-write remarks).

**Where the catch went:** n/a. Audit scheduled it as FR.7 (security).

**Tests:** `password-reset.test.ts` asserts a session existing *before* the reset is refused; all sequential. The
audit needed a forced interleaving (wrapping `ctx.password.verify` with a gate).

**Single-PR catchable:** only-with-cross-file-context — needs better-auth's sign-in and reset internals; the same "lost update" blind spot as F13.

---

## D5 — migration 0059's re-run verifies unproven accounts (20, 23)

**Introducing PR:** #470 (F14.2). `apps/web/drizzle/0059_f14_2_email_verified_backfill.sql` added only by 64a5b61.
**Class (a).** It was **known and documented by the implementer**: the header section "WHAT A RE-RUN COSTS …
Re-run after the gate has shipped … it also verifies accounts that signed up under the gate and never entered
their code", written by `implement F14.2` (wf_0f4baffc agent-a1a71a40fec1321b5 L390/L399). The implementer also
wrote a test that **pins the hazard as expected behaviour**: `apps/web/src/db/f14-2-migration.test.ts:184-185`
"A roll-forward re-applies the backfill: an account made unverified in between is verified again (the re-run
cost the migration's header names)". Finding 20's first half (pre-existing accounts become verified) is the spec's
intent (`roadmap/F14.2.md:91`, :126).

**CI reviewer — NEAR (looked, called it a feature).** Round 1: "It is a re-runnable data backfill. The rollback
block has the newest-migration precondition and its own ledger-row `DELETE`." Round 2 repeats it, adding "runs
the block, the refusal case and the re-run".

**In-session — NEAR.** `review F14.2 #1` (agent-a32a3e7c6455bb814 L230): "**Migration:** `0059` backfills
`email_verified`. Its rollback block has the newest-migration guard and deletes its own ledger row." Earlier round
(agent-a16a5c53019df388f L27–28) read the full header incl. "WHAT A RE-RUN COSTS" and raised nothing. Security: clear.

**Where the catch went:** never raised as a defect; it lived as a header sentence + a test. Audit parked it in
FR.10 (latent, operator step, nothing deployed).

**Tests:** the migration test exercises the re-run and asserts the defective outcome.

**Single-PR catchable:** yes — the hazard is stated in the diff's own header; reviewers read it as disclosure rather than as a defect.

---

## D6 — an account that never verifies is permanent (22)

**Introducing PR:** #470 (F14.2). `auth.ts:360-362` (`requireEmailVerification: true`) blames to 64a5b618.
Before #470 a sign-up was a normal signed-in account, so "unverified, sessionless, forever" did not exist.
**Class (a)**, with better-auth's duplicate-sign-up branch (generic 200, no mail) as the behaviour relied on.

**CI reviewer — MISSED.** Nothing on lifetime/purge in either round.
**In-session — MISSED.** Both F14.2 reviewers walked "Abandoned sign-up: `sendOnSignIn`, plus the
`EMAIL_NOT_VERIFIED` branch" (agent-a32a3e7c6455bb814 L230) — the come-back path only; both grepped `deleteUser`
(L149; agent-a16a5c53019df388f L107) for a different reason. Security: clear. Related but distinct implementer note
`…-5f8aba` (owner signed up first by someone else gets only 'Invalid email or password'), `kind: direction`, still in inbox.

**Where the catch went:** n/a. Audit parked it in FR.10.
**Tests:** none (an absence). **Single-PR catchable:** only-with-cross-file-context — the diff creates the rows; seeing that nothing removes them needs the scheduled handler and a repo-wide grep.

---

## D7 — APP_URL outside startup validation, defaults to localhost (25)

**Introducing PR:** pre-existing. `apps/web/src/lib/server/env.ts:59` `APP_URL: read('APP_URL') ?? 'http://localhost:3000'`
blames to 2ddf8b1 (2026-06-28); before the range APP_URL already built the invitation link (b1aea23 `auth.ts:986`).
**Class (c).** #466 (F14.1) drew the validation line — `parseServerEnv` makes BETTER_AUTH_URL and the transport
mandatory at module load (env.ts:51-55, blame 9c3c8a16) — and left APP_URL out; #473/#481/#482 added more emails
whose links use it.

**CI reviewer — NEAR (#466, #473).** #466: "Every `createAuth` caller still goes through `getServerEnv()`, so the
newly required `BETTER_AUTH_URL` comes through validation everywhere" — reviewed the validation set, no APP_URL.
#473: "The link is built from `env.APP_URL`, not from the request's host" — called sound.
**In-session — NEAR.** `review F14.1 #1` (agent-a99078b0f4747ddbd): candidates on the startup check
("no automated test checks that"; "startup check and the send read different sources") — fixed in round 1 — and
L252 grepped APP_URL in playwright config. Security F14.1: "Every link comes from APP_URL plus the invitation id".
On #482, `review F14.5 #1` candidate 4: the notice's origin is `process.env.APP_URL ?? 'http://localhost:3000'`
and "Would any test fail if the delivered notice linked to http://localhost:3000?"; the fixer reproduced and added
a test, concluding "The preview Worker does receive `process.env.APP_URL`, so there is no live defect" — right for
the preview env, but it answered test strength, not the unvalidated default.

**Where the catch went:** the #482 candidate was turned into a test of the *set* case; the unset case was never
raised. Audit parked it in FR.10 (latent, needs deploy).
**Tests:** none for unset APP_URL; `server-startup.test.ts` covers only the transport vars.
**Single-PR catchable:** only-with-cross-file-context — #466's diff shows the validated set; the missing member is in unchanged env.ts lines.
