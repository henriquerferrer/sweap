# Vendored consumer workflow fixtures

Snapshots of the real `.github/workflows/*.yml` from the sweap consumers
(anonymised as `consumer-a`, `consumer-b`), taken 2026-08-30. `sweap-merge.test.sh` parses these to
exercise `sm_classify_workflow` against workflow files with real-world shape —
`on:` blocks, `branches:` filters, `types:` lists, many jobs with different
`timeout-minutes`.

**They are snapshots, deliberately.** Until 2026-08-30 the suite `cp`'d these
files out of the consumer checkouts at run time, which made sweap's merge
bar depend on the current contents of a different repo on one particular Mac:
raising consumer-a's e2e `timeout-minutes` from 30 to 60 turned four sweap tests red
with no sweap commit, and on any other machine the `cp` silently produced an
empty fixture dir. A test suite that is the merge bar has to be reproducible.

**Refreshing them is a deliberate act, not a chore.** Re-copy, then re-derive
any assertion that names a number (the `timeout-minutes max` case, and the
`complete_deadline` arithmetic in §6, which is `2 x` that max). If a refresh
changes a number, that is the fixture telling you the driver's behaviour
against that consumer changed — read it before you edit the expectation.

The live checkouts are still consulted, but only by the optional DRIFT section
in the suite, which asserts invariants (classifies as `member`, timeout > 0)
and never a specific value. It runs only for the checkouts named in
`SWEAP_LIVE_CONSUMERS` (colon-separated paths) and skips otherwise.
