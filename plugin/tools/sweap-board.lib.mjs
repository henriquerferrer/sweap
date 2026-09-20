// sweap-board.lib.mjs — pure, testable core for the board viewer.
// No process/network side effects, with three exceptions, all scoped to the
// two capture inboxes under <backlogDir>: writeIdea() and writeDiscovered() are
// create-only fs-write helpers (new files under ideas/ and discovered/), and
// archiveDiscovered() is the one move a discovered note ever receives (into
// discovered/archive/, with its promotion provenance appended).
// buildState() itself takes injected git/gh/audit/stranded runners and touches
// no fs beyond reads.
// Reads item files with the same flat-frontmatter contract roadmap-lint enforces.
import { readFileSync, readdirSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { existsSync } from "node:fs";
import { basename } from "node:path";
import { createHash } from "node:crypto";

// Same flat-frontmatter contract as roadmap-lint.sh/audit-gate.sh: `key: value`
// lines; on a duplicate key the FIRST occurrence wins (their `sed -n ... | head -1`).
// YAML 1.2 requires unique keys and js-yaml rejects duplicates; sweap does not
// reject (no lint rule yet) — it only agrees with its own gate about which value
// is read.
export function parseFrontmatter(text) {
  const norm = String(text).replace(/\r\n?/g, "\n");
  const lines = norm.split("\n");
  if (lines[0] !== "---") return { fm: null, body: norm };
  let end = -1;
  for (let i = 1; i < lines.length; i++) if (lines[i] === "---") { end = i; break; }
  if (end === -1) return { fm: null, body: norm };
  const fm = {};
  for (let i = 1; i < end; i++) {
    const m = lines[i].match(/^([A-Za-z0-9_-]+):\s?(.*)$/);
    if (m && !Object.hasOwn(fm, m[1])) fm[m[1]] = m[2].trim();
  }
  return { fm, body: lines.slice(end + 1).join("\n") };
}

export function parseList(raw) {
  if (!raw) return [];
  const inner = String(raw).replace(/^\[/, "").replace(/\]$/, "").trim();
  if (!inner) return [];
  return inner.split(",").map((s) => s.trim()).filter(Boolean);
}

export function readConfig(projectDir) {
  const defaults = { backlogFile: "ROADMAP.md", backlogDir: "roadmap/" };
  let md;
  try { md = readFileSync(join(projectDir, "CLAUDE.md"), "utf8"); } catch { return defaults; }
  const grab = (key) => {
    const m = md.match(new RegExp("^" + key.replace(/\./g, "\\.") + ":\\s*(\\S+)", "m"));
    return m ? m[1] : null;
  };
  const dir = grab("backlog.dir") || defaults.backlogDir;
  return {
    backlogFile: grab("backlog.file") || defaults.backlogFile,
    backlogDir: dir.endsWith("/") ? dir : dir + "/",
  };
}

// --- the milestone index (backlog.file) ---------------------------------------
// The index carries the two things item files structurally cannot: a
// milestone's GOAL sentence and the human's PRIORITY ORDER. Both are what a
// "what is running" card has to say out loud, so the board reads the index for
// the first time here. Bullets are read ONLY under a heading naming milestones,
// which keeps the index's prose (which also uses dashes) out of the parse.
export function parseMilestoneIndex(text) {
  const out = [];
  const seen = new Set();
  let inSection = false, sketch = false;
  for (const raw of String(text).replace(/\r\n?/g, "\n").split("\n")) {
    const h = raw.match(/^#{1,6}\s+(.*)$/);
    if (h) {
      inSection = /milestone/i.test(h[1]);
      // "## Later milestones (sketch, not yet specced)" is not runnable work.
      sketch = inSection && /later|sketch|not yet|future/i.test(h[1]);
      continue;
    }
    if (!inSection) continue;
    const m = raw.match(/^\s*[-*]\s+([A-Za-z][A-Za-z0-9]*(?:\.\d+)*)\s*[—–:-]\s*(.*)$/);
    if (!m || seen.has(m[1])) continue;
    seen.add(m[1]);
    out.push({ id: m[1], goal: m[2].trim().replace(/\s+/g, " "), sketch });
  }
  return out;
}

export function readMilestoneIndex(projectDir, backlogFile) {
  try { return parseMilestoneIndex(readFileSync(join(projectDir, backlogFile), "utf8")); }
  catch { return []; }
}

// --- the run file (.claude/sweap-run.md) ---------------------------------------
// `/milestone` resolves a milestone and a run SHAPE at kickoff and, before this,
// forgot both the moment it printed the goal. This file is that memory: the one
// thing no other file on disk records. Gitignored and ephemeral, exactly like
// `.claude/sweap-board.md`, and ABSENT is a normal state — a run started before
// this shipped, or work driven by hand. The card then derives the milestone from
// what is in flight and says which of the two it did, so an inference is never
// mistaken for a fact. Same flat-frontmatter contract as every other sweap file.
export function readRunFile(projectDir) {
  let text;
  try { text = readFileSync(join(projectDir, ".claude", "sweap-run.md"), "utf8"); } catch { return null; }
  const { fm, body } = parseFrontmatter(text);
  if (!fm || !fm.milestone) return null;
  const turns = Number(fm.turns);
  // stop-failure-notify.sh APPENDS `stalled: <ts> <what>` below the frontmatter
  // when the orchestrator's turn dies on an API error. The last one is the live
  // one; it is the only trace that failure leaves anywhere a tool can read.
  const stalls = String(body || "").split("\n").filter((l) => l.startsWith("stalled: "));
  const lastStall = stalls.length ? stalls[stalls.length - 1].slice("stalled: ".length).trim() : null;
  return {
    stalled: lastStall ? { at: lastStall.split(" ")[0], detail: lastStall } : null,
    milestone: fm.milestone,
    shape: fm.shape || null,
    scope: parseList(fm.scope),
    turns: Number.isFinite(turns) && turns > 0 ? turns : null,
    started: fm.started || null,
    deferredHandoffs: parseList(fm.deferred_handoffs),
    // How the run ENDED, written by the run itself. Every field here is a
    // CLAIM: verifyEnd() re-derives whether it holds and the board renders the
    // verdict, never the claim alone. A run that stops is the one moment it is
    // least able to report on itself reliably, so nothing here is taken on trust.
    ended: fm.ended || null,
    reason: fm.reason || null,
    needs: parseList(fm.needs),
    // `why_not_agent: DS.5.3=taste, FM.10=taste` — per-id, flat, same contract
    // as every other key. This is the ONE thing a run knows that the board
    // cannot derive: why a person is required rather than another turn.
    whyNotAgent: Object.fromEntries(parseList(fm.why_not_agent)
      .map((p) => p.split("=").map((x) => x.trim()))
      .filter(([k, v]) => k && v)),
  };
}

// Longest chain of not-yet-done work hanging off an item. This is the DAG
// scheduler's "upward rank" (HEFT / critical path), and it is the right way to
// order competing hand-offs: counting DEPENDENTS under-ranks a single blocker
// sitting at the head of a nine-deep chain against one that releases nine
// parallel items. DS.5.3 is exactly the former — six levels, not nine abreast.
export function upwardRank(id, rev, byId, memo = new Map()) {
  if (memo.has(id)) return memo.get(id);
  memo.set(id, 0);                                    // cycle guard: an id in progress ranks 0
  let best = 0;
  for (const d of rev.get(id) || []) {
    const it = byId.get(d);
    if (!it || it.status === "done") continue;
    best = Math.max(best, 1 + upwardRank(d, rev, byId, memo));
  }
  memo.set(id, best);
  return best;
}

// The action plan: what the human must do, in the order worth doing it.
//
// DERIVED, never replayed. The run file records only what a run can legitimately
// know — which ids it waited on, and WHY a human is required. Everything a
// reader acts on (the command, what it unblocks, whether it is still needed) is
// recomputed here at render time, so a plan cannot outlive its cause. Terraform
// refuses a saved plan whose state serial moved; Kubernetes stamps
// observedGeneration. Same problem, same answer.
//
// Commands are BUILT, not interpolated: the only variable is an item id, and an
// id that does not match the strict shape below is dropped rather than pasted
// into a command string. Titles, questions and vendor errors never reach a
// command line (MITRE T1204.004 — a suggested command is an execution vector).
const SAFE_ID = /^[A-Za-z][A-Za-z0-9.]{0,62}$/;

export function resumePlan(items, needs = [], { whyNotAgent = {}, lintWhyNotAgent = false } = {}) {
  const byId = new Map(items.map((i) => [i.id, i]));
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }
  const rev = reverseDeps(items, byId, byMilestone);
  const memo = new Map();

  const steps = [], dropped = [];
  for (const id of needs) {
    const it = byId.get(id);
    if (!SAFE_ID.test(String(id))) { dropped.push({ id, why: "id is not a plain item id — refusing to build a command from it" }); continue; }
    if (!it) { dropped.push({ id, why: "no such item" }); continue; }
    if (it.status === "done") { dropped.push({ id, why: "already done — this step is stale" }); continue; }
    // Only the two AUTHORED human states have a drain command. Anything else is
    // not a thing a human resumes, and inventing a command for it would be the
    // failure this is meant to prevent.
    const kind = it.status === "attended" ? "handoff" : it.status === "blocked" ? "blocked" : null;
    if (!kind) { dropped.push({ id, why: `status is ${it.status}, which is not a human's to close` }); continue; }
    const ready = isUnblocked(it, byId, byMilestone);
    steps.push({
      id, kind,
      subject: it.title,
      ask: (kind === "handoff" ? it.handoff : it.blocked) || null,
      command: kind === "handoff" ? `/handoff ${id}` : `/unblock ${id}`,
      purpose: kind === "handoff" ? "do the work only you can do, and close it" : "answer the question the run could not",
      // rustc's Applicability, and for the same reason: a step whose own
      // dependencies are unmet cannot be run yet, so it must not be offered as
      // if it could. Only machine-applicable steps earn a copy-button.
      applicability: ready ? "machine-applicable" : "has-placeholders",
      doneWhen: kind === "handoff" ? `${it.file} reads status: done` : `${it.file} carries a > ANSWER: line and leaves status: blocked`,
      gates: gatedItems(id, rev, byId),
      rank: upwardRank(id, rev, byId, memo),
      // The SRE objection made answerable: if a step is fully machine-applicable
      // and nothing says why an agent may not do it, that is a bug in the run,
      // not a hand-off. Enforced rather than asserted.
      whyNotAgent: whyNotAgent[id] || null,
    });
  }
  // Longest downstream chain first, then breadth, then id for stability.
  steps.sort((a, b) => b.rank - a.rank || b.gates.length - a.gates.length || compareItems(byId.get(a.id), byId.get(b.id)));
  // Only lint a run that actually made a claim. On the DERIVED path the run
  // recorded nothing, so there is no `why_not_agent` to be missing — accusing it
  // of a bug it was never given the chance to avoid is how a good check earns
  // its way into being ignored.
  const suspect = lintWhyNotAgent
    ? steps.filter((s) => s.applicability === "machine-applicable" && !s.whyNotAgent).map((s) => s.id)
    : [];
  return { steps, dropped, suspect };
}

// Verify a run's own account of why it stopped against the backlog itself.
// This is audit-gate.sh's discipline applied to run state: do not trust that
// the run ended well, check that the condition it names actually holds. The
// three outcomes are deliberate — a claim that CONTRADICTS the backlog is worse
// than no claim at all, because it reads authoritative.
export function verifyEnd(runFile, { frontier = [], items = [] } = {}) {
  if (!runFile || !runFile.ended) return null;
  const byId = new Map(items.map((i) => [i.id, i]));
  const open = (id) => byId.has(id) && byId.get(id).status !== "done";
  const runnable = frontier.length;
  const reason = runFile.reason || "(none given)";
  const disagree = (detail) => ({ reason, verdict: "contradicted", detail, runnable });
  switch (runFile.reason) {
    case "frontier-empty":
      return runnable === 0
        ? { reason, verdict: "confirmed", detail: "nothing is runnable — the frontier is empty", runnable }
        : disagree(`claims the frontier is empty, but ${runnable} item${runnable > 1 ? "s are" : " is"} runnable: ${frontier.slice(0, 6).map((i) => i.id).join(", ")}`);
    case "awaiting-human": {
      // A run waiting on a person must NAME who/what it waits for, and those
      // items must still be open. Otherwise "waiting on you" outlives the wait.
      if (!runFile.needs.length) return disagree("claims it is waiting on a human but names nothing — say which item, or the wait is unfalsifiable");
      const settled = runFile.needs.filter((id) => !open(id));
      return settled.length
        ? disagree(`waits on ${settled.join(", ")}, which ${settled.length > 1 ? "are" : "is"} already resolved — this run file is stale`)
        : { reason, verdict: "confirmed", detail: `waiting on ${runFile.needs.join(", ")}`, runnable };
    }
    case "turns-exhausted":
      // Legitimate with work still runnable — that IS what running out means.
      return { reason, verdict: "confirmed", detail: `turn budget spent${runnable ? `; ${runnable} item(s) still runnable` : ""}`, runnable };
    case "goal-met":
      return runnable === 0
        ? { reason, verdict: "confirmed", detail: "nothing runnable remains", runnable }
        : disagree(`claims the goal is met, but ${runnable} item(s) are still runnable`);
    default:
      return { reason, verdict: "unverifiable", detail: "no recognised reason: — the board cannot check this claim", runnable };
  }
}

// Idea inbox: the board's ONLY write capability. Create-only — new uniquely
// named files under <backlogDir>/ideas/, a subdir loadItems/lint/dep
// resolution never read (same reason roadmap/archive/ is invisible).
export const slugify = (title) =>
  String(title).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

export function writeIdea(projectDir, backlogDir, { title, body = "", now }) {
  const t = String(title || "").replace(/\s+/g, " ").trim();
  let slug = slugify(t);
  if (!t || !slug) throw new Error("title required");
  // Cap the on-disk slug so an oversized title can't blow past filesystem
  // name limits (ENAMETOOLONG) into an opaque 500 — truncate, then re-trim
  // any trailing separator the cut may have exposed.
  slug = slug.slice(0, 120).replace(/-+$/, "");
  const dir = join(projectDir, backlogDir, "ideas");
  mkdirSync(dir, { recursive: true });
  let file = slug + ".md";
  for (let n = 2; existsSync(join(dir, file)); n++) file = `${slug}-${n}.md`;
  const content = `---\ntitle: ${t}\ncreated: ${new Date(now).toISOString()}\n---\n\n${String(body || "").trim()}\n`;
  writeFileSync(join(dir, file), content, { flag: "wx" });
  return { file: join(backlogDir, "ideas", file) };
}

export function loadIdeas(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir, "ideas");
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files
    .map((f) => {
      let fm = null;
      try { fm = parseFrontmatter(readFileSync(join(dir, f), "utf8")).fm; } catch { /* unreadable: fall through */ }
      return { file: f, title: (fm && fm.title) || f.replace(/\.md$/, ""), created: (fm && fm.created) || null };
    })
    .sort((a, b) => String(b.created || "").localeCompare(String(a.created || "")) || a.file.localeCompare(b.file));
}

