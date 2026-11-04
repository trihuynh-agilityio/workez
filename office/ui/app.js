// The office page: reads the board snapshot from the local server (a live stream, with a polling fallback)
// and draws it with scene.js. Characters are kept by key, so a change of place makes them walk there.
(function () {
  'use strict';
  const { sceneOf, age } = window.OfficeScene;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const store = {
    get(k, d) { try { const v = localStorage.getItem(`workez-office:${k}`); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem(`workez-office:${k}`, JSON.stringify(v)); } catch { /* private window */ } },
  };

  const ui = { snap: null, scene: null, pinned: null, alertOpen: false, bayLimit: store.get('bayLimit', 1), demo: false };
  const nodes = new Map(); // key -> {el, x, y, sig}

  // The robot: a screen head (eyes show the state), a body in the agent's colour, the task id on its chest.
  function eyes(c, y) {
    const L = 20, R = 28;
    if (c.status === 'error') return ['eyes', 'none', '#F87171', `M${L - 2} ${y - 2}l4 4M${L + 2} ${y - 2}l-4 4M${R - 2} ${y - 2}l4 4M${R + 2} ${y - 2}l-4 4`];
    if (c.status === 'done') return ['eyes', 'none', '#4ADE80', `M${L - 2.5} ${y + 1.2}Q${L} ${y - 2.6} ${L + 2.5} ${y + 1.2}M${R - 2.5} ${y + 1.2}Q${R} ${y - 2.6} ${R + 2.5} ${y + 1.2}`];
    if (c.status === 'idle' || c.quiet) return ['eyes', 'none', '#94A3B8', `M${L - 2.5} ${y - 0.5}Q${L} ${y + 2.2} ${L + 2.5} ${y - 0.5}M${R - 2.5} ${y - 0.5}Q${R} ${y + 2.2} ${R + 2.5} ${y - 0.5}`];
    if (c.status === 'waiting') return ['eyes hold', '#FB923C', 'none', `M${L - 1.8} ${y - 3}h1.4v6h-1.4zM${L + 0.4} ${y - 3}h1.4v6h-1.4zM${R - 1.8} ${y - 3}h1.4v6h-1.4zM${R + 0.4} ${y - 3}h1.4v6h-1.4z`];
    return ['eyes scan', '#22D3EE', 'none', `M${L - 2.2} ${y}a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0 -4.4 0M${R - 2.2} ${y}a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0 -4.4 0`];
  }
  function robot(c, sit) {
    const dy = sit ? 5 : 0;
    const [ecls, efill, estroke, ed] = eyes(c, sit ? 18.5 : 13.5);
    const base = sit
      ? `<ellipse cx="24" cy="60" rx="17" ry="4" fill="rgba(28,28,26,0.14)"/><rect x="9" y="50" width="30" height="8" rx="3" fill="#8C8A80"/>`
      : `<ellipse cx="24" cy="61" rx="15" ry="3.5" fill="rgba(28,28,26,0.14)"/><rect x="16" y="48" width="6" height="12" rx="2" fill="#64748B"/><rect x="26" y="48" width="6" height="12" rx="2" fill="#64748B"/>`;
    return `<svg aria-hidden="true" width="48" height="64" viewBox="0 0 48 64">${base}
      <rect x="11" y="${dy + 26}" width="26" height="${sit ? 22 : 24}" rx="5" fill="${c.outfit}"/>
      <rect class="arm" x="5" y="${dy + 29}" width="7" height="${sit ? 12 : 15}" rx="3.5" fill="#94A3B8"/>
      <rect class="arm" x="36" y="${dy + 29}" width="7" height="${sit ? 12 : 15}" rx="3.5" fill="#94A3B8"/>
      <line x1="24" y1="${dy}" x2="24" y2="${dy + 4}" stroke="#64748B" stroke-width="2"/>
      <circle cx="24" cy="${dy + 2}" r="2.5" fill="${c.outfit}"/>
      <rect x="12" y="${dy + 4}" width="24" height="20" rx="6" fill="#E2E8F0" stroke="#64748B" stroke-width="1.5"/>
      <rect x="15" y="${dy + 8}" width="18" height="11" rx="3" fill="#1E293B"/>
      <path class="${ecls}" d="${ed}" fill="${efill}" stroke="${estroke}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="24" y="${dy + (sit ? 41 : 42)}" text-anchor="middle" font-family="ui-monospace, Menlo, monospace" font-size="9" font-weight="600" fill="#FFFFFF">${esc(c.chest)}</text>
    </svg>`;
  }

  const LOOK = {
    doc: (p) => ({ bg: '#FFFFFF', bd: '#CBD5E1', band: p.color, fg: '#FFFFFF', lines: 'repeating-linear-gradient(#E2E8F0 0 1.5px, transparent 1.5px 5px)' }),
    ticket: () => ({ bg: '#FEF3C7', bd: '#E5B93C', band: '#CA8A04', fg: '#FFFFFF' }),
    code: () => ({ bg: '#1E293B', bd: '#0F172A', band: '#334155', fg: '#7DD3FC', lines: 'repeating-linear-gradient(#475569 0 1.5px, transparent 1.5px 5px)', dark: true }),
    diff: () => ({ bg: '#1E293B', bd: '#0F172A', band: '#334155', fg: '#FDE68A', lines: 'repeating-linear-gradient(#16A34A 0 1.5px, transparent 1.5px 5px, #DC2626 5px 6.5px, transparent 6.5px 10px)', dark: true }),
    term: () => ({ bg: '#0F172A', bd: '#020617', band: '#1E293B', fg: '#4ADE80', dark: true }),
    web: () => ({ bg: '#FFFFFF', bd: '#94A3B8', band: '#CBD5E1', fg: '#0E7490', lines: 'linear-gradient(#BAE6FD, #BAE6FD) 4px 12px / 22px 8px no-repeat' }),
    pr: () => ({ bg: '#F5F3FF', bd: '#7C3AED', band: '#7C3AED', fg: '#FFFFFF' }),
    merged: () => ({ bg: '#EDE9FE', bd: '#6D28D9', band: '#6D28D9', fg: '#FFFFFF' }),
  };
  function product(p) {
    const l = (LOOK[p.kind] || LOOK.doc)(p);
    const bg = l.lines ? `${l.lines}, ${l.bg}` : l.bg;
    return `<span class="prod ${p.kind}" aria-hidden="true" style="border-color: ${l.bd}; background: ${bg}">
      <span class="band" style="background: ${l.band}; color: ${l.fg}">${esc(p.label)}</span>
      <span class="sub" style="color: ${l.dark ? '#E2E8F0' : '#334155'}; background: ${l.dark ? 'rgba(15,23,42,0.6)' : 'rgba(255,255,255,0.8)'}">${esc(p.sub)}</span></span>`;
  }
  function tooltip(c) {
    const t = c.tip, st = t.status;
    const cls = ['tip', c.flipUp ? 'up' : '', c.alignRight ? 'right' : c.alignLeft ? 'left' : ''].join(' ');
    return `<span class="${cls}" role="tooltip"><span class="t">${esc(t.title)}</span><span class="s">${esc(t.sub)}</span>
      <span class="rows">${t.rows.map(([k, v]) => `<span class="k">${esc(k)}</span><span class="v">${esc(v)}</span>`).join('')}</span>
      ${t.reason ? `<span class="why" style="color: ${st.fg}; background: ${st.bg}; border-color: ${st.bd}">${esc(t.reason)}</span>` : ''}</span>`;
  }
  function inner(c, moving) {
    const st = c.tip.status;
    return [
      c.chat && !moving ? '<span class="chat ai" aria-hidden="true">?</span><span class="chat you" aria-hidden="true">…</span>' : '',
      c.bubble && !moving ? `<span class="bubble" aria-hidden="true" style="background: ${st.bg}; border-color: ${st.bd}; color: ${st.fg}">${esc(c.bubble)}</span>` : '',
      robot(c, c.sitting && !moving), product(c.product), `<span class="tag">${esc(c.tag)}</span>`, tooltip(c),
    ].join('');
  }

  function drawStatic(s) {
    $('static').innerHTML = [
      ...s.rooms.map((r) => `<div class="room" style="${r.style}"><span class="title">${esc(r.title)}</span></div>`),
      ...s.furniture.map((f) => `<div class="furn ${f.cls}" aria-hidden="true" style="${f.style}"></div>`),
      ...s.labels.map((l) => `<span class="label ${l.cls}" style="${l.style}">${esc(l.text)}</span>`),
    ].join('');
  }

  function drawChars(s) {
    const seen = new Set();
    for (const c of s.chars) {
      seen.add(c.key);
      let n = nodes.get(c.key);
      if (!n) {
        const el = document.createElement('button');
        el.type = 'button';
        el.addEventListener('click', () => { ui.pinned = ui.pinned === c.key ? null : c.key; render(); });
        $('chars').appendChild(el);
        n = { el, x: c.x, y: c.y, sig: '', moveUntil: 0 };
        nodes.set(c.key, n);
      }
      const moved = n.x !== c.x || n.y !== c.y;
      if (moved) n.moveUntil = Date.now() + 1600;
      const moving = Date.now() < n.moveUntil;
      n.x = c.x; n.y = c.y;
      n.el.style.left = `${c.x}px`;
      n.el.style.top = `${c.y}px`;
      n.el.className = ['who', moving ? 'bob' : '', c.status, c.typing && !moving ? 'typing' : '', c.status === 'error' && !moving ? 'slump' : '',
        c.quiet ? 'quiet' : '', ui.pinned === c.key ? 'pinned' : ''].filter(Boolean).join(' ');
      n.el.setAttribute('aria-label', `${c.tip.title}: ${c.tip.status.label}${c.tip.reason ? `, ${c.tip.reason}` : ''}, at ${c.tip.rows[0][1]}`);
      const html = inner(c, moving);
      if (html !== n.sig) { n.el.innerHTML = html; n.sig = html; }
      if (moved) setTimeout(render, 1650); // sit down and show the bubble again once arrived
    }
    for (const [k, n] of nodes) if (!seen.has(k)) { n.el.remove(); nodes.delete(k); }
  }

  function drawHeader(s) {
    // Build: the control only when more than one feature is building.
    $('bays').hidden = s.building.length < 2;
    $('bay-n').textContent = String(Math.min(ui.bayLimit, Math.max(1, s.building.length)));
    $('bay-minus').disabled = ui.bayLimit <= 1;
    $('bay-plus').disabled = ui.bayLimit >= s.building.length;
    $('bay-more').hidden = !s.hidden.length;
    $('bay-more').textContent = `+${s.hidden.length} more building`;
    $('bay-more').title = `Not shown: ${s.hidden.join(', ')}. Click to show all.`;

    const w = s.waiting;
    $('alert-n').textContent = String(w.length);
    $('alert').disabled = !w.length;
    $('alert').setAttribute('aria-label', `${w.length} waiting on you, show details`);
    if (!w.length) ui.alertOpen = false;
    $('alert').setAttribute('aria-expanded', String(ui.alertOpen));
    const list = $('alert-list');
    list.hidden = !ui.alertOpen;
    list.innerHTML = `<span class="head">Waiting on you · ${w.length}</span>` + w.map((x) => `<button type="button" data-key="${esc(x.key)}">
      <span class="row"><span>${esc(x.where)}</span><span class="age">${esc(x.age)}</span></span>
      <span class="why">${esc(x.reason)}</span>${x.hidden ? '<span class="off">In a Build bay that is not shown</span>' : ''}</button>`).join('');
  }

  function fit() {
    if (!ui.scene) return;
    const floor = $('floor');
    const k = Math.min((floor.clientWidth - 2) / ui.scene.W, (floor.clientHeight - 2) / ui.scene.H);
    $('fit').style.width = `${Math.round(ui.scene.W * k)}px`;
    $('fit').style.height = `${Math.round(ui.scene.H * k)}px`;
    $('stage').style.height = `${ui.scene.H}px`;
    $('stage').style.transform = `scale(${k.toFixed(4)})`;
  }

  function render() {
    if (!ui.snap) return;
    const s = sceneOf(ui.snap, { now: Date.now(), bayLimit: ui.bayLimit, prefer: ui.scene ? ui.scene.bays : [] });
    ui.scene = s;
    if (ui.pinned && !s.chars.some((c) => c.key === ui.pinned)) ui.pinned = null;
    drawStatic(s);
    drawChars(s);
    drawHeader(s);
    $('empty').hidden = !!(ui.snap.features || []).length;
    fit();
  }

  // Controls
  const setBays = (n) => { ui.bayLimit = Math.max(1, n); store.set('bayLimit', ui.bayLimit); render(); };
  $('bay-minus').addEventListener('click', () => setBays(ui.bayLimit - 1));
  $('bay-plus').addEventListener('click', () => setBays(ui.bayLimit + 1));
  $('bay-more').addEventListener('click', () => setBays(ui.scene ? ui.scene.building.length : ui.bayLimit));
  $('alert').addEventListener('click', () => { ui.alertOpen = !ui.alertOpen; render(); });
  $('alert-list').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-key]');
    if (!b) return;
    const key = b.dataset.key;
    if (ui.scene && ui.scene.hidden.length && !ui.scene.chars.some((c) => c.key === key)) setBays(ui.scene.building.length);
    ui.pinned = key; ui.alertOpen = false; render();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && (ui.alertOpen || ui.pinned)) { ui.alertOpen = false; ui.pinned = null; render(); } });
  document.addEventListener('click', (e) => { if (ui.alertOpen && !e.target.closest('.alert-wrap')) { ui.alertOpen = false; render(); } });
  new ResizeObserver(fit).observe($('floor'));
  setInterval(render, 30000); // times in step

  // Data: the live stream, polling /api/snapshot while it is down.
  const setConn = (state, text) => { $('conn').dataset.state = state; $('conn-text').textContent = text; };
  const take = (snap) => { ui.snap = snap; render(); };
  fetch('api/health').then((r) => r.json()).then((h) => {
    ui.demo = !!h.demo;
    $('project').textContent = h.demo ? 'demo' : (h.project || '').split('/').pop();
    document.title = `workez office · ${$('project').textContent}`;
    if (ui.snap && h.demo) setConn('demo', 'Demo data');
  }).catch(() => {});
  let poll = null;
  const startPoll = () => {
    if (poll) return;
    poll = setInterval(() => fetch('api/snapshot').then((r) => r.json()).then(take).catch(() => setConn('lost', 'Server stopped')), 5000);
  };
  const es = new EventSource('api/stream');
  es.addEventListener('snapshot', (e) => {
    clearInterval(poll); poll = null;
    setConn(ui.demo ? 'demo' : 'live', ui.demo ? 'Demo data' : 'Live');
    try { take(JSON.parse(e.data)); } catch { /* a broken frame waits for the next one */ }
  });
  es.onerror = () => { setConn('lost', 'Reconnecting…'); startPoll(); };
  fetch('api/snapshot').then((r) => r.json()).then((s) => { if (!ui.snap) take(s); }).catch(() => {});

  // For tests: the current scene.
  window.__office = { get scene() { return ui.scene; }, age };
})();
