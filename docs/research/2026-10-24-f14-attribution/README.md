# F14 audit attribution — the first milestone on the script-stage reviewer

2026-10-24. Same method as [F13's](../2026-10-24-f13-attribution/README.md), on the consumer A F14
audit (`roadmap/audits/F14.md`, range `b1aea23..30ad190`, 28 code findings). Every implementer,
reviewer and fixer ran sweap **0.37.1**: review as a script stage (0.35.0) and the high-effort
reviewer with hunt angles (0.36.0). So this measures the current reviewer; F13 mostly measured the
one before it. Transcripts archived to `~/Documents/consumer-a-f14-transcripts/`. Per-finding detail:
[verification code](findings-verification-code.md) (1, 3, 5, 6, 9, 10, 12, 14, 17, 18, 26),
[invitations](findings-invitations.md) (7, 8, 13, 15, 19, 24, 28),
[reset, migration and the rest](findings-reset-migration-misc.md) (2, 4, 11, 16, 20–23, 25, 27).

## Result

The 28 findings are **16 distinct defects** (the expired-code sweep alone is seven findings).
4 predate the range (lost invitation mail, expired invitations listed Pending, `rate_limit.key`
without a unique index, the `APP_URL` default). Of the **12 introduced in F14**:

| outcome | count | defects (findings) |
|---|---|---|
| caught by a review, shipped anyway | 3 | name residue (2, 21), send-seam spread override (11), accept waits on mail (8) |
| a review looked at the spot and called it sound / raised a neighbour | 5 | resend supersedes the code (12; a recorded non-goal), cancel/reject unguarded (15, 28), mail links open the active clinic (19), reset vs sign-in race (16, 27), migration 0059 re-run (20, 23) |
| missed by every layer | 4 | expired-code sweep (1, 3, 5, 6, 9, 14, 17), resend refused with a session (10, 18), resend vs in-flight verify (26), unverified accounts permanent (22) |

Compared with F13 (4 caught / 7 near / 6 missed of 17), the shape is the same: **no catch was
fixed before merge in either milestone.**

What F14 adds that F13 could not show: the round-1 reproduce-or-fix loop **does** fix what it is
handed. #481's five and #482's four round-1 candidates were all reproduced and fixed (one a real
double-accept race); #473's partial-write on reset was fixed; #470's takeover race became the
#467 blocked flip. Those bugs never reached the audit. The audit's survivors are what went
around that loop.

## Where F14's catches went — three routes, all in today's code

1. **Approve + a fixer that answers `blocked` is a dismissal.** `plugin/workflows/run.js:421-426`
   (unchanged in 0.38.1): after an approve, "anything but a committed change is a dismissal … the
   approve stands". On #470 the round-1 fixer reproduced the name-residue defect, committed
   869fcef, and returned `blocked` with a question. The question was dropped (no blocked flip),
   and 869fcef got no review of its own because `outcome` was not `committed`. The CI reviewer
   then forced it into a `kind: direction` note (`…1816c1`), still untriaged in the inbox.
2. **Round-2+ candidates only reach the PR body.** #481's round-2 reviewer named finding 8 ("a
   hung transport would stall 'Accepting...'"); it went to the PR body's "Unconfirmed candidates
   not acted on", the CI reviewer read that body and let it pass, and it merged.
3. **A CI reviewer advisory inside an approve goes nowhere.** It flagged the send-seam spread
   override (11) twice on #482 as a nit and approved; the run only sends a fixer on a red, and no
   note is filed.

Still open from F13: `kind: direction` notes are read only by `/roadmap` (63 of 86 inbox notes).

## What nobody caught

- **One call below the diff, inside better-auth (class d).** All four verification defects and
  the cancel/reject overwrite. The CI reviewer has no `node_modules` on its runner and said so,
  taking library behaviour from the item's Notes; the in-session reviewers had the exact library
  lines open and read them for the security question they were asked.
- **Concurrency.** Reset vs sign-in, resend vs verify, the rate-limit duplicate rows: every test
  is sequential, and e2e turns rate limiting off.
- **Absences.** Nothing expires an unverified account; `APP_URL` is outside startup validation.
- **A disclosed hazard read as diligence.** Migration 0059's header states the re-run cost and a
  test asserts it (`f14-2-migration.test.ts:184` pins the hazard); both reviewers counted it in
  the PR's favour.
- **A review-driven fix that introduced a false claim, re-approved.** The #481 fixer read only
  accept in better-auth and wrote that accept, reject and cancel are guarded; round 2, security
  (whose own grep showed one `fromStatus` hit) and CI approved it. F13 had the same pattern.
- **A flaky test with no route to a fix.** The expired-code e2e passed only via `retries: 1`;
  the F14.5 implementer measured 3 in 8 failing, filed a note, and #482 merged.

## Corrections to the audit record

The dedup section misses note `…1816c1` (the same defect as findings 2/21 and FR.2).

## The fixes, refuted (workflow wf_436bb2a0-ae4: three hostile reviewers per proposal, premise / wrong-fix / cost, majority kills)

- **Route 1, approve + `blocked` is a block — SURVIVED 2–1, built in 0.38.2.** The fixer's
  `blocked` after an approve now flips the item blocked with its question (and says when its fix
  commit is unreviewed); `gave-up` and an unchanged `committed` stay dismissals, and the fixer is
  told an unreproduced candidate is dismissed, never escalated. The resume after /unblock
  re-implements and reviews the whole branch from round 1, so the fixer's commit is reviewed.
  The dissent (premise): Henrique later answered #470's question with "the name stands" (FR.2,
  #484), so blocking would have cost a round trip for the same code; the real leak there is the
  untriaged direction note. Kept anyway: a reproduced spec question belongs to the human, and the
  change adds no agent call on the usual path.
- **Route 2, a fixer for round-2+ candidates — KILLED 2–1 (wrong-fix, cost).** Later-round
  candidates appear on 14 of 21 merged F13/F14/FQ PRs, and only #481's was a real defect: about
  one hit per 14 extra fixer+reviewer pairs (~30 min and ~450k cache-write tokens each, measured
  on #481). As proposed it also broke the +1 round allowance (the after-approve review lands on
  the last round) and could publish an unreviewed fixer commit. The cheaper alternative the cost
  reviewer offered, filing last-round `[diff]` candidates as discovered notes, is unrefuted and
  not built — and F13 showed notes leak at triage.
