# The merge gate's audit step: what it costs, why, and the fix (2026-09-23)

Trigger: consumer A PR #388 was denied twice with "audit gate refused: audit-gate
timed out" while green. sweap 0.31.1 raised the gate's budgets (10 → 40 s per
PR) and 0.31.2 corrected the claim that the step takes 20 ms. This memo is the
structural fix, written before it is built so three refuters can kill it.

## Measured (consumer A, 2026-09-23, 264 done items, five audit records)

| PR shape | `audit-gate.sh --files`, idle |
|---|---|
| touches any item file | 7.4 s (a full `--check` is 7.4 s too) |
| code only | 4 ms (the early exit at the top of merge mode) |

The 7.4 s is process spawns, not history search: merge mode calls
`validate_record` for every record of a complete milestone, and per record that
is one `roadmap-lint` run per follow-up the record declares (91 across the five
records, 56 ms each ≈ 5 s) plus one path-limited `git log -S` (~30 ms) and one
`git merge-base` (~28 ms) per done item the milestone holds (51 each ≈ 2 s).
Under a Mac at load 13 (both self-hosted runners busy plus an e2e run) it took
about 3x that. It grows with every audited milestone's follow-ups and done
items: F12 alone declares 26 follow-ups.

## Where the validation is redundant, and where it is not

The gate calls `--files` in the PRIMARY checkout on the base branch, so
everything it validates is the base's state — the PR's own edits are not
visible to it. The script's own merge-mode header says so: "a ROUTING decision
… never a validity decision. Validity is decided by --check", by (1) the CI job
that runs `--check` then `--files` on the PR's merge commit, and (2)
`post-merge-auditcheck.sh` after every merge. And the gate has already, two
seconds earlier in the same hook, verified that the PR's rollup is green with
the `audit-gate` contract check present and not skipped, and that the PR is not
behind base. So on a consumer with the CI job, the local verdict cannot differ
from CI's.

It is NOT redundant on a consumer whose CI job is missing, skipped or
skew-broken — the 2026-08-11 miss, when "every local control was
version-skewed" — and the tests pin that belt: T23, T28 and T30 require an
invalid record on main to block an item-file PR in merge mode with no CI in the
picture, and T29 forbids a broken record from becoming non-blocking by losing
a key. Any fix that drops the local validation fails those tests and reopens
the hole they were written for.

## Alternatives rejected

- **Routing-only merge mode** (record present ⇒ not debt; ~15 lines): fails
  T23/T28/T30; removes the local belt exactly where the header says it is the
  only one.
- **Skip validation when the working tree equals origin/main for the backlog
  dir** (~10 lines): same failure on T28 (record committed and identical to
  the anchor, still expected to deny).
- **Batch the lints and pickaxes**: a batch mode for `roadmap-lint` saves the
  per-file bash start-up, not the awk/sed pipelines (~4.5 s from 7.4); the
  `-S` per path is deliberately not batched (the comment in the done-item loop
  says why: `-S` over a directory answers a different question).
- **Bigger budgets**: 0.31.1 already did this; it is a knob, and the number
  keeps growing.

## Design: memoize valid verdicts on the inputs the validation read

`validate_record`'s verdict is a pure function of a finite input set. The fix
records, for each record it validated successfully, the set of paths it read
and a key over those inputs, and on the next run re-derives the key first; a
match means a fresh validation would pass, so it is skipped. An invalid record
is never cached: it is re-validated (and denied) every time, exactly as today.

Inputs, and how the key captures each:

| input the verdict depends on | captured by |
|---|---|
| the record's content (keys, counts, dispositions, axes) | `git hash-object` of the record file |
| each follow-up / blocked item the record references: existence, content, `followup_of`, lint result | `git hash-object` of each (a missing file hashes as `missing`) |
| each done item of the milestone: the commit that introduced `status: done` and its reachability from `range_head` | `git log -1 --format=%H -- <every recorded path>` (any new commit touching any of them moves it; a history rewrite changes every descendant id) plus the item's blob hash |
| the set of done items of the milestone | the milestone's rows from the single ITEMS scan (id and status), already in memory |
| `roadmap-lint`'s cross-file check that `depends_on` targets exist | the sorted list of all top-level item ids (existence only — a status flip elsewhere does not invalidate) |
| `range_base` / `range_head` resolve to themselves, base is an ancestor of head, `open_at_audit` blobs at head, the flip commit's path list | immutable given the SHAs; the SHAs are in the record's content |
| `range_head` is an ancestor of HEAD | NOT cached: re-checked live on every hit (one `merge-base`, ~28 ms) — HEAD moves every merge and a reset of main can un-ancestor it |
| the validator itself and the format it speaks | a hash of `audit-gate.sh` and `roadmap-lint.sh`, plus `RECORD_FORMAT` and the cache-layout version |
| the backlog location and config | `BACKLOG_DIR` and `git hash-object CLAUDE.md` |

