// sweap-fleet.test.mjs — the fleet rule, pure and end-to-end against a fake gh.
// Run: node --test plugin/tools/sweap-fleet.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { classify, newestPerWorkflow, dedupeSets, report } from "./sweap-fleet.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const R = (name, status, labels, extra = {}) => ({ name, status, busy: false, labels, version: "2.337.0", ...extra });

test("classify: a set naming self-hosted with NO registered runner at all is fleet-down (a consumer, 2026-09-24: the runners deregistered themselves, total_count 0)", () => {
  const c = classify([["self-hosted", "e2e"], ["self-hosted"]], []);
  assert.equal(c.verdict, "fleet-down");
  assert.deepEqual(c.missing, [["self-hosted", "e2e"], ["self-hosted"]]);
});

test("classify: half a fleet is an outage for the sets only the dead runner carried", () => {
  const runners = [R("local-1", "online", ["self-hosted", "general", "checks"]), R("local-2", "offline", ["self-hosted", "e2e"])];
  const c = classify([["self-hosted"], ["self-hosted", "checks"], ["self-hosted", "e2e"]], runners);
  assert.equal(c.verdict, "fleet-down");
  assert.deepEqual(c.missing, [["self-hosted", "e2e"]], "checks and the plain set have local-1; e2e has nobody online");
});

test("classify: online but busy is a slow queue, not an outage", () => {
  const runners = [R("local-1", "online", ["self-hosted", "checks"], { busy: true })];
  assert.equal(classify([["self-hosted", "checks"]], runners).verdict, "ok");
});

test("classify: a set without self-hosted targets the fleet when a registered runner carries it (runs-on: [e2e], runner groups)", () => {
  const runners = [R("local-2", "offline", ["self-hosted", "e2e"])];
  const c = classify([["e2e"]], runners);
  assert.equal(c.verdict, "fleet-down");
  assert.deepEqual(c.targeted, [["e2e"]]);
});

test("classify: a hosted label set no runner matches is not this tool's business", () => {
  const runners = [R("local-1", "offline", ["self-hosted", "ubuntu-24.04"])];
  const c = classify([["ubuntu-latest"]], runners);
  assert.equal(c.verdict, "ok");
  assert.deepEqual(c.hosted, [["ubuntu-latest"]]);
  // but a hosted-LOOKING set that a registered runner does carry is fleet-targeted (a consumer's runners carry ubuntu-24.04)
  assert.equal(classify([["ubuntu-24.04"]], runners).verdict, "fleet-down");
});

test("classify: labels match case-insensitively, as GitHub matches them (runners report Linux/ARM64)", () => {
  const runners = [R("l1", "online", ["self-hosted", "Linux", "ARM64"])];
  assert.equal(classify([["self-hosted", "linux", "arm64"]], runners).verdict, "ok");
});

test("classify: no sets at all is ok (nothing targets anyone)", () => {
  assert.equal(classify([], []).verdict, "ok");
});

test("newestPerWorkflow keeps the first (newest) run per path; dedupeSets ignores order", () => {
  const runs = [{ path: "a.yml", databaseId: 3 }, { path: "b.yml", databaseId: 2 }, { path: "a.yml", databaseId: 1 }];
  assert.deepEqual(newestPerWorkflow(runs).map((r) => r.databaseId), [3, 2]);
  assert.deepEqual(dedupeSets([["e2e", "self-hosted"], ["self-hosted", "e2e"], ["self-hosted"]]), [["e2e", "self-hosted"], ["self-hosted"]]);
});

