# F14 attribution, batch B: findings 7, 8, 13, 15, 19, 24, 28

Range `b1aea23..30ad190`. Evidence: `git blame`/`log` at 30ad190 in ~/Documents/consumer-a,
`gh pr view` comments and bodies, and the transcripts in ~/Documents/consumer-a-f14-transcripts/.
Transcript paths are shortened below:
- `S1` = `74329441-9ea5-4951-9308-f813828caf43/subagents/workflows/`
- `S2` = `e3c2e15f-33c4-42c7-b0d9-647c4cecced2/subagents/workflows/`

Plugin version: every reviewer, fixer and implementer in wf_0f4baffc, wf_73294554 and wf_c7090936
loads `plugins/cache/sweap/sweap/0.37.1/`. So the 0.35.0 script-stage review and the 0.36.0 hunt
angles were both live. The run script copy (`S2/../workflows/scripts/run-wf_c7090936-df8.js`)
has the expected routing:
- round-1 candidates go to a fixer (L361);
- `[pre-existing]` candidates become notes (L407);
- last-round candidates go to the PR body as "Unconfirmed candidates … not acted on" (L458).

## Duplicate grouping

| defect | findings | one line |
|---|---|---|
| A | 7, 24 | A failed invitation send is reported as "Invitation sent." and leaves no way to resend or cancel for 48 h |
| B | 13 | An expired invitation stays listed as Pending for good, and there is no resend or withdraw |
| C | 8 | The accept-invitation response waits on two mail sends with no deadline. A disconnect drops both mails |
| D | 15, 28 | better-auth's cancel and reject are unguarded and overwrite an accepted invitation. The F14.4 wrapper's header claims otherwise |
| E | 19 | Mails about one clinic link to `/app/...` screens that open on the session's active clinic |

13 shares its "no resend/withdraw" half with A. The audit holds all three under FR.4. Its own
claim, expired rows listed as Pending, is a separate defect in a different line, so it is kept
apart.

---

## A — findings 7 and 24: a lost invitation mail is reported as sent, and the pending row blocks a re-invite for 48 h

**Introducing PR: none in the range. Class (c) pre-existing plus (d) library behaviour.**
- The swallow is better-auth 1.6.23's `runInBackgroundOrAwait` (`better-auth/dist/context/create-context.mjs:214-223`).
  It catches a send's rejection and only `logger.error("Failed to run background task:", e)`s it, both with a
  background handler and inline (`else await promise` inside the same `try`). better-auth was 1.6.23 at both
  ends of the range (`apps/web/package.json` at b1aea23 and 30ad190).
- At b1aea23, `sendInvitationEmail` already `await sendEmail(...)` with no catch (auth.ts:985-993), and the
  old `sendEmail` threw on a non-OK answer. The outcome was therefore the same before the range: 200,
  pending, failure only logged. The audit's GATE 3 ("no background handler (inline await): provider 429 still
  => resolves pending") confirms this.
- The "Invitation sent." toast is `ddde00a9` (2026-09-02, members.tsx:369). The control-less Pending tab is
  `19539678`/`d88e327f` (September). All three predate the range.
- In-range PRs that touched the path without changing the outcome:
  - #466 (F14.1) rebuilt `sendInvitationEmail` on the shell (auth.ts:1276-1287 blame 9c3c8a16), still with
    no catch.
  - #473 (F14.3) added `advanced.backgroundTasks` (auth.ts:503-511), so the response now goes out before the
    send. This is finding 24's "200 before the mail is attempted".
  - #482 rewrote line 1288.
  - #481 (F14.4) raised the stakes, since the invitation became the only way in for a newcomer. The audit
    triage says: "No F14 item promised resend or withdraw … F14.4 made the invitation the only way in, which is
    what turns their absence into a 48-hour dead end" (F14.md:98-104, bucket 3, FR.4).

**CI reviewer**
- #466: approve, "Findings: important=0 nit=4". It mentions `sendInvitationEmail` only for permission and
  escaping. **MISSED.**
- #473 round 1: approve, nit=3. It names the library catch as something it relied on and could not read:
  "The library behaviour is therefore taken from the item's Notes … That covers … `runInBackgroundOrAwait`
  catching errors". Its advisory 1 noted that the background handler "applies to every
  `runInBackgroundOrAwait` call", but only for the sign-up code mail. **NEAR at most**: it saw the catch as
  containment, not as a lost mail.
- #481: approve, nit=4. Nothing on send failure. **MISSED.**

