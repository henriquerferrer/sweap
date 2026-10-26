# F13 audit attribution: findings 4, 8, 11, 13, 15, 19

Repo: ~/Documents/consumer-a. Range 5f69472..96c2162. All blame is at 96c2162.
Transcripts: ~/Documents/consumer-a-f13-transcripts/ (abbreviated below as `T/`).

**A PR title misleads.** PR #444 is titled "docs(F13.9): record the premise check that blocks the item", but it is the whole F13.9 implementation (merge 57ec206). Its CI reviewer told the author to retitle it. Blame sha `57ec2064` is F13.9.

---

## 4. Service rename's calendar re-sync can overwrite a concurrent cancel's delete intent

**Introducing PR: #444 (F13.9), merge 57ec206. Class (a)**, built on unchanged pre-range machinery.
- `services.ts:98-110` is all `57ec2064`: the unlocked `SELECT ... status='scheduled' AND start_at > now`, then `for (...) await enqueueCalendarSync(tx, ...)`.
- The overwrite mechanics predate the range and #444 did not change them:
  - `upsertJob`'s `onConflictDoUpdate set desiredState` comes from `6c4f9b04` (F9.2, #117, 2026-08-11) and `062bba09` (#229).
  - At 96c2162 the drain's `effective = job.desiredState === 'upsert' && ctx.ownedByConnection ? 'upsert' : 'delete'` (calendar-sync.ts:780) has no cancelled check. That check was added later by FQ.2 (#455).
- The new code path was the trigger, so #444 is the introducer.

**CI reviewer: MISSED.** Four reviews ran (3051163 → b4bbade, final verdict approve). The only concurrency remark covers the rename against booking/reschedule, not against cancel:
> "**Locking.** Booking and reschedule take `FOR KEY SHARE` on the service and a rename takes `FOR NO KEY UPDATE`. Those two modes don't conflict, so this adds no lock cycle."

It also cleared the rename re-sync on tenancy grounds only ("the `updateService` rename re-sync all join `services` inside `withTenant`").

**In-session reviewer: MISSED.** Files: `T/a55b2a72.../subagents/workflows/wf_3d827b43-477/`.
- sweap:reviewer #1 (`agent-a18c21982bbbd894b.jsonl` L173, needs-work) and #2 (`agent-abea0c7fd8b924974.jsonl` L209, approve) never raise a cancel race. Their assistant text has no "cancel race", "concurrent" or "overwrite" mention.
- security-reviewer (`agent-a203c71f7e699c5be.jsonl` L64) was "clear" and looked only at tenancy.
- Review round 2 ran before the two CI-driven fix commits, but those fixes touched only appointment-invoice.tsx. The services.ts code that merged was reviewed.

**Tests:** #444 added a calendar-sync test with a cancelled appointment. It calls `cancelAppointment` and then `drain()` *before* the rename and asserts no job, so it covers only the sequential case. No test interleaves a cancel with the rename's loop.

**Other signals:** none before the audit. No discovered note mentions the race. The later FQ.2 work filed `backfillfutureappointments-can-overwrite-a-cancel-job-with-upsert-ff40c6.md` for the sibling loop.

**Single-PR catchable: only-with-cross-file-context.** The loop is in the diff. Seeing the bug also needs the pre-existing `cancelAppointment` → `enqueueCalendarUnsync`, `upsertJob`'s blind overwrite, and the drain's missing status check, none of which are in the diff.

---

## 8. An 'unrestricted' clinic still refuses any booking that crosses local midnight

**Introducing PR: #407 (F13.4), merge 29853c8. Class (a)**, built on pre-range mechanics.
- `effectiveAvailabilityRules` (`availability.ts:281-302`) is all `29853c8a`. It adds seven per-weekday `[0,1440)` windows.
- The start-date-only resolution predates the range:
  - `localDateOf(startAt)` → `resolveAvailability` at `appointments.ts:200-202` is `5bce84db`, F5.1 #47.
  - The single-window containment in `isWithinAvailability` is `5bce84db` / `4633f8a5`.
- #407 is what promised "any time is bookable" (F13.4.md: "false means unrestricted (any time bookable)"), so the broken promise is #407's.
- The 1440-minute variant became reachable only once #408 (F13.5, merged after #407) added durations. The 23:30+60 case needs only #407.

**CI reviewer: MISSED.** Two reviews, both approve.
- Review 1: "Findings: important=0 nit=0".
- Review 2: one nit, about the practitioner-scope save flipping the clinic flag.
- It praised the change as "Correct 'unrestricted vs closed' split" and never mentions midnight or multi-day intervals.

