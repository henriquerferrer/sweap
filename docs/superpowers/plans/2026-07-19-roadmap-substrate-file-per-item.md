# Roadmap Substrate: File-Per-Item + Dispatch Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-mutable-ROADMAP.md backlog with a two-layer substrate (thin index + one file per item under `roadmap/`), add the mechanical pre-dispatch spec gate (`roadmap-lint.sh`), and encode lane serialization, event-driven frontier release, and the review-bandwidth cap in doctrine.

**Architecture:** Spec is `docs/superpowers/specs/2026-07-19-roadmap-substrate-design.md` — read it first; its "Locked decisions" section is normative. This plugin is markdown doctrine + bash hooks: the "code" tasks are the lint script (TDD) — everything else is precise doctrine edits whose exact text is given below.

**Tech Stack:** bash (POSIX-ish, mirrors existing hooks), markdown.

## Global Constraints

- Never weaken existing gates; `pre-merge-gate.test.sh` must stay at 63 passed, 0 failed (baseline verified 2026-07-19).
- Frontmatter keys are single-line; `depends_on` is an inline `[a, b]` list (spec locked decision 2).
- Status enum: `todo | blocked | deferred | done` (+ `dropped` in `roadmap/archive/` only).
- Config keys: `backlog.file` default `ROADMAP.md` (index); NEW `backlog.dir` default `roadmap/`.
- All shell follows the repo idiom: `set -uo pipefail`, never fail the session from hooks, comments explain contract not mechanics.
- Commit messages follow repo style: `feat(...)`/`docs:`/`test:` prefixes, present tense.

---

### Task 1: `roadmap-lint.sh` — the mechanical spec gate (TDD)

**Files:**
- Create: `plugin/hooks/roadmap-lint.sh`
- Create: `plugin/hooks/roadmap-lint.test.sh`

**Interfaces:**
- Produces: `bash plugin/hooks/roadmap-lint.sh <item-file> [items-dir]` → exit 0 pass; exit 1 fail with `FAIL: <reason>` lines on stdout; exit 2 usage. `items-dir` defaults to the item file's directory. Later tasks reference it as `bash ${CLAUDE_PLUGIN_ROOT}/hooks/roadmap-lint.sh <file>`.

- [ ] **Step 1: Write the failing test file** — full content:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails** — `bash plugin/hooks/roadmap-lint.test.sh`; expected: every case FAILs / script errors because `roadmap-lint.sh` does not exist. Paste RED output in the report.

- [ ] **Step 3: Write the implementation** — full content of `plugin/hooks/roadmap-lint.sh`:

```bash
#!/usr/bin/env bash
#
# roadmap-lint.sh — the mechanical spec gate on roadmap item files.
#
# One gate, two call sites: /roadmap runs it on every new/changed item file
# before the milestone PR opens; the dispatching session (serial loop or
# coordinator) runs it on an item before dispatch. Fail = the item is not
# runnable — fix mechanically or escalate; never dispatch past a failing lint.
#
# Usage: roadmap-lint.sh <item-file> [items-dir]
#   items-dir defaults to the item file's own directory (where item-level
#   depends_on entries must resolve to <ID>.md files).
# Exit: 0 = pass; 1 = fail (one "FAIL: reason" per line on stdout); 2 = usage.
#
# Format contract (playbook "Backlog format"): flat single-line frontmatter
# keys; depends_on is an inline [a, b] list. This constraint is what keeps
# this script trivial — do not grow a YAML parser here.
set -uo pipefail

file="${1:-}"
if [ -z "$file" ]; then
  echo "usage: roadmap-lint.sh <item-file> [items-dir]"
  exit 2
fi
if [ ! -f "$file" ]; then
  echo "FAIL: no such file: $file"
  exit 1
fi
dir="${2:-$(dirname "$file")}"

fails=0
fail() { echo "FAIL: $1"; fails=1; }

# --- frontmatter: first block delimited by --- lines, must start at line 1 ---
fm="$(awk 'NR==1{ if ($0!="---") exit; next } /^---$/{ exit } { print }' "$file")"
if [ -z "$fm" ]; then
  fail "missing frontmatter (file must start with a --- block)"
fi

get() { printf '%s\n' "$fm" | sed -n "s/^$1:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'; }

id="$(get id)"
status="$(get status)"
base="$(basename "$file" .md)"

[ -n "$id" ] || fail "missing id:"
if [ -n "$id" ] && [ "$id" != "$base" ]; then
  fail "id ($id) != filename ($base)"
fi

case "$status" in
  todo|blocked|deferred|done|dropped) : ;;
  "") fail "missing status:" ;;
  *)  fail "invalid status: $status (todo|blocked|deferred|done|dropped)" ;;
esac
if [ "$status" = "deferred" ] && [ -z "$(get premise)" ]; then
  fail "deferred item missing premise: (the machine-checkable predicate it waits on)"
fi
if [ "$status" = "blocked" ] && [ -z "$(get blocked)" ]; then
  fail "blocked item missing blocked: (the question awaiting an ANSWER)"
fi

# --- depends_on: inline [a, b]; entries containing a dot are item-level and
# must resolve to a file; bare milestone tags (no dot) are allowed as-is -----
deps="$(get depends_on | tr -d '[]' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  case "$dep" in
    *.*)
      [ -f "$dir/$dep.md" ] || fail "depends_on $dep: no file $dir/$dep.md"
      ;;
  esac
done <<DEPS
$deps
DEPS

# --- body sections: ## Spec (three named bullets) + ## Acceptance ------------
body="$(awk 'NR==1 && $0=="---" { infm=1; next } infm && /^---$/ { infm=0; next } !infm { print }' "$file")"
section() { printf '%s\n' "$body" | awk -v h="^## $1" 'BEGIN{on=0} $0~h{on=1;next} /^## /{on=0} on{print}'; }

spec="$(section "Spec")"
acc="$(section "Acceptance")"
printf '%s' "$spec" | grep -q '[^[:space:]]' || fail "missing/empty '## Spec' section"
printf '%s' "$acc"  | grep -q '[^[:space:]]' || fail "missing/empty '## Acceptance' section"
if printf '%s' "$spec" | grep -q '[^[:space:]]'; then
  for bullet in "Surface" "Interfaces" "Out of scope"; do
    printf '%s\n' "$spec" | grep -q "^- \*\*$bullet" || fail "Spec missing '- **$bullet:**' bullet"
  done
fi

# Unfilled <...> placeholders make a todo item undispatched-able; done/other
# statuses are historical records and are not re-gated.
if [ "$status" = "todo" ]; then
  if printf '%s\n%s\n' "$spec" "$acc" | grep -q '<[^>]*>'; then
    fail "unfilled <...> placeholder in Spec/Acceptance of a todo item"
  fi
fi

exit "$fails"
```

