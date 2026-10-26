# F13 audit attribution: findings 1, 3, 6, 18, 20, 5, 12, 21

Repo: ~/Documents/consumer-a. Range: 5f69472..96c2162. Everything here was done read-only.
Transcript paths are relative to ~/Documents/consumer-a-f13-transcripts/. `S1` = session 6e939c5c-d222-4efe-94dd-3369ce073303, which covers #412–#424.
Reviewer agent jsonl files are in `S1/subagents/`. Implementer jsonl files are in `S1/subagents/workflows/wf_6cd74658-d74/`.

---

## 1. A non-moving appointment edit after a rule edit or timezone change arms a second reminder

**Introducing PR: #421 (F13.13), squash commit 2e39b92. Class (a), with a caveat.**
- Blame at 96c2162 of reminders.ts:430-630 gives 193 of 201 lines to 2e39b92. The insert arm runs when a (rule, channel) has no non-terminal row: `wanted` holds the channel, `row` is undefined, so control falls to `tx.insert(notifications)...` without calling `deliveredForCurrentTime`. Only the "row went terminal under us" branch (`rearmed.length === 0`) calls it.
- Caveat: the single-lead model before the range (5f69472 reminders.ts:345-400) had the same shape. It inserted on "no NON_TERMINAL row" without a delivered check, so a lead-time change followed by a non-moving edit could already re-send. #421 rewrote the function per rule, carried that gap over, and added the timezone/wall-clock variant, which is new because wall-clock rules are new. The in-session reviewer and the implementer's note both say "inherited from before this change" and "Pre-dates F13.13 in shape".

