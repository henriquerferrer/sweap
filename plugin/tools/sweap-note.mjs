#!/usr/bin/env node
// sweap-note.mjs — the capture-inbox writer behind `bin/sweap-note`. It is the
// same two library calls the playbook and `/sweap:idea` used to spell as a
// `node --input-type=module -e '…'` one-liner: writeDiscovered() for a
// discovered note, writeIdea() for an idea. Both are create-only writes under
// <backlogDir>/{discovered,ideas}/ — this file adds no behaviour of its own,
// it only gives them an argv a session can type and a project can allowlist.
//
// Positional order is unchanged from the one-liner it replaces:
//   sweap-note discovered <title> <gap|direction> <from> <why> <by>
//   sweap-note idea <title> [body]
// Paths are resolved against process.cwd(), exactly as the one-liner did, so
// it must be run from the repo (or worktree) root.
import { readConfig, writeDiscovered, writeIdea } from "./sweap-board.lib.mjs";

const USAGE = `usage:
  sweap-note discovered <title> <gap|direction> <from> <why> <by>
  sweap-note idea <title> [body]
`;

const [sub, ...rest] = process.argv.slice(2);
const cwd = process.cwd();

try {
  if (sub !== "discovered" && sub !== "idea") {
    process.stderr.write(USAGE);
    process.exit(2);
  }
  const { backlogDir } = readConfig(cwd);
  const now = Date.now();
  const out = sub === "discovered"
    ? writeDiscovered(cwd, backlogDir, { title: rest[0], kind: rest[1], from: rest[2], why: rest[3], by: rest[4], now })
    : writeIdea(cwd, backlogDir, { title: rest[0], body: rest[1] || "", now });
  console.log(out.file);
} catch (err) {
  process.stderr.write(`sweap-note: ${err && err.message ? err.message : err}\n`);
  process.exit(1);
}
