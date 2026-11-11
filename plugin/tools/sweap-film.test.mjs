// sweap-film.test.mjs — bin/sweap-film (the demo skill's recorder) and the skill's guards.
// No browser here: the runner, ffmpeg, ffprobe and pgrep are stubs on PATH, so these tests pin
// what the script decides (supported or not, which runner, which environment, what it prints).
// Whether a tour films well is witnessed in a real project, not here.
// Run: node --test plugin/tools/sweap-film.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync, realpathSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const PLUGIN = join(HERE, "..");
const BIN = join(PLUGIN, "bin", "sweap-film");
const SKILL = join(PLUGIN, "skills", "demo");

const withDir = (fn) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "sweap-film-")));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
};
const stub = (bin, name, body) => {
  const p = join(bin, name);
  writeFileSync(p, `#!/bin/sh\n${body}\n`);
  chmodSync(p, 0o755);
};

// A project: <root>/<lockfile>, <root>/e2e/.tours/tours.config.ts, an installed @playwright/test.
function project(root, { lock = "pnpm-lock.yaml", pw = "1.61.1", config = true, env } = {}) {
  const pkg = join(root, "e2e");
  mkdirSync(join(pkg, ".tours"), { recursive: true });
  if (lock) writeFileSync(join(root, lock), "");
  if (config) writeFileSync(join(pkg, ".tours", "tours.config.ts"), "export default {}\n");
  if (env) writeFileSync(join(pkg, ".tours", "env"), env);
  if (pw) {
    mkdirSync(join(root, "node_modules", "@playwright", "test"), { recursive: true });
    writeFileSync(join(root, "node_modules", "@playwright", "test", "package.json"), JSON.stringify({ name: "@playwright/test", version: pw }, null, 2));
  }
  return pkg;
}

// Stubs: every runner records its argv and env, then "records" one tour video.
function stubs(root, { running = false, ffmpeg = true } = {}) {
  const bin = join(root, "stub-bin");
  mkdirSync(bin);
  const record = `echo "$0 $*" > "${root}/argv"; env > "${root}/env.out"; : > "$TOURS_OUT/reset-password.webm"`;
  for (const r of ["pnpm", "npx", "yarn", "bunx"]) stub(bin, r, record);
  stub(bin, "pgrep", running ? "echo '4242 node playwright test'; exit 0" : "exit 1");
  if (ffmpeg) {
    stub(bin, "ffmpeg", 'for a; do last=$a; done; : > "$last"');
    stub(bin, "ffprobe", "echo 37.48");
  }
  return `${bin}:/usr/bin:/bin`;
}

const film = (pkg, PATH, extraEnv = {}) =>
  spawnSync(BIN, [pkg], { encoding: "utf8", env: { HOME: process.env.HOME, PATH, ...extraEnv } });

test("bin/sweap-film is executable and execs the skill's recorder", () => {
  assert.ok(statSync(BIN).mode & 0o111);
  assert.match(readFileSync(BIN, "utf8"), /^exec \/bin\/sh "\$root\/skills\/demo\/film\.sh" "\$@"$/m);
  assert.ok(statSync(join(SKILL, "film.sh")).isFile());
});

test("the skill is named demo, takes a milestone, and names its recorder by the bin, never a home path", () => {
  const md = readFileSync(join(SKILL, "SKILL.md"), "utf8");
  assert.match(md, /^---\nname: demo\n/);
  assert.match(md, /^argument-hint: "\[milestone or feature\]"$/m);
  assert.match(md, /\/sweap:demo/);
  assert.match(md, /`sweap-film <e2e-package-dir> \[filter\]`/);
  assert.ok(!/~\/\.claude|CLAUDE_PLUGIN_ROOT/.test(md), "the skill must not depend on a path the session cannot see");
  for (const f of ["tour.ts", "tours.config.example.ts"]) assert.ok(existsSync(join(SKILL, f)), f);
});

test("no tours config: not supported here (exit 2), nothing runs", () => withDir((root) => {
  const pkg = project(root, { config: false });
  const r = film(pkg, stubs(root));
  assert.equal(r.status, 2);
  assert.match(r.stderr, /no .*\.tours\/tours\.config\.\{ts,mjs,js\}/);
  assert.ok(!existsSync(join(root, "argv")));
}));

