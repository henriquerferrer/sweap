import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { tap, report, readingFrom } from "./sweap-usage-tap.mjs";

const SAMPLE = JSON.stringify({ session_id: "s1", model: { id: "claude-opus-5" }, cost: { total_cost_usd: 1.5 },
  rate_limits: { five_hour: { used_percentage: 23.5, resets_at: 1738425600 }, seven_day: { used_percentage: 41.2, resets_at: 1738857600 } } });

test("tap appends one reading with a timestamp and prints the two percentages", () => {
  const dir = mkdtempSync(join(tmpdir(), "swu-"));
  const log = join(dir, "usage.jsonl");
  const out = tap(SAMPLE, { log, inner: null, now: Date.UTC(2026, 8, 22, 12, 0, 0) });
  assert.equal(out, "5h 23.5% · 7d 41.2%\n");
  const rows = readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].ts, "2026-09-22T12:00:00.000Z");
  assert.equal(rows[0].seven_day.used, 41.2);
  assert.equal(rows[0].seven_day.resets_at, 1738857600);
  assert.equal(rows[0].session, "s1");
  rmSync(dir, { recursive: true, force: true });
});

test("tap records nothing when the meter is absent (API key, before the first response) and never throws on bad input", () => {
  const dir = mkdtempSync(join(tmpdir(), "swu-"));
  const log = join(dir, "usage.jsonl");
  assert.equal(tap(JSON.stringify({ model: { id: "x" } }), { log, inner: null }), "5h — · 7d —\n");
  assert.equal(tap("not json", { log, inner: null }), "5h — · 7d —\n");
  assert.ok(!existsSync(log));
  rmSync(dir, { recursive: true, force: true });
});

test("tap hands the same stdin to the inner status line and passes its stdout through", () => {
  const dir = mkdtempSync(join(tmpdir(), "swu-"));
  const log = join(dir, "usage.jsonl");
  const out = tap(SAMPLE, { log, inner: ["node", "-e", "process.stdin.on('data',d=>process.stdout.write('inner:'+JSON.parse(d).session_id))"] });
  assert.equal(out, "inner:s1");
  assert.ok(existsSync(log), "the reading is recorded before the inner command runs");
  rmSync(dir, { recursive: true, force: true });
});

test("report shows first/last, per-hour change and a reset", () => {
  const mk = (ts, used) => JSON.stringify(readingFrom({ rate_limits: { seven_day: { used_percentage: used, resets_at: 1 } } }, Date.parse(ts)));
  const lines = [mk("2026-09-22T10:00:00Z", 90), mk("2026-09-22T10:30:00Z", 93), mk("2026-09-22T11:00:00Z", 2), mk("2026-09-22T11:40:00Z", 4.5)];
  const out = report(lines);
  assert.match(out, /readings: 4/);
  assert.match(out, /7d: 90% -> 4.5%/);
  assert.match(out, /reset: 7d fell 93% -> 2% at 2026-09-22T11:00:00.000Z/);
  assert.match(out, /2026-09-22T10:00  7d 90% -> 93%  \(3.0\)/);
  assert.equal(report([]), "no readings\n");
});