The path set is collected by the reads themselves (every `fm_get`, lint, `git
log` and `hg_status_at` call site inside `validate_record` appends its path),
not by a hand-written list, so a new read site that forgets to register is the
one way the key can miss an input — a wiring test greps for that.

Store: `.claude/sweap-merge/audit-valid/<milestone>` in the checkout the gate
runs in (`.claude/sweap-merge/` is already in the scaffold's gitignore rule);
one line `key: <sha256>` then the recorded paths, one per line. Written via a
temp file and `mv` only after `ok=1`. Read only in `--files` mode; `--check`
(CI, post-merge, /milestone pre-flights) always validates in full. Anything
unreadable, malformed or with a differing key means a full validation. A
`SWEAP_AUDIT_CACHE=0` environment variable disables reads and writes (tests,
debugging). No sha256 tool on the machine means no cache, never a deny.

Steady-state cost per record: one `git hash-object` over the recorded paths,
one `git log -1`, one `merge-base`, one hash — about four spawns, ~0.1 s; five
records ≈ 0.3 s in place of 7.4 s. The first run after any change to a
record's inputs pays the full price for that record only.

## Claims (each falsifiable; a refuter scores each)

C1. The verdict of `validate_record` in merge mode depends on nothing outside
    the table above. (Refute by naming a read, a git fact or a config value
    that can change the verdict without changing the key.)
C2. Caching only VALID verdicts, keyed as above, cannot flip any verdict: a
    key match implies a fresh validation would also pass; an invalid record is
    unaffected. (Refute with a concrete sequence: cache written, then a change
    that a fresh validation would fail, with the key unchanged.)
C3. The steady-state cost is ≤0.3 s on consumer A and does not grow with audited
    milestones; the first-run cost is unchanged.
C4. The store is safe: gitignored, atomic, self-healing on corruption,
    disabled by env, absent from `--check`, harmless when written by CI's
    `--files` in a throwaway checkout, correct under two concurrent gates, and
    within sweap's existing threat model (a model with shell access can
    already edit the record or the item files; forging a cache entry buys it
    nothing that CI's `--check` on the PR does not catch, and nothing it could
    not do by editing the record).
C5. No cheaper or simpler fix keeps T23/T28/T29/T30 green.
C6. With 0.31.1's 40 s cap and a ~0.3 s step, a loaded Mac no longer produces
    a false deny on this step, and the growth per audited milestone stops
    mattering.

## Refutation

Three refuters — key completeness, alternatives and cost, operations and
threat model — scored the claims; two scores at or above 0.5 strike one.

| claim | key | alternatives | operations | verdict |
|---|---|---|---|---|
| C1 verdict depends on nothing outside the table | 0.90 | — | — | **refuted by demonstration** |
| C2 caching valid verdicts cannot flip one | 0.85 | — | — | **refuted by demonstration** |
| C3 ≤0.3 s steady state, no growth | — | 0.70 | — | refuted (0.45–0.6 s idle, 1.5–2 s loaded; +50 ms per record) |
| C4 the store is safe / within the threat model | 0.50 | — | 0.65 | **struck** |
| C5 no simpler fix keeps the tests green | — | 0.90 | — | **refuted by construction** |
| C6 no false deny on a loaded Mac | — | 0.50 | 0.40 | refuted on misses (the uncached path is unchanged) |

