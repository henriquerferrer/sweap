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
  /* A carried question is one that has already outlived a milestone. Warn-toned
     rather than red: the age is the nag, the question itself is the alarm. */
  .badge.carried { color:var(--warn); border-color:var(--warn); }
  /* Hand-offs are the human's OWN queue — warn-toned, never the red that means
     "an agent failed". Two different asks deserve two different colours. */
  .mine .item { border-color:var(--warn); } .mine .task { color:var(--warn); }
  .badge { display:inline-block; font-size:11px; padding:1px 6px; border-radius:10px; border:1px solid var(--line); }
  .ci-passing { color:var(--ok); border-color:var(--ok); } .ci-failing { color:var(--bad); border-color:var(--bad); } .ci-pending,.ci-unknown { color:var(--warn); border-color:var(--warn); }
  .st-done { color:var(--ok); } .st-todo { color:var(--fg); } .st-attended { color:var(--warn); } .st-blocked { color:var(--bad); } .st-deferred { color:var(--muted); } .malformed { color:var(--bad); font-style:italic; }
  #notes { color:var(--warn); font-size:12px; } #notes span { margin-right:12px; }
  .ms { margin-bottom:10px; } .ms h3 { font-size:13px; margin:0 0 4px; }
  svg { max-width:100%; height:auto; } .empty { color:var(--muted); font-size:12px; }
  #idea-form { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:8px; }
  #idea-form input, #idea-form textarea { background:var(--bg); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:6px 8px; font:inherit; }
  #idea-title { flex:1 1 220px; } #idea-body { flex:1 1 100%; min-height:52px; resize:vertical; }
  #idea-form button { background:var(--accent); color:#fff; border:0; border-radius:6px; padding:6px 14px; font:inherit; cursor:pointer; }
  #idea-msg { font-size:12px; color:var(--bad); align-self:center; }
  /* The running-milestone card. Accent-railed when a run is live, muted when it
     is only what would run next — the card must never let a prediction read
     like a fact. */
  .card { background:var(--card); border:1px solid var(--line); border-left:3px solid var(--accent); border-radius:8px; padding:12px 14px; }
  .card.next { border-left-color:var(--muted); }
  .card-head { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap; }
  .card-head .mid { font-size:20px; font-weight:700; letter-spacing:-.01em; }
  .card-head .goal { flex:1 1 240px; }
  .chip { font-size:10px; font-weight:700; letter-spacing:.08em; text-transform:uppercase; padding:2px 7px; border-radius:10px; border:1px solid currentColor; }
  .chip.running { color:var(--ok); } .chip.next { color:var(--muted); }
  .card .src { color:var(--muted); font-size:12px; }
  .card .bits { color:var(--muted); font-size:12px; margin-top:4px; }
  .bar { height:6px; border-radius:3px; background:var(--line); overflow:hidden; margin:10px 0 5px; }
  .bar > i { display:block; height:100%; background:var(--ok); transition:width .3s; }
  .card-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr)); gap:14px; margin-top:12px; }
  .card-grid h4 { font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 5px; font-weight:600; }
  .row { padding:2px 0; }
  /* Same two-colour rule the columns below use: warn is the human's OWN queue,
     red is "an agent got stuck". The card must not blur them back together. */
  .card .task { color:var(--warn); } .card .q { color:var(--bad); }
  /* The run's own account of why it stopped, and whether it survived checking.
     A contradicted claim is red because it reads authoritative while being
     wrong — worse than the run having said nothing at all. */
  .endbar { margin-top:10px; padding:7px 9px; border-radius:6px; font-size:12px; border:1px solid var(--line); }
  .end-confirmed { border-color:var(--muted); color:var(--muted); }
  .end-derived { border-color:var(--warn); color:var(--warn); }
  .end-contradicted, .end-unverifiable { border-color:var(--bad); color:var(--bad); }
  .end-idle { border-color:var(--warn); color:var(--warn); }
  .audit { margin-top:11px; padding-top:8px; border-top:1px solid var(--line); font-size:12px; }
  .a-clean { color:var(--ok); } .a-debt { color:var(--bad); }
  .a-deferred, .a-not-due, .a-blocked-by-debt { color:var(--warn); } .a-unknown { color:var(--muted); }
  /* Ties the card to the Backlog below it: the same milestone, marked once. */
  .ms.running { border-left:3px solid var(--accent); padding-left:9px; }
  .ms.running > h3 { color:var(--accent); }
  /* The resume plan: what the human does next. */
  .plan { margin-top:8px; } .plan h4 { font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:6px 0 4px; font-weight:600; }
  /* The plan is the human's to-do, not the run's verdict: readable fg even inside a red (contradicted) endbar. */
  .endbar .plan .row { color:var(--fg); }
  .cmd { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; background:var(--bg); border:1px solid var(--line); border-radius:4px; padding:0 5px; }
  .cmd.pending { opacity:.6; text-decoration:line-through; }
  .copy { font:inherit; font-size:11px; border:1px solid var(--line); background:var(--bg); color:var(--fg); border-radius:4px; padding:0 6px; cursor:pointer; }
  .suspect { color:var(--warn); } details.dropped { color:var(--muted); margin-top:4px; }
  #updated.err { color:var(--bad); }
