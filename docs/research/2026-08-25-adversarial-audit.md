# What survives when every finding has to beat its own refuters — a whole-repo audit of sweap

**Research memo — 2026-08-25.** Question: six weeks and 107 commits in, are
sweap's decisions the right ones? Not "is the code correct" — the test suites
answer that — but whether the *architecture* holds: a client-side hook as the
only merge enforcement on GitHub Free, an audit record the audited agent
writes, a roadmap that lives as markdown files on `main`, vendored scripts
rewritten on every session start, same-model refuters as the audit's evidence
standard. Which of those would a seasoned engineer challenge, does the
challenge survive contact with the code and the published prior art, and —
the part that matters — do the *fixes* survive the same treatment?

Method: five rounds, each a fan-out of agents with repo access, and from round
three web access. **(1)** Eight area auditors (merge gate, audit enforcement,
roadmap substrate, run lifecycle, board, templates/CI, plugin packaging,
strategy) produced ≤3 findings each; every finding was attacked by two refuters
with distinct lenses (evidence-in-code; design-alternatives given the
constraints). **(2)** The eleven recommendations that came out were each
attacked by three hostile reviewers (cost/benefit; wrong-fix/side-effects;
premise), majority kills. **(3)** Four hunters looked for decisions that are
*controversial at first sight*; a dedup pass; then one web-research agent per
decision (≥3 searches, ≥3 sources read). **(4)** Three hostile reviewers per
confirmed concern, majority kills. **(5)** For everything still standing, one
researcher checked the fix against lab/vendor/practitioner guidance and one
skeptic tried to break the resulting spec against the tests and the playbook.
Only then was anything built. 132 agents in total; roughly 6.3M subagent
tokens; 1,318 tool calls. Cited URLs were fetched by the pass that cites them.
The per-vote reasoning is in the session's task outputs, not in this repo.

---

## 0. The one-sentence answer

**The core is sound and the fixes were mostly wrong:** of 24 first-round
findings all 24 survived refutation, but of the 11 recommendations built on
them only 3 survived hostile review; of 6 controversial-looking decisions, 5
were confirmed as real concerns and *zero* of their recommendations survived —
each lost to something already in a spec, a memo, a test, or a commit message.
The repeatable lesson is not about any one hook. It is that **a problem being
real says nothing about a fix being right**, and the cheap way to learn that is
to make every fix beat three people paid to stop it, *before* building it.

## 1. What was confirmed sound under pressure

These were attacked and held, in some cases twice:

- **Fail-closed hook mechanics.** Never allows, only denies; always exit 0 with
  an EXIT-trap deny; jq/parser absence denies; the greedy-then-precise
  agreement rule (`lib-merge-parse.sh`). External evidence strengthened it:
  the GuardFall research note (CSA, June 2026) bypassed 10 of 11 open-source
  coding agents' bash guards *including tokenized parsers*, so a tree-sitter
  AST would not close the `eval`/`bash -c` residual either; Claude Code's own
  permission matcher has shipped fail-open compound-command bugs (#36637,
  #28784) — exactly the class the greedy trip-wire inverts. No agent framework
  (OpenHands, SWE-agent, Aider) ships a self-merge gate at all.
- **The client-side hook as THE enforcement on GitHub Free.** Rulesets, merge
  queue, and pre-receive hooks are unavailable on private Free repos; a GitHub
  App check-run can only block through a required-check rule that 403s. There
  is no non-bypassable server-side option; detect-and-revert after the fact
  (`post-merge-auditcheck.sh`) is the only server-adjacent move, and sweap has
  it.
- **The self-authored audit record.** Committing `journal.jsonl` buys zero
  forgery resistance (same author, same PR). Both "hollow record" incidents are
  already closed by `sweap_format`/required keys (0899766) and
  `finders_reporting` (87d1b7f). F9 never went *through* the gate — no gate was
  running.
- **File-per-item on `main`**, the notes-not-items inbox, and the
  membership-based frontier failing closed. `verifyEnd` re-deriving the run's
  end claim; `idle` computed structurally, never from activity.
- **Serial-by-default workers** (`parallel: 1`) after building the coordinator
  — a reversal made on measured data, with re-enable thresholds written down.
- **`AUDIT_GATE_RUNNER` as a repo variable** with a hosted default; the
  reader/prover split with worktree isolation; the board's escaping discipline;
  hook registration including `if` on 2.1.241.
- **Memo→code cadence.** Five of seven research memos landed in ≤3 days. The
  refuters explicitly rejected "sweap should dogfood its own substrate" — a
  `## Landed / Open` block per memo is the proportionate fix for a
  one-maintainer repo.

## 2. What was killed, and the decisive argument

Recorded so the same recommendation is not re-derived by the next auditor.

| Recommendation | Vote | Why it died |
|---|---|---|
| Extend merge gate to `git push`/`gh api` (as first proposed: fail-closed on everything) | 3–0 | Outside the stated threat model (`lib-merge-parse.sh:44-51`, "honest slips, not obfuscation"); `--force-with-lease` is the hot path the gate itself prescribes; blocks sanctioned direct-to-main chores. *A narrowed form — deny only when the destination resolves to the base — was later researched and built (§4).* |
| `permissions.deny: ["Bash(gh pr merge *)"]` as a second line | 3–0 | Deny rules run before hooks and cannot be overridden, so it makes `pre-merge-gate.sh` dead code, halts all merging until the unbuilt `sweap-merge` exists, and silences the three PostToolUse hooks keyed on the string. |
| `checks.expected` manifest (naked) | 2–1 | Read from the PR's own CLAUDE.md it is the merge-driver memo's own "not acceptable" design. The one stale-expected-set incident on record was a *false deny*. (#27 shipped the cheaper form: `ci-status` must be present when declared.) |
| Base-anchor `backlog.dir`/`audit.baseline` | 3–0 | Anchoring `audit.baseline` deadlocks the sanctioned add-to-baseline PR (`audit-gate.sh:409`); the gate already runs from the primary checkout. (#27 closed the actual hole differently: degenerate `backlog.dir: ./` no longer matches every path.) |
| Version-monotonic `sync_managed` | 2–1 | Wrong key: 15 of 21 gate-file commits shipped without a `plugin.json` bump, so "equal version → skip" would have frozen consumers on broken gates. History shows only forward moves; the real failure direction is consumers running an *older* gate, which content-sync closes. |
| `--check --pr` mode for the audit gate | 2–1 | Opens a record-deletion hole (`--files` never sets `touches_items` for `audits/`) and fixes half the symptom. The freeze has cost one 44-minute detour. |
| Vendor the review-verdict step as a managed script | 2–1 | A managed script cannot reach the create-once `claude-review.yml` caller; same one-PR effort as pasting the step. Zero wrong-direction verdicts in consumer B's last 15 PRs. |
| Align board milestone membership with the gate | 3–0 | Filtering `loadItems` blinds the frontier, debt list, and debt-first ordering (#22's core). Board and gate answer different questions by design. |
| `context-exhausted` end reason + worker brief | 2–1 | Unfalsifiable self-report (the model cannot sense fill), contradicting `verifyEnd`'s checked-claim rule. All three agreed the memo itself should be written and `playbook:1390` corrected — still owed. |
| Pin `performed_via_github_app.id` in the verdict jq | 2–1 | Only issue comments carry it; would blind two of the three surfaces consumer A#125 added. The fail-closed self-skip is theatre because the workflow runs on `pull_request`. |
| Commit `journal.jsonl` / recompute audit tallies in the gate | 3–0 | See §1; also ~1 MB of harness-owned, schema-unstable transcript, and recomputing violates `audit-gate.sh:44-47`'s "bash + git only" contract. |
| Diversify refuter seats / span-validate evidence / capture thinking | 3–0 | Span validation cannot live where proposed (Workflow scripts have no fs; a content rejection becomes a lost vote); per-seat model has no runtime surface; diversifying before the Tier-2 labeled set exists is the "re-roll the dice" `milestone-audit.js:365-379` forbids. The cited arXiv 2512.12117 does not report the claimed precision/recall. |

Three refutations were instructive beyond their item: the `finders_reporting`
guard targets only the *mechanical* 0/0/0 shape (a hand-typed 1/1/0 is the
conceded forgery class — R5 in the merge-driver memo is the real closure); the
`audit-agent-guard` subagent-spawn vector does not exist (subagents cannot
nest) and the script sits under a `Write|Edit|NotebookEdit|Bash` matcher, so
inverting it alone changes nothing; and two reviewers independently flagged
that a headless tick writes `sweap-run.md` gitignored in a sandbox the local
board never reads — an unsolved locality problem shared with the merge-driver
watch dir.

## 3. The bugs that were simply bugs

Two findings needed no debate once reproduced:

- **`planBlock` was undefined.** `sweap-board.page.mjs:151` called it (since
  ea3e5e5, #23); every ended run threw inside `tick()` and rendered as
  "disconnected" for four days. The inline script was only ever grep-tested.
- **`bounded_run` leaked a `sleep`.** Its watcher subshell orphaned a `sleep`
  holding the hook's stdout, so every bounded call paid its full timeout when
  read to EOF. Found while adding push-gate tests: the suite took 4 minutes for
  no reason it could name. It now takes 23 seconds.

## 4. What was built (PR #28, 0.12.0)

Each item below passed a source-backed research pass and a skeptic's spec
review; the corrections the skeptic made are the reason the item exists in
this shape and not the first one.

- **Push gate.** `git push` whose destination resolves to the base branch
  (explicit refspec, `HEAD`, bare push via `@{push}`, `--all`/`--mirror`/
  `--branches`) is denied fail-closed under the same greedy+precise rule as
  the merge gate. Item-branch pushes and `--force-with-lease` untouched.
  `SWEAP_PUSH_GATE=off` honoured only from the launching shell or user
  settings, voided if the project's `.claude` settings define it. A hook, not
  a `permissions.deny` rule: Anthropic's permissions doc says Bash deny rules
  are prefix matches that cannot carry allowlist exceptions, so
  `Bash(git push *)` would kill the hot path.
- **Self-modifying CI is never session-mergeable.** A PR touching
  `.github/workflows/**` or `.github/scripts/**` ran its own copy of every
  `pull_request` workflow (GitHub docs: `pull_request_target` runs in the
  default-branch context "rather than in the context of the merge commit, as
  the pull_request event does"). A human merges those.
- **Stamped vendored files.** `# Code generated by sweap <version> (source
  sha256:<12>). DO NOT EDIT.` — visibility only; sync stays `cmp`-based and is
  never gated on the stamp (a content hash, not a commit: the plugin cache dir
  has no `.git`, and a commit stamp would rewrite every file on every unrelated
  plugin commit). Sync skipped on `compact`/`clear`; re-run after the template
  copy so `audit-gate.yml` never ships before its script. New `scaffold.test.sh`.
- **Verdict identity.** Exact `claude[bot]` AND `.user.type == "Bot"`,
  overridable via `vars.CLAUDE_REVIEWER_LOGIN`. Consumers copy it by hand —
  init never overwrites the project-owned workflow.
- **Board.** `planBlock` defined honouring `applicability` (rustc semantics:
  MachineApplicable gets a copy affordance, HasPlaceholders does not); `tick()`
  split into fetch / server / render lanes so a JS error is never reported as
  "disconnected"; a `node:vm` harness executes the real inline script; the
  frontmatter parser is first-wins to match the shell parsers.
- **`/loop-schedule`** references `/milestone`'s pre-flights by name instead of
  embedding them (copying is what drifted); the stale status-based stop clause
  is gone from both it and the playbook. Default: no milestone = recurring
  drain-the-frontier; milestone = once; both = refused. The cloud premise was
  corrected: committed settings register the marketplace but do not install an
  external plugin (≥2.1.195) — the routine's setup script must.
- **`./test.sh`** runs every suite (node 24 rejects bare directories as test
  args); README documents it as the merge bar for a repo with no hosted CI.

## 5. Still owed

- The context-budget memo (research done 2026-08-22, never written) and the
  `playbook` line that implies autocompact protects a run.
- Why the scaffold hook appears never to have fired on consumer B. The stamp makes
  this visible now; it does not explain it.
- Consumer PRs copying the hardened verdict step (consumer A, consumer B), and one
  review of the stamped-managed-files diff each — both opened alongside this
  memo, both to be merged by a human per the rule this round shipped.
- The `sweap-merge` driver (R1 of the 2026-08-22 memo) remains the real
  closure for every gate-shaped residual above; nothing here substitutes for it.

## 6. Evidence strength, bluntly

Strong: the two bugs (reproduced, red-then-green tests); the push-gate and
CI-touch mechanisms (144 gate tests); the kill arguments that cite a specific
line, test, or commit. Medium: the web-sourced claims in §1 — each was read by
one research agent and spot-checked by one skeptic, not independently
replicated. Weak: any count of "incidents on record" — those come from reading
memos and commit messages, and an incident that was never written down is
invisible to this method. The all-24-survive result in round one is itself a
signal that two refuters with a "default to refuted" instruction still concede
too easily when the evidence is real; the three-reviewer, majority-kill shape
of rounds two and four produced the useful discrimination.