// End to end: a fake `gh` on PATH answers from fixture files; the tool must
// derive label sets per workflow, read runners, and query deprecations.
const fakeGh = (dir, fx) => {
  writeFileSync(join(dir, "fx.json"), JSON.stringify(fx));
  const sh = `#!/bin/sh
FX="${join(dir, "fx.json")}"
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' ;;
  "api "*)
    case "$2" in
      *"/actions/runs?"*) node -e 'const f=require(process.env.FX);process.stdout.write(JSON.stringify({workflow_runs:f.runs.map(r=>({id:r.databaseId,path:r.path,status:"completed"}))}))' ;;
      *"/runs/"*"/jobs"*) id=$(echo "$2" | sed 's#.*/runs/\\([0-9]*\\)/jobs.*#\\1#'); node -e 'const f=require(process.env.FX);process.stdout.write(JSON.stringify(f.jobs[process.argv[1]]||{jobs:[]}))' "$id" ;;
      *"/runners/deprecations/"*) v=$(echo "$2" | sed 's#.*/deprecations/##'); node -e 'const f=require(process.env.FX);const d=f.deprecations[process.argv[1]];if(!d){process.stderr.write("HTTP 404");process.exit(1)}process.stdout.write(JSON.stringify(d))' "$v" ;;
      *"/runners"*) node -e 'const f=require(process.env.FX);if(f.runners===403){process.stderr.write("HTTP 403");process.exit(1)}process.stdout.write(JSON.stringify(f.runners))' ;;
      *) echo "unexpected api $2" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
`;
  writeFileSync(join(dir, "gh"), sh); chmodSync(join(dir, "gh"), 0o755);
};
const run = (dir, args = []) => {
  const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, FX: join(dir, "fx.json") };
  try { return JSON.parse(execFileSync("node", [join(HERE, "sweap-fleet.mjs"), ...args], { env, encoding: "utf8" })); }
  catch (e) { return JSON.parse(e.stdout); }
};
const soon = new Date(Date.now() + 3 * 86400000).toISOString();
const late = new Date(Date.now() + 40 * 86400000).toISOString();
const FX = {
  runs: [{ databaseId: 11, path: ".github/workflows/audit-gate.yml" }, { databaseId: 10, path: ".github/workflows/ci.yml" }, { databaseId: 9, path: ".github/workflows/ci.yml" }],
  jobs: { 11: { jobs: [{ name: "audit-gate", labels: ["self-hosted"] }] }, 10: { jobs: [{ name: "checks", labels: ["self-hosted", "checks"] }, { name: "e2e", labels: ["self-hosted", "e2e"] }] }, 9: { jobs: [{ name: "old", labels: ["self-hosted", "old-label"] }] } },
  runners: { total_count: 2, runners: [{ name: "l1", status: "online", busy: true, version: "2.337.0", labels: [{ name: "self-hosted" }, { name: "checks" }] }, { name: "l2", status: "offline", busy: false, version: "2.336.0", labels: [{ name: "self-hosted" }, { name: "e2e" }] }] },
  deprecations: { "2.337.0": { runner_version: "2.337.0", runtime_deprecates_at: null }, "2.336.0": { runner_version: "2.336.0", runtime_deprecates_at: soon } },
};

test("end to end: label sets come from the newest run of EACH workflow, the dead e2e carrier is reported, a retirement within 7 days is listed", () => {
  const dir = mkdtempSync(join(tmpdir(), "swf-")); fakeGh(dir, FX);
  try {
    const r = run(dir);
    assert.equal(r.verdict, "fleet-down");
    assert.deepEqual(r.missing, [["self-hosted", "e2e"]]);
    assert.deepEqual(Object.keys(r.workflows).sort(), [".github/workflows/audit-gate.yml", ".github/workflows/ci.yml"]);
    assert.ok(!JSON.stringify(r.workflows).includes("old-label"), "an older run of the same workflow is not consulted");
    assert.equal(r.deprecations.length, 1); assert.equal(r.deprecations[0].version, "2.336.0"); assert.deepEqual(r.deprecations[0].runners, ["l2"]);
    assert.match(r.reason, /no online runner carries \[self-hosted, e2e\]/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("end to end: a runners endpoint that refuses (non-admin token) is unknown, never fleet-down", () => {
  const dir = mkdtempSync(join(tmpdir(), "swf-")); fakeGh(dir, { ...FX, runners: 403 });
  try { const r = run(dir); assert.equal(r.verdict, "unknown"); assert.match(r.reason, /runners endpoint refused/); }
  finally { rmSync(dir, { recursive: true, force: true }); }
});

test("end to end: no runs on the base branch is unknown (no label universe), and an all-online fleet with a far retirement is ok with a note", () => {
  const dir = mkdtempSync(join(tmpdir(), "swf-")); fakeGh(dir, { ...FX, runs: [] });
  try { assert.equal(run(dir).verdict, "unknown"); } finally { rmSync(dir, { recursive: true, force: true }); }
  const dir2 = mkdtempSync(join(tmpdir(), "swf-"));
  const ok = { ...FX, runners: { runners: FX.runners.runners.map((r) => ({ ...r, status: "online", version: "2.336.0" })) }, deprecations: { "2.336.0": { runner_version: "2.336.0", runtime_deprecates_at: late } } };
  fakeGh(dir2, ok);
  try { const r = run(dir2); assert.equal(r.verdict, "ok"); assert.equal(r.deprecations.length, 0); assert.ok(r.notes.some((n) => /retires/.test(n))); }
  finally { rmSync(dir2, { recursive: true, force: true }); }
});

test("bin/sweap-fleet is executable and execs the tool", () => {
  const src = execFileSync("cat", [join(HERE, "..", "bin", "sweap-fleet")], { encoding: "utf8" });
  assert.match(src, /exec node "\$root\/tools\/sweap-fleet\.mjs" "\$@"/);
});