**In-session reviewer: CAUGHT, but it never reached the implementer and nobody fixed it.**
- The implementer `T/c0e2d909.../subagents/workflows/wf_8e053136-694/agent-a0d6fa726d23cf568.jsonl` launched `/code-review high` in the background (L415). It then pushed and opened the PR without the result. Its StructuredOutput (L470) says:
  > "reviewer_verdict: none: sweap:reviewer could not be dispatched (this session has no Agent tool). A code-review skill run was launched in the background but had not returned when the PR opened."
- The code-review fork (`T/c0e2d909.../subagents/agent-ad8680ad3e96f1d01.jsonl` L134) filed it as finding #2:
  > "'Unrestricted' is built as seven separate 00:00-24:00 windows, one per day, and the booking check only looks at the start date's windows, so an appointment that crosses midnight is refused. ... A never-configured clinic books 23:30-00:30 ... throws OutsideAvailabilityError"

  It also reported: "my message to agent `a0d6fa726d23cf568` failed with 'No transcript found for agent ID'".
- The orchestrator relayed it to Henrique (`T/c0e2d909...jsonl` L101, L110). L110 reads:
  > "Decision for you: #407 is still at commit 404ddcd ... None of its ten findings have been fixed, including ... an appointment that crosses midnight is refused ... Otherwise the gate decides"

  The run was then stopped. #407 was later rebased and merged unchanged through the merge watcher of session 6e939c5c.

**Tests:** `unrestricted-hours.test.ts` "books a future appointment at any hour" uses one slot, `EARLY` = 02:00–03:00Z on a single local day. `availability.test.ts` "bookable at any hour of any weekday" tests the pure resolver per day. No test crosses midnight or uses a 24h duration.

**Other signals:** the F13.4 spec says "any time bookable". The audit later made it FQ.8, which was unblocked as "outside-hours bookings warn instead of refuse".

**Single-PR catchable: yes.** An in-session reviewer of exactly this diff did catch it. The lost hand-off (background fork, no wait, a SendMessage to a dead agent id) is why it shipped.

---

## 11. Reschedule's unlocked status check lets it overwrite a concurrent cancel

