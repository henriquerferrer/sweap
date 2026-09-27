#!/usr/bin/env node
// sweap-fleet — is the self-hosted runner fleet able to run this repo's CI?
//
// Prints one JSON object. `verdict` is one of:
//   ok          every label set CI targets at the fleet has an ONLINE runner
//   fleet-down  at least one has none (the sets are in `missing`)
//   unknown     the question cannot be answered (no runs on the base branch
//               to learn the label sets from, or the runners endpoint refused)
//
// Read-only: four kinds of `gh` GET calls, nothing written anywhere.
//
// WHY THIS EXISTS. A consumer, 2026-09-24: GitHub retired the runner version both
// self-hosted runners were on; they deregistered themselves in a loop for five
// hours. The merge driver reported every PR as queued, the watcher timed out
// after 99 minutes and filed the item as needing a human, and the run went on
// to the next item — opening PRs that could not test, one per 99 minutes. No
// stage asked the one question that would have ended it: is anyone there to
// run the jobs? This asks it, in one place, so the Resume stage, the watcher
// and the kickoff all give the same answer.
//
// THE RULE (refuted into shape on 2026-09-24, docs/research/2026-09-24-fleet-down.md):
// - The label sets come from the newest run of EACH workflow on the base
//   branch (its jobs' `labels`, present while queued too), never from one
//   "newest run": a workflow's run has only that workflow's jobs, and a fleet
//   with one runner up and the `e2e` carrier dead passes a check that looks
//   only at the last audit-gate run.
// - A set targets the fleet when it names `self-hosted` OR some REGISTERED
//   runner (any status) carries every label in it. `self-hosted` alone misses
//   `runs-on: [e2e]` and runner groups; the registered-runner match alone
//   misses a fleet that has deregistered itself entirely (today's case:
//   `total_count: 0`).
// - A targeted set is missing when no ONLINE runner carries every label in
//   it. Online-but-busy is not missing: a queue behind a wedged job is a slow
//   CI day, not an outage, and the driver's deadline handles it.
// - A set no registered runner matches and that does not name `self-hosted`
//   is GitHub-hosted (or a label typo): not this tool's business.
// - Runner versions carry a retirement date: GET .../runners/deprecations/<v>
//   returns `runtime_deprecates_at` (2.335.1: 2026-09-24T15:30:55Z, to the
//   minute of the outage). Versions retiring within `--warn-days` (7) are
//   listed under `deprecations` so a kickoff or a watchdog can act a week
//   early instead of learning it from a crash loop.
import { execFileSync } from "node:child_process";

// GitHub matches labels case-insensitively (runners report `Linux`, `ARM64`;
// a workflow may say `linux`); a case-sensitive test would call a healthy
// fleet down.
const norm = (l) => String(l).toLowerCase();
export const isSubset = (need, have) => { const h = have.map(norm); return need.every((l) => h.includes(norm(l))); };

// Pure: label sets + runners -> {verdict, missing, hosted, targeted}.
export function classify(labelSets, runners) {
  const registered = runners.map((r) => ({ ...r, labels: r.labels || [] }));
  const online = registered.filter((r) => r.status === "online");
  const targeted = [], hosted = [], missing = [];
  for (const set of labelSets) {
    const fleet = set.includes("self-hosted") || registered.some((r) => isSubset(set, r.labels));
    if (!fleet) { hosted.push(set); continue; }
    targeted.push(set);
    if (!online.some((r) => isSubset(set, r.labels))) missing.push(set);
  }
  return { verdict: missing.length ? "fleet-down" : "ok", targeted, hosted, missing };
}

// Newest run per workflow path, from a `gh run list` result (newest first).
export function newestPerWorkflow(runs) {
  const seen = new Map();
  for (const r of runs) if (r && r.path && !seen.has(r.path)) seen.set(r.path, r);
  return [...seen.values()];
}

export function dedupeSets(sets) {
  const out = [], keys = new Set();
  for (const s of sets) { const k = [...s].sort().join(","); if (!keys.has(k)) { keys.add(k); out.push(s); } }
  return out;
}

const gh = (args) => {
  try { return { ok: true, out: execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) }; }
  catch (e) { return { ok: false, err: String((e && e.stderr) || (e && e.message) || e).trim() }; }
};
const ghJson = (args) => { const r = gh(args); if (!r.ok) return r; try { return { ok: true, value: JSON.parse(r.out || "null") }; } catch (e) { return { ok: false, err: `not JSON: ${r.out.slice(0, 120)}` }; } };