// --- the discovered inbox (work an agent notices while on something else) ----
// A discovered note is deliberately NOT an item: no id (ids are minted at
// promotion, against main, so two parallel sessions can never collide), no
// status, no spec. It is the transactional-outbox row of the pipeline: written
// at discovery time to a place whose fate is independent of the feature branch
// that might die, gate-exempt by path (audit-gate.sh's "other subdirs" arm),
// and relayed later by a triage step that is idempotent on the filename.
// `kind:` is the ONE judgment the capturing session makes, on the line the
// playbook's audit triage already draws: `gap` = the spec promised it (a bug, a
// race, infra) — agent work, triaged against the harm bar by the next /milestone;
// `direction` = not in the spec — a human's call, surfaced by /roadmap.
// The hash suffix is what lets the same title be captured twice from two
// branches without the create-only write failing on the second.
export const DISCOVERED_KINDS = ["gap", "direction"];

export function writeDiscovered(projectDir, backlogDir, { title, kind, why = "", from = "", by = "", milestone = "", now }) {
  const one = (s) => String(s || "").replace(/\s+/g, " ").trim();
  const t = one(title);
  let slug = slugify(t);
  if (!t || !slug) throw new Error("title required");
  if (!DISCOVERED_KINDS.includes(kind)) throw new Error("kind must be gap or direction");
  const w = String(why || "").trim();
  if (!w) throw new Error("why required (a fresh session must be able to act on this note after the branch it was written on is gone)");
  slug = slug.slice(0, 100).replace(/-+$/, "");
  const hex = createHash("sha256").update(`${t}\n${now}\n${one(from)}\n${one(by)}`).digest("hex").slice(0, 6);
  const dir = join(projectDir, backlogDir, "discovered");
  mkdirSync(dir, { recursive: true });
  const file = `${slug}-${hex}.md`;
  const content = `---\ntitle: ${t}\nkind: ${kind}\ndiscovered_from: ${one(from)}\ndiscovered_by: ${one(by)}\nmilestone_hint: ${one(milestone)}\ncreated: ${new Date(now).toISOString()}\n---\n\n${w}\n`;
  writeFileSync(join(dir, file), content, { flag: "wx" });
  return { file: join(backlogDir, "discovered", file) };
}

