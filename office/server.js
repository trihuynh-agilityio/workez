#!/usr/bin/env node
'use strict';
// The office board's local server: the snapshot, a live stream of it, and the office page. Node only, no
// dependencies, read-only, bound to 127.0.0.1. It never calls a model.
//
//   node office/server.js [--project <dir>] [--port <n>] [--demo] [--idle-min <n>]
//
//   GET /api/health    {ok, pid, port, project, demo}
//   GET /api/snapshot  the board snapshot (office/model.js)
//   GET /api/stream    server-sent events: "snapshot" now and on every change
//   GET /              the office page (office/ui)
//
// It writes .claude/workflow/office/server.json ({pid, port, project}) so /workez:office reuses it, and exits
// after --idle-min minutes (30) with no page open and no new event.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { findProject, snapshot } = require('./load');

function parseArgs(argv) {
  const o = { project: null, port: 0, demo: false, idleMin: 30 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project') o.project = argv[++i];
    else if (a === '--port') o.port = Number(argv[++i]) || 0;
    else if (a === '--demo') o.demo = true;
    else if (a === '--idle-min') o.idleMin = Number(argv[++i]) || 30;
  }
  return o;
}

const UI = path.join(__dirname, 'ui');
const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/scene.js': ['scene.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
};

// A cheap fingerprint of every file the snapshot reads: names, sizes and modification times.
function fingerprint(project) {
  const parts = [];
  const stat = (f) => { try { const s = fs.statSync(f); parts.push(`${f}:${s.size}:${s.mtimeMs}`); } catch { /* gone */ } };
  const list = (d) => { try { return fs.readdirSync(d); } catch { return []; } };
  const wf = path.join(project, '.claude', 'workflow');
  for (const f of list(path.join(wf, 'office'))) if (f.startsWith('events-')) stat(path.join(wf, 'office', f));
  let docs = 'specs';
  try { const c = JSON.parse(fs.readFileSync(path.join(project, '.claude', 'workflow.json'), 'utf8')); if (typeof c.docs_dir === 'string') docs = c.docs_dir; } catch { /* default */ }
  for (const name of list(wf)) {
    if (name === 'office') continue;
    stat(path.join(wf, name, 'state.json'));
    stat(path.join(wf, name, 'plan.md'));
    stat(path.join(project, docs, name, 'plan.md'));
    stat(path.join(project, docs, name, 'plan-fix.md'));
  }
  stat(path.join(project, '.claude', 'office.json'));
  return parts.join('|');
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const project = opts.demo ? null : path.resolve(opts.project || findProject(process.cwd()) || '');
  if (!opts.demo && (!project || !fs.existsSync(path.join(project, '.claude', 'workflow.json')))) {
    console.error('office: no .claude/workflow.json here or above (use --project <dir>, or --demo)');
    process.exit(2);
  }
  const demo = opts.demo ? require('./demo') : null;
  const started = Date.now();

  // The current snapshot, recomputed when the files change (checked every second) and every 20 seconds for
  // the time-based marks (quiet). Demo: the next scripted frame every 5 seconds.
  let body = '', print = '', lastChange = Date.now();
  const clients = new Set();
  const publish = (snap) => {
    const p = JSON.stringify({ ...snap, generated: 0 });
    if (p === print) return;
    print = p; body = JSON.stringify(snap);
    if (!opts.demo) lastChange = Date.now();
    for (const res of clients) res.write(`event: snapshot\ndata: ${body}\n\n`);
  };
  const compute = () => { try { publish(snapshot(project)); } catch (e) { console.error(`office: snapshot failed: ${e.message}`); } };
  if (demo) {
    let i = 0;
    const frames = demo.frames(started);
    publish(frames[0]);
    setInterval(() => { i = (i + 1) % frames.length; publish({ ...frames[i], generated: Date.now() }); }, 5000).unref();
  } else {
    compute();
    let fp = fingerprint(project), ticks = 0;
    setInterval(() => {
      const f = fingerprint(project);
      if (f !== fp || ++ticks >= 20) { fp = f; ticks = 0; compute(); }
    }, 1000).unref();
  }

  const server = http.createServer((req, res) => {
    const port = server.address().port;
    // Only this machine, by name: a page on another site cannot reach the server through DNS rebinding.
    if (![`127.0.0.1:${port}`, `localhost:${port}`].includes(req.headers.host || '')) { res.writeHead(403).end('forbidden'); return; }
    if (req.method !== 'GET') { res.writeHead(405).end(); return; }
    const url = new URL(req.url, `http://${req.headers.host}`);
    const send = (code, type, data) => res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' }).end(data);
    switch (url.pathname) {
      case '/api/health':
        return send(200, 'application/json', JSON.stringify({ ok: true, pid: process.pid, port, project, demo: !!demo }));
      case '/api/snapshot':
        return send(200, 'application/json', body);
      case '/api/stream': {
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
        res.write(`retry: 3000\nevent: snapshot\ndata: ${body}\n\n`);
        clients.add(res);
        const ping = setInterval(() => res.write(': ping\n\n'), 25000);
        req.on('close', () => { clearInterval(ping); clients.delete(res); lastChange = Math.max(lastChange, Date.now()); });
        return;
      }
      default: {
        const f = STATIC[url.pathname];
        if (!f) return send(404, 'text/plain', 'not found');
        fs.readFile(path.join(UI, f[0]), (err, data) => (err ? send(500, 'text/plain', 'missing file') : send(200, f[1], data)));
      }
    }
  });

  const info = project ? path.join(project, '.claude', 'workflow', 'office', 'server.json') : null;
  const cleanup = () => {
    if (!info) return;
    try { const j = JSON.parse(fs.readFileSync(info, 'utf8')); if (j.pid === process.pid) fs.unlinkSync(info); } catch { /* not ours */ }
  };
  const quit = () => { cleanup(); process.exit(0); };
  process.on('SIGINT', quit);
  process.on('SIGTERM', quit);

  server.listen(opts.port, '127.0.0.1', () => {
    const port = server.address().port;
    if (info) {
      try {
        fs.mkdirSync(path.dirname(info), { recursive: true });
        fs.writeFileSync(info, JSON.stringify({ pid: process.pid, port, project, started }));
      } catch { /* read-only project: still serve */ }
    }
    console.log(`http://127.0.0.1:${port}/`);
  });
  server.on('error', (e) => { console.error(`office: ${e.message}`); process.exit(1); });

  // Idle exit: no page open and nothing new for idle-min minutes.
  setInterval(() => {
    if (!clients.size && Date.now() - lastChange > opts.idleMin * 60000) quit();
  }, 60000).unref();
}

if (require.main === module) main();
module.exports = { parseArgs, fingerprint };