**CI reviewer (#421): MISSED.** The verdict was `Findings: important=0 nit=1 / Verdict: approve`. It checked "Void-and-insert (never move a non-terminal `due_at`) preserves `stillTheSameReminder`'s invariant" and never raised the no-row insert arm.

**In-session reviewer: CAUGHT.**
- The round-2 `sweap:reviewer` (`S1/subagents/agent-a3309f3b6e4fb4f01.jsonl`, SendMessage at about line 113) reviewed commits 1138684+32b2018. Its Advisory says:
  - "An edge `upsertReminderRow` does not cover, inherited from before this change: It skips the delivered check when no non-terminal row exists, so an edited rule (same id) plus a later non-moving appointment edit can arm a second reminder for a time already reminded … worth a discovered note, since the item's Notes lean on 'an edited rule keeps its id so the delivered block refuses a second message'."
- Its overall verdict was needs-work, for a different reason (a deadlock).
- The round-1 code-review (`agent-ab3c81cef7bd2c09c.jsonl`) named a nearby cold-path delivered-check miss (finding 7, about NULL-rule rows) but not this one.
- The final commit 825df94 got only the security review, which said "Security verdict: clear". It did not touch these lines.

**Tests:** reminder-cadence.test.ts (added by #421) covers "editing the rules voids the edited rule rows and inserts fresh ones" and "a reconcile after a rules edit never moves an armed row". No test runs the sequence that triggers the bug: deliver, then edit the rule in place, then make a non-moving edit.

**Other signals:**
- The implementer filed `roadmap/discovered/upsertreminderrow-arms-without-the-delivered-check-when-no-non-terminal-row-exists-f9c10b.md`. Its fix description reads "Done looks like the insert arm consulting deliveredForCurrentTime, with a test."
- Triage #427 (e74fda2) archived the note as `declined: parked: re-arm only follows a rules edit that moves the due time forward (a duplicate, no harm class)`. The defect was found, filed, and then parked under the harm bar, even though the duplicate can be a paid SMS.

**Single-PR catchable: yes.** The in-session reviewer found it from the #421 diff alone.

---

## 3. A rules save that edits or adds a lower-slot rule sends a second identical reminder at the same instant

**Introducing PR: #421 (F13.13), commit 2e39b92. Class (a).**
- Blame of reminders.ts:780-880 gives 96 of 101 lines to 2e39b92. armReminders (about lines 841-850) runs `if (dueTimes.has(dueAt.getTime())) continue`. It skips the higher-slot rule as a duplicate but never voids that rule's existing armed row, which is still in `have`.
- upsertReminderRow, the booking path, voids the duplicate's row: `wanted = … duplicate ? [] : channels` takes the `!wanted` branch and sets status voided.
- The same-instant dedupe itself was added in round-1 fix commit 32b2018 ("same-instant rules armed once"), inside #421.

**CI reviewer (#421): NEAR.** The CI reviewer read the exact lines and called them correct: "Same-instant dedup keeps the lower slot on both the booking (upsertReminderRow:427) and re-arm (armReminders:836) paths." Verdict: approve.

**In-session reviewer: NEAR.**
- Round 1, code-review high (`agent-ab3c81cef7bd2c09c.jsonl` about line 105, finding 8): "Validation refuses only identical shapes, not different shapes with the same due time … offset 1440 and wall_clock 1 day @ 10:00 give identical due_at … the patient gets two texts at once."
- The implementer fixed it with the lower-slot skip in 32b2018. On armReminders that fix only stops new inserts.
- The round-2 sweap:reviewer reviewed 32b2018 and did not flag the missing void.
- So the risk was raised and an incomplete fix was accepted.

**Tests:** "F13.13: two rules that fall due at the same instant arm one reminder" (reminder-cadence.test.ts:701 at 2e39b92) sets the rules before booking and asserts on the booking path. It never runs armReminders against an already-armed higher-slot row.

**Other signals:** none found in roadmap/discovered.

**Single-PR catchable: yes.** Both dedupe loops are in the #421 diff. One voids and the other only `continue`s, and that asymmetry is visible side by side.

---

## 6. armReminders skips the higher-slot duplicate but never voids its existing armed row

**Introducing PR: #421 (F13.13), commit 2e39b92 (dedupe from 32b2018). Class (a).** This is the same root line as finding 3 (reminders.ts:845, the `continue`). The trigger is an in-place edit of rule 1 (it keeps its id), or a remove and re-add into slot 1. applyReminderRules (reminder-rules.ts:196, also 2e39b92 only) voids rule 1's future row. armReminders then inserts a fresh rule-1 row that coincides with rule 2's still-pending row.

**CI reviewer (#421): NEAR.** Same quote as finding 3: the reviewer called the armReminders:836 dedupe sound.

**In-session reviewer: NEAR.** Same evidence as finding 3. Round-1 code-review raised same-instant duplicates (finding 8). The fix in 32b2018 was incomplete, and round-2 sweap:reviewer reviewed that fix without flagging the missing void.

**Tests:** same as finding 3. No test edits a rule so that a lower slot lands on a higher slot that is already armed.

**Other signals:** none found.

**Single-PR catchable: yes.** Same reasoning as finding 3.

---

## 18. Clinic-settings writers each write their full PUT response into the cache, so an out-of-order response rolls back the other card's field

**Introducing PRs: #418 (F13.6, 75e8e0c) and then #422 (F13.14, dcd32a5). Class (b). #422 landed second and wrote the cited line.**
- reminder-timing-settings.tsx:155 `queryClient.setQueryData(clinicSettingsQuery(orgId).queryKey, data)` blames to dcd32a5 (#422), which added it with the "FP.11 —" comment. The #418 version of the file (75e8e0c) had no setQueryData.
- #418 created the separate reminder card on the Communications section, with a per-instance `savingRef` (lines 141-174 blame to 75e8e0c). It also made settings sections routed tabs. The remount path in interleaving B depends on that.
- The other writer, communications-settings.tsx:237 `setQueryData(...)`, predates the range: commit 1cbe00e, FP.11 #398, 2026-09-24, an ancestor of 5f69472.
- #428 (F13.28, 7c904d5) later edited the same submit (lines 145 and 152-163) but left the cache write as it was.

**CI reviewer:**
- #422: NEAR. Its Advisory raised a different in-flight race in the same handler: "`submit()` clears the draft with `setDraft(null)` on PUT success, so a rule added during the in-flight save is silently dropped." It did not raise the cache overwrite. Verdict: approve.
- #418: MISSED. "Partial-save race handling on the moved lead-time field is sound." The second review noted "the FP.11 cache-write from the communications card", so it knew one card writes the full row, but raised no ordering issue.
- #428: MISSED. "No correctness bug…"

**In-session reviewer:**
- #422: MISSED. None of the three reviewers raised it, though all three had the setQueryData hunk in their reads:
  - `agent-afe8922c878759abd.jsonl` (sweap:reviewer, needs-work on test comments)
  - `agent-ae50e7fed0a5a7cf6.jsonl` (re-review). Its "Save race: a rule added while a save is still in flight is silently dropped" is the F13.28 race, not this one.
  - `agent-af196c2ea2931b945.jsonl` (code-review high, 8 findings, none on cache ordering)
- #428: MISSED. The sweap:reviewer in session 6fd2698e (`subagents/workflows/wf_78145934-78a/agent-a70b62cce2088450a.jsonl`, line 34) gave "Verdict: approve".

**Tests:** reminder-timing-settings.test.tsx (#422/#428) renders the reminder card alone, with one PUT at a time. No test mounts both cards on one QueryClient or holds two PUTs, so response order is never exercised.

**Other signals:** no discovered note found.

**Single-PR catchable: only with cross-file context.** In #422's diff the setQueryData looks correct by itself. Seeing the bug needs communications-settings.tsx writing the same key (not in the diff) and #418's per-instance guard and remount behaviour.

---

## 20. The Clinic (timezone) save writes its toast or error into another clinic after a mid-save clinic switch

**Introducing PR: pre-range. Class (c).**
- settings.tsx:117-131 at 96c2162: the `submit` body blames to 8888fd2c (2026-07-06), fabbb369 (2026-07-06), 66dcf0cc (2026-08-08) and 178b5fc3 (2026-09-10). In range, #418 (75e8e0c) changed only line 126 (payload `{ timezone: tz }`) and lines 125/129, and #422 changed comment line 124.
- At 5f69472 the handler is already `await save.mutateAsync({ timezone: tz, reminderLeadMinutes: lead }); setMessage('Settings saved.')`. It has no `activeOrgRef` check and no ref or `pending`.
- #418 touched the hunk and created a sibling card copied from this same shape.

**CI reviewer (#418): MISSED.** It said "Reminder-timing partial save sends `{ reminderLeadMinutes }` alone with a clinic-tagged re-entry guard". That is about the sibling card; it said nothing on the Clinic submit. Verdict: approve.
**CI reviewer (#413, F13.15): MISSED** on the double-PUT half. Its scope was pending-carrying controls only.

**In-session reviewer (#418): NEAR.** It named the exact mechanism, but on the sibling card that #418 copied from this handler.
- `S1/subagents/agent-ac3f09e75a34b9b83.jsonl` (round-2 code-review high, line 111): "reminder-timing-settings.tsx:205 — The new lead-time save is not tagged with a clinic … switches to clinic B while the PUT is still running … A's promise resolves and calls setMessage('Settings saved.'), so B shows a success toast for a write it never made (or A's save error)."
- Round 1 (`agent-a59caac95b0e11ce3.jsonl`, line 116): "The new 'Save reminder timing' submit has no pending state or re-entry guard, against the F13.15 rule…"
- The implementer fixed the reminder card. The identical Clinic submit in settings.tsx, which both reviewers read (`agent-a59caac…` L24/L33 show the hunk), was left unguarded.

**Tests:** settings.test.tsx's save test submits with no clinic switch and a single submit. The post-switch tests added by #418 cover only reminder-timing-settings.

**Other signals:**
- The F13.15 spec scopes the gate to "call sites carrying a `pending={}` control", so this Save button (no `pending`) was out of scope by construction.
- No discovered note found.

**Single-PR catchable: yes, for #418.** The submit hunk was in #418's diff, and #418's own reviewer flagged the same mechanism one file over. The original defect predates the range.

---

## 5. Double-submit spec never checks how many reschedule PATCHes are sent

**Introducing PR: pre-range, #240 (b9aa481, 2026-09-03). Class (c).**
- ds5-audit-c56-double-submit.public.spec.ts:367 `const patches = record(page, isReschedulePatch)` and :374 `patches.reset()` both blame to b9aa481a.
- At 96c2162 those are the only two references to `patches`. At b9aa481 they were lines 353 and 362, so the counter was never read from day one.
- In-range PRs edited the reschedule half without touching the counter: #414 (bdcca6e), 57ec206 (#444), and #449 (96c2162).

**CI reviewer (#240, pre-range): NEAR.** A reviewer asserted the false premise: "The `.soft()` assertions on POST/PATCH counts sit alongside hard assertions … so a soft failure can't mask the real defect." There is no PATCH-count assertion.
- In range, #414 CI said "The C5.6 double-submit spec still asserts … exactly one POST". That is true for cancel, and it did not notice reschedule has no count.
- #449 CI flagged the same vacuity pattern elsewhere ("`appointments-detail.test.tsx:566` (`for … of patches`) pass without checking anything when no request was sent") but not in this spec.
- Rated MISSED for the in-range PRs.

**In-session reviewer: no evidence found for #240.** Its session predates the F13 archive and the live dir ~/.claude/projects/-Users-me-Documents-consumer-a/ has no session mentioning pull/240. For the in-range PRs that edited the spec: MISSED. A grep of all archived and live transcripts that mention `ds5-audit-c56` found no remark about the unused `patches` counter.

**Tests:** the spec is the defect. Modes A and B assert only that the form closes. Mode C makes soft aria-disabled and label checks. An unguarded reschedule would pass all three.

**Other signals:** none.

**Single-PR catchable: yes.** In #240's diff, a counter is declared and reset but never asserted, and the CI review even described an assertion that does not exist.

---

## 12. Pending-guard real-tree test is titled "finds pending controls to check" but never checks that any were found

**Introducing PR: #413 (F13.15), commit 9e040d8. Class (a).**
- lint-pending-guard.test.mjs:306-317 blame wholly to 9e040d86.
- The test was present from the first branch commit d94f52a (lines 209-216 there). It was reviewed by both in-session rounds and was in the final diff.

**CI reviewer (#413): MISSED.** `Findings: important=0 nit=3 / Verdict: approve`. Its third nit ("The pending-guard gate shape-checks handlers (it does not verify the ref is *cleared*)") is about the gate, not this test.

**In-session reviewer: MISSED, with adjacent findings.**
- Round 1 code-review (`S1/subagents/agent-a6a86afcc2e858cb8.jsonl`, line 160) and round 2 (`agent-ab00e6a02f6e9186b.jsonl`, line 120) raised 20 findings between them, many about the gate silently passing. Example: "The gate silently skips a `pending` submit control whose `<form>` is not a lowercase `<form>` ancestor… contradicts the docblock's promise that the gate fails closed."
- Round 1 even noted "the gate passes on the tree today (89 files)".
- Neither noticed that the real-tree test cannot detect zero controls checked.
- The round-2 fixes (b8cd772, +40 lines in this test file) were not re-reviewed in-session.

**Tests:** this is the defective test. It asserts only on the file list (patients.new.tsx present, no .test.tsx). `main()` returns 0 when nothing is flagged, so a broken attribute reader passes both real-tree tests.

**Other signals:** none found.

**Single-PR catchable: yes.** The test title and body sit side by side in the #413 diff.

---

## 21. Time-off/closure "Add" can be activated twice and create two exceptions

**Introducing PR: pre-range. Class (c).**
- availability-exceptions.tsx:257-305 at 96c2162 blames to 4633f8a5 (#205, 2026-08-24, a format pass) for 36 lines and a64f96ab (#312, 2026-09-12) for 13 lines. Both are ancestors of 5f69472.
- In-range commits to the file (#406, #418, #419) do not touch these lines. #418 only moved the card to /app/settings/time-off.

**CI reviewer: MISSED.**
- #413: "Every touched handler follows the same shape…". Its scope was the pending-carrying handlers only.
- #418: no mention.

**In-session reviewer: MISSED.**
- F13.15's two code-review rounds (same files as finding 12) attacked gate bypasses for `pending` controls. None mentioned submit controls without `pending`, or availability-exceptions.
- The F13.15 spec's Notes show the implementer knew non-pending call sites exist ("the assignment is not a `pending={}` call site … It got the ref guard anyway"). No sweep of other non-pending submits was done.

**Tests:** f13-15-double-activation.public.spec.ts covers only the listed data-creating controls. The lint, by design, skips elements without `pending` (lint-pending-guard.mjs:443-445 `if (!attrs.has('pending')) continue`).

**Other signals:**
- The F13.15 spec Surface reads "the ~20 mutating call sites carrying a `pending={}` control", which excludes this handler by construction.
- The #240 precursor note "pending-state-is-not-a-double-submit-guard" framed the gap the same way.
- No discovered note for this handler.

**Single-PR catchable: only with cross-file context.** The handler is in no in-range diff. #413's reviewer would have had to look beyond the pending-scoped surface the spec defined.