export function loadDiscovered(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir, "discovered");
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files
    .map((f) => {
      let fm = null, body = "";
      try { ({ fm, body } = parseFrontmatter(readFileSync(join(dir, f), "utf8"))); } catch { /* unreadable: fall through */ }
      const g = (k) => (fm && fm[k]) || null;
      const kind = DISCOVERED_KINDS.includes(g("kind")) ? g("kind") : "unknown";
      return { file: f, title: g("title") || f.replace(/\.md$/, ""), kind, from: g("discovered_from"), by: g("discovered_by"), milestoneHint: g("milestone_hint"), created: g("created"), why: String(body || "").trim() };
    })
    .sort((a, b) => String(b.created || "").localeCompare(String(a.created || "")) || a.file.localeCompare(b.file));
}

// Where a note promotes to: its explicit hint, else the milestone of the item
// it was discovered from. A note discovered from a PR number or nothing at all
// has no target and is listed for a human instead of guessed.
export function promotionTarget(note) {
  const hint = String(note.milestoneHint || "").trim();
  if (hint) return hint;
  const from = String(note.from || "").trim();
  return /^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$/.test(from) ? milestoneOf(from) : null;
}

// Mint the next id under a milestone from what is ON DISK — top-level items AND
// archive/ (a dropped item keeps its id; reusing it would resurrect its history).
// Numeric last segment, so F1.9 -> F1.10, never F1.91. Run against main at
// promotion time, never at capture time: that is the whole reason a note has
// no id.
export function nextItemId(projectDir, backlogDir, milestone) {
  const m = String(milestone || "").trim();
  if (!/^[A-Za-z][A-Za-z0-9.]*$/.test(m)) throw new Error("milestone required");
  let max = 0;
  for (const sub of ["", "archive"]) {
    let files;
    try { files = readdirSync(join(projectDir, backlogDir, sub)).filter((f) => f.endsWith(".md")); } catch { continue; }
    for (const f of files) {
      const id = f.replace(/\.md$/, "");
      if (milestoneOf(id) !== m) continue;
      const n = Number(id.slice(m.length + 1));
      if (Number.isInteger(n) && n > max) max = n;
    }
  }
  return `${m}.${max + 1}`;
}

// Promotion provenance: the note moves to discovered/archive/ with the id it
// became (or why it was declined) appended to its frontmatter. Create-only at
// the destination, so a re-run after a rebase cannot clobber the record.
export function archiveDiscovered(projectDir, backlogDir, file, { promotedTo = "", declined = "" } = {}) {
  const name = basename(file);
  const src = join(projectDir, backlogDir, "discovered", name);
  const key = promotedTo ? `promoted_to: ${String(promotedTo).trim()}` : declined ? `declined: ${String(declined).replace(/\s+/g, " ").trim()}` : null;
  if (!key) throw new Error("promotedTo or declined required");
  const text = readFileSync(src, "utf8");
  const out = text.replace(/^---\n([\s\S]*?)\n---/, (_, fm) => `---\n${fm}\n${key}\n---`);
  const dir = join(projectDir, backlogDir, "discovered", "archive");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), out, { flag: "wx" });
  unlinkSync(src);
  return { file: join(backlogDir, "discovered", "archive", name) };
}

// Output of hooks/stranded-roadmap.sh: one `branch<TAB>pr-state<TAB>age-days<TAB>path,path` line
// per not-merged branch whose <backlogDir> differs from main. `open` is a
// rider (the #181 shape — on a live PR, fine until it isn't); `closed` and
// `none` are stranded: nothing is scheduled to ever land those files.
export function parseStranded(stdout) {
  return String(stdout || "").split("\n").map((l) => l.trim()).filter(Boolean).map((l) => {
    const [branch, pr, age, paths] = l.split("\t");
    const ageDays = Number.isFinite(Number(age)) ? Number(age) : null;
    const state = ["open", "closed", "none"].includes(pr) ? pr : "unknown";
    return { branch, pr: state, ageDays, paths: String(paths || "").split(",").filter(Boolean), stranded: state === "closed" || state === "none" };
  }).filter((s) => s.branch);
}

