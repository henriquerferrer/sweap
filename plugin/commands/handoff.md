---
description: "Walk one attended item (a planned human hand-off) with the human, then flip it to done through a gated PR on their confirmation."
argument-hint: "[item-id] — defaults to the first unblocked attended item in frontier order"
---

Read `CLAUDE.md`, the playbook's **Attended items (planned human hand-offs)**
section, and the item files under `backlog.dir` first.

This command exists because a hand-off that is merely *listed* rots. The human
is doing this work anyway; the agent's job is to make it take minutes instead of
an afternoon, and then to close the loop in the backlog so the pipeline moves.

**Resolve the item.** The first argument if given; otherwise the first
`status: attended` item that is unblocked (every `depends_on` entry satisfied by
the usual rule — an item dep is satisfied when its file is `status: done`, a
bare-milestone dep when every item under it is done), in frontier order. If the
resolved item is not `status: attended`, stop and say so — this command does not
touch any other status. A `[blocked]` item is a *question* awaiting a
`> ANSWER:` line, not a hand-off; work it with `/unblock <id>` instead.

**Then, in order:**

1. **Brief the human.** State the `handoff:` task, why it is theirs (the
   `## Hand-off` section's rationale), and what it gates — the items that
   transitively depend on it and are not yet done. That number is the reason to
   do it now rather than later; say it plainly and once.

2. **Walk the steps.** Take the `## Hand-off` steps one at a time. **Do every
   part an agent legitimately can** — write the config file or `.env` line once
   they paste a value, run the verification command, open the right page, check
   the API responds, commit a resulting file change. What you must not do is
   the part that is theirs by nature: hold an identity, accept terms, spend
   money, make the taste call. Ask for exactly what you need, one thing at a
   time, and never invent a value to keep moving. A choice whose options differ
   in something a product user would see goes on the `explain` skill's live page
   first (its "When to show" trigger), with the link in the ask; every choice
   ends with the **explain** line (see `/unblock` step 2).

3. **Check the *Done when* condition.** Run it and show the output. If the item
   has no checkable condition, say so and ask the human to confirm in words —
   do not infer completion from the conversation going well.

4. **Close it — only on their explicit confirmation.** In a worktree (never on
   `main`): flip the item file to `status: done`, keeping the `handoff:` key and
   the `## Hand-off` section as the record of what was done, and add a
   `> **DONE (YYYY-MM-DD):** <what actually shipped, incl. anything that
   differed from the steps>` note under `## Notes`. Open a PR and merge it on
   green through the normal gate (the pre-merge-gate hook enforces greenness).
   Then run end-of-run hygiene as always. **Never flip the status without the
   human saying so in this session**, and never as part of an unattended run.

5. **If it cannot finish now** (a third party has to verify them, hardware is in
   the post): leave it `status: attended` and record
   `> **STARTED (YYYY-MM-DD):** <what is pending, and what will unblock it>`
   under `## Notes`, in the same gated PR. This is a real outcome, not a
   failure — a hand-off waiting on Stripe's identity check is exactly the
   long-lead work that should have been started on day one.

6. **Report what it released.** After the merge, name the items that just
   became unblocked and are now on the frontier. If a run is in flight, it
   recomputes the frontier after every merge and will pick them up
   with nothing further needed; if not, offer to run `/milestone`.

**What this command never does:** create an attended item, change any other
item's status, or convert a `[blocked]` item into a hand-off. Hand-offs are
authored with the human in `/roadmap` and are mechanically verified to be
authored rather than transitioned into (`audit-gate.sh --check`) — see the
playbook's "Never an escape hatch".
