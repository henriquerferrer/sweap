# A stale primary checkout ends a run "drained"; a flake line nothing can commit (2026-11-11)

**What happened.** A run in consumer A (`wf_49ac8a6a-99f`, F15, 0.43.0,
2026-11-09/10) returned `batch and F15 frontier drained` with `stopped: null`
while F15.7 was runnable. That string is word for word the goal's success
condition. The session caught it only because it had printed the last
watcher's free-text `cleanup` field, which said a pull was refused; it
fast-forwarded the checkout by hand and relaunched, and the second run built
F15.7. Its end report also listed one uncommitted line in the primary checkout
that the merge driver had appended to a flake note, "to travel in a PR or be
dropped by you".

Two gaps, investigated separately.

## Gap A: the frontier is read from a checkout the run cannot always advance

**Mechanism (re-verified from code and transcripts).**

1. `sweap-frontier` reads item files from disk in the primary checkout and
   never looks at a ref. The run's Scope stage calls it before every item.
2. The primary is advanced only by best-effort pulls: two in code
   (`post-merge-cleanup.sh`, `post-merge-auditcheck.sh`, both
   `pull --ff-only >/dev/null 2>&1 || true`) and two in prompts (the
   implementer's pre-flight, the watcher's "After merged").
3. git refuses a fast-forward when an uncommitted tracked file is among the
   incoming paths, **even when its bytes are identical to the incoming ones**
   (git 2.50.1, reproduced). A dirty file the incoming commits do not touch
   does not block it — the old comment "no-ops if it has local changes" was
   too broad.
4. `scaffold.sh`'s managed-file sync produces exactly that state. On
   2026-11-09 the human merged the 0.43.0 adoption PR (consumer A PR 497, a
   `.github/` PR an agent may not merge) and restarted the session without
   pulling; the SessionStart hook rewrote two vendored files in the working
   tree to the bytes origin already had. The hook's own stdout names both
   files, 20 seconds before the run launched.
5. 39 pulls were refused (17 implementer pre-flights, 22 watcher pulls), the
   first 90 seconds in; the two in-code pulls failed about 20 times each with
   no trace. The primary ended 21 commits behind. All 21 Scope outputs listed
   the same 20 ids, which were exactly the run's `attempted` set, so the loop
   found nothing to pick and said drained.

**Not a one-off.** A replay over every surviving run journal (14 completed
runs, 105 Scope outputs) for "a frontier listing an id the same run already
merged" fires in exactly two runs: this one (20 of 21 scopes, including the
last) and 2026-09-25 (`wf_6cd74658-d74`, scopes 13 to 15), where six
scaffold-written files collided with the 0.34.0 adoption PR for 2 h 45 min.
That one healed only because a watcher ran `git stash push -u` / pull /
`stash pop` in the maintainer's checkout, against its brief, and never
reported it. Both collisions were byte-identical. The precondition is sweap's
own release cycle: 9 adoption PRs in consumer A since the run workflow
shipped, 2 of which overlapped a run; both produced refused pulls.

**Correction to the first account.** The cost was not 40 minutes: the session
relaunched 64 seconds after the false result, and F15.7's 41 minutes were owed
anyway. The exposure is that the run's end word was false and nothing in code
said so.

**Candidate fixes, three hostile reviewers each (cost, wrong fix, premise);
two survive votes needed.**

