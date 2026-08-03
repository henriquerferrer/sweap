// sweap-board.page.mjs — the self-contained viewer page. renderPage() returns a
// full HTML document; the client polls /state.json and patches the DOM. No
// frameworks, no external assets.
export function renderPage() {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>sweap board</title>
<style>
  :root { --bg:#fff; --fg:#1a1a1a; --muted:#666; --line:#e3e3e3; --card:#f7f7f8; --ok:#1a7f37; --warn:#9a6700; --bad:#cf222e; --accent:#0969da; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8b949e; --line:#30363d; --card:#161b22; --ok:#3fb950; --warn:#d29922; --bad:#f85149; --accent:#58a6ff; } }
  * { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  header { display:flex; align-items:baseline; gap:12px; padding:12px 16px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--bg); }
  header h1 { font-size:15px; margin:0; font-weight:600; } #project { color:var(--accent); } #updated { color:var(--muted); font-size:12px; margin-left:auto; }
  main { padding:16px; max-width:1200px; margin:0 auto; } section { margin-bottom:22px; }
  h2 { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 8px; }
  .cols { display:grid; grid-template-columns:repeat(auto-fit,minmax(210px,1fr)); gap:12px; }
  .col { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px; min-height:44px; overflow-x:auto; }
  .item { padding:6px 8px; border:1px solid var(--line); border-radius:6px; margin-bottom:6px; background:var(--bg); }
  .item b { font-weight:600; } .meta { color:var(--muted); font-size:12px; }
  .blocked .item { border-color:var(--bad); } .blocked .q { color:var(--bad); }
  .badge { display:inline-block; font-size:11px; padding:1px 6px; border-radius:10px; border:1px solid var(--line); }
  .ci-passing { color:var(--ok); border-color:var(--ok); } .ci-failing { color:var(--bad); border-color:var(--bad); } .ci-pending,.ci-unknown { color:var(--warn); border-color:var(--warn); }
  .st-done { color:var(--ok); } .st-todo { color:var(--fg); } .st-blocked { color:var(--bad); } .st-deferred { color:var(--muted); } .malformed { color:var(--bad); font-style:italic; }
  #notes { color:var(--warn); font-size:12px; } #notes span { margin-right:12px; }
  .ms { margin-bottom:10px; } .ms h3 { font-size:13px; margin:0 0 4px; }
  svg { max-width:100%; height:auto; } .empty { color:var(--muted); font-size:12px; }
  #idea-form { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:8px; }
  #idea-form input, #idea-form textarea { background:var(--bg); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:6px 8px; font:inherit; }
  #idea-title { flex:1 1 220px; } #idea-body { flex:1 1 100%; min-height:52px; resize:vertical; }
  #idea-form button { background:var(--accent); color:#fff; border:0; border-radius:6px; padding:6px 14px; font:inherit; cursor:pointer; }
  #idea-msg { font-size:12px; color:var(--bad); align-self:center; }
</style></head>
<body>
<header><h1>sweap <span id="project">…</span></h1><span id="notes"></span><span id="updated"></span></header>
<main>
  <section><h2>Live run</h2>
    <div class="cols">
      <div><h2>Frontier (ready)</h2><div class="col" id="frontier"></div></div>
      <div><h2>In-flight</h2><div class="col" id="inflight"></div></div>
      <div><h2>Merge queue</h2><div class="col" id="mergequeue"></div></div>
      <div class="blocked"><h2>⛔ Blocked — needs you</h2><div class="col" id="blocked"></div></div>
    </div>
  </section>
  <section><h2>Backlog</h2><div id="backlog"></div></section>
  <section><h2>Ideas (inbox — triaged by /roadmap)</h2>
    <form id="idea-form">
      <input id="idea-title" placeholder="idea title" maxlength="200" required/>
      <button type="submit">Capture</button><span id="idea-msg"></span>
      <textarea id="idea-body" placeholder="details (optional)"></textarea>
    </form>
    <div class="col" id="ideas"></div>
  </section>
  <section><h2>Dependencies</h2><div id="graph"></div></section>
</main>
<script>
const esc = (s) => String(s==null?"":s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const empty = (el, msg) => { el.innerHTML = '<div class="empty">'+esc(msg)+'</div>'; };
function renderList(el, arr, fn, msg) { if (!arr || !arr.length) return empty(el, msg); el.innerHTML = arr.map(fn).join(""); }
function draw(s) {
  document.getElementById("project").textContent = s.project || "";
  const ago = Math.max(0, Math.round((Date.now() - s.generatedAt)/1000));
  document.getElementById("updated").textContent = "updated " + ago + "s ago" + (s.run.active ? "" : " · no run in flight");
  document.getElementById("notes").innerHTML = (s.notes||[]).map(n => '<span>⚠ '+esc(n)+'</span>').join("");
  renderList(document.getElementById("frontier"), s.frontier, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+(i.lane?' <span class="meta">lane:'+esc(i.lane)+'</span>':'')+'</div>', "nothing ready");
  renderList(document.getElementById("inflight"), s.inFlight, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+'<div class="meta">'+esc(i.step||"working")+(i.branch?' · '+esc(i.branch):'')+(i.pr?' · PR #'+i.pr:'')+' <span class="badge ci-'+esc(i.ci)+'">'+esc(i.ci)+'</span></div></div>', "nothing in flight");
  renderList(document.getElementById("mergequeue"), s.mergeQueue, q => '<div class="item">PR #'+q.pr+' '+esc(q.title)+' <span class="badge ci-'+esc(q.ci)+'">'+esc(q.ci)+'</span></div>', "queue empty");
  renderList(document.getElementById("blocked"), s.blocked, b => '<div class="item"><b>'+esc(b.id)+'</b> '+esc(b.title)+'<div class="q">'+esc(b.question)+'</div></div>', "none blocked 🎉");
  document.getElementById("backlog").innerHTML = (s.backlog||[]).map(g => '<div class="ms"><h3>'+esc(g.milestone)+'</h3>'+g.items.map(i => '<div class="item'+(i.malformed?' malformed':'')+'"><span class="st-'+esc(i.status)+'">●</span> <b>'+esc(i.id)+'</b> '+esc(i.title)+' <span class="meta">'+esc(i.status)+(i.dependsOn&&i.dependsOn.length?' · deps: '+i.dependsOn.map(esc).join(", "):'')+'</span></div>').join("")+'</div>').join("") || '<div class="empty">no items</div>';
  renderList(document.getElementById("ideas"), s.ideas, i => '<div class="item"><b>'+esc(i.title)+'</b> <span class="meta">'+esc(i.file)+(i.created?' · '+esc(i.created.slice(0,10)):'')+'</span></div>', "inbox empty");
  document.getElementById("graph").innerHTML = graphSvg(s);
}
function graphSvg(s) {
  const items = (s.backlog||[]).flatMap(g => g.items);
  if (!items.length) return '<div class="empty">no items</div>';
  const depth = new Map(); const byId = new Map(items.map(i => [i.id, i]));
  const d = (id, seen) => { if (depth.has(id)) return depth.get(id); if (seen.has(id)) return 0; seen.add(id); const it = byId.get(id); const dd = it && it.dependsOn.length ? 1 + Math.max(0, ...it.dependsOn.filter(x=>byId.has(x)).map(x => d(x, seen))) : 0; depth.set(id, dd); return dd; };
  items.forEach(i => d(i.id, new Set()));
  const cols = new Map(); items.forEach(i => { const k = depth.get(i.id)||0; if (!cols.has(k)) cols.set(k, []); cols.get(k).push(i.id); });
  const CW=170, RH=30, PAD=16; const pos = new Map(); let maxRows=0;
  [...cols.keys()].sort((a,b)=>a-b).forEach((k,ci) => { cols.get(k).forEach((id,ri) => pos.set(id, { x: PAD+ci*CW, y: PAD+ri*RH })); maxRows=Math.max(maxRows, cols.get(k).length); });
  const W = PAD*2 + (cols.size||1)*CW, H = PAD*2 + Math.max(1,maxRows)*RH;
  const line = (e) => { const a=pos.get(e.from), b=pos.get(e.to); if(!a||!b) return ""; return '<line x1="'+(a.x+120)+'" y1="'+(a.y+9)+'" x2="'+b.x+'" y2="'+(b.y+9)+'" stroke="var(--line)"/>'; };
  const node = (id) => { const p=pos.get(id), it=byId.get(id); return '<g><rect x="'+p.x+'" y="'+p.y+'" width="120" height="18" rx="4" fill="var(--card)" stroke="var(--line)"/><text x="'+(p.x+6)+'" y="'+(p.y+13)+'" font-size="11" fill="var(--fg)">'+esc(id)+' '+esc((it.status||"")[0]||"")+'</text></g>'; };
  return '<svg viewBox="0 0 '+W+' '+H+'" width="'+W+'">'+(s.edges||[]).map(line).join("")+items.map(i=>node(i.id)).join("")+'</svg>';
}
async function tick() { try { const r = await fetch("/state.json", {cache:"no-store"}); draw(await r.json()); } catch (e) { document.getElementById("updated").textContent = "disconnected"; } }
tick(); setInterval(tick, 3000);
document.getElementById("idea-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = document.getElementById("idea-msg");
  const title = document.getElementById("idea-title").value.trim();
  if (!title) return;
  try {
    const r = await fetch("/ideas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title, body: document.getElementById("idea-body").value }) });
    if (r.ok) { e.target.reset(); msg.textContent = ""; tick(); }
    else { msg.textContent = "capture failed: " + await r.text(); }
  } catch { msg.textContent = "capture failed: server unreachable"; }
});
</script>
</body></html>`;
}
