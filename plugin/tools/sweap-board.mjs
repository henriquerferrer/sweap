#!/usr/bin/env node
// sweap-board.mjs — loopback-only, read-only viewer server + CLI.
// Reads state; NEVER writes files, mutates the board, or invokes the pipeline.
import http from "node:http";
import { execFile } from "node:child_process";
import { buildState } from "./sweap-board.lib.mjs";
import { renderPage } from "./sweap-board.page.mjs";

const run = (cmd, cwd) => (args) => new Promise((resolve) => {
  execFile(cmd, args, { cwd, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => resolve({ stdout: stdout || "", code: err ? (err.code || 1) : 0 }));
});

export function createServer({ projectDir, git = run("git", projectDir), gh = run("gh", projectDir), ghCacheMs = 15000 }) {
  let ghCache = { key: null, at: 0, promise: null };
  const cachedGh = (args) => {
    const key = JSON.stringify(args); const now = Date.now();
    if (ghCache.key !== key || !ghCache.promise || now - ghCache.at > ghCacheMs) { ghCache = { key, at: now, promise: gh(args) }; }
    return ghCache.promise;
  };
  const PAGE = renderPage();
  return http.createServer(async (req, res) => {
    if (req.method !== "GET") { res.writeHead(405); return res.end("read-only"); }
    try {
      if (req.url === "/" || req.url.startsWith("/index")) { res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return res.end(PAGE); }
      if (req.url.startsWith("/state.json")) {
        const state = await buildState(projectDir, { git, gh: cachedGh, now: Date.now() });
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
  process.stdout.write(`sweap-board: ${url}  (project: ${args.projectDir})\nread-only — Ctrl-C to stop\n`);
  if (args.open) openBrowser(url);
}