**In-session reviewer (0.37.1)**
- #466 (`S1/wf_0f4baffc-bdb/agent-a99078b0f4747ddbd.jsonl` L263, round 1): approve with 8 `[diff]`
  candidates, none on send failure. Round 2 (`agent-af97c57cf66d77cb4`): approve, 3 candidates, none
  relevant. Security (`agent-a64e7646b2f692310`): clear. **MISSED.**
- #473, round-1 reviewer (`S1/wf_73294554-61c/agent-a45fc46c41729a55b.jsonl`, final StructuredOutput), a
  `[pre-existing]` candidate at auth.ts:1250: "The member-invitation and F14.2 verification-code sends have
  no catch of their own. better-auth logs their failures as 'Failed to run background task:' with the whole
  error object. EmailSendError.message embeds Resend's free-text `message`…". **NEAR**: it saw that the
  invitation send's failure only reaches a log, but framed it as log hygiene (an address could leak into
  logs), not as the inviter being told "sent" with no recovery.
- #481 rounds 1/2 and security (`S2/wf_c7090936-df8/agent-a8f2c167…`, `a0917163…`, `a39c1209…`): nothing on
  invite-send failure. **MISSED.**

**Where the near-catch went.** The `[pre-existing]` candidate became note
`invite-and-verification-code-sends-log-raw-error-bodies-not-the-structured-line-d1dbad.md` (kind `gap`,
from F14.3, created 2026-10-02). Triage #476 (1d97c52) archived it with "declined: parked: operator-only
worker logs, not new, and no address reaches a user; F15.7 owns what leaves the worker". By its own framing
that was a fair call; the user-facing consequence was never in the note.

**Tests.**
- No test drives a failed invitation send through the members screen.
- `members.test.tsx` doubles the client.
- e2e uses a working Mailpit.
- The audit needed scratch tests with a 429/ECONNREFUSED transport to show it.
- No retry dependence found; none of the relevant tests are involved.

**Single-PR catchable?** No. It is a product gap: library swallow plus a screen that predates the range. No
F14 diff introduced it, and the audit itself filed it as a design question (FR.4) rather than a defect
against an item.

---

## B — finding 13: expired invitations stay listed as Pending; no resend or withdraw

**Introducing PR: none. Class (c) pre-existing.**
- `members.tsx:318-320` filters `i.status === 'pending'` without `expiresAt` (blame `19539678`, 2026-09-07).
  The fixed `<Badge variant="warning">Pending</Badge>` at :733 is blame `d88e327f` (2026-09-20).
- The only in-range edit to members.tsx is #466, and it only swaps the role `<option>`s for `ROLE_LABELS`
  (`git show 9c3c8a1 -- apps/web/src/routes/app/members.tsx`).
- `proven: none` in the record; it was confirmed by reading.

**CI reviewer**: #466 did not look at the Pending filter. **NOT IN DIFF / MISSED.**

