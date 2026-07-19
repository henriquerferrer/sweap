// sweap-board.lib.mjs — pure, testable core for the read-only board viewer.
// No process/network side effects: buildState() takes injected git/gh runners.
// Reads item files with the same flat-frontmatter contract roadmap-lint enforces.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

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

export const milestoneOf = (id) => String(id).split(".")[0];

export function isUnblocked(item, byId, byMilestone) {
  return item.dependsOn.every((dep) => {
    if (dep.includes(".")) { const d = byId.get(dep); return Boolean(d && d.status === "done"); }
    const items = byMilestone.get(dep) || [];
    return items.length > 0 && items.some((i) => i.status === "done");
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
  for (const i of items) for (const dep of i.dependsOn) if (dep.includes(".") && byId.has(dep)) edges.push({ from: dep, to: i.id });

  return { frontier, blocked, backlog, edges };
}