**Introducing PR: pre-existing. Class (c)**, amplified in range by #421 (F13.13).
- The defect is the unlocked read plus `status !== 'scheduled'` check and the id-only UPDATE (`appointments.ts:463-477`, `525-535`). Those lines are `63a9d7d6` = F2.2 #22, 2026-07-06.
- The un-filtered `upsertReminderRow` call (L539) is `fabbb369` (F2.4 #24). The `enqueueCalendarSync` call is `6c4f9b04` / `062bba09`.
- In range:
  - #421 (2e39b92, F13.13) added the rules `FOR KEY SHARE` lock (L460-461). It rewrote `upsertReminderRow` to insert one row per rule and channel (`reminders.ts:342-430`, `2e39b92a`), which multiplies the reminders the race re-arms.
  - #444 (F13.9) touched the function at L470, 484-488, 531 and 543 (serviceId and type).
- **The audit's text "F13.10 rewrote this function" is not supported by blame.** #449 (96c2162) changes no line in `lib/server/appointments.ts`. The in-range editors are #421 and #444.

**CI reviewer: MISSED** on both in-range PRs that touched the function.
- #421 (approve) reviewed reschedule locking only for lock order: "bookings/reschedules take rules `FOR KEY SHARE` first (appointments.ts:213,397). Deadlock-freedom is exercised by real blocking tests". It never mentions the appointment row or a cancel.
- #444: same "Locking" paragraph as in finding 4, plus "reschedule still loads the target through `ownershipScope`". No status race.

**In-session reviewer: MISSED.**
- #421: sweap:reviewer `T/6e939c5c.../subagents/agent-a3309f3b6e4fb4f01.jsonl` L116 (needs-work) found a settings-save/rules-save deadlock, a stale timezone read, and comment drift. Its non-blocking notes mention "an older gap in the per-appointment reconcile that could send a second reminder for the same appointment time". That is the same-instant-duplicate class, not the cancel race.
- #421: code-review fork `agent-ab3c81cef7bd2c09c.jsonl` L131 and security-reviewer `agent-aa2646255fdda86b1` have no "cancel" mention.
- #444: the reviewers in `wf_3d827b43-477` have no mention either.

**Tests:** #421's blocking tests (`reminder-cadence.test.ts`) cover a settings save against a booking. No test races a reschedule against a cancel.

**Other signals:** none before the audit. Later notes `reschedule-update-skips-the-ownership-check-other-mutations-repeat-491f1e.md` and `setappointmentstatus-un-cancels-...-b199b3.md` led to FQ.14 (#477).

**Single-PR catchable: only-with-cross-file-context.** The race lives in untouched lines of a function both PRs edited. Seeing the bug needs `cancelAppointment` and `upsertReminderRow`'s lack of a status filter.

---

## 13. Cancel and status endpoints silently dropped `type` from their response when F13.9 removed the column

**Introducing PR: #444 (F13.9), merge 57ec206. Class (a).**
- Migration 0057 drops `appointments.type`.
- #444 added `AppointmentWrite = Appointment & { type: string }` and patched only create and reschedule (`return { appointment: { ...updated[0], type: serviceName } ... }`, L543 `57ec2064`).
- `cancelAppointment` and `setAppointmentStatus` (`appointments.ts:549-589`, `63a9d7d6`, unchanged) still `.returning()` the raw row. `routes/api/appointments.$appointmentId.cancel.ts` returns `json({ appointment })`.
- The client contract (`lib/queries/appointments.ts`) still types these responses as `{ appointment: AppointmentDto }`, and `AppointmentDto` requires `type`.
- #444's design note (`docs/superpowers/specs/2026-09-28-f13-9-appointment-service-id.md`) scopes the guarantee to two endpoints: "Create and reschedule return the written row with the same `type`, so the API's response shape does not lose the field."
- The implementer's own doc-comment says the same (`agent-a8b67ad7467ae98a4.jsonl` L781): "so the write responses keep carrying the field the read DTO carries".

**CI reviewer: MISSED.** No review mentions cancel or status responses. The one related remark is about tests: "Two `expect(...type)` assertions were replaced by equivalent `serviceId` assertions". Those were the reschedule assertions, `ok?.appointment.type` → `.serviceId`.

**In-session reviewer: MISSED.**
- Reviewer #1 (`agent-a18c21982bbbd894b.jsonl`) listed the routes directory: L47 shows `appointments.$appointmentId.cancel.ts` and `appointments.$appointmentId.status.ts`. It raised nothing about them.
- Reviewer #2 and the security reviewer raised nothing either.

**Tests:** the cancel and status vitests assert only `.status` (`appointments.test.ts:552-568`), never the response's keys. `json()` erases the type at the HTTP boundary, so typecheck cannot catch the DTO mismatch.

**Other signals:** the design-note clause above is a spec clause that names exactly two of the four write endpoints.

**Single-PR catchable: only-with-cross-file-context.** The column drop and the create/reschedule patch are in the diff. `cancelAppointment` and `setAppointmentStatus` sit in the same file but in untouched hunks, and their routes are not in the diff. The question to ask is "who else returns this row?"

---

## 15. Service rename makes 3-4 sequential round trips per future appointment inside one transaction that holds the service row lock

**Introducing PR: #444 (F13.9), merge 57ec206. Class (a).** `services.ts:78-84` (`FOR NO KEY UPDATE`) and `98-110` (the per-row awaited loop) are all `57ec2064`.

**CI reviewer: CAUGHT as advisory, then accepted as already filed.** Reviews 2–4:
> "`apps/web/src/lib/server/services.ts:98-110`: the rename enqueues one calendar sync per future appointment inside the request transaction. Already filed as direction note b19702."

It named the exact mechanism, minus the lock-hold, and did not block. Final verdict: approve.

**In-session reviewer: CAUGHT as advisory, deferred to a note.** sweap:reviewer #1 (`T/a55b2a72.../wf_3d827b43-477/agent-a18c21982bbbd894b.jsonl` L173) said:
> "`[diff]` **`lib/server/services.ts` `updateService`:** it queues each future appointment one at a time. Each one costs about three queries, all inside the request's transaction while holding the service row lock. A popular service with hundreds of future bookings makes the rename request slow on the Neon WebSocket driver."

The review-fix agent (`agent-a8e5641e70b10e50d`, 22:25–22:33Z) filed it as a direction note instead of fixing it. The note was created at 22:30:49Z.

**Tests:** #444's rename test uses a handful of appointments and asserts only which jobs exist. Nothing bounds queries or time, so the test cannot see a scale problem.

**Other signals:**
- `roadmap/discovered/a-service-rename-enqueues-calendar-syncs-one-appointment-at-a-time-inside-its-request-b19702.md` (`kind: direction`, `discovered_from: F13.9`) still exists today. Its "Done looks like" is "a set-based enqueue ... or a measured bound".
- The triages (#443, #447, #450) did not promote it.
- The audit's "Deduplication against the discovered inbox" section does not mention it, although finding 15 restates the note.

**Single-PR catchable: yes.** Both review layers did catch it. The gap is that "file a direction note" was accepted as a resolution and the note was never triaged in.

---

## 19. Booking/reschedule end time comes from a catalogue copy that no longer refreshes, and the server does not check it against the service duration

**Introducing PR: #449 (F13.10), merge 96c2162. Class (b)** with #420 (F13.23, 7d1b980). #420 landed first (2026-09-25), #449 second (2026-09-30). The server gap is pre-existing.
- `appointments.new.tsx:409,415-416` (`service = serviceOptions.find(...)`, `endAt = bookingEnd(startAt, service.durationMinutes)`) is `96c21629`. The `servicesQuery` read at L406 is `57ec2064` (#444).
- #420 set `refetchOnWindowFocus: false` and `refetchOnReconnect: false` app-wide, which removed the only background refresh of that cached catalogue.
- The server's lack of a duration check is pre-range. `create` and `reschedule` validate only `endAt > startAt`; F13.10.md puts "any change to what booking validates server-side beyond the derived end" out of scope.
- The core defect, client-derived length with no server check, is in #449's diff. #420 widens the stale window.

**CI reviewer: NEAR.**
- #449's first review raised the server gap and accepted it as out of scope, without naming the stale-catalogue path:
  > "So is the note for the server still accepting any `endAt`, which is out of scope."
- #449's second review: no mention.
- #420: MISSED. The only cost it noted was that "a read that failed while offline stays on ErrorState until Retry".

**In-session reviewer: MISSED. The implementer flagged it itself.**
- #449 sweap:reviewer #1 (`T/a55b2a72.../wf_af5acbde-0af/agent-a07af4976656afd93.jsonl` L188, approve) lists note 878082 in `files_reviewed` but raises no candidate about it. Reviewer #2 (`agent-acc3f1e34fa54e656.jsonl` L109) reviewed only the fixer commit b7a6947.
- The F13.10 implementer (`T/a55b2a72.../wf_3d827b43-477/agent-ae0dcfef534e34d0d.jsonl`):
  - Design note at L222: "The appointment's `end_at` is still written by the client ... the server validates what it validated before".
  - At L937 it ran `sweap-note discovered "The appointment API accepts any end time ..."`.
- #420 in-session reviewers (`T/6e939c5c.../subagents/agent-a700fadb8b3bf4875.jsonl` L96, `agent-a7f5e760681fd2a4a`): 10 candidates. The nearest is #7, on the reconnect error path. Nothing about stale data feeding a write.

**Tests:** the #449 vitest and e2e (`f13-10-booking.public.spec.ts`) assert end = start + duration against a fresh catalogue. No test changes the duration in another session while the form is open, and no server test rejects a mismatched `endAt`. The API fixtures post explicit ends on purpose.

**Other signals:**
- `roadmap/discovered/the-appointment-api-accepts-any-end-time-so-the-service-derived-end-is-a-client-rule-only-878082.md` (filed by #449) names the exact trigger: "so an API client, or a stale tab, can book a 90-minute appointment on a 30-minute service". It is still in the inbox.
- The audit's dedup section does not mention it, and triage #447 did not promote it.
- The spec's out-of-scope clause is what licensed it.

**Single-PR catchable: yes.** The implementer described the defect from this diff. Reviewers saw the note and accepted the spec's out-of-scope clause.

---

## Cross-cutting observations

- **Two of six were caught in-session and shipped anyway:** 8 and 15.
  - 8: the code-review result was lost (background fork, implementer opened the PR without waiting, SendMessage to a dead agent id). It was relayed to Henrique as "the gate decides", and the CI gate approved.
  - 15: both layers caught it and accepted a direction note that triage never promoted.
- **One more was self-filed by the implementer:** 19, as note 878082. The CI reviewer echoed it as "out of scope".
- **Notes b19702 and 878082 are still in the inbox, and the F13 audit's dedup section missed both.**
- **The three concurrency findings (4, 11, 13) were MISSED everywhere.** In each, the defect sits in pre-existing or untouched code next to the diff. Every reviewer's "Locking" pass checked lock *cycles*, not read-then-write races.
- **Correction to the audit text for finding 11:** #449 did not touch `rescheduleAppointment`; #421 and #444 did.
