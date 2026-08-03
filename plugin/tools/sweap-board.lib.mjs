// sweap-board.lib.mjs — pure, testable core for the read-only board viewer.
// No process/network side effects: buildState() takes injected git/gh runners.
// Reads item files with the same flat-frontmatter contract roadmap-lint enforces.
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { existsSync } from "node:fs";
import { basename } from "node:path";

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
    if (m) fm[m[1]] = m[2].trim();
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

// Idea inbox: the board's ONLY write capability. Create-only — new uniquely
// named files under <backlogDir>/ideas/, a subdir loadItems/lint/dep
// resolution never read (same reason roadmap/archive/ is invisible).
export const slugify = (title) =>
  String(title).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

export function writeIdea(projectDir, backlogDir, { title, body = "", now }) {
  const t = String(title || "").replace(/\s+/g, " ").trim();
  const slug = slugify(t);
  if (!t || !slug) throw new Error("title required");
  const dir = join(projectDir, backlogDir, "ideas");
  mkdirSync(dir, { recursive: true });
  let file = slug + ".md";
  for (let n = 2; existsSync(join(dir, file)); n++) file = `${slug}-${n}.md`;
  const content = `---\ntitle: ${t}\ncreated: ${new Date(now).toISOString()}\n---\n\n${String(body || "").trim()}\n`;
  writeFileSync(join(dir, file), content, { flag: "wx" });
  return { file: join(backlogDir, "ideas", file) };
}

export function loadItems(projectDir, backlogDir) {
  const dir = join(projectDir, backlogDir);
  let files;
  try { files = readdirSync(dir).filter((f) => f.endsWith(".md")); } catch { return []; }
  return files.map((f) => {
    const id = f.replace(/\.md$/, "");
    const bad = { id, title: id, status: "unknown", dependsOn: [], reviewDimensions: [], lane: null, followupOf: null, blocked: null, malformed: true, file: f };
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
    const items = byMilestone.get(dep) || [];
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

export function deriveBacklog(items) {
  const byId = new Map(items.map((i) => [i.id, i]));
  const byMilestone = new Map();
  for (const i of items) { const m = milestoneOf(i.id); if (!byMilestone.has(m)) byMilestone.set(m, []); byMilestone.get(m).push(i); }

  const frontier = items
    .filter((i) => i.status === "todo" && isUnblocked(i, byId, byMilestone))
    .sort(compareItems);

  const blocked = items.filter((i) => i.status === "blocked").map((i) => ({ id: i.id, title: i.title, question: i.blocked || "(no question recorded)" }));

  const backlog = [...byMilestone.entries()]
    .sort((a, b) => compareItems({ id: a[0] + ".0", followupOf: null }, { id: b[0] + ".0", followupOf: null }))
    .map(([milestone, its]) => ({ milestone, items: [...its].sort(compareItems) }));

  const edges = [];
  for (const i of items) for (const dep of i.dependsOn) if (byId.has(dep)) edges.push({ from: dep, to: i.id });

  return { frontier, blocked, backlog, edges };
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

export function parseBoard(text) {
  const ann = { steps: {}, prByItem: {}, wtByItem: {}, questions: {} };
  if (!text) return ann;
  for (const raw of String(text).split("\n")) {
    const parts = raw.split("|").map((s) => s.trim());
    if (parts.length < 2) continue;
    const id = parts[0].replace(/^[-*#\s>]+/, "").trim();
    if (!/^[A-Za-z]+\d/.test(id)) continue;
    if (parts[1]) ann.steps[id] = parts[1];
    const wt = raw.match(/(\S+)@(\S+)/); if (wt) ann.wtByItem[id] = { worktree: wt[1], branch: wt[2] };
    const pr = raw.match(/PR\s*#?(\d+)/i); if (pr) ann.prByItem[id] = parseInt(pr[1], 10);
    const last = parts[parts.length - 1]; if (last && last !== "-") ann.questions[id] = last;
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
// Match an item id inside a branch/PR ref only at a token boundary, so "F1.1"
// does NOT match "feat-F1.10" (a different item). Case-insensitive.
export function refMatchesId(ref, id) {
  if (!ref || !id) return false;
  return new RegExp("(^|[^0-9A-Za-z.])" + escId(id) + "(?![0-9.])", "i").test(String(ref));
}

async function readGh(gh, notes) {
  try {
    const { stdout, code } = await gh(["pr", "list", "--json", "number,title,headRefName,state,statusCheckRollup,mergeStateStatus"]);
    if (code !== 0) { notes.push("PR/CI unavailable (gh returned non-zero)"); return null; }
    return JSON.parse(stdout || "[]");
  } catch { notes.push("PR/CI unavailable (gh not runnable)"); return null; }
}

export async function buildState(projectDir, { git, gh, now }) {
  const notes = [];
  const { backlogDir } = readConfig(projectDir);
  const items = loadItems(projectDir, backlogDir);
  if (items.some((i) => i.malformed)) notes.push("one or more item files are malformed (shown flagged)");
  if (items.length === 0) notes.push(`no backlog items found under ${backlogDir}`);
  const { frontier, blocked, backlog, edges } = deriveBacklog(items);
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
  const linkPr = (item) => {
    if (ann.prByItem[item.id] != null) return (prs || []).find((p) => p.number === ann.prByItem[item.id]) || { number: ann.prByItem[item.id] };
    const wt = ann.wtByItem[item.id];
    if (wt && prByRef.has(wt.branch)) return prByRef.get(wt.branch);
    for (const p of prs || []) if (refMatchesId(p.headRefName, item.id)) return p;
    return null;
  };
  const linkWt = (item) => ann.wtByItem[item.id] || worktrees.find((w) => refMatchesId(w.branch, item.id)) || null;

  const inFlight = items
    .filter((i) => i.status !== "done" && i.status !== "blocked" && (ann.wtByItem[i.id] || ann.prByItem[i.id] != null || linkWt(i) || linkPr(i)))
    .map((i) => {
      const wt = linkWt(i); const pr = linkPr(i);
      return { id: i.id, title: i.title, step: ann.steps[i.id] || null, worktree: wt ? (wt.worktree || basename(wt.path || "")) : null, branch: wt ? wt.branch : null, pr: pr ? pr.number : null, ci: pr && pr.statusCheckRollup ? ciSummary(pr.statusCheckRollup) : "unknown" };
    });

  const inFlightPrs = new Set(inFlight.map((f) => f.pr).filter(Boolean));
  const inFlightIds = new Set(inFlight.map((f) => f.id));
  const mergeQueue = (prs || []).filter((p) => inFlightPrs.has(p.number)).map((p) => ({ pr: p.number, title: p.title, ci: ciSummary(p.statusCheckRollup), mergeState: p.mergeStateStatus || null })).sort((a, b) => a.pr - b.pr);

  const active = boardText.trim().length > 0 || inFlight.length > 0;
  if (!active) notes.push("no run in flight");

  return { generatedAt: now, project: basename(projectDir), run: { active, prsAvailable }, frontier: frontier.filter((i) => !inFlightIds.has(i.id)).map((i) => ({ id: i.id, title: i.title, lane: i.lane, reviewDimensions: i.reviewDimensions })), inFlight, mergeQueue, blocked, backlog: backlog.map((g) => ({ milestone: g.milestone, items: g.items.map((i) => ({ id: i.id, title: i.title, status: i.status, dependsOn: i.dependsOn, malformed: i.malformed })) })), edges, notes };
}
