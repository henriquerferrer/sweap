---
title: Last-round review candidates become inbox notes
created: 2026-10-24T14:29:06.878Z
---

A review's round-2+ [diff] candidates only reach the PR body today, where nothing acts on them (consumer PR #481: a round-2 reviewer named a real hang, the CI reviewer read it in the body, it merged and the audit re-found it). Alternative to a second fixer, which was refuted 2026-10-24 (fires on 14 of 21 PRs for one hit): file them through the existing discovered-note path, zero extra agent calls. Untested and unrefuted. Risk: F13/F14 showed notes leak at triage (harm-bar parked real harms; direction notes are never triaged during a run), so only worth it once triage is shown to keep them. See docs/research/2026-10-24-f14-attribution/.