**In-session reviewer**: #466 rounds 1/2. One round-1 candidate touched members.tsx, but only as a
ROLE_LABELS drift risk ("ROLE_LABELS restates the role names the members screen uses … so they can drift
apart"). **MISSED** (out of diff scope).

**Catch went**: n/a. UI block 30 (U02) is the screen view of the same issue; both are under FR.4, now `todo`
after `/unblock FR.4` on 2026-10-10 (F14.md:115-119).

**Tests**: no test seeds an expired invitation into the members screen.

**Single-PR catchable?** No. Nothing in the range introduced it. Reviewing #466 it would need context from
outside the diff; reviewing #481 it would need product reasoning about recovery.

---

## C — finding 8: the accept response waits on two mail sends with no deadline; a disconnect drops both

**Introducing PR: #481 (F14.4), class (a).**
- `apps/web/src/lib/server/invitation-accepted-mail.ts:90`:
  `const results = await Promise.allSettled(mails.map((mail) => mail.then(sendEmail)))`. Blame 8b7cb9a8,
  as is the header :29-32: "The two sends are awaited inside the hook, so a request carries them to
  completion on workerd, which cancels work left running after its response."
- `auth.ts:1094-1095` `afterAcceptInvitation` awaits it.
- `email.ts` at 30ad190 has no `timeout`, `abort` or `signal`.
- The premise was already false at the time. #473 (F14.3) had added `requestScope().background`
  (`waitUntil`), and `backgroundTask` is in scope in `createAuth`. The item's own acceptance line says
  "fire-and-forget, no outbox row" (roadmap/F14.4.md:54), and the implementation awaits.

**CI reviewer** (#481, the only round, head `22e817a`): "Findings: important=0 nit=4 / Verdict: approve".
- On the mails it says only: "**The mails go to the right people.** … It is skipped for a self-invite."
- Its advisory 1 says "The PR body already mentions it" about the *other* round-2 candidate, so it read the
  PR body that carried this candidate (line 29), and still did not raise it. **MISSED.** Arguably it
  dropped a lead it was handed.

**In-session reviewer (0.37.1, `S2/wf_c7090936-df8/`)**
- Round 1 (`agent-a8f2c167eb2e70f78.jsonl` L105): needs-work, 1 finding (lapsed session) and 6 candidates.
  None on a hang. MISSED.
- Fixer round 1 (`agent-a2a63fc2200cc61dd.jsonl` L212): fixed the finding and all 5 `[diff]` candidates.
- **Round 2 (`agent-a09171638797a883f.jsonl` L138): approve, and CAUGHT it as a `[diff]` candidate at
  auth.ts:1101:** "The accept's response now waits on the two mails. `afterAcceptInvitation` awaits
  `notifyInvitationAccepted`, which awaits both `sendEmail` calls, and `apps/web/src/lib/email.ts` shows no
  timeout or abort on a send. A send that FAILS is handled … A send that HANGS or is slow is not: the member
  row and the active clinic are already written, but the reader sits on 'Accepting...' until the transport
  answers. … The existing test only covers a transport that throws."
  - That is the audit's T2/T4 symptom exactly. It does not mention the disconnect-drops-mail half.
- Security (`agent-a39c12093e94731bf.jsonl` L82): clear, nothing on it.

**Where the catch went: a round-2+ candidate that only reached the PR body.** PR #481 body, line 29:
"Unconfirmed candidates not acted on: the accept response waits on the two mails (a hung transport would
stall "Accepting...")".
- The orchestrator saw it in a tool result (`e3c2e15f-….jsonl` L360) and took no action.
- No discovered note carries it: there is no hit for "hung transport", "Accepting" or "waits on the two
  mails" under roadmap/discovered at 30ad190.
- The CI reviewer read the body and dropped it.
- Merged 2026-10-09T16:10. The audit later re-found it, and it is FR.5 (todo, outage).

**Tests.** `lib/invitation-accepted-mail.test.ts` covers a transport that throws ("logged, accept succeeds")
and the concurrent-accept race. It has no stalled-transport or client-abort case, as the round-2 reviewer
said.

**Single-PR catchable?** Yes. The round-2 reviewer caught it from the diff plus `email.ts`.

---

## D — findings 15 and 28: cancel and reject overwrite an accepted invitation; the wrapper header says they are guarded

**Class (d) third-party library behaviour, also (c) at the endpoint level. #481 wrote down the opposite of
what the library does.**
- better-auth 1.6.23's `crud-invites.mjs`:
  - accept passes `fromStatus: "pending"` (L285-288);
  - reject (L393) and cancel (L447) call `updateInvitation` without it;
  - cancel checks only `if (!invitation)` (L428).
  - `adapter.mjs:677` adds the status clause only `if (data.fromStatus)`.
- The cancel endpoint was mounted and unguarded before the range too, with no `disabledPaths` entry at either
  end. So "accept, then cancel → canceled with a member row" was already reachable through the raw API at
  b1aea23.
- #481 added `apps/web/src/lib/server/invitation-status-move.ts`, whose header :12-13 (blame 8b7cb9a8)
  states "better-auth accepts, rejects and cancels an invitation with a guarded update,
  `updateInvitation({ status, fromStatus: 'pending' })`". It also added the accept-time mails, which go out
  while the row ends up canceled.
- **Origin of the false sentence: the review-fix agent.**
  - Round-1 candidate 4 asked for a concurrent-accept test ("I checked the hook's call site at
    crud-invites.mjs:285-290 and the claim holds").
  - The fixer (`S2/wf_c7090936-df8/agent-a2a63fc2200cc61dd.jsonl`) reproduced a real double-accept and wrote
    the wrapper (L165 `cat > src/lib/server/invitation-status-move.ts`).
  - Its only library reads were `sed -n 240,330p crud-invites.mjs` (accept only, L83) and
    `updateInvitation` in `adapter.mjs` (L122). It never read reject or cancel, then generalised to all
    three.
- No product code calls cancel or reject. The CI reviewer noted this ("Nothing else in `apps/web/src` calls
  … `rejectInvitation`"), and so did triage: "endpoints no product code calls" → FR.10, deferred, no harm
  class.

**CI reviewer** (#481): "**The concurrent-accept fix** … the takeover is narrow … Everything else, including
better-auth's unguarded reset, passes through untouched. Moving the guard from the sub-select onto the row
is the right fix". Advisory 4 is also on this file, about the outer `db` and transactions. It could not read
the library: "I could not read better-auth 1.6.23's source: the `incrementOne` shape, `crud-invites.mjs`
line citations…". **NEAR**: it reviewed the exact file and accepted its false premise on the PR's word.

**In-session reviewer (0.37.1)**
- Round 1 (`agent-a8f2c167…` L105) verified only accept's guard (candidate quoted above). **NEAR.**
- Round 2 (`agent-a09171638797a883f.jsonl`) read `adapter.mjs` `updateInvitation` (L48) and accept's body
  (L51, L92), not reject or cancel. It approved with no candidate on the wrapper. **MISSED/NEAR.**
- Security (`agent-a39c12093e94731bf.jsonl`, L36-37): grepped `fromStatus` across the whole `crud-invites.mjs`.
  The output shows a single hit, `288: fromStatus: "pending"` (accept). That contradicts the header it then
  approved: "Security verdict: clear". **NEAR**: the disproving evidence was on screen.

**Where the catch went**: no catch.
- The fixer's note `better-auth-s-drizzle-incrementone-is-not-a-compare-and-set-on-postgres-…-23b277.md`
  (kind `direction`, still in the inbox) is about `incrementOne`'s other callers and the missing
  `member(organization_id,user_id)` unique index, not cancel or reject.
- The audit keeps that note in the inbox, out of scope for FR.3.
- #472/#474 (block/unblock F14.4) are about inviter-minted inbox proof and do not touch this. The first
  F14.4 attempt's round-1 TOCTOU candidate (`S1/wf_73294554-61c/agent-ad4da01d5f989c03a.jsonl`, "A cancel
  or accept that lands between the check and the write…") was against the discarded
  `invitations.$invitationId.sign-up.ts` route, so it is not this defect.

**Tests.**
- `invitation-status-move.test.ts` covers only the accept shape. It pins the one-clause `where` (the shape
  cancel and reject send) as "the unguarded reset to pending" that passes through untouched.
- No test runs accept followed by cancel or reject.
- The race test in `invitation-accepted-mail.test.ts` is accept against accept only.

**Single-PR catchable?** Only with library internals. The header's claim is checkable by reading two more
functions in `crud-invites.mjs`, and the security reviewer's own grep showed it.

---

## E — finding 19: mails about one clinic link to screens that open on the active clinic

**Two separate PRs, each (a), with the same pattern. This is not an interaction.**
- #481 (F14.4), `packages/emails/src/templates/invitation-accepted.tsx:51-52` (blame 8b7cb9a8):
  ``<EmailLink href={`${appUrl}/app/members`}>``.
- #482 (F14.5), `packages/emails/src/templates/sms-allowance-exhausted.tsx:24`, `:59` (blame 30ad190a):
  `` smsAllowanceBillingUrl = (appUrl) => `${appUrl}/app/settings/billing` ``.
  - At b1aea23 the exhaustion mail (`notifications.ts:338-370`) had no link, only the text "upgrade your plan
    in Settings → Billing". So the clickable link is new in #482.
- The target screens resolving against the session's active clinic predates the range.

**CI reviewer**
- #481: nothing on the link. **MISSED.**
- #482, all three rounds approve (nit=2/4/4). Round 1: "`/app/settings/billing` resolves through
  `settings_.$section.tsx`". Round 3: "`/app/settings/billing` is a real route". **NEAR**: it checked that the
  link resolves, not which clinic it opens.

**In-session reviewer (0.37.1)**
- #481 rounds 1/2 and security: no candidate on the link. **MISSED.**
- #482 round 1 (`S2/wf_c7090936-df8/agent-ab52da0fbf828f42c.jsonl`) raised a `[diff]` candidate on the same
  link's *origin*: "The allowance notice is the one shell email whose origin comes from
  `process.env.APP_URL ?? 'http://localhost:3000'` … The spec asserts only that the text part contains
  `/app/settings/billing`". The round-1 fixer (`agent-a44541459870c80ec.jsonl` L129) "REPRODUCED, FIXED
  (tests only)", pinning the origin. So the round-1 mechanism worked on that candidate, but nobody asked
  about the clinic. **NEAR.**
- Round 2 (`agent-a583336c21a11e034`): approve, only checks.ts candidates. MISSED.

**Catch went**: no catch. The audit filed it as FR.8 (todo, wrong-data).

**Tests.** The e2e for the SMS notice checks the link's origin and path against `baseURL`. The F14.4 e2e
checks the mails' existence and shell. Neither has a recipient who belongs to two clinics.

**Single-PR catchable?** Only with cross-file context. You need to know that `/app/*` resolves against the
session's active organization and that a user can belong to several clinics. Neither is in the diff.