export function loadItems(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir);
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files.map((f) => {
    const id = f.replace(/\.md$/, "");
    const bad = { id, title: id, status: "unknown", dependsOn: [], reviewDimensions: [], lane: null, followupOf: null, blocked: null, carried: 0, handoff: null, malformed: true, file: f };
    let fm;
    try { fm = parseFrontmatter(readFileSync(join(dir, f), "utf8")).fm; } catch { return bad; }
    if (!fm || !fm.status) return bad;
    return {
      id: fm.id || id,
      title: fm.title || id,
      status: fm.status,
      dependsOn: parseList(fm.depends_on),
      reviewDimensions: parseList(fm["review-dimensions"]),
      lane: fm.lane || null,
      followupOf: fm.followup_of || null,
      blocked: fm.blocked || null,
      // Milestone boundaries this question has survived unanswered. Absent on
      // every item authored before the blocked-queue drain shipped, and absent
      // on every question that has never crossed a boundary — both read as 0.
      carried: Number.isFinite(Number(fm.carried)) && Number(fm.carried) >= 0 ? Number(fm.carried) : 0,
      handoff: fm.handoff || null,
      malformed: Boolean(fm.id && fm.id !== id),
      file: f,
    };
  });
}

// A milestone id is an item id with its last dotted segment removed:
// F1.1 -> F1, DS.2.1 -> DS.2, DS.1 -> DS. This is dot-depth-agnostic, so a
// milestone whose ids carry a dot (DS.2) groups its items (DS.2.1) correctly.
export const milestoneOf = (id) => String(id).replace(/\.[^.]*$/, "");

export function isUnblocked(item, byId, byMilestone) {
  return item.dependsOn.every((dep) => {
    // A dep that names an actual item is satisfied when that item is done;
    // otherwise treat it as a milestone dep (all its items done). Classifying by
    // membership (not by counting dots) is what makes multi-segment ids work.
    if (byId.has(dep)) return byId.get(dep).status === "done";
    // Follow-ups are debt OF a milestone, not members of it (audit-gate.sh draws
    // the same line): a parked one must not hold the milestone open forever.
    const items = (byMilestone.get(dep) || []).filter((i) => !i.followupOf);
    return items.length > 0 && items.every((i) => i.status === "done");
  });
}

const numKey = (id) => String(id).split(".").map((s) => { const m = s.match(/\d+/); return m ? parseInt(m[0], 10) : 0; });

export function compareItems(a, b) {
  const ad = a.followupOf ? 0 : 1, bd = b.followupOf ? 0 : 1;
  if (ad !== bd) return ad - bd;
  const ak = numKey(a.id), bk = numKey(b.id);
  for (let i = 0; i < Math.max(ak.length, bk.length); i++) { const d = (ak[i] || 0) - (bk[i] || 0); if (d) return d; }
  return String(a.id).localeCompare(String(b.id));
}

// Reverse dependency map: dep id -> [ids that depend on it]. A dep naming a
// MILESTONE expands to every item in it, so "what does this hand-off gate?"
// answers correctly for bare-milestone deps too (same classify-by-membership
// rule as isUnblocked).
export function reverseDeps(items, byId, byMilestone) {
  const rev = new Map();
  for (const i of items) {
    for (const dep of i.dependsOn) {
      const targets = byId.has(dep) ? [dep] : (byMilestone.get(dep) || []).map((x) => x.id);
      for (const t of targets) { if (!rev.has(t)) rev.set(t, []); rev.get(t).push(i.id); }
    }
  }
  return rev;
}

// Every not-yet-done item transitively waiting on `id`. This is the number that
// makes the /milestone kickoff fork a real choice ("this hand-off gates 3 of 7
// items") instead of a nag.
export function gatedItems(id, rev, byId) {
  const seen = new Set();
  const stack = [id];
  while (stack.length) {
    for (const d of rev.get(stack.pop()) || []) if (!seen.has(d)) { seen.add(d); stack.push(d); }
  }
  return [...seen].filter((d) => byId.has(d) && byId.get(d).status !== "done").sort();
}

export function deriveBacklog(items) {
  const byId = new Map(items.map((i) => [i.id, i]));
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }

  const frontier = items
    .filter((i) => i.status === "todo" && isUnblocked(i, byId, byMilestone))
    .sort(compareItems);

  // `carried` rides along so the column can show a question's AGE. The queue was
  // always visible here; what it never showed is that a question had sat through
  // whole milestones, which is the thing that makes it worth answering now.
  const blocked = items
    .filter((i) => i.status === "blocked")
    .map((i) => ({ id: i.id, title: i.title, question: i.blocked || "(no question recorded)", carried: i.carried || 0 }));

  // Hand-offs are a SEPARATE queue from blocked on purpose: blocked means an
  // agent failed and needs an answer, attended means this was always the
  // human's to do. Mixing them is what makes a needs-me-now list stop being read.
  const rev = reverseDeps(items, byId, byMilestone);
  const attended = items
    .filter((i) => i.status === "attended")
    .sort(compareItems)
    .map((i) => ({
      id: i.id,
      title: i.title,
      task: i.handoff || "(no hand-off recorded)",
      ready: isUnblocked(i, byId, byMilestone),
      gates: gatedItems(i.id, rev, byId),
    }));

  const backlog = [...byMilestone.entries()]
    .sort((a, b) => compareItems({ id: a[0] + ".0", followupOf: null }, { id: b[0] + ".0", followupOf: null }))
    .map(([milestone, its]) => ({ milestone, items: [...its].sort(compareItems) }));

  const edges = [];
  for (const i of items) for (const dep of i.dependsOn) if (byId.has(dep)) edges.push({ from: dep, to: i.id });

  return { frontier, attended, blocked, backlog, edges };
}

