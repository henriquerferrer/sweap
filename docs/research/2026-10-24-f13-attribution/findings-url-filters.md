# F13 audit attribution, group C (findings 2, 7, 9, 10, 14, 16, 17)

Repo: ~/Documents/consumer-a. Range 5f69472..96c2162. Every blame below was run at 96c2162.

PRs involved:
- **#433** F13.26 (merge 9529ee0, final head 430eecf, merged 2026-09-27 19:42). Session 6fd2698e, workflow wf_78145934-78a.
  - Implementer: `agent-aa01858bbe7347493`.
  - Review #1: `agent-a8aca389ac49ab719`, verdict needs-work.
  - Review-fix: `agent-aa62e4f5b89156e25`.
  - Review #2: `agent-a71428db9d1e1c91b`, verdict approve. It reviewed 430eecf, which is the final head.
- **#449** F13.10 (merge 96c2162, final head 4d66988). Session a55b2a72, workflow wf_af5acbde-0af.
  - Implementer: `agent-a00337264eda8b69c`.
  - Review #1: `agent-a07af4976656afd93`, approve with 7 candidates.
  - Review-fix: `agent-ade326cca71782757`, commit b7a6947.
  - Review #2: `agent-acc3f1e34fa54e656`, approve.
  - CI fix: `agent-ac1138b227ce5e9f9`, commit 4d66988. It changed only an e2e spec, so the in-session review did not see the final head. This makes no difference to these findings.
- **#440** F13.7 (merge f3971ba). Session a55b2a72, workflow wf_1ca16e9a-d29. Implementer: `agent-aaff9aa234fe6f5f9`.

Transcript paths are relative to ~/Documents/consumer-a-f13-transcripts/<session>/subagents/workflows/<wf>/. Reviewer thinking blocks are redacted (null), so the only reviewer evidence is the tool calls and the structured output.

---

## 2. Patients list: a page past the end shows "No patients found" + first-patient prompt, pager stuck