export function report({ repo, base, warnDays = 7, runLimit = 40 } = {}) {
  const notes = [];
  if (!repo || !base) {
    const v = ghJson(["repo", "view", "--json", "nameWithOwner,defaultBranchRef"]);
    if (!v.ok) return { verdict: "unknown", reason: `gh repo view failed: ${v.err}`, notes };
    repo = repo || v.value.nameWithOwner;
    base = base || (v.value.defaultBranchRef && v.value.defaultBranchRef.name) || "main";
  }
  // The REST list carries each run's workflow `path`; `gh run list --json` does not.
  const runs = ghJson(["api", `repos/${repo}/actions/runs?branch=${encodeURIComponent(base)}&per_page=${runLimit}`]);
  if (!runs.ok) return { verdict: "unknown", reason: `listing runs failed: ${runs.err}`, repo, base, notes };
  const newest = newestPerWorkflow(((runs.value && runs.value.workflow_runs) || []).map((r) => ({ databaseId: r.id, path: r.path, status: r.status })));
  if (!newest.length) return { verdict: "unknown", reason: `no workflow runs on ${base} to learn the label sets from`, repo, base, notes };
  const sets = [];
  const workflows = {};
  for (const r of newest) {
    const jobs = ghJson(["api", `repos/${repo}/actions/runs/${r.databaseId}/jobs?per_page=100`]);
    if (!jobs.ok) { notes.push(`jobs of run ${r.databaseId} (${r.path}): ${jobs.err}`); continue; }
    const labelSets = ((jobs.value && jobs.value.jobs) || []).map((j) => (j.labels || []).slice()).filter((l) => l.length);
    workflows[r.path] = dedupeSets(labelSets);
    sets.push(...labelSets);
  }
  const runnersRes = ghJson(["api", `repos/${repo}/actions/runners?per_page=100`]);
  if (!runnersRes.ok) return { verdict: "unknown", reason: `runners endpoint refused (admin access or the repo scope is needed): ${runnersRes.err}`, repo, base, workflows, notes };
  const runners = ((runnersRes.value && runnersRes.value.runners) || []).map((r) => ({ name: r.name, status: r.status, busy: !!r.busy, version: r.version || null, labels: (r.labels || []).map((l) => l.name) }));
  const c = classify(dedupeSets(sets), runners);
  const deprecations = [];
  for (const v of [...new Set(runners.map((r) => r.version).filter(Boolean))]) {
    const d = ghJson(["api", `repos/${repo}/actions/runners/deprecations/${v}`]);
    if (!d.ok || !d.value) continue;
    const at = d.value.runtime_deprecates_at;
    if (!at) continue;
    const days = (new Date(at).getTime() - Date.now()) / 86400000;
    const entry = { version: v, runtime_deprecates_at: at, days_left: Math.round(days * 10) / 10, runners: runners.filter((r) => r.version === v).map((r) => r.name) };
    if (days <= warnDays) deprecations.push(entry); else notes.push(`runner ${v} retires ${at} (${Math.floor(days)} days)`);
  }
  return {
    verdict: c.verdict,
    reason: c.verdict === "fleet-down"
      ? `no online runner carries ${c.missing.map((s) => `[${s.join(", ")}]`).join(" or ")}; registered: ${runners.length ? runners.map((r) => `${r.name}=${r.status}${r.busy ? "/busy" : ""}`).join(", ") : "none"}`
      : (c.targeted.length ? `every fleet-targeted label set has an online runner` : `CI targets no self-hosted label set`),
    repo, base, missing: c.missing, targeted: c.targeted, hosted: c.hosted, runners, deprecations, workflows, notes,
  };
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const a = process.argv.slice(2), opts = {};
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--repo") opts.repo = a[++i];
    else if (a[i] === "--branch" || a[i] === "--base") opts.base = a[++i];   // the branch whose runs are read (a PR's head branch has the PR-only workflows); --base is the old name
    else if (a[i] === "--warn-days") opts.warnDays = Number(a[++i]);
    else if (a[i] === "--help" || a[i] === "-h") { process.stdout.write("usage: sweap-fleet [--repo owner/name] [--branch branch] [--warn-days n]\nprints JSON; .verdict is ok | fleet-down | unknown\n"); process.exit(0); }
  }
  const r = report(opts);
  process.stdout.write(JSON.stringify(r, null, 2) + "\n");
  process.exit(r.verdict === "fleet-down" ? 1 : 0);
}
