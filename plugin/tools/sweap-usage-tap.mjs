#!/usr/bin/env node
// sweap-usage-tap.mjs — records the subscription meter with a timestamp.
//
// Claude Code hands a status-line command JSON on stdin that, for Pro/Max
// accounts, carries `rate_limits.five_hour` and `rate_limits.seven_day`
// (`used_percentage`, `resets_at`). Nothing else records that number: the
// 2026-09-22 memo could not say WHEN its "93%" was read, so the weekly meter's
// size could only be re-imagined. This tap appends one JSON line per refresh to
// a log and hands the JSON on to whatever status line you already run, so it
// costs nothing to keep on. It does NOT try to fit per-token-kind weights from
// the log — three refuters showed that regression is unidentifiable on a serial
// run; the memo's "Refutation" section gives the burst protocol that is.
//
//   sweap-usage-tap [--log <path>] [-- <inner status-line command...>]
//       reads stdin, appends a line, then runs the inner command with the same
//       stdin and passes its stdout through (or prints "5h 23% · 7d 41%").
//   sweap-usage-tap install [--log <path>]
//       copies this script to ~/.claude/sweap-usage-tap.mjs (a path that
//       survives plugin updates — the plugin cache path does not) and prints the
//       `statusLine` setting to paste into ~/.claude/settings.json.
//   sweap-usage-tap report [--log <path>] [--since <ISO>]
//       prints the readings: first, last, the change per hour, and each reset.
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const DEFAULT_LOG = join(process.env.SWEAP_USAGE_HOME || join(homedir(), ".claude"), "sweap-usage.jsonl");

function parseArgs(argv) {
  const a = { log: DEFAULT_LOG, inner: null, since: null, sub: null };
  let i = 0;
  if (argv[0] === "install" || argv[0] === "report") { a.sub = argv[0]; i = 1; }
  for (; i < argv.length; i++) {
    const v = argv[i];
    if (v === "--log") a.log = argv[++i];
    else if (v === "--since") a.since = argv[++i];
    else if (v === "--") { a.inner = argv.slice(i + 1); break; }
  }
  return a;
}

const pct = (w) => (w && typeof w.used_percentage === "number") ? w.used_percentage : null;

export function readingFrom(json, now) {
  const rl = (json && json.rate_limits) || {};
  return {
    ts: new Date(now).toISOString(),
    session: json && json.session_id ? json.session_id : null,
    model: json && json.model && json.model.id ? json.model.id : null,
    five_hour: rl.five_hour ? { used: pct(rl.five_hour), resets_at: rl.five_hour.resets_at ?? null } : null,
    seven_day: rl.seven_day ? { used: pct(rl.seven_day), resets_at: rl.seven_day.resets_at ?? null } : null,
    cost_usd: json && json.cost && typeof json.cost.total_cost_usd === "number" ? json.cost.total_cost_usd : null,
  };
}

export function tap(stdinText, { log, inner, now = Date.now() }) {
  let json = null;
  try { json = JSON.parse(stdinText); } catch { json = null; }
  const r = readingFrom(json, now);
  // Record only when the meter is present: a line of nulls is noise, and the
  // field is absent before the first API response and behind API-key auth.
  if (r.five_hour || r.seven_day) {
    try { mkdirSync(join(log, ".."), { recursive: true }); appendFileSync(log, JSON.stringify(r) + "\n"); } catch { /* never break the status line */ }
  }
  if (inner && inner.length) {
    const res = spawnSync(inner[0], inner.slice(1), { input: stdinText, encoding: "utf8", shell: false });
    return res.stdout || "";
  }
  const f = r.five_hour && r.five_hour.used != null ? `5h ${r.five_hour.used}%` : "5h —";
  const w = r.seven_day && r.seven_day.used != null ? `7d ${r.seven_day.used}%` : "7d —";
  return `${f} · ${w}\n`;
}

export function report(lines, { since = null } = {}) {
  const rows = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((r) => r && r.ts && (!since || r.ts >= since));
  if (!rows.length) return "no readings\n";
  const out = [];
  const first = rows[0], last = rows[rows.length - 1];
  const wk = (r) => (r.seven_day && r.seven_day.used != null ? r.seven_day.used : null);
  out.push(`readings: ${rows.length}  first: ${first.ts}  last: ${last.ts}`);
  out.push(`7d: ${wk(first)}% -> ${wk(last)}%`);
  // Per-hour change of the weekly meter, skipping across resets (a drop).
  let prev = null;
  for (const r of rows) {
    if (prev && wk(prev) != null && wk(r) != null) {
      if (wk(r) < wk(prev) - 5) out.push(`reset: 7d fell ${wk(prev)}% -> ${wk(r)}% at ${r.ts}`);
    }
    prev = r;
  }
  const hours = new Map();
  for (const r of rows) { const h = r.ts.slice(0, 13); if (!hours.has(h)) hours.set(h, []); hours.get(h).push(r); }
  for (const [h, rs] of hours) {
    const a = wk(rs[0]), b = wk(rs[rs.length - 1]);
    if (a != null && b != null) out.push(`${h}:00  7d ${a}% -> ${b}%  (${(b - a).toFixed(1)})`);
  }
  return out.join("\n") + "\n";
}

const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const a = parseArgs(process.argv.slice(2));
  if (a.sub === "install") {
    const dest = join(process.env.SWEAP_USAGE_HOME || join(homedir(), ".claude"), "sweap-usage-tap.mjs");
    copyFileSync(fileURLToPath(import.meta.url), dest);
    const q = (p) => `'${String(p).replace(/'/g, `'\\''`)}'`;
    const setting = { statusLine: { type: "command", command: `node ${q(dest)} --log ${q(a.log)}`, refreshInterval: 60 } };
    process.stdout.write(`installed ${dest}\nPaste into ~/.claude/settings.json — it records every reading and shows the two percentages:\n${JSON.stringify(setting, null, 2)}\nTo keep a status line you already run, append " -- <its command>" to "command" (the tap hands it the same JSON and shows its output); the tap never picks one for you.\nReadings go to ${a.log}; "sweap-usage-tap report" prints them.\n`);
  } else if (a.sub === "report") {
    const text = existsSync(a.log) ? readFileSync(a.log, "utf8") : "";
    process.stdout.write(report(text.split("\n").filter(Boolean), { since: a.since }));
  } else {
    let stdin = "";
    try { stdin = readFileSync(0, "utf8"); } catch { stdin = ""; }
    process.stdout.write(tap(stdin, { log: a.log, inner: a.inner }));
  }
}