- [ ] **Step 4: Run the tests to verify they pass** — `bash plugin/hooks/roadmap-lint.test.sh`; expected `RESULT: 14 passed, 0 failed`, exit 0. Paste GREEN output. Also run `bash plugin/hooks/pre-merge-gate.test.sh` (expected 63 passed) to confirm no cross-talk.

- [ ] **Step 5: Commit**

```bash
git add plugin/hooks/roadmap-lint.sh plugin/hooks/roadmap-lint.test.sh
git commit -m "feat(hooks): roadmap-lint spec gate for item files (TDD)"
```

---

### Task 2: Templates + scaffold

**Files:**
- Modify: `plugin/templates/ROADMAP.md` (full rewrite)
- Create: `plugin/templates/roadmap/.gitkeep` (empty)
- Modify: `plugin/templates/CLAUDE.md`
- Modify: `plugin/hooks/scaffold.sh` (one message string)

**Interfaces:**
- Consumes: schema from spec locked decision 2 (documented for projects by the playbook section Task 3 adds).
- Produces: scaffolded projects get `ROADMAP.md` (index) + empty `roadmap/` dir + `backlog.dir` config key.

- [ ] **Step 1: Replace `plugin/templates/ROADMAP.md`** with exactly:

```markdown
# ROADMAP (index)

Direction-level view only. **Backlog items live one file each under
`roadmap/`** (`roadmap/<ID>.md`, e.g. `roadmap/F1.1.md`) — see the sweap
playbook's **Backlog format** section for the item schema (frontmatter:
`id`, `title`, `status`, `depends_on`, `review-dimensions`, optional `lane` /
`followup_of` / `premise` / `blocked`; body: `## Spec` + `## Acceptance
(e2e)`). Status truth is the item files; this index never carries per-item
status. Dropped items move to `roadmap/archive/`.

## Milestones (priority order)

- F1 — <first milestone goal>

## Later milestones (sketch, not yet specced)

- F2 — <...>
```