**Introducing PR: class (b).** A pre-range server defect, activated by #433.
- `apps/web/src/lib/server/patients.ts:98` `const page = Math.max(1, opts.page ?? 1)` blames to **6e1ce8a** (F1.4 #4, 2026-07-03, pre-range). There is no upper bound.
- The pager's one-sided Previous guard (`aria-disabled={!known || page <= 1 …}`, pager.tsx:195) blames to 61e89b8 (FP.19 #401), also pre-range.
- Before #433, `requestedPage` was `useState(1)` (9529ee0^ patients.tsx:1181). The patients list has no row-level archive (only the Archived filter option, :908). Archiving happens on the sibling record route, which unmounts the list, so coming back reset the page to 1. A past-the-end page was effectively unreachable.
- **#433 (9529ee0)** put `page` in the URL (`validateSearch`, diff +115: `page: Number.isFinite(page) && page > 1 ? Math.floor(page) : undefined`; `requestedPage = search.page ?? 1`, diff +335). Back, bookmarks and shared links can now land past the end. #433 landed second, and the server was untouched ("the server is unchanged", implementer premises).

**CI reviewer (#433): MISSED.** It examined page URL handling and stopped at the lower bound and fractions:
> "going back to page 1 yields the bare address"
> Advisory: "A hand-crafted `?page=1.5` normalises to page 1 in-memory … harmless."
> "Findings: important=0 nit=0 / Verdict: approve"

**In-session reviewer (#433): MISSED.** Review #1 (`agent-a8aca389ac49ab719.jsonl` l.33) has one finding, about overlay-scroll test integrity. Review #2 (`agent-a71428db9d1e1c91b.jsonl` l.32) approved with no findings. Neither mentions an upper page bound. Both read only the diff (`git diff origin/main...HEAD`) and never opened `lib/server/patients.ts`.

**Tests.**
- `list-filters-search.test.ts` checks only that the sanitiser accepts any integer > 1.
- The f13-26 e2e only turns to page 2 of a 25-row set.
- No test covers a page whose rows have gone.

**Other signals:** no discovered note found (grepped roadmap/discovered and archive at 96c2162 for "last page/past/first 20/placeholder").

**Single-PR catchable: only-with-cross-file-context.** The diff makes page URL-addressable. Seeing the harm needs the unchanged server (`patients.ts:98`) and `ui/pager.tsx`, neither of which is in the diff.

---

## 7. Booking overlay's first patient search shows the agenda's unfiltered first page while the search is in flight

**Introducing PR: #449 (96c2162), class (a).** It interacts with a pre-range line that is visible as diff context.
- `appointments.new.tsx:337-341` (`searched` gate), `:343` (`enabled: !switching && searched`) and `:349-355` (the "ONLY A SEARCH'S ROWS" guard) all blame to **96c2162**.
- The `placeholderData: (previous, previousQuery) => … key[0] === orgId ? previous : undefined` at `:344-347` blames to a64f96a (F12.5 #312, pre-range). Before #449 that placeholder was the intended "carry the same clinic's page across". #449's new guarantee is what turns it into a defect: the disabled q='' query becomes `#lastQueryWithDefinedData` and leaks through the placeholder once `searched` is true.
- The guard covers only `!searched`.

**CI reviewer (#449): NEAR.** It raised the exact cache collision and accepted the incomplete guard as sufficient.
- First comment: "The patient read is gated on `searched`. This also hides the agenda's shared `q:''` cache entry."
- Second comment (head 4d66988): "The picker's pre-search key collides with the agenda's cached first page; this is guarded, and a vitest covers it."
- Both end "Findings: important=0", with nit=3 and nit=6 respectively, and "Verdict: approve".

**In-session reviewer (#449): MISSED.**
- Review #1 (`agent-a07af4976656afd93.jsonl` l.188) listed 7 candidates: archive count staleness, Cancel guard, focus, controlled-select mismatch, the dead `isSelected` branch, the live region, and the reschedule catalogue error. None is about the picker's placeholder or the agenda cache. A grep for placeholderData, keepPrevious and "agenda…cache" returned no hits in either reviewer.
- Review #2 (`agent-acc3f1e34fa54e656.jsonl` l.110) approved with 4 candidates, all on services and tests.

**Tests.**
- #449 added `F13.10: the agenda's cached first page does not fill the picker before a search` (appointments-new.test.tsx). It seeds the q='' entry and asserts zero rows **before any search**.
- No test searches while the q=<term> read is held, which is the only path where the placeholder fires. The audit's Test A is exactly that test, and it fails.

**Other signals.**
- The implementer knew about the collision. F13.10.md Notes (l.82-84): "The booking panel's patient read shares its pre-search cache key with the agenda's patient filter, so the 'empty until a search' picker opened with the agenda's first page in it. The e2e caught it; the rows are now read only after a search."
- That is a partial fix of the same mechanism, with no discovered note for the in-flight case.

**Single-PR catchable: yes.** The guard, the gate and the `placeholderData` callback are adjacent in one hunk. A reviewer who already named the collision only had to ask what the placeholder returns on the first search.

---

## 9. Agenda patient filter: a URL patient not in the 20-row dropdown shows "All patients" but stays filtered; Apply resubmits it

**Introducing PR: class (b).** #433, on top of a pre-range 20-row option list.
- `appointments.tsx:345` `useQuery(patientOptionsQuery(orgId, {}, …))` (first page of 20 active patients) blames to a64f96a (F12.5 #312, pre-range).
- **#433 (9529ee0)** added the URL-sourced `patient` filter (`appointmentsSearch`, :77-92, with `patient` UUID-validated but never checked against the options). It also added the controlled draft select (:381-389).
- Before #433 the filter was component state, so it was set only from the dropdown and reset on remount. #433 landed second.

**CI reviewer (#433): NEAR.** It praised the controlled select for exactly the missing-option family and accepted it:
> "a `<select>` whose roster options arrive after mount keeps its URL value instead of silently dropping the filter on submit."

That is the mechanism of this finding: a controlled value with no matching option keeps submitting the hidden id. The reviewer treated it as a fix rather than as "displayed ≠ submitted".

**In-session reviewer (#433): MISSED.** Neither review #1 (l.33) nor review #2 (l.32) mentions the patient options or a value missing from the options.

**Tests.**
- The f13-26 e2e "appointments: the day and the other filters live in the URL" uses a freshly created patient, which is always inside the first 20 active patients.
- No archived or 21st patient is exercised.

**Other signals.**
- #433's own code comment (patients.tsx:592-595, and the same pattern in appointments) reasons about "a `<select>` whose options arrive after mount … falls back to its first option and then silently drops the filter". The implementer considered options that arrive late, not options that never arrive.
- No discovered note.

**Single-PR catchable: only-with-cross-file-context.** You need to know that `patientOptionsQuery(orgId, {})` returns only the first 20 active patients (defined in lib/queries). The diff shows only the call.

---

## 10. /app/patients builds each URL commit from the last committed search; a second action during a pending navigation drops the first

(This is the same defect as 16. Both carry disposition FQ.6.)

**Introducing PR: #433 (9529ee0), class (a).**
- `patients.tsx:1368-1370` `function commit(next) { navigate({ to: '/app/patients', search: patientsSearch(next) }) }` blames to 9529ee0.
- So do `:1375` `commit({ ...next, sort: search.sort })`, `:1379` `commit({ ...search, page: next })` and `:1385-1386` (`dir` from the render-time `sort`, then `commit({ ...search, sort: …})`).
- The function signatures (4633f8a) are pre-range. All the stale-read lines are #433's.

**CI reviewer (#433): MISSED.** It reviewed these exact handlers and judged them correct:
> "`handleSearch` drops `page` and keeps `sort`; `handleSort`/`handlePage` preserve the other keys; going back to page 1 yields the bare address."

**In-session reviewer (#433): MISSED.** No mention in review #1 (l.33) or review #2 (l.32).

**Tests.**
- The f13-26 e2e awaits `expect.poll(() => searchOf(page)…)` after every action, so no two commits ever overlap.
- `list-filters-search.test.ts` tests only the sanitiser.

**Other signals (a strong partial catch, after the merge).**
- F13.7's implementer hit the same bug on /app/services and fixed it there (services.tsx:307-320, function-form `search: (prev) => …`, plus a vitest "two quick presses"). It also filed **`roadmap/discovered/the-patients-and-agenda-sort-heads-read-the-render-s-sort-so-two-quick-presses-ask-for-the-same-dire-0a0941.md`**, verified in #440's diff.
  - Note created 2026-09-28T10:51. Transcript: a55b2a72 …/wf_1ca16e9a-d29/agent-aaff9aa234fe6f5f9.jsonl ~l.678-750.
  - The note names `routes/app/patients.tsx handleSort`.
  - Its "Done looks like" says "every URL-driven sort and filter commit computes from the latest search".
- Triage **#443 (2e53953)** parked the note: "declined: parked: no harm class — the sort head and list both reflect the URL, so nothing false is shown". The audit then showed the filter-drop case, where the toolbar shows "Ana" over unfiltered rows. That is a wrong-data harm, and it is why FQ.6 is now a harm-class follow-up.
- #440's CI review also noted "Sort commits read the router's latest search, so a quick double press is not lost". Nobody back-ported the fix to patients.tsx.

**Single-PR catchable: yes.** Building the next search by spreading render-time `search`/`sort` into an async `navigate` is a stale-closure pattern visible in the diff. The size of the window (/app's beforeLoad) needs runtime knowledge, but the double-press case doesn't. F13.7 found it within a day with an ordinary e2e.

---

## 14. F13.26 made `?practitioner=` both the agenda's filter and the booking overlay's click-to-book prefill

**Introducing PR: class (b).** #433, on top of a pre-range child key. #449 landed later and is contradicted by it.
- `appointments.tsx:77-99` (`appointmentsSearch` reads `practitioner`; `validateSearch`) and `:334` (`useSearch({strict:false})`) blame to **9529ee0** (#433).
- So do `appointments.new.tsx:1436-1439` (the parent exit strips only `start`, which is effect b).
- `appointments.new.tsx:46-57` (child `validateSearch` reading `practitioner`) blames to 79fe036 (F5.3 #51, 2026-07-13, pre-range).
- `appointments.new.tsx:605-614` (prefill seed) blames to 96c2162 (#449). #449 rewrote the seed and added acceptance l.23 ("an owner, clinic admin or receptionist caller finds nothing preselected and a 'choose a practitioner' prompt"). Effect (c) breaks that acceptance whenever the overlay is opened from a filtered agenda.
- #433 is the cause. #449 is a second PR that could have noticed.

**CI reviewer.**
- **#433: CAUGHT, accepted as deferred:**
  > "The `?practitioner=` collision between the agenda filter and the booking prefill is real but correctly deferred as a filed discovered note, not a defect in this diff." … "Verdict: approve"
- **#449: MISSED.** It describes the seed ("The practitioner default tries the grid prefill first, then a practitioner caller") without connecting it to the agenda filter key or to the open note.

**In-session reviewer.**
- **#433: CAUGHT, accepted as deferred, by both rounds.**
  - Review #1 advisory (`agent-a8aca389ac49ab719.jsonl` l.33): "`appointments.new.tsx`: the parent exit drops only `start`, so a `practitioner` value that came from calendar click-to-book ends up filtering the agenda. This is covered by the filed discovered note (74f565), so it doesn't block."
  - Review #2 advisory (`agent-a71428db9d1e1c91b.jsonl` l.32): "(2) The dismiss exit in appointments.new.tsx keeps `practitioner` in the parent search while dropping `start` … tracked rather than hidden."
  - Both name effect (b), which the note itself does not spell out.
- **#449: MISSED.** No hit for practitioner=, filter or 74f565 in either reviewer.

**Tests.**
- The f13-26 e2e "the booking overlay opens and closes onto the same filtered URL" asserts that the filter survives the round trip. It encodes the collision as intended behaviour.
- #449's f13-10 e2e opens `/app/appointments/new` bare (l.140), so its "Choose a practitioner" assertion never runs from a filtered agenda.

**Other signals: partial catch by the implementer, verified.**
- `roadmap/discovered/the-agenda-s-practitioner-filter-and-the-booking-panel-s-practitioner-prefill-share-one-url-key-74f565.md` is added in #433's diff (kind: direction, discovered_from F13.26, created 2026-09-27T18:14). It is listed in the implementer's `notes_filed` (`agent-aa01858bbe7347493.jsonl` l.385). F13.26.md Notes l.63-64 also cite it.
- The note states effects (a) and (c): "a list filtered to a practitioner opens New appointment prefilled with that practitioner … click-to-book also renders the agenda behind the scrim filtered to X". It does not state (b), which the in-session reviewers did.
- The note was **never triaged during the milestone**. Triages #439, #443 and #447 did not touch it (it is a `direction` note). It sat in the inbox, visible in the F13.10 implementer's listing (a55b2a72 …/wf_3d827b43-477/agent-ae0dcfef534e34d0d.jsonl l.40), until audit #450 (4acbea6) archived it with `promoted_to: FQ.7`.

**Single-PR catchable: yes.** It was in fact caught on #433 by the implementer and by all three reviews, and was consciously deferred. On #449, catching it needed the open note or cross-file knowledge of the parent route's search.

---

## 16. Patients list builds the next sort/page URL from the render-time search, so a second quick commit undoes the first

Same defect, same lines and same evidence as **10** (FQ.6). Cited lines `patients.tsx:1367-1387` blame to 9529ee0 (#433), class (a).

**CI reviewer (#433): MISSED.** It vouched for these exact handlers: "`handleSort`/`handlePage` preserve the other keys".

**In-session reviewer (#433): MISSED.** Neither round mentions it.

**Tests.** No test fires two commits in one task.
- The audit's prover mirrored `services.test.tsx`'s double-press test (added by #440) against patients and got 2 failures.
- Switching `commit` to the services function form made all 29 pass.

**Other signals.**
- Discovered note 0a0941 (F13.7/#440), parked by #443 as "no harm class".
- services.tsx (#440) carries the fix with a comment naming the measured failure.

**Single-PR catchable: yes** (see 10).

---

## 17. Filter-toolbar re-seed effects overwrite edits made while a filter navigation is resolving

**Introducing PR: #433 (9529ee0), class (a).** The pattern was copied by #440.
- `patients.tsx:600-605` (`useState(filters)` plus `useEffect(() => setDraft({...}), [filters.q, filters.status, filters.practitioner])`) blames to 9529ee0.
- The agenda's twin at `appointments.tsx:381-389` also blames to 9529ee0.
- The services copy, `services.tsx:484-485` `useEffect(() => setDraft(applied), [applied])`, blames to f3971ba (#440, landed after #433). The F13.7 implementer's docstring says it is "CONTROLLED, as the exemplar's is (F13.26)" (agent-aaff9aa234fe6f5f9.jsonl ~l.299).

**CI reviewer (#433): NEAR.** It checked exactly the clobber property and passed it:
> "The draft re-seeds only when the applied (URL) values change (primitive `useEffect` deps), so live typing isn't clobbered"

It considered re-seeding on every render, not the window between Apply and the router committing.

**In-session reviewer (#433): MISSED.** No mention in either round.

**Tests.**
- The f13-26 e2e checks that the toolbar shows the URL values after a reload or Back. It never types while a navigation is pending.
- Locally the commit lands within ms. The audit needed a 1.5 s delay on get-session to open the window.

**Other signals.**
- The implementer's own docstring (patients.tsx:597-598): "depending on it would re-seed on every keystroke and discard the typing". The same partial reasoning as the CI reviewer.
- No discovered note.
- #440 propagated the pattern to services, and its reviews did not flag it.

**Single-PR catchable: only-with-cross-file-context.** The effect is local to the diff, and the CI reviewer examined exactly this property. Seeing the window means knowing that the applied search changes only after /app's beforeLoad (two auth reads) resolves, which is in the parent route rather than the diff.

---

## Summary

| # | PR | class | CI | in-session | tests | catchable |
|---|---|---|---|---|---|---|
| 2 | #433 (activates pre-range 6e1ce8a server cap gap) | b | MISSED (checked page=1 and 1.5, not the upper bound) | MISSED | e2e only pages 2 of 25; no vanished-page case | cross-file |
| 7 | #449 (with pre-range a64f96a placeholderData in the hunk) | a | NEAR (named the q='' collision, accepted "guarded") | MISSED | vitest asserts pre-search only; no held in-flight search | yes |
| 9 | #433 (on pre-range a64f96a 20-row options) | b | NEAR (praised controlled select keeping a value absent from the options) | MISSED | e2e patient always within the first 20 | cross-file |
| 10 | #433 | a | MISSED (vouched for handleSort/handlePage) | MISSED | e2e polls the URL between actions | yes |
| 14 | #433 (on pre-range F5.3 79fe036); #449 later missed it | b | #433 CAUGHT-deferred; #449 MISSED | #433 CAUGHT-deferred (both rounds, incl. effect b); #449 MISSED | e2e encodes it as intended; f13-10 opens bare /new | yes (caught, deferred) |
| 16 | #433 (same as 10) | a | MISSED | MISSED | no same-task double commit | yes |
| 17 | #433 (copied into services by #440) | a | NEAR (checked "typing isn't clobbered", missed the pending window) | MISSED | never types during a pending nav | cross-file |

Implementer partial catches:
- 14: 74f565, filed by F13.26 and left untriaged until the audit.
- 10/16: 0a0941, filed by F13.7 the next day and parked by triage #443 as "no harm class".
- 7: F13.10.md Notes record fixing the pre-search half of the same collision.
