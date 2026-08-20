#!/usr/bin/env node
// sweap-board.mjs — loopback-only viewer server + CLI, read-only against all
// pipeline state (item files, git worktree list, gh pr list, the board
// annotation file). Its ONLY write is create-only idea capture: POST /ideas
// creates new files under <backlogDir>ideas/; it never modifies or deletes
// anything, and never mutates the board or invokes the pipeline.
import http from "node:http";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildState, readConfig, writeIdea } from "./sweap-board.lib.mjs";
import { renderPage } from "./sweap-board.page.mjs";

const run = (cmd, cwd, opts = {}) => (args) => new Promise((resolve) => {
  execFile(cmd, args, { cwd, maxBuffer: 8 * 1024 * 1024, ...opts }, (err, stdout) => resolve({ stdout: stdout || "", code: err ? (err.code || 1) : 0 }));
});

// Loopback-only guard for the write route: accepts Host 127.0.0.1|localhost
// (any port) and, when present, an Origin whose host is likewise loopback —
// blocks CSRF/DNS-rebinding from a page loaded on some other origin.
const localHost = (h) => /^(127\.0\.0\.1|localhost)(:\d+)?$/i.test(String(h || ""));

// The audit verdict for the running-milestone card. Prefers the repo's VENDORED
// gate when it exists, exactly like /milestone's and /roadmap's pre-flights do:
// the vendored copy is what CI runs, and the plugin path can be a stale cache
// build. `--check` is read-only against the repo (its only write is a mktemp dir
// it removes), so this stays inside the board's read-only mandate.
// Timed out rather than left to hang: the gate walks git history, and a wedged
// subprocess would stall every /state.json poll behind it. A kill reads as a
// non-zero exit with no recognisable output, which classifyAudit already calls
// "unknown" — the card degrades to a question mark instead of a stuck page.
export function auditRunner(projectDir, sh = run("bash", projectDir, { timeout: 10000 })) {
  const vendored = join(projectDir, ".github", "scripts", "audit-gate.sh");
  return () => sh([
    existsSync(vendored) ? vendored : fileURLToPath(new URL("../hooks/audit-gate.sh", import.meta.url)),
    "--check",
  ]);
}

export function createServer({ projectDir, git = run("git", projectDir), gh = run("gh", projectDir), audit = auditRunner(projectDir), ghCacheMs = 15000, auditCacheMs = 15000 }) {
  let ghCache = { key: null, at: 0, promise: null };
  const cachedGh = (args) => {
    const key = JSON.stringify(args); const now = Date.now();
    if (ghCache.key !== key || !ghCache.promise || now - ghCache.at > ghCacheMs) { ghCache = { key, at: now, promise: gh(args) }; }
    return ghCache.promise;
  };
  // Same reason as the gh cache: the page polls every 3s and the gate walks git
  // history. Do not let a viewer tab set the cost of the audit check.
  let auditCache = { at: 0, promise: null };
  const cachedAudit = () => {
    const now = Date.now();
    if (!auditCache.promise || now - auditCache.at > auditCacheMs) auditCache = { at: now, promise: Promise.resolve().then(audit) };
    return auditCache.promise;
  };
  const PAGE = renderPage();
  return http.createServer(async (req, res) => {
    if (req.method === "POST" && req.url === "/ideas") {
      if (!localHost(req.headers.host)) { res.writeHead(403); return res.end("forbidden"); }
      const origin = req.headers.origin;
      if (origin) {
        let originHost;
        try { originHost = new URL(origin).host; } catch { res.writeHead(403); return res.end("forbidden"); }
        if (!localHost(originHost)) { res.writeHead(403); return res.end("forbidden"); }
      }
      let raw = "";
      req.setEncoding("utf8");
      req.on("data", (c) => { raw += c; if (raw.length > 64 * 1024) { res.writeHead(413); res.end("too large"); req.destroy(); } });
      req.on("end", () => {
        if (res.writableEnded) return;
        let parsed;
        try { parsed = JSON.parse(raw || "{}"); } catch { res.writeHead(400); return res.end("invalid JSON"); }
        try {
          const { backlogDir } = readConfig(projectDir);
          const { file } = writeIdea(projectDir, backlogDir, { title: parsed.title, body: parsed.body, now: Date.now() });
          res.writeHead(201, { "content-type": "application/json" });
          res.end(JSON.stringify({ file }));
        } catch (e) {
          res.writeHead(/title required/.test(e.message) ? 400 : 500);
          res.end("error: " + e.message);
        }
      });
      return;
    }
    if (req.method !== "GET") { res.writeHead(405); return res.end("read-only"); }
    try {
      if (req.url === "/" || req.url.startsWith("/index")) { res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return res.end(PAGE); }
      if (req.url.startsWith("/state.json")) {
        const state = await buildState(projectDir, { git, gh: cachedGh, audit: cachedAudit, now: Date.now() });
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        return res.end(JSON.stringify(state));
      }
      res.writeHead(404); res.end("not found");
    } catch (e) { res.writeHead(500); res.end("error: " + e.message); }
  });
}

function parseArgs(argv) {
  const a = { port: 7878, open: true, projectDir: process.cwd() };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === "--port") a.port = parseInt(argv[++i], 10);
    else if (v === "--no-open") a.open = false;
    else if (v === "--project") a.projectDir = argv[++i];
  }
  return a;
}

async function listenWithFallback(srv, port, host, tries = 10) {
  for (let p = port; p < port + tries; p++) {
    const ok = await new Promise((resolve, reject) => {
      const onErr = (e) => { if (e.code === "EADDRINUSE") resolve(false); else reject(e); };
      srv.once("error", onErr);
      srv.listen(p, host, () => { srv.removeListener("error", onErr); resolve(true); });
    });
    if (ok) return p;
  }
  throw new Error(`no free port in ${port}..${port + tries}`);
}

function openBrowser(url) {
  const cmd = process.platform === "darwin" ? "open" : process.platform === "win32" ? "explorer" : "xdg-open";
  execFile(cmd, [url], () => {});
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const args = parseArgs(process.argv.slice(2).filter((a) => a !== "serve"));
  const srv = createServer({ projectDir: args.projectDir });
  let port;
  try { port = await listenWithFallback(srv, args.port, "127.0.0.1"); }
  catch (e) { process.stderr.write(`sweap-board: cannot start — ${e.message}\n`); process.exit(1); }
  const url = `http://127.0.0.1:${port}/`;
  process.stdout.write(`sweap-board: ${url}  (project: ${args.projectDir})\nread-only (writes only new idea files under the roadmap ideas/ inbox) — Ctrl-C to stop\n`);
  if (args.open) openBrowser(url);
}
