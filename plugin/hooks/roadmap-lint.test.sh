#!/usr/bin/env bash
#
# roadmap-lint.test.sh — deterministic, offline tests for roadmap-lint.sh
# (the mechanical spec gate on roadmap item files).
#
# Run:  bash plugin/hooks/roadmap-lint.test.sh
# Exit: 0 = all pass, 1 = a failure (prints which case).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/roadmap-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
check() { # check <desc> <wanted-exit> <file>
  local desc="$1" want="$2" f="$3" out rc
  out="$(bash "$LINT" "$f" "$WORK" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail+1)); printf '  FAIL  %s (exit %s, wanted %s)\n%s\n' "$desc" "$rc" "$want" "$out"
  fi
}
mk() { printf '%s' "$2" > "$WORK/$1"; }

# A done dependency target other items point at.
mk F1.1.md '---
id: F1.1
title: dep target
status: done
depends_on: []
review-dimensions: []
---

# F1.1 — dep target

## Spec
- **Surface:** src/a.ts
- **Interfaces:** none
- **Out of scope:** everything else

## Acceptance (e2e)
- it works
'

mk F1.2.md '---
id: F1.2
title: valid item
status: todo
depends_on: [F1.1, F3]
review-dimensions: [security]
lane: auth
---

# F1.2 — valid item

## Spec
- **Surface:** src/auth/login.ts
- **Interfaces:** exports login(email, password) -> Session
- **Out of scope:** password reset

## Acceptance (e2e)
- submitting valid credentials lands on /home
'
check "valid todo item passes (item dep resolves; bare milestone dep allowed)" 0 "$WORK/F1.2.md"

mk nofm.md '# F9.9 — no frontmatter

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "missing frontmatter fails" 1 "$WORK/nofm.md"

mk F2.1.md '---
id: F2.9
title: mismatched
status: todo
depends_on: []
---

# F2.9 — mismatched

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "id != filename fails" 1 "$WORK/F2.1.md"

mk F2.2.md '---
id: F2.2
title: bad status
status: doing
depends_on: []
---

# F2.2 — bad status

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "invalid status fails" 1 "$WORK/F2.2.md"

mk F2.3.md '---
id: F2.3
title: deferred sans premise
status: deferred
depends_on: []
---

# F2.3 — deferred sans premise

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "deferred without premise: fails" 1 "$WORK/F2.3.md"

mk F2.4.md '---
id: F2.4
title: blocked sans question
status: blocked
depends_on: []
---

# F2.4 — blocked sans question

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "blocked without blocked: fails" 1 "$WORK/F2.4.md"

mk F2.5.md '---
id: F2.5
title: dangling dep
status: todo
depends_on: [F8.8]
---

# F2.5 — dangling dep

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "item-level dep with no file fails" 1 "$WORK/F2.5.md"

mk F2.6.md '---
id: F2.6
title: no spec section
status: todo
depends_on: []
---

# F2.6 — no spec section

## Acceptance (e2e)
- ok
'
check "missing ## Spec fails" 1 "$WORK/F2.6.md"

mk F2.7.md '---
id: F2.7
title: no acceptance
status: todo
depends_on: []
---

# F2.7 — no acceptance

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z
'
check "missing ## Acceptance fails" 1 "$WORK/F2.7.md"

mk F2.8.md '---
id: F2.8
title: missing spec bullet
status: todo
depends_on: []
---

# F2.8 — missing spec bullet

## Spec
- **Surface:** x
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "Spec missing an Interfaces bullet fails" 1 "$WORK/F2.8.md"

mk F2.10.md '---
id: F2.10
title: unfilled placeholder
status: todo
depends_on: []
---

# F2.10 — unfilled placeholder

## Spec
- **Surface:** <files this touches>
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "todo item with <...> placeholder fails" 1 "$WORK/F2.10.md"

mk F2.11.md '---
id: F2.11
title: done item placeholder ok
status: done
depends_on: []
---

# F2.11 — done item placeholder ok

## Spec
- **Surface:** <was never filled>
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "done item with <...> placeholder passes (rule gates todo only)" 0 "$WORK/F2.11.md"

# Regression (review finding 1): generic types / JSX in an Interfaces bullet are
# real content, not template placeholders — a valid todo item must NOT be failed.
mk F3.1.md '---
id: F3.1
title: generic types are not placeholders
status: todo
depends_on: [F1.1]
---

