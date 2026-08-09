---
title: Auto-baseline on adoption — self-migrating audit.baseline config
created: 2026-08-09T22:45:00.000Z
---

Make the v0.2.0 audit-gate adoption zero-touch, superpowers-style: no manual
CLAUDE.md edit when a consumer repo first updates into audit enforcement.

Trigger signature (adoption, not a real missed audit): the `## sweap config`
block has NO `audit.baseline` key at all AND `audit-gate.sh --check` reports
debt spanning multiple milestones. A repo that adopted earlier and then
skipped one audit has the key present — that stays a hard failure.

Sketch:
- On first session after update (scaffold.sh path, or a `/milestone`//`/roadmap`
  pre-flight fallback), detect the signature, compute the baseline from the
  gate's own FAIL list (it already names every complete-but-unaudited
  milestone), and write `audit.baseline: [<list>]` into the config block.
- The file stays explicit and greppable — the design decision from the
  2026-08-09 audit-enforcement spec (explicit list over implicit cutoff) is
  preserved; only the human typing disappears.
- Land the edit like the legacy-migration precedent in the playbook: a
  one-time, self-announcing change (session says what it grandfathered and
  why), committed through the normal gate, never silent.
- Guard rails: never touch an existing `audit.baseline` key; never fire when
  only ONE milestone is in debt (that is the normal "audit me" case, not
  adoption); the written list must round-trip through cfg_get (inline list,
  comment-safe).

Why: sweap is deliberately stateful (config + roadmap + records live in the
consumer repo — that's what makes enforcement possible), so contract changes
can need repo-side migrations. This makes the plugin own its own migrations
instead of handing them to the human — the property that makes superpowers
updates feel flawless, applied to sweap's statefulness.