</style></head>
<body>
<header><h1>sweap <span id="project">…</span></h1><span id="notes"></span><span id="updated"></span></header>
<main>
  <section><h2>Running milestone</h2><div class="card" id="milestone"></div></section>
  <section><h2>Live run</h2>
    <div class="cols">
      <div><h2>Frontier (ready)</h2><div class="col" id="frontier"></div></div>
      <div><h2>In-flight</h2><div class="col" id="inflight"></div></div>
      <div><h2>Open PRs</h2><div class="col" id="mergequeue"></div></div>
      <div class="mine"><h2>🙋 Yours — hand-offs</h2><div class="col" id="attended"></div></div>
      <div class="blocked"><h2>⛔ Blocked — needs you</h2><div class="col" id="blocked"></div></div>
    </div>
  </section>
  <section><h2>Backlog</h2><div id="backlog"></div></section>
  <section><h2>Ideas (inbox — triaged by /sweap:roadmap)</h2>
    <form id="idea-form">
      <input id="idea-title" placeholder="idea title" maxlength="200" required/>
      <button type="submit">Capture</button><span id="idea-msg"></span>
      <textarea id="idea-body" placeholder="details (optional)"></textarea>
    </form>
    <div class="col" id="ideas"></div>
  </section>
  <section><h2>Discovered (captured mid-run — <code>gap</code> is triaged at the next /sweap:milestone, <code>direction</code> waits for /sweap:roadmap)</h2>
    <div class="col" id="discovered"></div>
  </section>
  <section><h2>Roadmap changes on branches, not on main</h2>
    <div class="col" id="stranded"></div>
  </section>
  <section><h2>Dependencies</h2><div id="graph"></div></section>