// --- the running-milestone card -------------------------------------------------
// The board could always answer "which items are moving"; it could never answer
// --- the acceptance pass (session sheets, and what /walkthrough should walk) --------
// A session sheet is the record that a HUMAN exercised a shipped milestone.
// It lives at <backlogDir>sessions/<M>-<YYYY-MM-DD>.md and is deliberately a
// third inbox subdir rather than an item: audit-gate.sh's "other subdirs" arm
// already classifies anything under <backlogDir>*/* as non-item, so a session
// PR is not backlog-advancing (it lands during audit debt) and rides the
// roadmap-only CI lane. No gate change was needed to add this.
//
// Why a durable record at all, when the blocked-queue research
// (docs/research/2026-08-16-blocked-question-queue.md §7) is explicit that
// "more surfacing" changes nothing: because a CONTROL reads it. /milestone's
// kickoff fork decides off it. That is the same test the playbook applies to
// .claude/sweap-run.md, which it demotes precisely because "nothing in the loop
// reads it to decide anything".
// The lib owns this format, exactly as writeIdea owns the idea file's — and for
// a sharper reason than symmetry. `gaps: 0` is what trips the kill condition
// (`dry` below), and an unparseable sheet would otherwise read as a session that
// found nothing, i.e. a formatting slip would argue for deleting the command.
// So sheets are written through here, and a sheet that cannot be parsed is
// marked `malformed` rather than silently counted as barren — the same
// convention loadItems already uses for an item file it cannot read.
export function writeSession(projectDir, backlogDir, { milestone, date, counts = {}, body = "", viewports = [] }) {
  const m = String(milestone || "").trim();
  const d = String(date || "").trim();
  if (!m || !/^[A-Za-z][A-Za-z0-9.]*$/.test(m)) throw new Error("milestone required (a plain milestone tag)");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) throw new Error("date required (YYYY-MM-DD)");
  const num = (v) => { const n = Number(v); return Number.isFinite(n) && n >= 0 ? Math.trunc(n) : 0; };
  const keys = ["duration_min", "charter", "walked", "skipped", "on_charter", "on_opportunity", "observations", "gaps", "directions", "ideas", "answered"];
  const verdicts = ["accepted", "accepted-with-followups", "rejected"];
  const verdict = verdicts.includes(counts.verdict) ? counts.verdict : "accepted-with-followups";
  const dir = join(projectDir, backlogDir, "sessions");
  mkdirSync(dir, { recursive: true });
  let file = `${m}-${d}.md`;
  for (let n = 2; existsSync(join(dir, file)); n++) file = `${m}-${d}-${n}.md`;
  const fm = ["sweap_format: 1", `milestone: ${m}`, `date: ${d}`]
    .concat(`viewports: [${(viewports || []).map((v) => String(v).trim()).filter(Boolean).join(", ")}]`)
    .concat(keys.map((k) => `${k}: ${num(counts[k])}`))
    .concat(`verdict: ${verdict}`);
  writeFileSync(join(dir, file), `---\n${fm.join("\n")}\n---\n\n${String(body || "").trim()}\n`, { flag: "wx" });
  return { file: join(backlogDir, "sessions", file) };
}

export function loadSessions(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir, "sessions");
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  const num = (v) => { const n = Number(v); return Number.isFinite(n) && n >= 0 ? n : 0; };
  return files
    .map((f) => {
      let fm = null;
      try { fm = parseFrontmatter(readFileSync(join(dir, f), "utf8")).fm; } catch { /* unreadable — malformed, below */ }
      if (!fm || !fm.milestone) {
        return { file: f, milestone: (fm && fm.milestone) || null, date: (fm && fm.date) || null, verdict: null, walked: 0, gaps: 0, directions: 0, ideas: 0, malformed: true };
      }
      return {
        file: f,
        milestone: fm.milestone,
        date: fm.date || null,
        verdict: fm.verdict || null,
        walked: num(fm.walked),
        gaps: num(fm.gaps),
        directions: num(fm.directions),
        ideas: num(fm.ideas),
        malformed: false,
      };
    })
    .sort((a, b) => String(b.date || "").localeCompare(String(a.date || "")) || b.file.localeCompare(a.file));
}

// The instrumentation A13 demanded, and the only number that decides whether
// /walkthrough keeps existing. Urbach (mandating an identical checklist across 215,711
// procedures moved outcomes at P=0.13) and Sendlhofer (usage held ~90% while
// COMPLETION fell 81.7%→53.2%) are the same finding twice: "did it happen?" is
// the one signal that decays invisibly, and a hollow session satisfies it
// perfectly. So measure YIELD, never attendance.
// `dry` counts the most recent consecutive sessions that produced no gap note —
// at 3 the automated filters have caught up and the command should be cut back.
export function sessionStats(sessions = []) {
  // A malformed sheet is a bug in the writer, not a barren session. Counting it
  // toward `dry` would let a formatting slip argue for deleting the command,
  // so it is excluded from the yield maths and surfaced on its own.
  const ok = sessions.filter((s) => !s.malformed);
  const gaps = ok.reduce((n, s) => n + s.gaps, 0);
  const notes = ok.reduce((n, s) => n + s.gaps + s.directions + s.ideas, 0);
  let dry = 0;
  for (const s of ok) { if (s.gaps > 0) break; dry++; }
  return {
    sessions: ok.length,
    malformed: sessions.length - ok.length,
    gaps,
    notes,
    dry,
    notesPerSession: ok.length ? notes / ok.length : 0,
  };
}

// Which milestone /walkthrough should walk, and — always — WHY it picked that one.
// There is no existing implementation of "the most recently completed
// milestone" to borrow: workflows/milestone-audit.js falls back to that literal
// phrase inside an LLM prompt, and the playbook records that this once audited
// the WRONG milestone. So this resolves mechanically and carries a `source`,
// under the same rule buildMilestoneCard follows — an inference must never be
// readable as a fact.
//
// Complete = every non-follow-up item in the group is done, and the group holds
// at least one non-follow-up item (a `followup_of:` family like FN is debt OF a
// milestone, never a milestone — audit-gate.sh:169-176 draws the same line).
// Order = the INDEX's order, not the id's; unlisted milestones sort last.
export function resolveTestTarget({ items = [], index = [], sessions = [] } = {}) {
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }

  const rank = new Map(index.map((m, n) => [m.id, n]));
  const order = (m) => (rank.has(m) ? rank.get(m) : Number.MAX_SAFE_INTEGER);
  const compareMs = (a, b) => (order(a) - order(b)) || compareItems({ id: a + ".0", followupOf: null }, { id: b + ".0", followupOf: null });

  const members = (m) => (byMilestone.get(m) || []).filter((i) => !i.followupOf);
  const complete = [...byMilestone.keys()]
    .filter((m) => members(m).length > 0 && members(m).every((i) => i.status === "done"))
    .sort(compareMs);
  if (!complete.length) return null;

  const walked = new Set(sessions.map((s) => s.milestone).filter(Boolean));
  const untested = complete.filter((m) => !walked.has(m));
  const pick = untested.length ? untested[untested.length - 1] : complete[complete.length - 1];
  const priors = sessions.filter((s) => s.milestone === pick);

  return {
    milestone: pick,
    items: members(pick).length,
    sessions: priors.length,
    source: priors.length
      ? `last complete milestone in index order; every complete milestone already has a session (${pick} has ${priors.length})`
      : "last complete milestone in index order with no session sheet",
    untested: untested.length,
  };
}