# F3.1 — generic types are not placeholders

## Spec
- **Surface:** src/parse.ts
- **Interfaces:** parse(input: Array<string>) -> Map<string, number>; renders <UserCard user={u} />
- **Out of scope:** streaming

## Acceptance (e2e)
- parsing two items yields a 2-entry map
'
check "generic types / JSX in Interfaces do NOT trip the placeholder rule (todo passes)" 0 "$WORK/F3.1.md"

# Regression (review finding 2): a YAML block-style depends_on reads as empty
# inline and would silently skip dep resolution — the lint must reject the
# off-contract form outright (here it also names a dangling dep, F8.8).
mk F3.2.md '---
id: F3.2
title: block-style depends_on
status: todo
depends_on:
  - F1.1
  - F8.8
---

# F3.2 — block-style depends_on

## Spec
- **Surface:** x
- **Interfaces:** y
- **Out of scope:** z

## Acceptance (e2e)
- ok
'
check "block-style depends_on (not inline [a, b]) fails" 1 "$WORK/F3.2.md"

# Regression (review finding 3): a CRLF checkout must not fail a valid item.
printf '%s\r\n' '---' 'id: crlf' 'title: crlf ok' 'status: todo' 'depends_on: []' '---' '' \
  '# crlf — crlf ok' '' '## Spec' '- **Surface:** x' '- **Interfaces:** y' \
  '- **Out of scope:** z' '' '## Acceptance (e2e)' '- ok' > "$WORK/crlf.md"
check "CRLF line endings still pass a valid todo item" 0 "$WORK/crlf.md"

# --- #1: the ## Spec/## Acceptance gate is todo-only; records migrate as-is ---
mk R1.1.md '---
id: R1.1
title: historical done record, no spec sections
status: done
depends_on: []
---

# R1.1 — historical done record

Just prose carried over by a legacy migration. No ## Spec, no ## Acceptance.
'
check "done item WITHOUT ## Spec/## Acceptance passes (records are not gated)" 0 "$WORK/R1.1.md"

mk R1.2.md '---
id: R1.2
title: blocked, awaiting a decision
status: blocked
blocked: which provider?
depends_on: []
---

# R1.2 — blocked

No spec yet; it earns one when promoted to todo.
'
check "blocked item WITHOUT spec sections passes (needs blocked:, not a full spec)" 0 "$WORK/R1.2.md"

mk R1.3.md '---
id: R1.3
title: todo still needs a spec
status: todo
depends_on: []
---

# R1.3 — todo without spec

no sections here
'
check "todo item WITHOUT ## Spec/## Acceptance still fails" 1 "$WORK/R1.3.md"

# --- #4: dot-depth-agnostic dependency resolution (multi-segment ids) ---------
# Milestone DS.2 whose items are the two-dot ids DS.2.1 / DS.2.2.
mk DS.2.1.md '---
id: DS.2.1
title: ds child one
status: done
depends_on: []
---

# DS.2.1 — child one
prose
'
mk DS.2.2.md '---
id: DS.2.2
title: ds child two
status: done
depends_on: []
---

# DS.2.2 — child two
prose
'
mk MD.1.md '---
id: MD.1
title: depends on a dotted milestone and a multi-dot item
status: todo
depends_on: [DS.2, DS.2.1]
---

# MD.1 — dotted deps

## Spec
- **Surface:** src/x.ts
- **Interfaces:** none
- **Out of scope:** y

## Acceptance (e2e)
- it resolves both deps
'
check "dep on dotted milestone DS.2 (has items) AND multi-dot item DS.2.1 both resolve" 0 "$WORK/MD.1.md"

mk MD.2.md '---
id: MD.2
title: dangling dotted dep
status: done
depends_on: [ZZ.9.9]
---

# MD.2 — dangling
prose
'
check "dotted dep that is neither an item nor a milestone-with-items fails" 1 "$WORK/MD.2.md"

check "missing file fails" 1 "$WORK/does-not-exist.md"

out="$(bash "$LINT" 2>&1)"; rc=$?
if [ "$rc" = "2" ]; then pass=$((pass+1)); printf '  PASS  no-args usage error (exit 2)\n'
else fail=$((fail+1)); printf '  FAIL  no-args usage error (exit %s, wanted 2)\n' "$rc"; fi

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