- [ ] **Step 2: Create empty `plugin/templates/roadmap/.gitkeep`** (zero bytes; the scaffold's template copy then creates `roadmap/` in every project).

- [ ] **Step 3: Edit `plugin/templates/CLAUDE.md`** — three exact replacements:

Old:
```
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Backlog: `ROADMAP.md`.
```
New:
```
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Backlog:
`ROADMAP.md` (index) + `roadmap/` (one file per item).
```

Old:
```
backlog.file:     ROADMAP.md
```
New:
```
backlog.file:     ROADMAP.md
backlog.dir:      roadmap/                  # one file per item — see playbook "Backlog format"
```

Old:
```
- When blocked or ambiguous in an unattended run: escalate, don't guess —
  record the question on the item in ROADMAP.md, notify, move to the next item.
- Honor each ROADMAP item's `review-dimensions` tags.
```
New:
```
- When blocked or ambiguous in an unattended run: escalate, don't guess —
  record the question in the item file's `blocked:` key (status: blocked),
  notify, move to the next item.
- Honor each backlog item's `review-dimensions` tags.
```

- [ ] **Step 4: Edit `plugin/hooks/scaffold.sh`** — in the `msg=` TODO string, replace the exact substring:

Old: `(4) write the first ROADMAP milestone with /roadmap.`
New: `(4) write the first milestone with /roadmap (one file per item under roadmap/ — see the playbook's 'Backlog format' section).`

- [ ] **Step 5: Verify** — `bash -n plugin/hooks/scaffold.sh` (syntax OK); `grep -n "backlog.dir" plugin/templates/CLAUDE.md` (present); `test -f plugin/templates/roadmap/.gitkeep && echo ok`.

- [ ] **Step 6: Commit**

```bash
git add plugin/templates/ROADMAP.md plugin/templates/roadmap/.gitkeep plugin/templates/CLAUDE.md plugin/hooks/scaffold.sh
git commit -m "feat(templates): file-per-item backlog — index ROADMAP, roadmap/ dir, backlog.dir key"
```

---

### Task 3: Playbook — Backlog format section + doctrine edits

**Files:**
- Modify: `plugin/playbook/agentic-loop-playbook.md`

**Interfaces:**
- Consumes: `roadmap-lint.sh` CLI contract (Task 1), schema (spec decision 2).
- Produces: the section title **"Backlog format (file-per-item)"** and the key `backlog.dir` — Tasks 4–5 reference both by name.

All edits below are exact old→new replacements unless marked INSERT.

- [ ] **Step 1: Config-key list** — replace:

Old:
```
- **`backlog.file`** — the backlog/roadmap file. Default **`ROADMAP.md`**.
```
New:
```
- **`backlog.file`** — the backlog **index** file (milestone list + the
  later-milestones sketch; never per-item status). Default **`ROADMAP.md`**.
- **`backlog.dir`** — the per-item backlog directory, one file per item — see
  **Backlog format (file-per-item)**. Default **`roadmap/`**.
```

- [ ] **Step 2: INSERT the new section** immediately before `## Operating model — the per-feature loop`:

```markdown
## Backlog format (file-per-item)

The backlog is two layers, split by state lifetime. Evidence (2026-07-19
roadmap-substrate spec): every verified lab system coordinates parallel agents
through per-task files — a single mutable backlog file is the one pattern the
evidence rules out, and shared-file mutation (not markdown itself) is the
hazard.

- **`ROADMAP.md`** (`backlog.file`) — the human-facing **index**: the
  milestone list in priority order plus the "Later milestones" sketch.
  Direction-level only; it never carries per-item status, so it changes only
  at milestone boundaries (human-in-the-loop moments) and is never a
  concurrent-write hotspot.
- **`roadmap/`** (`backlog.dir`) — **one file per item**: `roadmap/<ID>.md`
  (e.g. `roadmap/F1.2.md`), the single source of truth for that item's
  status, dependencies, and spec. Parallel workers touch disjoint item files
  by construction.
- **`roadmap/archive/`** — dropped items move here (`status: dropped` plus a
  `dropped_reason:` key): a reversible soft-delete, visible in git history.
- **`.claude/sweap-board.md`** (gitignored) stays the *ephemeral* layer —
  in-flight claims and queue order only (see Parallel runs).

Item file schema. Frontmatter keys are single-line and `depends_on` is an
inline `[a, b]` list — keep it flat so `roadmap-lint.sh` and plain greps stay
trivial (this flatness is a format contract, not a style preference):

    ---
    id: F1.2                 # must equal the filename (F1.2.md)
    title: <short feature name>
    status: todo             # todo | blocked | deferred | done (dropped: archive only)
    depends_on: []           # item IDs (F1.1) and/or bare milestone tags (F2)
    review-dimensions: []    # from the review.dimensions config set
    lane:                    # optional; same-lane items NEVER co-dispatch
    followup_of:             # optional milestone tag — marks an audit-debt item
    premise:                 # REQUIRED when deferred — machine-checkable predicate
    blocked:                 # REQUIRED when blocked — the question awaiting "> ANSWER:"
    ---

    # F1.2 — <title>

    ## Spec
    - **Surface:** <files/modules this item is expected to touch>
    - **Interfaces:** <contracts produced/consumed — exact names/signatures wherever two concurrent items share one>
    - **Out of scope:** <what this item deliberately does not do>

    ## Acceptance (e2e)
    - <observable behavior a test asserts>

    ## Notes
    <optional: "> ANSWER:" threads, UNBLOCKED annotations, links>

**Spec gate (mechanical, one gate, two call sites).** An item is runnable
only if `roadmap-lint.sh` passes on its file — frontmatter valid and
consistent, item-level `depends_on` entries resolve to existing files,
`## Spec` (all three bullets) and `## Acceptance` present, no unfilled `<…>`
placeholders on a `todo` item. `/roadmap` runs it on every new/changed item
file before the milestone PR opens; the dispatching session (serial loop or
coordinator) runs it again before dispatch. A todo item failing lint is not
runnable: fix it if the fix is mechanical, else escalate (status: blocked
with the question). Evidence: vague delegation is the dominant
parallel-dispatch failure mode; a self-contained spec naming surface,
interfaces, and out-of-scope is the lab-converged prerequisite — and when two
concurrent items share a contract, the **Interfaces** bullet is where it gets
pre-declared.

**Frontier order** (replaces the old "top-of-file order"): debt first (items
with `followup_of:` set), then milestone order as listed in the index, then
numeric item order within a milestone (numeric segment compare: F1.9 before
F1.10). An item is *unblocked* when every `depends_on` entry is satisfied —
item-level entry (has a dot): that file reads `status: done`; bare milestone
entry: that milestone is complete (every one of its item files is done).

**Legacy migration (one-time, agentic).** A project whose `backlog.file`
still contains item headers (`### … [todo]`-style) migrates before its next
`/roadmap` or `/milestone` proceeds: one PR through the gate that moves every
item into a `backlog.dir` file (parsed fields → frontmatter; `Depends on:` →
`depends_on`; `Premise:` → `premise:`; items under `## <milestone> audit
follow-ups` sections → `followup_of: <milestone>`; body bullets → Spec /
Acceptance, filling Spec gaps best-effort and leaving `<…>` placeholders
where genuinely unknown), rewrites the index, and deletes the legacy
sections. The session performs the split itself (no shell parser) and lints
every produced file.
```

- [ ] **Step 3: Review-dimensions pointer** — replace:

Old: `Each roadmap item carries `review-dimensions: [...]`, drawn from the project's`
New: `Each item file carries `review-dimensions: [...]` frontmatter, drawn from the project's`

And replace (same section, the `security` bullet is unaffected):
Old: `(from the item's `review-dimensions` tags\nin `ROADMAP.md` — see below): run each required extra reviewer before the PR.`
New: `(from the item file's `review-dimensions`\nfrontmatter — see below): run each required extra reviewer before the PR.`

- [ ] **Step 4: Hygiene — status flips verified** — replace:

Old:
```
- `ROADMAP.md` status updates are part of the item's PR, not separate commits.
```
New:
```
- Item status updates (the `status:` flip in the item's `roadmap/<ID>.md`) are
  part of the item's PR, not separate commits — conflict-free by construction
  (disjoint files). Verified, not trusted (agent-self-reported task state is
  unreliable — Anthropic's own agent-teams docs): after a merge lands, confirm
  the merged item file on `main` reads `status: done`; a missed flip is a
  worker error, fixed through the next gated PR (e.g. folded into the next
  queued item's branch), never by committing to `main`.
```

- [ ] **Step 5: Deferred section** — replacements:

Old: `**Premise (required on every deferred item).** Each deferred item carries a\n`Premise:` line — the assumption it is waiting on, written wherever possible as a`
New: `**Premise (required on every deferred item).** Each deferred item carries a\n`premise:` frontmatter key — the assumption it is waiting on, written wherever possible as a`

Old (the item-level vs milestone-level paragraph): replace the two sentences
```
The unblock scan is
*item-level*: it fires when a `Depends on:` entry that names a **taggable item**
(a numbered sub-item like `F4.3`, using the configured milestone prefix) turns
`[done]`. A dependency on a **whole milestone** — a bare `F4`, whose section
header never carries a status tag (only numbered sub-items do) — is **not**
auto-scannable and must not be treated as `[done]` by text-match (nor as
vacuously done because the milestone has no items yet).
```
New:
```
The unblock scan is
*item-level*: it fires when a `depends_on` entry that names an **item** (a
dotted ID like `F4.3`, using the configured milestone prefix) turns
`status: done` in its file. A dependency on a **whole milestone** — a bare
`F4`, which has no single file to read a status from — is **not**
auto-scannable and must not be treated as done by text-match (nor as
vacuously done because the milestone has no item files yet).
```

Old: `annotate it\n`> **UNBLOCKED (YYYY-MM-DD):** <what shipped vs. the premise>`, and list it in`
New: `annotate it\n`> **UNBLOCKED (YYYY-MM-DD):** <what shipped vs. the premise>` under its `## Notes`, and list it in`

Old: `**No longer makes sense** → **propose drop.** Move the item to the\n`## Archived / dropped` section with a one-line reason.`
New: `**No longer makes sense** → **propose drop.** Move the file to\n`roadmap/archive/` with `status: dropped` and a one-line `dropped_reason:`.`

Old: ``[done]`?", recomputed from `ROADMAP.md`, so missing it once costs nothing):**`
New: `done?", recomputed from the item files, so missing it once costs nothing):**`

Old: `**Backstop — `/milestone` pre-flight.** `/milestone` re-runs the same scan when\nit reads `ROADMAP.md`, catching`
New: `**Backstop — `/milestone` pre-flight.** `/milestone` re-runs the same scan when\nit reads the backlog, catching`

Also in this section: replace remaining `Depends on:` with `depends_on` and `[done]`/`[todo]`/`[deferred]`/`[blocked]` with `status: done` / `status: todo` / `deferred` / `blocked` phrasing where they refer to the new frontmatter (keep the conceptual tag names in the two definition bullets at the top of the section — they define the states, which still exist).

- [ ] **Step 6: Milestone brainstorm section** — replacements:

Old: `draft items in the ROADMAP house format (status tag, `Depends on:`,\n   `review-dimensions:`, e2e acceptance criteria).`
New: `draft items in the item-file format (frontmatter + Spec/Acceptance body —\n   see **Backlog format (file-per-item)**).`

Old: `the items are written into `ROADMAP.md`'s active section via a PR through the\n   gate.`
New: `the item files are written under `backlog.dir` (plus the index's\n   milestone-list update) via a PR through the gate, linted by\n   `roadmap-lint.sh` before the PR opens.`

- [ ] **Step 7: Milestone audit triage buckets** — replacements:

Old: `append as an audit-follow-up\n   fix-item (using the milestone prefix, e.g. `FA.*`) at the top of `ROADMAP.md`\n   (`[todo]`, tagged), under this milestone's `## <milestone> audit follow-ups`\n   section. Hands-off. These are **auto-folded, debt-first, into the next\n   `/milestone` run** — its pre-flight audit-debt scan collects every unblocked\n   `[todo]` under a `## <milestone> audit follow-ups` section and drains it ahead`
New: `write it as a new item file under\n   `backlog.dir` with `followup_of: <milestone>` set (`status: todo`, tagged,\n   lint-clean). Hands-off. These are **auto-folded, debt-first, into the next\n   `/milestone` run** — its pre-flight audit-debt scan collects every unblocked\n   todo item file with `followup_of:` set and drains it ahead`

Old: `Write it to `ROADMAP.md` as a `[blocked]` entry with the question verbatim,\n   push-notify the human, and move on. It waits for their `> ANSWER:` line exactly`
New: `Write it as a `status: blocked` item file with the question verbatim in\n   `blocked:`, push-notify the human, and move on. It waits for their\n   `> ANSWER:` line exactly`

- [ ] **Step 8: Coordinator mode** — replacements:

Old:
```
1. **Frontier:** every unblocked `[todo]` item, debt-first, top-of-file
   order — the `/milestone` picker taking the top K instead of the top 1.
   Recompute after every merge or block (a merge may unblock items).
```
New:
```
1. **Frontier:** every unblocked `status: todo` item that **passes
   `roadmap-lint.sh`** (the spec gate — a todo item failing lint is not
   runnable: fix mechanically or escalate), in frontier order (debt-first,
   then index milestone order, then numeric item order) — the `/milestone`
   picker taking the top K instead of the top 1. Recompute after every merge
   or block (a merge may unblock items), and dispatch **event-driven**: the
   moment a merge frees or unblocks a slot, fill it — never hold dispatch
   waiting for the rest of a "wave" to finish.
```

Old: `Co-dispatch judgment rule: never two items plausibly touching\n   the same surface at once; two `migration`-tagged items NEVER run\n   together.`
New: `Co-dispatch rules: items sharing a `lane:` value NEVER run together (a\n   declared coupled chain is serial by construction); two `migration`-tagged\n   items NEVER run together; and judgment on top — never co-dispatch two\n   items plausibly touching the same surface (the **Interfaces** bullets are\n   the first thing to compare).`

Old: `A textual conflict\n   during the rebase — including ROADMAP.md status-line conflicts — is\n   resolved by the owning worker, never by force-pushing over the other side.`
New: `A textual conflict\n   during the rebase — rare by construction now that status lives in\n   per-item files and the index changes only at milestone boundaries — is\n   resolved by the owning worker, never by force-pushing over the other side.`

INSERT after the numbered list's item 4 (Board), as a new paragraph before **Failure handling**:
```
**Width is review bandwidth, not worker capacity.** A dispatch slot is held
until the item's PR *merges* — not until code-complete — so open unmerged PRs
consume width and the queue self-throttles to what actually lands. This is
the practitioner-converged constraint ("it's only so much my mind can
review"): more workers than the merge queue can absorb just piles up unmerged
branches going stale. Raise `parallel:` only when the instrumentation shows
the queue, not the workers, is idle.
```

- [ ] **Step 9: Three loops + build order + pick-up-cold** — replacements:

Old: `**Prompting loop — fully automated.** `ROADMAP.md` is the interface: the agent\n   always picks the top unblocked item.`
New: `**Prompting loop — fully automated.** The backlog is the interface (index +\n   item files): the agent always picks the first unblocked item in frontier\n   order.`

Old: `if an item is\n   ambiguous or a gate stays red after ~3 distinct attempts, mark the item\n   blocked with a written question in `ROADMAP.md`, notify the human, move to the\n   next item.`
New: `if an item is\n   ambiguous or a gate stays red after ~3 distinct attempts, set the item's\n   file to `status: blocked` with the written question in `blocked:`, notify\n   the human, move to the next item.`

Old: `**`ROADMAP.md`** — the first milestone broken into 3–5 feature-sized items with\n   acceptance criteria; a rough sketch of the next milestones.`
New: `**The backlog** — the `ROADMAP.md` index plus the first milestone broken\n   into 3–5 feature-sized item files with acceptance criteria; a rough sketch\n   of the next milestones in the index.`

Old: `then `git log --oneline -20` and `ROADMAP.md` (if it exists yet).\n2. If `ROADMAP.md` is missing, the current task is step 2 of the build order:`
New: `then `git log --oneline -20` and the backlog (`ROADMAP.md` index +\n   `roadmap/`, if they exist yet).\n2. If the backlog is missing, the current task is step 2 of the build order:`

- [ ] **Step 10: Verify + commit** — `grep -n "top-of-file order\|house format\|audit follow-ups\` section\|Premise:\` line" plugin/playbook/agentic-loop-playbook.md` returns nothing; `grep -c "Backlog format" plugin/playbook/agentic-loop-playbook.md` ≥ 4.

```bash
git add plugin/playbook/agentic-loop-playbook.md
git commit -m "feat(doctrine): file-per-item backlog format, spec gate, lane + event-driven frontier, review-bandwidth width"
```

---

### Task 4: Commands, skill, workflow

**Files:**
- Modify: `plugin/commands/roadmap.md`
- Modify: `plugin/commands/milestone.md`
- Modify: `plugin/commands/milestone-audit.md`
- Modify: `plugin/commands/loop-schedule.md`
- Modify: `plugin/skills/milestone-cross-check/SKILL.md`
- Modify: `plugin/workflows/milestone-audit.js`

**Interfaces:**
- Consumes: playbook section title "Backlog format (file-per-item)", `backlog.dir`, `roadmap-lint.sh` (Tasks 1, 3).

- [ ] **Step 1: `roadmap.md`** —

Old: `Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and\n`ROADMAP.md` (`backlog.file`) first.`
New: `Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and\nthe backlog first — `backlog.file` (the index) plus the item files under\n`backlog.dir` (see the playbook's "Backlog format (file-per-item)" section).\n**Legacy pre-flight:** if `backlog.file` still contains item headers\n(`### … [todo]`-style), run the one-time migration defined there (one PR\nthrough the gate) before anything below.`

Old: `otherwise the next milestone from the "Later milestones" sketch\n  that has **no active ROADMAP items yet** (the next one to author), using the\n  default prefix above.`
New: `otherwise the next milestone from the index's "Later milestones" sketch\n  that has **no item files yet** under `backlog.dir` (the next one to author),\n  using the default prefix above.`

Old: `Lock the core decisions\n   and draft items in the ROADMAP house format (status tag, `Depends on:`,\n   `review-dimensions:`, e2e acceptance criteria). Before drafting, surface any\n   outstanding audit follow-ups (unblocked `[todo]` items under a\n   `## <prefix># audit follow-ups` section, for any configured prefix) as\n   read-only context, so the\n   new milestone isn't authored blind to pending fixes on the same surface. When\n   scanning for these, match only ROADMAP item headers (`### …` lines carrying a\n   status tag), never the status-tag legend/explainer line or a prose mention of\n   a tag. Do NOT drain`
New: `Lock the core decisions\n   and draft items in the item-file format (frontmatter + Spec/Acceptance\n   body — the playbook's "Backlog format (file-per-item)" section). Before\n   drafting, surface any outstanding audit follow-ups (unblocked\n   `status: todo` item files with `followup_of:` set, any configured prefix)\n   as read-only context, so the new milestone isn't authored blind to pending\n   fixes on the same surface. Do NOT drain`

Old: `**Reconcile** — after the human answers the forks, write the milestone into\nROADMAP.md's active section as a PR through the gate (move it out of the\n"Later milestones" sketch).`
New: `**Reconcile** — after the human answers the forks, write one item file per\ndrafted item under `backlog.dir`, update the index's milestone list (move the\nmilestone out of "Later milestones"), and run\n`bash ${CLAUDE_PLUGIN_ROOT}/hooks/roadmap-lint.sh <file>` on every new item\nfile — fix failures before the PR opens (authoring and dispatch share one\nspec gate). All of it lands as one PR through the gate.`

Also replace the remaining `ROADMAP.md` mentions in the intro/step-4 prose with "the backlog"/"the index" as grammar requires (step 4's merge/cleanup mechanics are unchanged).

- [ ] **Step 2: `milestone.md`** —

Old: `Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and\n`ROADMAP.md` (`backlog.file`) first.`
New: `Read `CLAUDE.md`, `${CLAUDE_PLUGIN_ROOT}/playbook/agentic-loop-playbook.md`, and\nthe backlog first — `backlog.file` (the index) plus the item files under\n`backlog.dir` (playbook: "Backlog format (file-per-item)").\n**Legacy pre-flight:** if `backlog.file` still contains item headers\n(`### … [todo]`-style), run the one-time migration defined there (one PR\nthrough the gate) before anything below.`

Old: `otherwise the next runnable milestone in ROADMAP.md —\n  across ALL configured prefixes, taken in top-of-file order — that has `[todo]`\n  items whose dependencies are all `[done]` (the next runnable milestone).`
New: `otherwise the next runnable milestone —\n  across ALL configured prefixes, in the index's milestone order — that has\n  `status: todo` item files whose dependencies are all satisfied (the next\n  runnable milestone).`

Replace the deferred-backstop paragraph body:
Old: `Before\nresolving the milestone, scan ROADMAP.md for newly-unblocked **`[deferred]`**\nitems — these may have unblocked outside an autonomous run (e.g. a hand-merged\ndependency) and the end-of-run scan never fired. Match only ROADMAP **item\nheaders** (lines beginning with `### ` that carry a status tag) — never the\nstatus-tag legend/explainer line or a prose mention of `[deferred]`, both of\nwhich are false positives for a naive substring match. An item counts as unblocked when\neither: (a) every **item-level** `Depends on:` (a taggable ID like `F4.3` or\n`DS.4`, using any configured prefix) is `[done]`; or (b) a **milestone-level**\n`Depends on:` (a bare milestone tag like `F#` or `DS#`) has *completed* — that\nmilestone's section exists and every item in it is `[done]` (this pre-flight\nis the designated surfacing point for milestone-level deps, which the item\nscan cannot catch). For each unblocked\nitem, apply the lifecycle: if its `Premise:` is machine-checkable and verifiably\nholds, promote it to `[todo]``
New: `Before\nresolving the milestone, scan `backlog.dir` for newly-unblocked\n**`status: deferred`** item files — these may have unblocked outside an\nautonomous run (e.g. a hand-merged dependency) and the end-of-run scan never\nfired. (A frontmatter scan — no header matching needed.) An item counts as unblocked when\neither: (a) every **item-level** `depends_on` entry (a dotted ID like `F4.3`\nor `DS.4`, any configured prefix) has its file at `status: done`; or (b) a\n**milestone-level** entry (a bare tag like `F#` or `DS#`) has *completed* —\nitem files for that milestone exist and every one is `status: done` (this\npre-flight is the designated surfacing point for milestone-level deps, which\nthe item scan cannot catch). For each unblocked\nitem, apply the lifecycle: if its `premise:` is machine-checkable and verifiably\nholds, promote it to `status: todo``

Replace the audit-debt scan body:
Old: `Collect the\ndebt set `D`: every `### …` item under a `## <prefix># audit follow-ups`\nsection — for ANY configured prefix (e.g. `## F2 audit follow-ups` or `## DS.3\naudit follow-ups`) — that is `[todo]` AND unblocked (all `Depends on:` items are `[done]`;\n`[blocked]` and `[deferred]` items are excluded — same rule as the\ntop-of-backlog picker). As with the deferred scan, match only ROADMAP item\nheaders (`### …` lines carrying a status tag), never the status-tag\nlegend/explainer line or a prose mention of a tag. These are auto-folded`
New: `Collect the\ndebt set `D`: every item file with `followup_of:` set — for ANY configured\nprefix — that is `status: todo` AND unblocked (all `depends_on` satisfied;\nblocked and deferred items are excluded — same rule as the frontier picker).\nA frontmatter scan; no header matching. These are auto-folded`

INSERT at the end of the "Parallel width (coordinator mode)" paragraph:
```
Before any dispatch (either mode, serial included), run the spec gate on the
item: `bash ${CLAUDE_PLUGIN_ROOT}/hooks/roadmap-lint.sh <backlog.dir>/<ID>.md`
— a failing todo item is not runnable (fix mechanically or escalate), per the
playbook's Backlog format section.
```

- [ ] **Step 3: `milestone-audit.md`** — mirror the playbook's bucket wording:

Old: `**Small gap / non-urgent** (races, infra) — append it as a `[todo]`,\n   tagged fix-item (using the milestone prefix, e.g. `FA.*`) at the top of\n   `ROADMAP.md`, under a `## <milestone> audit follow-ups` section. These\n   auto-fold, debt-first, into the next `/milestone` run.`
New: `**Small gap / non-urgent** (races, infra) — write it as a new item file\n   under `backlog.dir` with `followup_of: <milestone>` (`status: todo`,\n   tagged, lint-clean). These auto-fold, debt-first, into the next\n   `/milestone` run.`

Old: `Write it to `ROADMAP.md` as a `[blocked]` entry with the question verbatim,\n   push-notify the human, and move on.`
New: `Write it as a `status: blocked` item file with the question verbatim in\n   `blocked:`, push-notify the human, and move on.`

Also: `and `ROADMAP.md` (`backlog.file`) first.` → `and the backlog (index + item files under `backlog.dir`) first.`; `infer the\nrange from the backlog file's `[done]` items` → `infer the\nrange from the item files at `status: done``.

- [ ] **Step 4: `loop-schedule.md`** —

Old: `> Drain the top unblocked backlog items in ROADMAP.md per the sweap playbook.`
New: `> Drain the backlog's unblocked items in frontier order (index + item files\n> under `backlog.dir`) per the sweap playbook.`

Old: `blocker to a `[blocked]` ROADMAP entry plus a notification instead of`
New: `blocker to a `status: blocked` item file plus a notification instead of`

Check the file's read-list line and milestone-resolution line for `ROADMAP.md` mentions; align them to "the backlog (index + item files)" phrasing.

- [ ] **Step 5: `milestone-cross-check/SKILL.md`** —

Old (frontmatter description): `Completeness critic for a drafted milestone ROADMAP section. Use AFTER an interactive superpowers:brainstorming pass has produced draft items and BEFORE writing them to ROADMAP.md.`
New: `Completeness critic for a milestone's drafted item files. Use AFTER an interactive superpowers:brainstorming pass has produced draft items and BEFORE writing them under backlog.dir (roadmap/).`

Old: `- `ROADMAP.md` (prior milestones, house format, the project's core invariants),`
New: `- the backlog (the `ROADMAP.md` index + prior milestones' item files under\n  `roadmap/`; the item schema lives in the playbook's "Backlog format"\n  section),`

- [ ] **Step 6: `milestone-audit.js`** — in the `meta` `whenToUse` string:

Old: `Pass {range: "<base>..<head>"} or let the Scope stage infer it from the backlog file (ROADMAP.md by default; backlog.file in the project CLAUDE.md config).`
New: `Pass {range: "<base>..<head>"} or let the Scope stage infer it from the backlog (item files at status: done under backlog.dir, roadmap/ by default; backlog.file is the index).`

Then `grep -n "ROADMAP\|backlog" plugin/workflows/milestone-audit.js` and align any scope-stage prompt text the same way (item files' `status: done`, not `[done]` headers).

- [ ] **Step 7: Verify + commit** — `grep -rn "audit follow-ups\` section\|house format\|top-of-file order\|match only ROADMAP" plugin/commands plugin/skills` returns nothing.

```bash
git add plugin/commands plugin/skills/milestone-cross-check/SKILL.md plugin/workflows/milestone-audit.js
git commit -m "feat(commands): backlog = index + item files — frontmatter scans, lint gate, legacy pre-flight"
```

---

### Task 5: Consistency sweep

**Files:**
- Possibly modify: `README.md`, `plugin/commands/agentic-loop-init.md`, any file the greps surface.

- [ ] **Step 1: Sweep** — run and fix every hit that still assumes the monolithic format (item headers in ROADMAP.md, `[todo]`-in-file pickers, `Depends on:` frontmatter-era references):

```bash
grep -rn "Depends on:" plugin README.md
grep -rn "top unblocked" plugin README.md
grep -rn "### F" plugin/templates
grep -rn "status tag" plugin
grep -rniE "roadmap\.md" plugin README.md | grep -viE "index|backlog.file|legacy|migrat"
```
Judgment call per hit: references to the *index* or to `backlog.file` stay; references implying items-live-inside-ROADMAP.md get the new phrasing. `agentic-loop-init.md`'s "Write the first ROADMAP milestone with `/roadmap`" → "Write the first milestone with `/roadmap` (item files under `roadmap/`)".

- [ ] **Step 2: Full test re-run** — `bash plugin/hooks/roadmap-lint.test.sh` (14 passed) and `bash plugin/hooks/pre-merge-gate.test.sh` (63 passed).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: consistency sweep for file-per-item backlog"
```