// "which MILESTONE is moving, and what stands between it and done". Nothing on
// disk recorded that, so nothing could show it. This derives it.
//
// Which milestone is running, in order of authority:
//   1. `.claude/sweap-run.md` — what /milestone actually resolved (exact: it
//      knows the run SHAPE, which no amount of item-file reading can recover).
//      Ignored once that milestone has no unfinished items: the run ended and
//      the file is just litter.
//   2. otherwise the milestone of the earliest IN-FLIGHT item that is not an
//      audit follow-up — a follow-up belongs to the milestone that was audited,
//      not to the one being run, so leading with it would name the wrong one.
//   3. otherwise the next runnable milestone — the same rule /milestone
//      resolves by: first in index order holding a todo item whose deps are all
//      satisfied. This is a guess about the future, so `state` says "next".
// `source` rides along on every card: an inference must never be readable as a
// fact, which is the whole reason the run file exists at all.
export function buildMilestoneCard({ items, index = [], runFile = null, inFlight = [], frontier = [], attended = [], blocked = [], audit = null }) {
  if (!items.length) return null;
  const byId = new Map(items.map((i) => [i.id, i]));
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }

  // Priority order is the INDEX's order — that is the human's stated order, and
  // it is not always numeric. Milestones the index never lists sort after it.
  const rank = new Map(index.map((m, n) => [m.id, n]));
  const order = (m) => (rank.has(m) ? rank.get(m) : Number.MAX_SAFE_INTEGER);
  const compareMs = (a, b) => (order(a) - order(b)) || compareItems({ id: a + ".0", followupOf: null }, { id: b + ".0", followupOf: null });

  // An audit-follow-up FAMILY is not a milestone. `FN.3` groups under "FN", but
  // FN is a family keyed by `followup_of: F11` — consumer A's config says so in as
  // many words, and its backlog holds 13 such families against 15 real
  // milestones. A group with no non-follow-up item in it has never been a
  // milestone, so the card must never name one; that is exactly the wrong
  // answer inference reaches for when a run is draining debt.
  const isMilestone = (m) => (byMilestone.get(m) || []).some((i) => !i.followupOf);
  const incomplete = [...byMilestone.keys()]
    .filter((m) => isMilestone(m) && byMilestone.get(m).some((i) => i.status !== "done"))
    .sort(compareMs);
  // Follow-ups are excluded here for the same reason they are excluded from
  // `lead` below: debt is the scope `D` that runs AHEAD of a milestone, not the
  // milestone's own work. A milestone whose only ready item is a follow-up is
  // not the milestone being run — its debt is.
  const readyIds = new Set(frontier.filter((i) => !i.followupOf).map((i) => i.id));
  const nextRunnable = incomplete.find((m) => byMilestone.get(m).some((i) => readyIds.has(i.id))) || null;
  // ...and a milestone whose every item is GATED — the hand-offs-outstanding
  // shape — is still the milestone being run. It is the shape /milestone models
  // explicitly, and it is the state consumer A sat in for this whole run: DS.5's
  // nine todo items all wait on DS.5.3, an attended hand-off. Requiring a READY
  // item here is what made the card render nothing at all on the one project
  // actually running a milestone.
  const nextGated = incomplete.find((m) => byMilestone.get(m).some((i) => !i.followupOf && i.status !== "done")) || null;

  const flight = inFlight.map((f) => byId.get(f.id)).filter(Boolean);
  const lead = flight.filter((i) => !i.followupOf).sort(compareItems)[0] || null;

  let id = null, source = null;
  if (runFile && incomplete.includes(runFile.milestone)) { id = runFile.milestone; source = "run-file"; }
  else if (lead) { id = milestoneOf(lead.id); source = "in-flight"; }
  else if (nextRunnable) { id = nextRunnable; source = "derived"; }
  else if (nextGated) { id = nextGated; source = "gated"; }
  if (!id) return null;

  const mine = byMilestone.get(id) || [];
  const counts = { total: mine.length, done: 0, todo: 0, blocked: 0, attended: 0, deferred: 0, other: 0 };
  for (const i of mine) { if (Object.prototype.hasOwnProperty.call(counts, i.status) && i.status !== "total") counts[i.status]++; else counts.other++; }

  const inScope = (itemId) => milestoneOf(itemId) === id;
  const inFlightIds = new Set(inFlight.map((f) => f.id));
  // Every in-flight item shows, tagged by where it sits in the run's scope: the
  // run is `D` then `M` (debt-first), so a follow-up moving right now is this
  // run's work even though it belongs to an older milestone's numbering.
  const flightRows = inFlight.map((f) => {
    const it = byId.get(f.id);
    return { ...f, scope: it && it.followupOf ? "debt" : inScope(f.id) ? "milestone" : "other" };
  });
  const ready = frontier
    .filter((i) => inScope(i.id) && !inFlightIds.has(i.id))
    .map((i) => ({ id: i.id, title: i.title, lane: i.lane }));
  // Audit debt `D` — every follow-up that is todo AND unblocked, anywhere. The
  // frontier already holds them; the card names them as the scope PREFIX
  // instead, because that is what debt-first means for this run's shape.
  const debt = frontier.filter((i) => i.followupOf).map((i) => ({ id: i.id, title: i.title, followupOf: i.followupOf }));

  const handoffs = attended.filter((a) => inScope(a.id));
  const blockedHere = blocked.filter((b) => inScope(b.id));

  // Audit, most-specific first. "blocked-by-debt" is deliberately loud even
  // though the debt is ANOTHER milestone's: while it stands, no backlog-
  // advancing PR merges at all, so it is this run's problem too.
  let state = "unknown", detail = null;
  const notDue = handoffs.length
    ? `${handoffs.length} open hand-off${handoffs.length > 1 ? "s keep" : " keeps"} ${id} incomplete, so its audit is not due this run`
    : null;
  if (audit && audit.unknown) {
    // The gate failing outranks "not due": not-due is about THIS milestone's
    // hand-offs, and says nothing about whether an older milestone's missing
    // record is about to deny every merge. Claiming the smaller answer here
    // would read as the whole one.
    detail = "audit-gate --check did not run here" + (notDue ? ` · ${notDue}` : "");
  } else if (audit) {
    if (audit.debt.includes(id)) { state = "debt"; detail = `${id} is complete but has no valid audit record — run /milestone-audit ${id}`; }
    else if (audit.deferred.includes(id)) { state = "deferred"; detail = `${id} completes in the state under review, so its audit cannot have run yet — land it, then run /milestone-audit ${id}`; }
    else if (audit.debt.length) { state = "blocked-by-debt"; detail = `audit debt on ${audit.debt.join(", ")} — no backlog-advancing PR merges until it is discharged`; }
    else if (notDue) { state = "not-due"; detail = notDue; }
    else state = "clean";
  } else if (notDue) { state = "not-due"; detail = notDue; }

  // How the run ended, and whether its own account survives checking. Derived
  // when it made no claim — which is the case that matters, since a run that
  // stops badly is exactly the one that forgets to write anything down. The
  // board must never be blind just because an agent did not remember.
  let end = verifyEnd(runFile, { frontier, items });
  if (end) {
    end = { ...end, source: "run-file", at: runFile.ended };
    // What the human must actually DO. Derived here rather than read from the
    // file, so it cannot be stale, and so a run cannot hand out a command for
    // work that is already closed.
    end.plan = resumePlan(items, runFile.needs, { whyNotAgent: runFile.whyNotAgent, lintWhyNotAgent: runFile.reason === "awaiting-human" });
  }
  else if (!frontier.length && !inFlight.length) {
    end = { reason: "frontier-empty", verdict: "derived", source: "derived", at: null, runnable: 0,
            detail: "nothing is runnable and nothing is in flight — the run has no legal work left, whether or not it said so" };
    // Nothing was recorded, so derive the needs too: every open human-owned item
    // gating unfinished work. A run that forgets to say what it needs must not
    // cost the human the answer.
    const owed = items.filter((i) => (i.status === "attended" || i.status === "blocked"));
    end.plan = resumePlan(items, owed.map((i) => i.id));
  }
  // Distinct from `end`: there IS work and nobody is on it. This is the state
  // consumer A sat in for 7h on 2026-08-21 while looking, from every tool, like
  // silence. Cheap to compute and it needs no cooperation from the run.
  const idle = frontier.length && !inFlight.length
    ? { runnable: frontier.length, detail: `${frontier.length} item${frontier.length > 1 ? "s are" : " is"} runnable and nothing is in flight` }
    : null;

  const entry = index.find((m) => m.id === id) || null;
  return {
    id,
    end,
    idle,
    // Only while the run has not recorded an end AFTER it: a stall the run
    // recovered from and then finished is history, not a state.
    stalled: runFile && runFile.stalled && !(runFile.ended && String(runFile.ended) > runFile.stalled.at) ? runFile.stalled : null,
    goal: entry ? entry.goal : null,
    sketch: entry ? entry.sketch : false,
    state: flight.length ? "running" : "next",
    source,
    shape: runFile ? runFile.shape : null,
    turns: runFile ? runFile.turns : null,
    started: runFile ? runFile.started : null,
    deferredHandoffs: runFile ? runFile.deferredHandoffs : [],
    counts,
    inFlight: flightRows,
    ready,
    debt,
    handoffs,
    blocked: blockedHere,
    audit: {
      state,
      detail,
      debtMilestones: audit ? audit.debt : [],
      integrity: audit ? audit.integrity : [],
    },
  };
}

