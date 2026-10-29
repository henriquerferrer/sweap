// sweap-playbook.test.mjs — bin/sweap-playbook prints the playbook a run reads.
// Run: node --test plugin/tools/sweap-playbook.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, statSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const BIN = join(HERE, "..", "bin", "sweap-playbook");
const PLUGIN_BOOK = realpathSync(join(HERE, "..", "playbook", "agentic-loop-playbook.md"));
const run = (args, cwd, env = process.env) => execFileSync(BIN, args, { cwd, env, encoding: "utf8" });

const withDir = (fn) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "sweap-playbook-")));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
};

test("bin/sweap-playbook is executable (a bin/ file without the x bit is not a command)", () => {
  assert.ok(statSync(BIN).mode & 0o111);
});

test("outside a checkout with a vendored copy it prints the installed plugin's playbook", () => {
  withDir((dir) => {
    execFileSync("git", ["init", "-q", dir]);
    assert.equal(run([], dir).trim(), PLUGIN_BOOK);
  });
});

test("a checkout that vendors docs/agentic-loop-playbook.md gets its own copy", () => {
  withDir((dir) => {
    execFileSync("git", ["init", "-q", dir]);
    mkdirSync(join(dir, "docs"));
    writeFileSync(join(dir, "docs", "agentic-loop-playbook.md"), "vendored\n<!-- run-core:end -->\nreference\n");
    mkdirSync(join(dir, "sub"));
    assert.equal(run([], join(dir, "sub")).trim(), join(dir, "docs", "agentic-loop-playbook.md"), "found from a subdirectory too");
    assert.equal(run(["--run-core"], dir), "vendored\n<!-- run-core:end -->\n");
  });
});

test("reached through a PATH symlink it still resolves the plugin root from its real path", () => {
  withDir((dir) => {
    mkdirSync(join(dir, "pathbin"));
    symlinkSync(BIN, join(dir, "pathbin", "sweap-playbook"));
    const env = { ...process.env, PATH: `${join(dir, "pathbin")}:${process.env.PATH}` };
    const out = execFileSync("sh", ["-c", "sweap-playbook"], { cwd: dir, env, encoding: "utf8" });
    assert.equal(out.trim(), PLUGIN_BOOK);
  });
});

test("--run-core prints the playbook's top through the run-core:end line and nothing after", () => {
  withDir((dir) => {
    const core = run(["--run-core"], dir);
    const book = readFileSync(PLUGIN_BOOK, "utf8");
    assert.ok(core.endsWith("<!-- run-core:end -->\n"));
    assert.ok(book.startsWith(core));
    assert.ok(core.length < book.length);
  });
});

test("an unknown flag is a usage error, not a silent path", () => {
  assert.throws(() => run(["--bogus"], tmpdir()), (e) => e.status === 2);
});