</main>
<script>
const esc = (s) => String(s==null?"":s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const empty = (el, msg) => { el.innerHTML = '<div class="empty">'+esc(msg)+'</div>'; };
function renderList(el, arr, fn, msg) { if (!arr || !arr.length) return empty(el, msg); el.innerHTML = arr.map(fn).join(""); }
const agoText = (ms) => { const t = Math.round(ms/1000); if (t < 90) return t+"s"; const m = Math.round(t/60); if (m < 90) return m+"m"; const h = Math.round(m/60); return h < 48 ? h+"h" : Math.round(h/24)+"d"; };
const plural = (n, w) => n + " " + w + (n === 1 ? "" : "s");
// Where the card's milestone came from. Spelled out on every render: a derived
// milestone is a good guess, and a good guess still must not read as a fact.
const SOURCE = { "run-file": "resolved by /sweap:milestone", "in-flight": "inferred from what is in flight", derived: "next runnable in index order", gated: "next in index order — every item of it is gated" };
const AUDIT_ICON = { clean: "✓", debt: "✗", deferred: "⏳", "blocked-by-debt": "✗", "not-due": "—", unknown: "?" };
// The resume plan: what the human does next, in the lib's order. Only a
// machine-applicable step earns a copy button — rustc's Applicability rule,
// already promised in the lib: a step whose own deps are unmet must not be
// offered as if it could run. Every field goes through esc(), the command and
// its data-cmd attribute included; never an inline handler.
function planBlock(plan) {
  if (!plan) return "";
  const steps = plan.steps || [], dropped = plan.dropped || [], suspect = plan.suspect || [];
  if (!steps.length && !dropped.length) return "";
  const stepRow = (s) => {
    const ready = s.applicability === "machine-applicable";   // anything else is treated as has-placeholders (conservative)
    const cls = s.kind === "blocked" ? "q" : "task";
    const meta = [esc(s.purpose)];
    if (s.ask) meta.push("ask: " + esc(s.ask));
    if (s.gates && s.gates.length) meta.push("gates " + plural(s.gates.length, "item"));
    if (s.whyNotAgent) meta.push("why not an agent: " + esc(s.whyNotAgent));
    const cmd = ready
      ? '<code class="cmd">' + esc(s.command) + '</code> <button type="button" class="copy" data-cmd="' + esc(s.command) + '">copy</button>'
      : '<code class="cmd pending">' + esc(s.command) + '</code> <span class="meta">not yet — its own dependencies are unmet</span>';
    return '<div class="row step step-' + esc(s.kind) + (ready ? "" : " pending") + '"><span class="' + cls + '">'
      + (s.kind === "blocked" ? "⛔ " : "🙋 ") + '<b>' + esc(s.id) + '</b> ' + esc(s.subject) + '</span>'
      + '<div class="meta">' + meta.join(" · ") + '</div>'
      + '<div>' + cmd + '</div>'
      + '<div class="meta">done when: ' + esc(s.doneWhen) + '</div></div>';
  };
  let out = '<div class="plan">';
  if (steps.length) out += '<h4>To resume</h4>' + steps.map(stepRow).join("");
  if (suspect.length) out += '<div class="meta suspect">⚠ machine-applicable with no why_not_agent: ' + suspect.map(esc).join(", ") + ' — a hand-off an agent could arguably have done</div>';
  // Dropped steps are audit trail, not a to-do: collapsed.
  if (dropped.length) out += '<details class="dropped"><summary>' + plural(dropped.length, "stale/unknown step") + ' dropped</summary>'
    + dropped.map((d) => '<div class="row"><b>' + esc(d.id) + '</b> — ' + esc(d.why) + '</div>').join("") + '</details>';
  return out + '</div>';
}
function milestoneCard(m) {
  const el = document.getElementById("milestone");
  if (!m) { el.className = "card next"; return empty(el, "no milestone to run — nothing is todo with its dependencies satisfied"); }
  const running = m.state === "running";
  el.className = "card" + (running ? "" : " next");
  const c = m.counts;
  const pct = c.total ? Math.round(100 * c.done / c.total) : 0;
  const tally = [c.done + "/" + c.total + " done"];
  if (c.todo) tally.push(c.todo + " todo");
  if (c.blocked) tally.push(plural(c.blocked, "blocked"));
  if (c.attended) tally.push(c.attended + " yours");
  if (c.deferred) tally.push(c.deferred + " deferred");

  const bits = [];
  if (m.shape) bits.push("shape: " + esc(m.shape));
  // Debt-first is the run's real scope, so the card leads with it rather than
  // leaving the follow-ups to be found one row down in the frontier.
  bits.push("scope: " + esc(m.debt.length ? plural(m.debt.length, "audit follow-up") + " → " + m.id : m.id));
  if (m.turns) bits.push("budget " + plural(m.turns, "turn"));
  if (m.started) { const t = Date.parse(m.started); if (!isNaN(t)) bits.push("started " + agoText(Date.now()-t) + " ago"); }

  const flightRow = (i) => '<div class="row"><b>'+esc(i.id)+'</b> '+esc(i.title)
    + (i.scope === "debt" ? ' <span class="badge">debt</span>' : i.scope === "other" ? ' <span class="badge">other milestone</span>' : '')
    + '<div class="meta">'+esc(i.step||"working")+(i.branch?' · '+esc(i.branch):'')+(i.pr?' · PR #'+i.pr:'')
    + ' <span class="badge ci-'+esc(i.ci)+'">'+esc(i.ci)+'</span></div></div>';
  const readyRow = (i) => '<div class="row"><b>'+esc(i.id)+'</b> '+esc(i.title)+(i.lane?' <span class="meta">lane:'+esc(i.lane)+'</span>':'')+'</div>';
  const stopRow = (h) => '<div class="row"><span class="task">🙋 <b>'+esc(h.id)+'</b> '+esc(h.title)+'</span><div class="meta">'
    + esc(h.task) + (h.gates && h.gates.length ? ' · gates '+plural(h.gates.length, "item") : '') + ' · ' + (h.ready ? '/sweap:handoff '+esc(h.id) : 'waiting on a dependency') + '</div></div>';
  const blockRow = (b) => '<div class="row"><span class="q">⛔ <b>'+esc(b.id)+'</b> '+esc(b.title)+'</span><div class="meta">'
    + esc(b.question) + (b.carried ? ' · carried '+b.carried+' boundar'+(b.carried>1?'ies':'y') : '') + ' · /sweap:unblock '+esc(b.id)+'</div></div>';
  const stops = m.handoffs.map(stopRow).concat(m.blocked.map(blockRow));

  // Never render the claim alone — always the claim AND the verdict on it.
  const VERDICT = { confirmed: "checked", derived: "derived by the board — the run recorded nothing",
                    contradicted: "✗ CONTRADICTED BY THE BACKLOG", unverifiable: "? cannot be checked" };
  let endbar = "";
  if (m.end) endbar = '<div class="endbar end-'+esc(m.end.verdict)+'"><b>run ended</b> · '+esc(m.end.reason)
    + ' — ' + esc(m.end.detail) + ' <span class="meta">(' + esc(VERDICT[m.end.verdict] || m.end.verdict) + ')</span>' + planBlock(m.end.plan) + '</div>';
  else if (m.idle) endbar = '<div class="endbar end-idle"><b>idle</b> — '+esc(m.idle.detail)
    + '. The run is not ended; it just is not working.</div>';
  if (m.stalled) endbar = '<div class="endbar end-contradicted"><b>stalled</b> — '+esc(m.stalled.detail)+'</div>' + endbar;

  const col = (title, rows, msg) => '<div><h4>'+title+'</h4>'+(rows.length ? rows.join("") : '<div class="empty">'+esc(msg)+'</div>')+'</div>';
  el.innerHTML =
    '<div class="card-head"><span class="chip '+(running?"running":"next")+'">'+(running?"running":"next up")+'</span>'
    + '<span class="mid">'+esc(m.id)+'</span>'
    + '<span class="goal">'+(m.goal ? esc(m.goal) : '<span class="empty">no goal line in the roadmap index</span>')+'</span>'
    + '<span class="src">'+esc(SOURCE[m.source] || m.source)+'</span></div>'
    + '<div class="bits">'+bits.join(" · ")+'</div>'
    + '<div class="bar"><i style="width:'+pct+'%"></i></div>'
    + '<div class="meta">'+esc(tally.join(" · "))+'</div>'
    + '<div class="card-grid">'
    +   col("Right now", m.inFlight.map(flightRow), running ? "nothing in flight" : "nothing in flight — paste the /sweap:milestone goal to start")
    +   col("Next ready", m.ready.map(readyRow), "nothing ready in " + m.id)
    +   col("Blocking completion", stops, c.todo ? "nothing in the way — " + plural(c.todo, "item") + " to go" : "nothing in the way")
    + '</div>'
    + endbar
    + '<div class="audit a-'+esc(m.audit.state)+'">'+(AUDIT_ICON[m.audit.state]||"")+' audit: '+esc(m.audit.state)
    +   (m.audit.detail ? ' — '+esc(m.audit.detail) : '')
    + '</div>';
}
function draw(s) {
  document.getElementById("project").textContent = s.project || "";
  const ago = Math.max(0, Math.round((Date.now() - s.generatedAt)/1000));
  document.getElementById("updated").textContent = "updated " + ago + "s ago" + (s.run.active ? "" : " · no run in flight");
  document.getElementById("notes").innerHTML = (s.notes||[]).map(n => '<span>⚠ '+esc(n)+'</span>').join("");
  milestoneCard(s.milestone);
  renderList(document.getElementById("frontier"), s.frontier, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+(i.lane?' <span class="meta">lane:'+esc(i.lane)+'</span>':'')+'</div>', "nothing ready");
  renderList(document.getElementById("inflight"), s.inFlight, i => '<div class="item"><b>'+esc(i.id)+'</b> '+esc(i.title)+'<div class="meta">'+esc(i.step||"working")+(i.branch?' · '+esc(i.branch):'')+(i.pr?' · PR #'+i.pr:'')+' <span class="badge ci-'+esc(i.ci)+'">'+esc(i.ci)+'</span></div></div>', "nothing in flight");
  renderList(document.getElementById("mergequeue"), s.mergeQueue, q => '<div class="item">PR #'+q.pr+' '+esc(q.title)+' <span class="badge ci-'+esc(q.ci)+'">'+esc(q.ci)+'</span></div>', "none open");
  renderList(document.getElementById("attended"), s.attended, a => '<div class="item"><b>'+esc(a.id)+'</b> '+esc(a.title)+'<div class="task">'+esc(a.task)+'</div><div class="meta">'+(a.ready?'/sweap:handoff '+esc(a.id):'waiting on a dependency')+(a.gates&&a.gates.length?' · gates '+a.gates.length+' item'+(a.gates.length>1?'s':'')+': '+a.gates.map(esc).join(", "):'')+'</div></div>', "no hand-offs 🎉");
  renderList(document.getElementById("blocked"), s.blocked, b => '<div class="item"><b>'+esc(b.id)+'</b> '+esc(b.title)+'<div class="q">'+esc(b.question)+'</div><div class="meta">'+(b.carried?'<span class="badge carried">carried '+b.carried+' boundar'+(b.carried>1?'ies':'y')+(b.carried>=2?' · asked at the next /sweap:roadmap':'')+'</span> · ':'')+'/sweap:unblock '+esc(b.id)+'</div></div>', "none blocked 🎉");
  const runningMs = s.milestone ? s.milestone.id : null;
  document.getElementById("backlog").innerHTML = (s.backlog||[]).map(g => '<div class="ms'+(g.milestone===runningMs?' running':'')+'"><h3>'+esc(g.milestone)+(g.milestone===runningMs?' <span class="chip '+(s.milestone.state==="running"?"running":"next")+'">'+(s.milestone.state==="running"?"running":"next up")+'</span>':'')+'</h3>'+g.items.map(i => '<div class="item'+(i.malformed?' malformed':'')+'"><span class="st-'+esc(i.status)+'">●</span> <b>'+esc(i.id)+'</b> '+esc(i.title)+' <span class="meta">'+esc(i.status)+(i.dependsOn&&i.dependsOn.length?' · deps: '+i.dependsOn.map(esc).join(", "):'')+'</span></div>').join("")+'</div>').join("") || '<div class="empty">no items</div>';
  renderList(document.getElementById("ideas"), s.ideas, i => '<div class="item"><b>'+esc(i.title)+'</b> <span class="meta">'+esc(i.file)+(i.created?' · '+esc(i.created.slice(0,10)):'')+'</span></div>', "inbox empty");
  renderList(document.getElementById("discovered"), s.discovered, d => '<div class="item"><b>'+esc(d.title)+'</b> <span class="badge kind-'+esc(d.kind)+'">'+esc(d.kind)+'</span><div class="meta">'+esc(d.file)+(d.from?' · from '+esc(d.from):'')+(d.milestoneHint?' · → '+esc(d.milestoneHint):'')+(d.created?' · '+esc(d.created.slice(0,10)):'')+'</div></div>', "nothing discovered");
  renderList(document.getElementById("stranded"), s.stranded, b => '<div class="item'+(b.stranded?' malformed':'')+'"><b>'+esc(b.branch)+'</b> <span class="badge">'+(b.pr==="open"?"riding an open PR":b.pr==="closed"?"PR closed, not merged":b.pr==="none"?"no PR":b.pr==="parked"?"parked work, lands with its item":"unknown")+'</span>'+(b.ageDays!=null?' <span class="meta">'+b.ageDays+'d old</span>':'')+'<div class="meta">'+b.paths.map(esc).join(", ")+'</div></div>', "nothing on branches");
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
const setStatus = (t, bad) => { const u = document.getElementById("updated"); u.textContent = t; u.className = bad ? "err" : ""; };
// Three lanes, kept apart on purpose: a network failure, a server that answered
// badly, and a bug in this page. Folding them into "disconnected" hid a render
// bug for four days while blaming the connection. Polling continues after any
// lane — the next tick may succeed.
async function tick() {
  let r;
  try { r = await fetch("/state.json", { cache: "no-store" }); }
  catch (e) { return setStatus("disconnected", true); }
  if (!r.ok) return setStatus("server error HTTP " + r.status, true);
  let s;
  try { s = await r.json(); } catch (e) { return setStatus("server error: invalid JSON", true); }
  try { draw(s); setStatus(document.getElementById("updated").textContent, false); }
  catch (e) { console.error("board render failed", e); setStatus("render error: " + ((e && e.message) || e) + " — state fetched fine; this is a board bug", true); }
}
tick(); setInterval(tick, 3000);
// One delegated listener, attached once: milestoneCard re-runs every tick and
// must not stack handlers. navigator.clipboard is absent outside a secure
// context and writeText may reject (NotAllowedError) — neither ever throws here.
document.getElementById("milestone").addEventListener("click", (e) => {
  const btn = e.target && e.target.closest ? e.target.closest("button.copy") : null;
  if (!btn) return;
  const cb = typeof navigator !== "undefined" && navigator.clipboard;
  if (!cb || !cb.writeText) return;                       // the command is still on screen to select
  cb.writeText(btn.dataset.cmd).then(() => { btn.textContent = "copied"; setTimeout(() => { btn.textContent = "copy"; }, 1500); }, () => {});
});
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