// audit-gate.sh --check speaks in line prefixes (its own header documents the
// contract): FAIL: milestone/record = audit debt, FAIL: hand-off = a backlog-
// integrity violation no audit discharges, DEFERRED: = not debt yet, AGING: =
// informational.
export function classifyAudit(stdout, code) {
  const res = { debt: [], deferred: [], integrity: [], unknown: false };
  let recognized = 0;
  for (const l of String(stdout || "").split("\n")) {
    let m;
    if ((m = l.match(/^FAIL: milestone (\S+)/))) { res.debt.push(m[1]); recognized++; }
    else if ((m = l.match(/^FAIL: record (\S+?):/))) { res.debt.push(basename(m[1], ".md")); recognized++; }
    else if ((m = l.match(/^FAIL: hand-off (\S+?):/))) { res.integrity.push(m[1]); recognized++; }
    else if ((m = l.match(/^DEFERRED: milestone (\S+)/))) { res.deferred.push(m[1]); recognized++; }
    else if (/^(AGING|FAIL):/.test(l)) recognized++;
  }
  // A non-zero exit we cannot read a single known line out of means the gate did
  // not run here (no git, no anchor, wrong cwd) — report unknown rather than a
  // clean bill of health the gate never actually gave.
  if (code !== 0 && recognized === 0) res.unknown = true;
  res.debt = [...new Set(res.debt)];
  res.deferred = [...new Set(res.deferred)];
  return res;
}

export function parseWorktrees(stdout) {
  const out = [];
  let cur = null;
  for (const line of String(stdout).split("\n")) {
    if (line.startsWith("worktree ")) { if (cur) out.push(cur); cur = { path: line.slice(9), branch: null }; }
    else if (line.startsWith("branch ") && cur) cur.branch = line.slice(7).replace("refs/heads/", "");
  }
  if (cur) out.push(cur);
  return out;
}