| Fix | Survive–kill | What decided it |
|---|---|---|
| A1 Scope fetches and stops when the primary is behind and cannot fast-forward | 1–2 | `run.js` has no shell, so it is prose for a small-model Scope agent or a new git path. It would have stopped the 2026-11-09 run at scope 1 for a commit that changed no item file. Its only extra reach over A7 (a fresh relaunch on a still-stale checkout) has no incident. |
| A2 `sweap-frontier` reads from `origin/<base>` | 0–3 | Wrong layer: it hides the stale tree from one reader and leaves it for the rest (the board's end check, the watcher's status grep, the implementer's lint, the audit readers), so a true "drained" would be contradicted by the board. Largest diff on the list. |
| A3 scaffold does not write the colliding file | 0–3 | On 2026-11-09 the local `origin/<base>` ref was itself stale at session start and the hook runs no git; knowing would need a network fetch inside a 10 s session-blocking hook. On 2026-09-25 the write came first and *is* the source of the adoption PR. |
| A4 `git pull --ff-only --autostash` | 0–3 | On a non-identical edit it exits 0, leaves conflict markers and an unmerged index, keeps the stash, and every later pull exits 128 (reproduced). The trigger state existed in the consumer that day: the appended flake line of gap B. |
| A5 refuse to start on a dirty primary | 0–3 | Refuses a healthy checkout: the consumer's primary was 0 commits behind and dirty with the driver's own flake line. It would also not have fired on 2026-09-25, where the collision arose mid-run. |
| A6 no code change | 0–3 | The by-hand recovery was model luck both times: on 2026-11-09/10, 39 agents saw the refusal and none acted; the structured result said drained. |
| **A7** the run stops when the frontier lists an id it merged as done | **2–1** | The frontier is todo-only, so the condition can only mean the files it read are not the base. Zero false fires in 13 clean runs, fires in both incidents. Code in `run.js`, no git, no prompt. The cost reviewer's kill: alone it is a mid-run stop that repairs nothing; it earns its place only as the detector beside A8. |
| **A8** when the pull is refused, drop only files identical to the upstream copy, then pull | **3–0** | No stash, in code where the pull already fails silently, no stop, no consumer PR. It would have cleared both incidents at the first driver merge after the collision. Reviewers' conditions: only on a checkout strictly behind, and the refusal must reach someone instead of `/dev/null`. Built differently from what was voted on: see below. |

**The hostile review of the first diff changed A8.** As reviewed, A8 restored
the identical files to HEAD and pulled again. A reviewer given that diff broke
it eight ways, each reproduced in a throwaway repository:

- staged work on the file was overwritten (the identity check compared the
  working tree, `git checkout HEAD -- f` rewrote the index too);
- an uncommitted clean merge was wiped with `MERGE_HEAD` left behind, so the
  next commit would have been a merge that reverts upstream;
- a textconv driver, a lossy clean filter or `core.autocrlf=input` made the
  identity check say "same" for different bytes, which were then lost;
- the restore pass re-derived its file list instead of using the verified one;
- the second step was a network pull, so an unreachable remote or two hooks at
  once (49 of 59 concurrent runs) left files restored and the checkout stale;
- three kinds of blocker were missed by the scan, breaking all-or-nothing;
- on a by-hand merge the stderr line reached nobody (the hook is registered
  with `2>/dev/null`);
- 1,500 dirty files took 35 to 51 s against a 30 s hook bound.

**Built.**

- `plugin/hooks/lib-primary-ff.sh`, `primary_ff <dir>`, used by
  `post-merge-cleanup.sh`. It never writes the working tree. When the pull is
  refused on a checkout that is strictly behind, with nothing staged and no
  merge, rebase, cherry-pick, revert or bisect under way, it takes the tracked
  files that are modified on disk and changed by the incoming commits; if each
  hashes to the upstream's blob it **stages** them and runs
  `git merge --ff-only` to the commit it checked. Git accepts a fast-forward
  over an index entry that already equals the incoming one and leaves the file
  on disk alone. If git still refuses, the staging is undone. So every case
  the review broke now ends as git's own refusal with every byte as it was:
  the test suite covers staged work, an uncommitted merge, a bisect, a lossy
  clean filter (the local bytes are still on disk after the fast-forward), a
  mode difference, an untracked file in the way, a diverged branch and more
  than 100 modified files, and each guard goes red when removed.
- When it cannot heal, one line saying how far behind the checkout is and what
  is in the way goes to the session as the hook's `additionalContext`, which
  reaches both a by-hand merge and the merge driver (the driver records it in
  the PR's state file).
- `post-merge-auditcheck.sh` keeps its plain pull: on a by-hand merge the two
  hooks run at the same time, and one healer is enough.
- `plugin/workflows/run.js`: after every Scope, a frontier that lists an id
  this run merged with `status_done: yes` stops the run with the cause and the
  remedy named. It is never "drained". The stop text does not assume the
  primary is behind (it may be on another branch): it says to check
  `git status -sb` first.
- `plugin/agents/merge-watcher.md` reads the merged item's status with
  `git show origin/<default branch>:<file>`, not from the file on disk. This
  was not one of the voted fixes: two reviewers flagged that the stop depends
  on it (a grep of a stale file reads `todo`, the item goes to `needs_human`
  and the stop never fires), and 16 of 16 watchers already did it unasked.
- The playbook's "`--ff-only` no-ops on local changes" is corrected.

**Known limits, deliberately not built.** A relaunch on a still-stale checkout
has an empty merged list, so the stop cannot see it before the first merge (A1
would; no incident). A file that differs from the incoming copy, or an
untracked file where the pull creates one (a release that adds a new managed
file), is reported, not healed.

## Gap B: the flake note's appended line has no carrier

**Mechanism.** When a PR goes red, is rerun through `sweap-merge rerun` and
goes green on the same head, the driver files one discovered note per workflow
path, in the primary checkout. Each later flake of that workflow appended one
line to the existing note: an edit to a **tracked** file in the primary. No
stage may commit there, every sweep rule covers untracked files only, and
implementers work in their own worktrees.

**Measured in consumer A (2026-09-18 to 2026-11-10).** 12 driver writes: 2 new
notes, 10 appended lines, matching the 12 state-file reruns with
`flake_noted: true` exactly. Eleven reached the base branch, none through a
sweep: each was hand-carried by whichever session noticed, across 9 PRs, two
opened for nothing else and one more that set out to carry a line already
landed. Time from append to base: 1 h at first, then 6.8 and 12.2 days. At
least 6 recorded agent statements say the line was seen and left alone. The
hand-carry is two steps (copy into a worktree, restore the primary) and
skipping the second freezes the primary's next pull (reproduced): gap A again.

**Nobody reads the lines.** Nothing in the consumer cites either note; eight
triage passes left both in the inbox; the line count never informed a decision.
The ledger also mixes at least six causes under one title (it is keyed by
workflow path and titled after the first occurrence), and the one flake that
recurred was diagnosed in a separate hand-written note that cites none of it.
The state file already holds a superset per occurrence: head, run id, workflow
path, reason, time, who, `flake_noted`.

| Fix | Survive–kill | What decided it |
|---|---|---|
| B1 widen the sweep to modified tracked notes | 0–3 | No ordering of copy and restore is safe across prose-instructed agents; the implementer is forbidden to act in the primary; and nothing reads the line. |
| B2 one new file per occurrence | 0–3 | Moves the orphan from a tracked edit to an untracked file in the primary, which the worktree sweep cannot see either; 12 notes instead of 2 in an inbox of 113. |
| **B3** stop writing later occurrences to the repo; the state file is the record | **3–0** | A deletion: the record is written before the append ran. Survives only without the PR comment that was part of the proposal (a `gh` write inside the pre-merge budget, for a reader that does not exist). |
| B4 the driver opens a PR for the line | 0–3 | About 17 minutes of CI per flake on the machine whose contention causes the flakes; a note PR can flake and file another. |
| B5 drop the append; derive the rate from GitHub run history | 2–1 | The same deletion as B3. Its justification was refuted: "attempts > 1" overcounts by a third (16 rerun PRs, 12 flakes) and GitHub holds no reason. Built as B3. |
| B6 no code change | 0–3 | Recurs on every flake by construction; the human was told twice and the line was still uncommitted a day later. |
| B7 render the lines at carry time from the state files | 0–3 | A new verb and two prose call sites to feed a ledger with no reader, from machine-local data. |
| B8 detect the pending edit in `sweap-stranded` | 0–3 | Detection is not what is missing: agents already report it almost every time. |

**Built.** `sm_flake_note` writes nothing to the repo when the workflow is
already noted, and says so on stderr. The first note per workflow is still
filed, and its body says where later occurrences live. `flake_noted` is set as
before. The test that pinned the append now commits the first note and asserts
the second flake leaves it byte-identical with a clean inbox.

**Outside research that bore on it.** Tools that keep a long-lived clone and
decide from it either reset it to the remote on every sync (Renovate) or fail
closed with a named cause and no stash (`gh repo sync`); neither works around a
dirty tree silently. None of the CI setups checked (Kubernetes, Chromium)
records a flake occurrence by committing a line to the repository: recurrences
go to an issue comment or CI-native history. Appending to one shared tracked
file from several places is a documented conflict generator (the reason
changelog tools moved to one file per entry).

**Left to the maintainer.** The one line already pending in consumer A's
primary: commit it or restore it. With the append gone it is the last one.
The first note of a workflow is still created untracked in the primary with no
carrier under the run workflow; no instance has occurred since the loop moved
into a script, so nothing was built for it.

## Method

One workflow, nine agents: an investigator per gap (mechanism, frequency
across every surviving transcript, git experiments in throwaway repos), one
outside researcher, then three hostile reviewers per gap, each returning a
verdict on every candidate fix with evidence it looked at itself. 14 fixes
proposed (6 + 6 from the first account, 2 + 2 added by the investigators),
3 survived as 3 code changes. Then one hostile reviewer on the diff, told to
break it in throwaway repositories and to mutate the code under the tests: 12
findings, 8 of them against the first version of the heal, which was rewritten
(above); the others were a run-stop clause no test could fail, stop wording
that named one cause for several states, and four guards no test pinned.
