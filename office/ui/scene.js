// The office scene: a pure function from a board snapshot (office/model.js) to what the floor draws, in
// floor coordinates (1120 wide). No DOM, so it runs in the browser (window.OfficeScene) and in Node tests.
//
//   sceneOf(snapshot, {now, bayLimit, prefer}) -> {W, H, rooms, labels, furniture, chars, building, bays, hidden, waiting}
//
// prefer: the bays shown last time; they keep their place while still building, so a bay does not swap
// to another feature each time a status changes.
//
// Each workflow step is a place in a room: Plan (intent, a brainstorm with you), Design (spec),
// Implementation plan (plan.md), Tasks (issues), Build (one bay per feature, lanes A and B, the lane
// stations), Verify (its stations), Done, and Your office, where a card goes when it waits for you to
// approve something or merge a PR. A question or a permission prompt waits where the agent works.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.OfficeScene = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const W = 1120;
  const LANE_PLACES = ['queue', 'implement', 'review', 'ui_check', 'pr'];
  const MONO = "font-family: ui-monospace, 'JetBrains Mono', SFMono-Regular, Menlo, monospace;";

  const AGENT_COLOR = {
    main: '#334155', lane: '#64748B', implementer: '#2563EB', 'code-reviewer': '#7C3AED', 'ui-verifier': '#0E7490',
    'e2e-verifier': '#0F766E', 'spec-reviewer': '#9333EA', 'github-ops': '#A16207', none: '#9CA3AF',
  };
  const STATUS = {
    working: { label: 'Working', fg: '#1D4ED8', bg: '#EEF3FE', bd: '#C9D8FB', icon: '•••' },
    waiting: { label: 'Waiting on you', fg: '#B43C0B', bg: '#FFF1E6', bd: '#F4B58E', icon: '!' },
    error: { label: 'Error', fg: '#B91C1C', bg: '#FEECEC', bd: '#F2B8B5', icon: '✗' },
    done: { label: 'Done', fg: '#166534', bg: '#E9F5EC', bd: '#BFDDC7', icon: '✓' },
    idle: { label: 'Not started', fg: '#5F5F5A', bg: '#F1F1EC', bd: '#DEDDD6', icon: '–' },
    quiet: { label: 'Quiet 10 min+', fg: '#8A5A00', bg: '#FFF4D6', bd: '#EBCB7A', icon: 'zzz' },
  };
  const PLACE_NAME = {
    intent: 'Plan: brainstorm with you (intent)', spec: 'Design (spec)', plan: 'Implementation plan (plan.md)',
    issues: 'Tasks (issues)', queue: 'Build: queued', implement: 'Build: implement + check-task', review: 'Build: review loop',
    ui_check: 'Build: UI check', pr: 'Build: push + PR body', checks: 'Verify: checks', e2e: 'Verify: E2E',
    vreview: 'Verify: feature review', done: 'Done', you: 'Your office',
  };

  // Places: a room area with seats, or a lane station (x only; its y comes from the feature's bay).
  const basePlaces = () => ({
    intent: { x: 20, y: 40, seats: [[14, 92], [92, 92], [170, 92]] },
    spec: { x: 282, y: 40, seats: [[56, 84], [150, 84]] },
    plan: { x: 544, y: 40, seats: [[60, 84], [140, 84]] },
    issues: { x: 806, y: 40, seats: [[170, 92], [226, 92]], stand: true },
    queue: { x: 34, w: 96, lane: true },
    implement: { x: 140, w: 200, lane: true },
    review: { x: 350, w: 180, lane: true },
    ui_check: { x: 540, w: 170, lane: true },
    pr: { x: 720, w: 120, lane: true },
    checks: { x: 34, y: 600, seats: [[40, 70]] },
    e2e: { x: 176, y: 600, seats: [[40, 70]] },
    ac: { x: 318, y: 600, seats: [[40, 70]] },
    vreview: { x: 460, y: 600, seats: [[50, 70]] },
    done: { x: 632, y: 560, seats: [[20, 110], [84, 110], [148, 110], [52, 30]], stand: true },
    you: { x: 872, y: 258, stand: true, seats: [[16, 84], [84, 84], [152, 84], [16, 194], [84, 194], [152, 194], [16, 304], [84, 304], [152, 304], [16, 414], [84, 414], [152, 414]] },
  });

  // Waiting for an approval or a merge sends the card to your office; a question or a permission prompt
  // keeps it where it works.
  const toYou = (c) => c.status === 'waiting' && (c.gate || /\bapprov/i.test(c.reason || ''));

  function placeOfFeature(f) {
    if (toYou(f)) return 'you';
    switch (f.step) {
      case 'spec': return 'spec';
      case 'plan': return 'plan';
      case 'issues': return 'issues';
      case 'build': return 'queue';
      case 'verify': {
        const t = f.agent && f.agent.type;
        return t === 'e2e-verifier' ? 'e2e' : t === 'code-reviewer' ? 'vreview' : 'checks';
      }
      case 'done': return 'done';
      default: return 'intent';
    }
  }
  function placeOfTask(t) {
    if (t.status === 'done' || t.step === 'done') return 'done';
    if (toYou(t)) return 'you';
    return { todo: 'queue', implement: 'implement', review: 'review', ui_check: 'ui_check', pr_open: 'pr' }[t.step] || 'queue';
  }

  const initials = (name) => (name ? name.split(/[-_ .]+/).filter(Boolean).slice(0, 3).map((w) => w[0]).join('').toUpperCase() : 'NEW');

  function age(ms, now) {
    if (!ms) return '';
    const m = Math.max(0, Math.round((now - ms) / 60000));
    return m < 60 ? `${m}m` : m < 1440 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}` : `${Math.floor(m / 1440)}d`;
  }

  // The characters: a feature's tasks while it builds, else the feature itself.
  function charactersOf(snap) {
    const out = [];
    for (const f of snap.features || []) {
      const name = f.name || 'new feature';
      const maxWave = Math.max(0, ...(f.tasks || []).map((t) => t.wave || 0));
      const wave = f.wave != null ? `wave ${f.wave}${maxWave > 1 ? ` of ${maxWave}` : ''}` : '';
      if (f.tasks && f.tasks.length) {
        for (const t of f.tasks) {
          const extra = [t.issue, t.pr ? `PR #${t.pr}` : null, t.reviews ? `review round ${t.reviews}` : null, t.wave ? `wave ${t.wave}` : null]
            .filter(Boolean).join(' · ');
          out.push({ key: t.key, feature: name, featureKey: f.key, task: t.id, lane: t.lane === 'B' ? 'B' : 'A', title: t.title,
            place: placeOfTask(t), status: t.status, quiet: !!t.quiet, agent: t.agent, since: t.since, reason: t.reason,
            gate: !!t.gate, pr: t.pr, extra, chest: t.id, wave, buildTask: f.kind === 'task' });
        }
      } else {
        out.push({ key: f.key, feature: name, featureKey: f.key, task: null, lane: 'A', title: null, place: placeOfFeature(f),
          status: f.status, quiet: !!f.quiet, agent: f.agent || (f.status === 'working' ? { type: 'main', model: null } : null),
          since: f.since, reason: f.reason, gate: !!f.gate, pr: null, chest: initials(f.name),
          extra: [f.skill ? f.skill.replace(/^workez:/, '') : null, f.fix_round ? `fix round ${f.fix_round}` : null].filter(Boolean).join(' · '),
          wave, buildTask: f.kind === 'task' });
      }
    }
    return out;
  }

  // What the agent is producing in this step, held next to the robot.
  const DOC = { INTENT: ['#B45309', 'intent.md'], SPEC: ['#7C3AED', 'spec.md'], PLAN: ['#2563EB', 'plan.md'], FIX: ['#B91C1C', 'plan-fix.md'] };
  function productOf(c) {
    const doc = (k) => ({ kind: 'doc', label: k, sub: '', color: DOC[k][0], name: DOC[k][1] });
    const r = c.reason || '';
    const prNum = c.pr || (r.match(/PR #(\d+)/) || [])[1];
    switch (c.place) {
      case 'intent': return doc('INTENT');
      case 'spec': return doc('SPEC');
      case 'plan': return doc('PLAN');
      case 'issues': return { kind: 'ticket', label: 'ISSUE', sub: '#…', name: 'task sub-issues' };
      case 'queue': return c.task ? { kind: 'ticket', label: c.task, sub: '', name: 'task issue' } : { kind: 'ticket', label: 'TASKS', sub: '', name: 'task issues' };
      case 'implement': return { kind: 'code', label: '</>', sub: 'code', name: 'code + tests in the task worktree' };
      case 'review': return { kind: 'diff', label: 'DIFF', sub: '', name: 'the task diff under review' };
      case 'ui_check': return { kind: 'web', label: 'UI', sub: '', name: 'UI check screenshots' };
      case 'pr': return { kind: 'pr', label: 'PR', sub: prNum ? `#${prNum}` : '', name: 'branch push + PR body' };
      case 'checks': return { kind: 'term', label: '>_', sub: 'tests', name: 'tests, lint, build' };
      case 'e2e': return { kind: 'web', label: 'E2E', sub: '', name: 'E2E evidence' };
      case 'vreview': return { kind: 'diff', label: 'DIFF', sub: 'all', name: 'whole-feature diff' };
      case 'done': return { kind: 'merged', label: 'PR', sub: prNum ? `#${prNum}` : '✓', name: prNum ? `PR #${prNum} merged` : 'merged' };
      default: // your office: what you must approve or merge
        if (/final PR/i.test(r)) return { kind: 'pr', label: 'PR', sub: 'final', name: 'final PR to merge' };
        if (prNum) return { kind: 'pr', label: 'PR', sub: `#${prNum}`, name: `PR #${prNum} to merge` };
        if (/merge/i.test(r)) return { kind: 'pr', label: 'PRs', sub: '', name: 'PRs to merge' };
        if (/plan-fix/i.test(r)) return doc('FIX');
        if (/plan/i.test(r)) return doc('PLAN');
        if (/spec/i.test(r)) return doc('SPEC');
        return doc('INTENT');
    }
  }

  function sceneOf(snap, opts = {}) {
    const now = opts.now || Date.now();
    const P = basePlaces();
    const all = charactersOf(snap || {});

    // Build: one bay per feature, at most bayLimit of them: the ones shown before, then features that need
    // you or failed, then the rest in snapshot order.
    const building = [];
    for (const c of all) if (LANE_PLACES.includes(c.place) && !building.includes(c.feature)) building.push(c.feature);
    const urgent = (f) => (all.some((c) => c.feature === f && (c.status === 'waiting' || c.status === 'error')) ? 0 : 1);
    const prefer = opts.prefer || [];
    const sticky = (f) => (prefer.includes(f) ? 0 : 1);
    const ranked = building.map((f, i) => [sticky(f), urgent(f), i, f]).sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2]).map((r) => r[3]);
    const bayLimit = Math.max(1, opts.bayLimit || 1);
    const shown = ranked.slice(0, bayLimit), hidden = ranked.slice(bayLimit);
    const bays = building.filter((f) => shown.includes(f)); // bays keep the snapshot's order on the floor
    const BAY_TOP = 300, BAY_H = 236, nb = Math.max(1, bays.length);
    const bayTop = (i) => BAY_TOP + i * BAY_H;
    const laneY = (f, ln) => bayTop(Math.max(0, bays.indexOf(f))) + 22 + (ln === 'B' ? 108 : 0);
    const hallBottom = BAY_TOP + nb * BAY_H + 4, DY = hallBottom - 530, H = 790 + DY;
    for (const k of ['checks', 'e2e', 'ac', 'vreview', 'done']) P[k].y += DY;

    const chars = all.filter((c) => !(LANE_PLACES.includes(c.place) && hidden.includes(c.feature)));
    const working = (c) => c.status === 'working' && !c.quiet;
    const busy = (place, lane, f) => chars.some((c) => c.place === place && working(c) && (!lane || c.lane === lane) && (!f || c.feature === f));

    const box = (x, y, w, h, bg, extra) => `left: ${x}px; top: ${y}px; width: ${w}px; height: ${h}px; background: ${bg}; ${extra || ''}`;
    const text = (x, y, t, style, cls) => ({ text: t, cls: cls || '', style: `left: ${x}px; top: ${y}px; ${style || ''}` });
    const room = (title, x, y, w, h, floor, you) => ({ title,
      style: box(x, y, w, h, floor, you ? 'border-radius: 12px; border: 2px solid #F0A271' : 'border-radius: 12px; border: 1px solid #D3D0C5') });
    const rooms = [
      room('Plan', 20, 40, 250, 170, '#F6F1E7'),
      room('Design', 282, 40, 250, 170, '#F3EEF6'),
      room('Implementation plan', 544, 40, 250, 170, '#EEF2F7'),
      room('Tasks', 806, 40, 294, 170, '#F4F0E6'),
      room('Build', 20, 258, 840, hallBottom - 258, '#EAEFF6'),
      room('Verify', 20, 560 + DY, 600, 216, '#EDF3EF'),
      room('Done', 632, 560 + DY, 228, 216, '#EDF4EE'),
      room('Your office', 872, 258, 228, 518 + DY, '#FFF4EA', true),
    ];

    const small = `${MONO} font-size: 10px; font-weight: 600;`;
    const labels = [text(30, 282, 'QUEUED', `${small} color: #4A4A45`)];
    for (const [k, t] of [['implement', 'IMPLEMENT + check-task'], ['review', 'REVIEW (≤3 rounds)'], ['ui_check', 'UI CHECK (lane browser)'], ['pr', 'PUSH + PR BODY']])
      labels.push(text(P[k].x + 4, 282, t, `${small} color: #4A4A45`));
    for (const [k, t] of [['checks', 'CHECKS'], ['e2e', 'E2E (lane A)'], ['ac', 'AC TABLE'], ['vreview', 'FEATURE REVIEW']])
      labels.push(text(P[k].x + 8, P[k].y + 6, t, `${small} color: #3F5F46`));
    labels.push(text(894, 298, 'WAITING ON YOU', `${small} color: #9A3412`));

    const furniture = [];
    const desk = (x, y, on) => {
      furniture.push({ cls: '', style: box(x - 8, y + 26, 64, 30, '#C9B79C', 'border-radius: 6px; box-shadow: inset 0 -4px 0 rgba(0,0,0,0.08)') });
      furniture.push({ cls: on ? 'screen-on' : '', style: box(x + 6, y - 2, 36, 26, on ? '#9DC3F5' : '#3B3A36', 'border-radius: 4px; border: 3px solid #2A2A27') });
    };
    // Build bays, each with its lanes and stations.
    const waveOf = (f) => (chars.find((c) => c.feature === f && c.wave) || {}).wave || '';
    for (let i = 0; i < nb; i++) {
      const f = bays[i] || null, by = bayTop(i);
      if (i > 0) furniture.push({ cls: '', style: box(34, by - 6, 818, 2, 'repeating-linear-gradient(90deg, #B8C4D9 0 8px, transparent 8px 14px)') });
      labels.push(text(40, by + 1, f ? [f, waveOf(f)].filter(Boolean).join(' · ') : 'no feature building',
        `display: inline-flex; align-items: center; height: 18px; padding: 0 8px; border-radius: 9px; background: ${f ? '#1E3A8A' : '#CBD5E1'}; color: #FFFFFF; ${MONO} font-size: 10.5px; font-weight: 700; white-space: nowrap`));
      for (const ln of ['A', 'B']) {
        const ly = laneY(f, ln);
        furniture.push({ cls: '', style: box(40, ly - 2, 806, 102, 'rgba(255,255,255,0.55)', 'border-radius: 10px; border: 1px solid #D5DEEC') });
        for (const k of ['implement', 'review', 'ui_check', 'pr']) desk(P[k].x + 30, ly + 20, f ? busy(k, ln, f) : false);
        furniture.push({ cls: '', style: box(P.queue.x + 8, ly + 74, 80, 12, '#A08A6B', 'border-radius: 4px') });
        for (const s of [P.implement, P.review, P.ui_check]) furniture.push({ cls: '', style: box(s.x + s.w - 8, ly + 44, 10, 4, '#9AA9C2', 'border-radius: 2px') });
        labels.push(text(24, ly + 38, ln, `${MONO} font-size: 12px; font-weight: 700; color: #1E3A8A`));
      }
    }
    // Plan: a brainstorm board of ideas. Design: two desks. Implementation plan: a table. Tasks: the issue board.
    furniture.push({ cls: '', style: box(93, 48, 104, 50, '#FFFFFF', 'border: 2px solid #8C8A80; border-radius: 4px') });
    for (const [x, y, c] of [[101, 55, '#FDE68A'], [121, 58, '#BFDBFE'], [141, 54, '#FBCFE8'], [105, 76, '#BBF7D0'], [127, 79, '#FED7AA'], [149, 75, '#FDE68A']])
      furniture.push({ cls: '', style: box(x, y, 16, 14, c, 'border-radius: 2px; transform: rotate(-3deg)') });
    furniture.push({ cls: '', style: box(173, 56, 14, 14, '#FACC15', 'border-radius: 50%; box-shadow: 0 0 0 3px rgba(250,204,21,0.3)') });
    furniture.push({ cls: '', style: box(177, 70, 6, 5, '#8C8A80', 'border-radius: 1px') });
    desk(314, 96, busy('spec')); desk(406, 96, false);
    furniture.push({ cls: '', style: box(586, 118, 110, 56, '#C9B79C', 'border-radius: 50%; box-shadow: inset 0 -5px 0 rgba(0,0,0,0.08)') });
    furniture.push({ cls: '', style: box(806, 84, 130, 64, '#D9C9A8', 'border-radius: 4px; border: 2px solid #8C7A5B') });
    for (const [x, y, c] of [[816, 92, '#FDE68A'], [842, 98, '#BFDBFE'], [868, 90, '#FBCFE8'], [894, 100, '#BBF7D0'], [826, 120, '#E9D5FF'], [856, 124, '#FED7AA']])
      furniture.push({ cls: '', style: box(x, y, 20, 16, c, 'border-radius: 2px') });
    furniture.push({ cls: '', style: box(884, 290, 204, 470 + DY, 'rgba(255,255,255,0.5)', 'border-radius: 10px; border: 1px dashed #F0A271') });
    for (const k of ['checks', 'e2e', 'ac', 'vreview']) desk(P[k].x + P[k].seats[0][0], P[k].y + 92, busy(k));
    furniture.push({ cls: '', style: box(648, 620 + DY, 196, 10, '#8C7A5B', 'border-radius: 3px') });
    for (const [x, y, c] of [[664, 598, '#E5B93C'], [704, 602, '#C0C0C0'], [744, 596, '#E5B93C'], [784, 602, '#CD8F52']])
      furniture.push({ cls: '', style: box(x, y + DY, 18, 22, c, 'border-radius: 4px 4px 2px 2px') });

    // Seats: lane stations by feature and lane; elsewhere the place's seats in order, then stacked on the last.
    const used = {};
    const seatOf = (c) => {
      const p = P[c.place];
      const key = p.lane ? `${c.place}/${c.feature}/${c.lane}` : c.place;
      const i = (used[key] = used[key] == null ? 0 : used[key] + 1);
      if (p.lane) return [p.x + 22 + Math.min(i, 2) * 56 + Math.max(0, i - 2) * 6, laneY(c.feature, c.lane) + 22, p];
      const s = p.seats[Math.min(i, p.seats.length - 1)], extra = Math.max(0, i - p.seats.length + 1) * 6;
      return [p.x + s[0] + extra, p.y + s[1] - extra, p];
    };

    const out = chars.map((c) => {
      const [x, y, p] = seatOf(c);
      const st = STATUS[c.quiet ? 'quiet' : c.status] || STATUS.idle;
      const type = c.agent && c.agent.type;
      const agentText = type ? (type === 'main' ? 'Claude (main session)' : type === 'lane' ? 'Lane subagent' : type) + (c.agent.model ? ` · ${c.agent.model}` : '') : 'No agent running';
      const sitting = !p.stand && c.status !== 'done';
      return {
        key: c.key, x, y, place: c.place, feature: c.feature, featureKey: c.featureKey, task: c.task,
        status: c.status, quiet: c.quiet, sitting, chest: c.chest,
        outfit: AGENT_COLOR[type] || AGENT_COLOR[type ? 'lane' : 'none'],
        tag: c.task ? `${c.feature.split('-')[0]} ${c.task}` : c.feature.split(' ')[0],
        bubble: c.status !== 'idle' && !(c.status === 'working' && !c.quiet) ? st.icon : null,
        chat: c.place === 'intent' && working(c),
        typing: working(c) && sitting,
        product: productOf(c),
        tip: {
          title: `${c.feature}${c.task ? ` · ${c.task}` : ''}`,
          sub: c.title || (c.buildTask ? 'build-task' : 'Feature (main session)'),
          rows: [['Where', PLACE_NAME[c.place]], ['Status', st.label], ['In step', age(c.since, now) || '—'], ['Agent', agentText],
            ...(LANE_PLACES.includes(c.place) || c.task ? [['Lane', c.lane]] : []), ['Product', productOf(c).name], ...(c.extra ? [['More', c.extra]] : [])],
          reason: c.reason || null, status: st,
        },
        flipUp: y > H - 270, alignRight: x > 820, alignLeft: x < 120,
      };
    });

    const waiting = all.filter((c) => c.status === 'waiting')
      .map((c) => ({ key: c.key, where: `${c.feature}${c.task ? ` ${c.task}` : ''}`, reason: c.reason || 'waiting for you', age: age(c.since, now), hidden: !chars.includes(c) }));

    return { W, H, rooms, labels, furniture, chars: out, building, bays, hidden, waiting };
  }

  return { sceneOf, charactersOf, placeOfFeature, placeOfTask, productOf, age, STATUS, AGENT_COLOR };
});