// A cell holding only dashes (`-`, `—`, `–`) is the markdown idiom for "nothing
// here", not a value. Reading one as a blocked question is how every row of a
// real table acquires a phantom question.
const BLANK_CELL = /^[-—–\s]*$/;
// Markdown emphasis and code ticks around an id are formatting, not part of it.
const cleanId = (s) => String(s).replace(/^[-*#\s>]+/, "").replace(/[`*_]/g, "").trim();

export function parseBoard(text) {
  const ann = { steps: {}, prByItem: {}, wtByItem: {}, questions: {} };
  if (!text) return ann;
  for (const raw of String(text).split("\n")) {
    let parts = raw.split("|").map((s) => s.trim());
    if (parts.length < 2) continue;
    // A real markdown table pipes its outer edges too, which lands an empty
    // cell at each end. The board's documented one-line form does not. Accept
    // both — consumer A writes the table, and its every row was being dropped.
    if (parts[0] === "") parts = parts.slice(1);
    if (parts.length && parts[parts.length - 1] === "") parts = parts.slice(0, -1);
    if (parts.length < 2) continue;
    if (parts.every((c) => /^:?-{2,}:?$/.test(c))) continue;          // the header rule row
    const id = cleanId(parts[0]);
    // Anchored on BOTH ends: an id is the whole cell, never a prefix of one.
    // Unanchored, "FN.1 → FN.2 → FN.3" read as an item and a table of lanes
    // became in-flight claims. Dotted ids (`FN.3`, `DS.5.1`) must pass — the
    // old `[A-Za-z]+\d` shape silently rejected every one of them.
    if (!/^[A-Za-z]+[0-9.]*[0-9]$/.test(id)) continue;
    if (parts[1] && !BLANK_CELL.test(parts[1])) ann.steps[id] = parts[1];
    const wt = raw.match(/(\S+)@(\S+)/); if (wt) ann.wtByItem[id] = { worktree: wt[1], branch: wt[2] };
    const pr = raw.match(/PR\s*#?(\d+)/i); if (pr) ann.prByItem[id] = parseInt(pr[1], 10);
    const last = parts[parts.length - 1]; if (last && !BLANK_CELL.test(last)) ann.questions[id] = last;
  }
  return ann;
}

export function ciSummary(rollup) {
  if (!Array.isArray(rollup) || rollup.length === 0) return "unknown";
  const states = rollup.map((c) => (c.conclusion || c.status || "").toUpperCase());
  if (states.some((s) => s === "FAILURE" || s === "TIMED_OUT" || s === "CANCELLED" || s === "ERROR")) return "failing";
  if (states.every((s) => s === "SUCCESS" || s === "NEUTRAL" || s === "SKIPPED")) return "passing";
  return "pending";
}

const escId = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// Branch names routinely drop an id's dots — consumer A ships `fn3-status-guards`
// for FN.3 and `fn10-message-tables` for FN.10 — so a strict match finds
// nothing and the whole live-run section reads empty during an active run.
export const dotless = (s) => String(s).toLowerCase().replace(/\./g, "");
// ...but only where the dotless form is UNAMBIGUOUS across the backlog: `F1.3`
// and `F13` collapse to the same key, and a wrong link is worse than no link.
// Returns id -> true for the ids whose dotless form nothing else claims.
export function dotlessOwners(items) {
  const owner = new Map();
  for (const i of items) { const k = dotless(i.id); owner.set(k, owner.has(k) ? null : i.id); }
  return owner;
}
// Match an item id inside a branch/PR ref only at a token boundary, so "F1.1"
// does NOT match "feat-F1.10" (a different item). Case-insensitive.
export function refMatchesId(ref, id) {
  if (!ref || !id) return false;
  return new RegExp("(^|[^0-9A-Za-z.])" + escId(id) + "(?![0-9.])", "i").test(String(ref));
}

// Strict first, then the dotless form when this id owns it outright. The token
// boundary carries over unchanged, so `fn1` still refuses `fn10-...`.
export function refMatchesLoosely(ref, id, owner) {
  if (refMatchesId(ref, id)) return true;
  const key = dotless(id);
  if (key === String(id).toLowerCase()) return false;      // no dots: nothing new to try
  return owner.get(key) === id && refMatchesId(ref, key);
}

async function readGh(gh, notes) {
  try {
    const { stdout, code } = await gh(["pr", "list", "--json", "number,title,headRefName,state,statusCheckRollup,mergeStateStatus"]);
    if (code !== 0) { notes.push("PR/CI unavailable (gh returned non-zero)"); return null; }
    return JSON.parse(stdout || "[]");
  } catch { notes.push("PR/CI unavailable (gh not runnable)"); return null; }
}

export async function buildState(projectDir, { git, gh, audit = null, stranded: strandedRun = null, now }) {
  const notes = [];
  const { backlogFile, backlogDir } = readConfig(projectDir);
  const items = loadItems(projectDir, backlogDir);
  const ideas = loadIdeas(projectDir, backlogDir);
  const discovered = loadDiscovered(projectDir, backlogDir);
  const index = readMilestoneIndex(projectDir, backlogFile);
  const runFile = readRunFile(projectDir);
  if (items.some((i) => i.malformed)) notes.push("one or more item files are malformed (shown flagged)");
  // A note whose `kind:` is neither gap nor direction is promoted by nothing and
  // listed by nothing, so it vanishes in an inbox whose one job is not to lose
  // things. Consumer A #290/#292 (2026-09-09): two notes hand-written on a code PR
  // against the playbook's "never write the file by hand" (the CLI writer has
  // always rejected a bad kind) sat invisible until someone happened to look.
  // Surfaced here, in the channel the page header and /milestone already read,
  // and never coerced (see loadDiscovered): the file is wrong, not its label.
  const unknownKind = discovered.filter((d) => d.kind === "unknown").length;
  if (unknownKind) notes.push(`${unknownKind} discovered note(s) carry a kind neither /milestone nor /roadmap reads — set kind: to gap or direction (the sweap-note writer would have refused it; the file was written by hand)`);
  if (items.length === 0) notes.push(`no backlog items found under ${backlogDir}`);
  const { frontier, attended, blocked, backlog, edges } = deriveBacklog(items);
  const byId = new Map(items.map((i) => [i.id, i]));

  let worktrees = [];
  try { const g = await git(["worktree", "list", "--porcelain"]); if (g.code === 0) worktrees = parseWorktrees(g.stdout); else notes.push("git worktrees unavailable"); }
  catch { notes.push("git worktrees unavailable"); }

  const prs = await readGh(gh, notes);
  const prsAvailable = prs !== null;

  let boardText = "";
  const boardPath = join(projectDir, ".claude", "sweap-board.md");
  if (existsSync(boardPath)) { try { boardText = readFileSync(boardPath, "utf8"); } catch { /* ignore */ } }
  const ann = parseBoard(boardText);

  const prByRef = new Map((prs || []).map((p) => [p.headRefName, p]));
  const owner = dotlessOwners(items);
  const linkPr = (item) => {
    if (ann.prByItem[item.id] != null) return (prs || []).find((p) => p.number === ann.prByItem[item.id]) || { number: ann.prByItem[item.id] };
    const wt = ann.wtByItem[item.id];
    if (wt && prByRef.has(wt.branch)) return prByRef.get(wt.branch);
    for (const p of prs || []) if (refMatchesLoosely(p.headRefName, item.id, owner)) return p;
    // The TITLE is the last resort and stays STRICT. Convention puts the id in
    // it ("fix(reminders): FN.3 — ..."), which rescues an item whose branch name
    // resembles nothing; loosening it too would let prose claim an item.
    for (const p of prs || []) if (refMatchesId(p.title, item.id)) return p;
    return null;
  };
  const linkWt = (item) => ann.wtByItem[item.id] || worktrees.find((w) => refMatchesLoosely(w.branch, item.id, owner)) || null;

  const inFlight = items
    .filter((i) => i.status !== "done" && i.status !== "blocked" && i.status !== "attended" && (ann.wtByItem[i.id] || ann.prByItem[i.id] != null || linkWt(i) || linkPr(i)))
    .map((i) => {
      const wt = linkWt(i); const pr = linkPr(i);
      return { id: i.id, title: i.title, step: ann.steps[i.id] || null, worktree: wt ? (wt.worktree || basename(wt.path || "")) : null, branch: wt ? wt.branch : null, pr: pr ? pr.number : null, ci: pr && pr.statusCheckRollup ? ciSummary(pr.statusCheckRollup) : "unknown" };
    });

  const inFlightPrs = new Set(inFlight.map((f) => f.pr).filter(Boolean));
  const inFlightIds = new Set(inFlight.map((f) => f.id));
  const mergeQueue = (prs || []).filter((p) => inFlightPrs.has(p.number)).map((p) => ({ pr: p.number, title: p.title, ci: ciSummary(p.statusCheckRollup), mergeState: p.mergeStateStatus || null })).sort((a, b) => a.pr - b.pr);

  const active = boardText.trim().length > 0 || inFlight.length > 0;
  if (!active) notes.push("no run in flight");

  // The audit verdict is the one thing the card cannot derive from item files:
  // "is a record missing" is a git-provenance question, and audit-gate.sh is the
  // single answer to it (a second reading of that rule here is how the two would
  // drift apart). --check is read-only — its only write is a mktemp dir it
  // removes — so shelling out keeps the board's read-only mandate intact.
  let auditRes = null;
  if (audit) {
    try { const a = await audit(); auditRes = classifyAudit(a.stdout, a.code); }
    catch { auditRes = { debt: [], deferred: [], integrity: [], unknown: true }; }
    if (auditRes.unknown) notes.push("audit status unavailable (audit-gate --check did not run here)");
    for (const bad of auditRes.integrity) notes.push(`backlog integrity: hand-off ${bad} was transitioned into, not authored — no audit discharges this`);
  }
  const milestone = buildMilestoneCard({ items, index, runFile, inFlight, frontier, attended, blocked, audit: auditRes });

  // Roadmap changes sitting on branches that are not on main. The scan is a
  // git question (which branches are not merged, what under <backlogDir> do
  // they change), answered by hooks/stranded-roadmap.sh — the same script the
  // post-merge hook and the stop path run — so the board never re-derives it.
  let stranded = [];
  if (strandedRun) {
    try { const r = await strandedRun(); if (r.code === 0) stranded = parseStranded(r.stdout); else notes.push("stranded-roadmap scan unavailable"); }
    catch { notes.push("stranded-roadmap scan unavailable"); }
    for (const s of stranded) if (s.stranded) notes.push(`stranded backlog: ${s.branch} carries ${s.paths.length} roadmap file(s) that are not on main and have no open PR`);
  }

  return { generatedAt: now, project: basename(projectDir), run: { active, prsAvailable }, milestone, frontier: frontier.filter((i) => !inFlightIds.has(i.id)).map((i) => ({ id: i.id, title: i.title, lane: i.lane, reviewDimensions: i.reviewDimensions })), inFlight, mergeQueue, attended, blocked, ideas, discovered, stranded, backlog: backlog.map((g) => ({ milestone: g.milestone, items: g.items.map((i) => ({ id: i.id, title: i.title, status: i.status, dependsOn: i.dependsOn, malformed: i.malformed })) })), edges, notes };
}
