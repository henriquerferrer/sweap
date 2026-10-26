# F13 audit attribution — which review saw each proven bug, and what it did

2026-10-24. Decision D12 of the 2026-09-26 worth review: for every proven code finding of the
Consumer A F13 audit (`roadmap/audits/F13.md`, range `5f69472..96c2162`, 21 findings, 19 proven by
execution), find the PR that introduced it and what each review layer said about that PR. The
only quality measurement since F12.

Evidence: the CI reviewer's PR comment, the in-session reviewers in the run transcripts
(archived to `~/Documents/consumer-a-f13-transcripts/` before the 30-day cleanup took them; two 09-23
sessions were already gone, none of them F13 PRs), git blame at range head, and the discovered
notes. Per-finding detail with quotes and transcript line numbers:
[reminders and tests](findings-reminders-and-tests.md) (1, 3, 5, 6, 12, 18, 20, 21),
[booking and services](findings-booking-and-services.md) (4, 8, 11, 13, 15, 19),
[URL filters](findings-url-filters.md) (2, 7, 9, 10, 14, 16, 17).
The 30 UI-axis findings are excluded: design critique of finished screens, not something a code
review is asked to catch. Reviewer thinking is redacted in the transcripts, so verdicts rest on
the reviewers' tool calls and structured output.

## Result

4 of the 21 predate the range (5, 11, 20, 21; F13 PRs touched the code, did not cause them).
Of the **17 introduced in F13**:

| outcome | count | findings |
|---|---|---|
| caught by a review, shipped anyway | 4 | 1, 8, 14, 15 |
| a review looked at the exact spot and called it sound / raised a neighbour | 7 | 3, 6, 7, 9, 17, 18, 19 |
| missed by every layer | 6 | 2, 4, 10, 12, 13, 16 |

- In-session reviewer: caught 4 (1, 8, 14, 15). CI reviewer: caught 2 (14, 15), both of them as
  advisories it accepted as "already filed as a note". **No catch was fixed before merge.**
- 11 of the 17 were catchable from the PR's own diff; 6 needed code next to the diff.
- Five came from one PR, #433 (F13.26, URL filters), approved by all four of its review passes.

## Where the catches went

Every catch left the PR as a note or a message, and every route leaked:

1. **Harm-bar triage parked it.** Finding 1 (a second reminder, possibly a paid SMS) was filed by
   the implementer as `…f9c10b` and archived by triage #427 as "a duplicate, no harm class". The
   10/16 double-press bug was re-found by F13.7's implementer (fixed on its own screen, note
   `…0a0941` naming `patients.tsx`) and parked by triage #443 as "nothing false is shown"; the
   audit showed the dropped filter does show something false.
2. **`kind: direction` notes are never triaged during a run** — only `/roadmap` reads them, and
   no `/roadmap` ran. Finding 14 (`…74f565`) sat until the audit promoted it. Findings 15
   (`…b19702`) and 19 (`…878082`, filed by the implementer itself) are **still in the consumer A
   inbox today**; the audit's dedup section missed both (both are parked in FQ.12).
3. **Lost hand-off.** Finding 8: the F13.4 implementer launched `/code-review` in the background
   and opened #407 before it returned; the review's message back failed ("No transcript found for
   agent ID"). The orchestrator relayed the two blocking findings to Henrique with "otherwise the
   gate decides", and the gate merged it unfixed (c0e2d909 transcript L101/L110).

## Blind spots in what was reviewed

- **Lost updates.** Each "Locking" check (4, 11, 13's PRs) confirmed there was no lock cycle;
  none asked whether an unlocked read could be overwritten by a concurrent write.
- **A review-driven fix re-reviewed as correct.** Round 1 on #421 raised same-instant duplicate
  reminders; the fix stopped new rows but never voided the existing one (3, 6). Round 2 and the CI
  reviewer both called those lines sound.
- **A spec's scope as the review's scope.** F13.15 covered controls with `pending={}`; the Save
  buttons without it (20, 21) were outside by construction. #418's review found the mid-save
  clinic-switch leak on the copied card and not on the original it sat next to.
- **Unreviewed final commits:** #421's 825df94 (security reviewer only) and #413's b8cd772 (none).
  Neither touched a finding's lines.

## Corrections to the audit record

- Finding 11 says "F13.10 rewrote this function"; #449 changes no line of
  `lib/server/appointments.ts`. The in-range edits were #421 and #444.
- PR #444 is titled "docs(F13.9): record the premise check…" but carries the whole F13.9
  implementation (4, 13, 15).

## Caveat on what this measures

The review-depth change (0.36.0, #69: effort high, hunt angles, reproduce-or-dismiss) and R1
(review as a script stage, 0.35.0) landed 2026-09-27, mid-run. Most of F13 ran on the reviewer
before them. F14's audit is the first measure of the current reviewer.