test("no ffmpeg: not supported here (exit 2)", () => withDir((root) => {
  const pkg = project(root);
  const r = film(pkg, stubs(root, { ffmpeg: false }));
  assert.equal(r.status, 2);
  assert.match(r.stderr, /ffmpeg is required/);
}));

test("@playwright/test not installed, or older than 1.61: not supported here (exit 2)", () => withDir((root) => {
  let r = film(project(join(root, "a") , { pw: null }) , stubs(mkdirP(join(root, "a"))));
  assert.equal(r.status, 2);
  assert.match(r.stderr, /@playwright\/test is not installed/);
  r = film(project(mkdirP(join(root, "b")), { pw: "1.56.2" }), stubs(join(root, "b")));
  assert.equal(r.status, 2);
  assert.match(r.stderr, /1\.56 is installed; demos need 1\.61 or newer/);
}));

test("another Playwright run going: refuse (exit 3) without starting a second", () => withDir((root) => {
  const pkg = project(root);
  const r = film(pkg, stubs(root, { running: true }));
  assert.equal(r.status, 3);
  assert.match(r.stderr, /already going/);
  assert.ok(!existsSync(join(root, "argv")));
}));

test("pnpm project: one worker, no foreign base URL, env file sourced, MP4 + contact sheet printed", () => withDir((root) => {
  const pkg = project(root, { env: "APP_RUN_ID=tours\n" });
  const r = film(pkg, stubs(root), { PLAYWRIGHT_BASE_URL: "https://staging.example.com" });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(join(root, "argv"), "utf8"), /pnpm exec playwright test -c \.tours\/tours\.config\.ts/);
  const env = readFileSync(join(root, "env.out"), "utf8");
  assert.match(env, /^PLAYWRIGHT_WORKERS=1$/m);
  assert.match(env, /^APP_RUN_ID=tours$/m);
  assert.ok(!/PLAYWRIGHT_BASE_URL/.test(env), "a base URL from the environment could point the tours at a real server");
  const out = join(pkg, ".tours", "out");
  assert.match(r.stdout, new RegExp(`^FILMED ${out}/reset-password\\.mp4 \\(37s\\) contact: ${out}/reset-password\\.contact\\.png$`, "m"));
  assert.ok(existsSync(join(out, "reset-password.mp4")) && existsSync(join(out, "reset-password.contact.png")));
}));

test("the runner follows the nearest lockfile: npm → npx --no-install, yarn → yarn", () => withDir((root) => {
  const a = mkdirP(join(root, "a"));
  film(project(a, { lock: "package-lock.json" }), stubs(a));
  assert.match(readFileSync(join(a, "argv"), "utf8"), /npx --no-install playwright test -c /);
  const b = mkdirP(join(root, "b"));
  film(project(b, { lock: "yarn.lock" }), stubs(b));
  assert.match(readFileSync(join(b, "argv"), "utf8"), /yarn playwright test -c /);
}));

test("a video left over from an earlier run is not reported as filmed this run", () => withDir((root) => {
  const pkg = project(root);
  const PATH = stubs(root);
  const out = join(pkg, ".tours", "out");
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "old-flow.webm"), "");
  const r = film(pkg, PATH);
  assert.ok(!/old-flow/.test(r.stdout));
}));

test("tour.ts refuses to film anything but a local app", async () => {
  const { assertLocal } = await import(pathToFileURL(join(SKILL, "tour.ts")).href);
  const page = (u) => ({ url: () => u });
  assert.throws(() => assertLocal(page("https://staging.example.com/app")), /not a local app/);
  for (const u of ["http://localhost:3100/app", "http://127.0.0.1:4317/", "http://[::1]:8080/"]) assert.doesNotThrow(() => assertLocal(page(u)));
});

test("the end of a milestone run and the next kickoff both remind, never ask: walkthrough or demo", () => {
  const book = readFileSync(join(PLUGIN, "playbook", "agentic-loop-playbook.md"), "utf8");
  assert.match(book, /`<M> is done: \/sweap:walkthrough <M>\nto walk it with me, or \/sweap:demo <M> to film what it delivered\.`/);
  const ms = readFileSync(join(PLUGIN, "commands", "milestone.md"), "utf8");
  assert.match(ms, /or \/sweap:demo <Mprev> to film what it delivered/);
  assert.match(ms, /never start `\/sweap:walkthrough` or `\/sweap:demo` from here/);
});

function mkdirP(p) { mkdirSync(p, { recursive: true }); return p; }
