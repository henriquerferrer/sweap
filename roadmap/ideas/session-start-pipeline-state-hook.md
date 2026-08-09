---
title: SessionStart hook surfaces pipeline state (audit debt, frontier) superpowers-style
created: 2026-08-09T22:30:00.000Z
---

Borrow obra/superpowers' one structural trick sweap lacks: a `SessionStart`
hook that makes pipeline state ambient in every session instead of waiting to
be asked. superpowers uses its session-start hook to inject the
`using-superpowers` meta-skill, which is why its skills appear to "run by
themselves"; sweap's equivalent is injecting *state*, not doctrine.

Sketch:
- Hook runs `audit-gate.sh --check` (fast, offline) from the project root at
  session start.
- When debt exists, inject one line of context: "audit debt: F2 complete, no
  record — discharge before backlog work (run /milestone-audit F2)".
- Optionally also surface the frontier/board summary (next runnable items,
  in-flight claims from .claude/sweap-board.md) so a fresh session knows where
  the pipeline stands without reading the playbook first.
- Keep it read-only and one-to-three lines — ambient awareness, not a wall of
  state; the deterministic gate underneath stays the enforcement.

Why: the audit gate (v0.2.0) already makes skipping mechanically impossible at
merge time, but a session can still burn a whole run drifting toward a merge
the gate will deny. Surfacing debt at session start converts a late hard
denial into an early soft redirect — the superpowers lesson (ambient
instruction injection) applied to sweap's state instead of doctrine.