**The cache is dead.** The validator is not a pure function of the inputs it
reads. Reproduced here, no exotic tooling: a done item authored with
`followup_of: F1` after the audit, never referenced by the record, passes
merge mode; a later commit that only removes that `followup_of:` line makes
the same PR deny — while the record blob, the item blobs and the last commit
touching every read path are byte-identical. The membership test at the top of
the done-item loop reads a column the key never saw. The key-completeness
refuter found five more classes with tested repos: `git replace` grafts and a
shallow clone change ancestry with every id unchanged; `log.follow = true`
changes the per-path pickaxe; a follow-up's `depends_on` target under a
subdirectory is probed by the lint and enumerated by nothing; `git hash-object`
without `--no-filters` hashes cleaned content; `core.quotePath` decides what
the hand-off carve-out sees. Each has a patch; the shape does not: every hidden
input a refuter did not find is a stale "valid", and a stale valid is an
allow. The operations refuter added that the entry is forgeable by anything
with shell access, and stealthier than editing the record (gitignored,
survives pull and reset, never re-examined), and that a store whose file
lists its own inputs lets the writer pick them. And no existing test ever
validates a valid record in merge mode, so the cache path would have had zero
coverage.

**A second design died in review.** The alternatives refuter built and
measured a directory-wide pickaxe (`git log --name-only --no-renames -S -- <backlog dir>`
joined against one `rev-list` per record) that matched the per-path answer 41
of 41 on consumer A and on synthetic co-edit, flip-unflip-flip and merge repos, and
it was built. The fresh-context review of the diff then found the case those
repos lacked: git's default history simplification is decided PER PATHSPEC. A
merge that is TREESAME to the mainline parent for one item file is followed
along that parent only when the pathspec is that file, but walked on both sides
when the pathspec is the directory. Reproduced: a branch flips F1.1 done, the
merge puts it back to todo, the mainline flips it done after the audit's
range_head. Per path, the flip is the mainline commit, outside the range, and
the record fails — correctly. Directory-wide, the older branch-side flip is
attributed, it is reachable, and the record validates. Fail-open on the exact
shape the check exists for, and the mirror shape fails closed on a record that
was valid. The batching is reverted; T75 fences it.

**What survived, built as 0.32.0.**

- **One `rev-list` per record instead of one `merge-base` per done item.** A
  commit is an ancestor of range_head exactly when it is in
  `git rev-list range_head`, and a 40-hex sha can only match a whole line of
  that list. Identical semantics; 51 git spawns become 5 on consumer A.
- **The pickaxe stays per path**, with `log.follow` and literal pathspecs
  pinned so a developer's git config cannot change the answer.
- **Each (kind, id) disposition reference judged once.** consumer A F12 names 25
  follow-ups under 51 blocks; 26 of the 91 lint runs per gate call were repeats.
- **The gate runs from the repository root, fail-closed.** From a subdirectory
  it found no CLAUDE.md, no items and no debt, and exited 0.
- **Hermetic git.** Replace refs ignored for the run; `core.quotePath` pinned
  where the hand-off carve-out reads paths.
- **The merge gate requires the `audit-gate` check to be present** when the
  repo declares the job, as it already did for `ci-status`, and both
  declarations are now read from the repository root rather than the session's
  cwd, where a subdirectory made them silently not apply.
- **The post-merge backstop says when it times out** (28 s under a 30 s hook
  timeout, instead of 20 s under 25 and silence).

**Not built: skipping the follow-up lint in merge mode.** Two lines, all tests
green, 4.0 s idle from 6.0 (measured on the pre-0.32.0 script). It is a semantic change — a follow-up that later
fails lint would no longer count as debt in merge mode (it still would in
`--check` on CI and after every merge) — and no test pins it either way. That
is the maintainer's call; the numbers: with it, ~2.5 s idle / ~11 s at load 16;
without, ~4.2 s idle / ~20 s at load 16, against a per-PR cap of 40 s minus two
gh calls (~9 s at load 13).

**Cost after 0.32.0, consumer A.** Idle: from 6.0–7.4 s to ~4.5 s (measured
below). At load 16 the per-path pickaxes (~3.2 s) remain and the merge-base
line (~1.7 s) and 26 repeat lints (~5 s) are gone: an estimated ~24 s against a
cap of 40 s minus two gh calls. The step still grows with each audited
milestone's distinct follow-ups and done items; only the ancestry line stopped
growing.

**Also corrected.** The 20 ms figure in #61 timed the empty-file-list fast
path; the memo's own "about four spawns, ~0.1 s per record" arithmetic did not
add up to its 0.3 s; and the redundancy argument overstated the rollup check,
which required `ci-status` to be present but not `audit-gate` (now fixed).
