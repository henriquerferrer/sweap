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

check "missing file fails" 1 "$WORK/does-not-exist.md"

out="$(bash "$LINT" 2>&1)"; rc=$?
if [ "$rc" = "2" ]; then pass=$((pass+1)); printf '  PASS  no-args usage error (exit 2)\n'
else fail=$((fail+1)); printf '  FAIL  no-args usage error (exit %s, wanted 2)\n' "$rc"; fi

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
