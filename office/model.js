'use strict';
// The office board model: a pure function from what the workflow left behind (hook events, state.json
// files, plans) to a board snapshot. No file access, no clock: load.js reads the files and passes `now`.
//
//   buildSnapshot({events, states, plans, config, now, mtimes, agentModels}) -> snapshot
//
// events       hook events (docs/office-events.md), any order; sorted here by ts
// states       {<feature>: {state: <state.json>, mtime: <ms>}}
// plans        {<feature>: [{id, title, wave, lane, issue}]}
// config       office/board.json, merged with the project's .claude/office.json
// mtimes       {<transcript path>: <ms>}, for the paths transcriptPaths(events) lists
// agentModels  {<agent type>: <model>}, from the plugin's agents/*.md
//
// How a card's step is decided: every source gives timed observations (a step, a status, an agent), and
// the newest wins. A skill or agent event maps to a step through config.steps; a state.json maps to a
// step through stateView/taskStateView at its modification time. Waiting on you (a question, a
// permission prompt, a stopped session) is an overlay on the final card, cleared by the session's next
// event, so it never moves a card.
//
// A card's `gate` is true when it waits at one of the workflow's own gates (approve the plan, merge a PR,
// approve plan-fix.md), read from state.json; a question, a permission prompt or a stopped session is not a gate.

const RESULT_RE = /^(PR_READY|PR_EXISTS|BLOCKED|FAILED)\b\s*(.*)$/;

// norm('workez:implementer') -> 'implementer'; agent types and skills are compared without the plugin.
const norm = (s) => (typeof s === 'string' && s ? s.replace(/^[^:]*:/, '') : '');

// The feature card's step, status and reason from its state.json, or null for an unknown state.
function stateView(s) {
  if (!s || typeof s !== 'object') return null;
  const ho = s.handed_off === true;
  switch (`${s.phase}/${s.status}`) {
    case 'plan/done': return { step: 'spec', status: 'working' };
    case 'design/done': return { step: 'plan', status: 'working' };
    case 'write-plan/done': return ho ? { step: 'plan', status: 'waiting', reason: 'approve the plan' } : { step: 'plan', status: 'working' };
    case 'tasks/done': return { step: 'build', status: 'working' };
    case 'build/in_progress': return { step: 'build', status: 'working' };
    case 'build/waiting_review': return { step: 'build', status: 'waiting', reason: 'review and merge the open task PRs' };
    case 'build/blocked': return { step: 'build', status: 'error', reason: 'build blocked: a PR was closed, a task has no issue or failed' };
    case 'build/done': return { step: 'verify', status: 'working' };
    case 'verify/in_progress': return { step: 'verify', status: 'working' };
    case 'verify/waiting_merge': return { step: 'verify', status: 'waiting', reason: 'verify passed: merge the final PR' };
    case 'verify/failed': return { step: 'verify', status: 'waiting', reason: 'verify failed: approve plan-fix.md' };
    case 'verify/blocked': return { step: 'verify', status: 'error', reason: 'verify could not run' };
    case 'task/in_progress': return { step: 'build', status: 'working' };
    case 'task/waiting_review': return { step: 'build', status: 'waiting', reason: 'review and merge the task PR' };
    case 'task/blocked': return { step: 'build', status: 'error', reason: 'task blocked' };
    case 'task/done': return { step: 'done', status: 'done' };
    default: return null;
  }
}

// A task card's view from state.json tasks.<id>. todo and resume are only a baseline (ts 0), because a
// state written for another reason must not move a running task back.
function taskStateView(t) {
  const pr = t && t.pr ? ` #${t.pr}` : '';
  switch (t && t.status) {
    case 'todo': return { baseline: true, step: 'todo', status: 'idle' };
    case 'resume': return { baseline: true, step: 'todo', status: 'idle', reason: 'resumes from its worktree' };
    case 'waiting': return { step: 'pr_open', status: 'waiting', reason: `review and merge PR${pr}` };
    case 'done': return { step: 'done', status: 'done' };
    case 'closed': return { step: 'pr_open', status: 'error', reason: `PR${pr} closed without merge` };
    default: return null;
  }
}

// Lookups from config.steps: skill -> step, agent type -> {step, level}.
function indexSteps(config) {
  const bySkill = {}, byAgent = {}, level = {};
  for (const [id, s] of Object.entries(config.steps || {})) {
    level[id] = s.level || 'feature';
    for (const k of s.skills || []) bySkill[norm(k)] = id;
    for (const a of s.agents || []) byAgent[norm(a)] = id;
  }
  return { bySkill, byAgent, level };
}

// The transcript files whose modification time tells that a session or a subagent is still alive.
function transcriptPaths(events) {
  const out = new Set();
  for (const e of events) {
    if (!e || typeof e.transcript !== 'string' || !e.transcript) continue;
    out.add(e.transcript);
    if (e.agent_id) out.add(subagentTranscript(e.transcript, e.agent_id));
  }
  return [...out];
}
const subagentTranscript = (sessionTranscript, agentId) =>
  `${sessionTranscript.replace(/\.jsonl$/, '')}/subagents/agent-${agentId}.jsonl`;

function buildSnapshot({ events = [], states = {}, plans = {}, config = {}, now = 0, mtimes = {}, agentModels = {} }) {
  const idx = indexSteps(config);
  const known = new Set([...Object.keys(states), ...Object.keys(plans)]);
  const cards = new Map(); // key -> {key, obs: [], agents: Set, sessions: Set, transcripts: Set, ...}
  const card = (key, extra) => {
    if (!cards.has(key)) cards.set(key, { key, obs: [], active: new Map(), transcripts: new Set(), reviews: 0, ...extra });
    return cards.get(key);
  };
  const featureKey = (f) => `feature:${f}`;
  const taskKey = (f, t) => `task:${f}/${t}`;
  const observe = (key, ts, o, extra) => card(key, extra).obs.push({ ts, ...o });

  const sessions = new Map(); // sid -> {feature, pending, waiting, transcript}
  const agents = new Map();   // agent_id -> {feature, task, type, model, parent, session}
  const launches = [];        // Agent calls not yet matched to a SubagentStart

  const sorted = events.filter((e) => e && typeof e === 'object' && Number.isFinite(e.ts))
    .map((e, i) => [e, i]).sort((a, b) => a[0].ts - b[0].ts || a[1] - b[1]).map(([e]) => e);

  for (const e of sorted) {
    const sid = e.session || '';
    if (!sessions.has(sid)) sessions.set(sid, { feature: null, pending: null, waiting: null, transcript: null });
    const ses = sessions.get(sid);
    if (e.transcript) ses.transcript = e.transcript;
    const detail = e.detail || {};
    const ctx = e.agent_id ? agents.get(e.agent_id) : null;
    const feature = (known.has(e.feature) && e.feature) || (ctx && ctx.feature) || ses.feature;
    const task = e.task || (ctx && ctx.task) || null;
    // The card this event is about: the task, else the feature, else the session's unnamed feature.
    const target = feature && task ? taskKey(feature, task) : feature ? featureKey(feature) : ses.pending;
    const track = (key) => { if (key && e.transcript) card(key).transcripts.add(e.transcript); };

    // Waiting on you ends with the session's next event: any event after a stop or a notification; the
    // answer (or the next main-thread event) after a question.
    if (ses.waiting) {
      const w = ses.waiting;
      const answered = e.hook === 'PostToolUse' && e.tool_use_id && e.tool_use_id === w.tool_use_id;
      if (w.kind === 'ask' ? answered || (!e.agent_id && e.hook !== 'Notification') : e.hook !== 'Notification' || w.kind === 'stop')
        ses.waiting = null;
    }

    switch (e.hook) {
      case 'SessionStart': ses.ended = false; break;
      case 'SessionEnd':
        ses.ended = true;
        ses.waiting = { kind: 'ended', target: ses.feature ? featureKey(ses.feature) : ses.pending, reason: 'session ended' };
        for (const a of agents.values()) if (a.session === sid) a.stopped = true;
        break;
      case 'Stop':
        if (!e.agent_id) ses.waiting = { kind: 'stop', target: ses.feature ? featureKey(ses.feature) : ses.pending, reason: 'Claude stopped: your turn' };
        break;
      case 'Notification': {
        const t = detail.type;
        if (t === 'permission_prompt' || t === 'elicitation_dialog' || t === 'idle_prompt')
          ses.waiting = { kind: 'notify', target: target || (ses.feature && featureKey(ses.feature)) || ses.pending,
            reason: detail.message || 'Claude is waiting for you' };
        break;
      }
      case 'UserPromptSubmit':
      case 'PreToolUse':
      case 'PostToolUse':
      case 'SubagentStart':
      case 'SubagentStop':
        break;
    }

    // A workez skill starts: the feature moves to the skill's step.
    if (e.skill && (e.tool === 'Skill' || e.hook === 'UserPromptSubmit')) {
      const step = idx.bySkill[norm(e.skill)];
      if (known.has(e.feature)) {
        ses.feature = e.feature;
        if (ses.pending) card(ses.pending).resolved = true;
        ses.pending = null;
        if (step) { observe(featureKey(e.feature), e.ts, { step, status: 'working', agent: null }, { kind: 'feature', name: e.feature }); track(featureKey(e.feature)); }
      } else if (step && idx.level[step] === 'feature') {
        // A skill that names no known feature yet (plan-feature's idea, build-task's description): the
        // session's unnamed card, until a later skill in the session names the feature.
        ses.feature = null;
        ses.pending = ses.pending || `pending:${sid}`;
        observe(ses.pending, e.ts, { step, status: 'working', agent: null }, { kind: 'pending', name: null, skill: e.skill, session: sid });
        track(ses.pending);
      }
    }

    // An agent is launched: remember it for SubagentStart, and move its task (or feature) to its step.
    if ((e.tool === 'Agent' || e.tool === 'Task') && e.hook === 'PreToolUse') {
      const type = norm(detail.subagent_type) || 'general-purpose';
      const launchFeature = (known.has(e.feature) && e.feature) || (ctx && ctx.feature) || ses.feature;
      const launchTask = e.task || (ctx && ctx.task) || null;
      launches.push({ type, feature: launchFeature, task: launchTask, model: detail.model || agentModels[type] || null,
        parent: e.agent_id || null, session: sid, lane: !e.agent_id && type === 'general-purpose' && !!launchTask });
      const step = idx.byAgent[type];
      const agent = { type, model: detail.model || agentModels[type] || null };
      if (launchFeature && launchTask) {
        const key = taskKey(launchFeature, launchTask);
        if (type === 'code-reviewer') card(key, { kind: 'task', feature: launchFeature, id: launchTask }).reviews++;
        const lane = !e.agent_id && type === 'general-purpose';
        observe(key, e.ts, { ...(step && idx.level[step] !== 'feature' ? { step } : lane ? { step: 'implement' } : {}),
          status: 'working', reason: null, agent: lane ? { type: 'lane', model: agent.model } : agent },
          { kind: 'task', feature: launchFeature, id: launchTask });
        track(key);
      } else if (launchFeature) {
        observe(featureKey(launchFeature), e.ts, { ...(step && idx.level[step] === 'feature' ? { step } : {}), agent },
          { kind: 'feature', name: launchFeature });
      }
    }

    // A subagent starts: match it to the oldest launch of the same type, so its later events (its own
    // tool calls, its stop) find their feature and task by agent_id.
    if (e.hook === 'SubagentStart' && e.agent_id) {
      const type = norm(e.agent_type) || 'general-purpose';
      const i = launches.findIndex((l) => l.type === type && l.session === sid);
      const l = i >= 0 ? launches.splice(i, 1)[0] : { type, feature: ses.feature, task: null, model: agentModels[type] || null, parent: null };
      const parent = l.parent ? agents.get(l.parent) : null;
      const a = { ...l, feature: l.feature || (parent && parent.feature) || null, task: l.task || (parent && parent.task) || null, session: sid };
      agents.set(e.agent_id, a);
      const key = a.feature && a.task ? taskKey(a.feature, a.task) : a.feature ? featureKey(a.feature) : null;
      if (key) {
        card(key).active.set(e.agent_id, { type: a.lane ? 'lane' : a.type, model: a.model, since: e.ts });
        if (e.transcript) card(key).transcripts.add(subagentTranscript(e.transcript, e.agent_id));
      }
    }

    // A lane's (or agent's) result: PR_READY / PR_EXISTS move the task to "PR open", BLOCKED / FAILED is an error.
    const result = typeof detail.result === 'string' ? detail.result.match(RESULT_RE) : null;
    if ((e.hook === 'SubagentStop' || (e.hook === 'PostToolUse' && (e.tool === 'Agent' || e.tool === 'Task')))) {
      const a = e.hook === 'SubagentStop' && e.agent_id ? agents.get(e.agent_id) : null;
      const rf = (a && a.feature) || feature, rt = (a && a.task) || task;
      if (result && rf && rt) {
        const key = taskKey(rf, rt);
        if (result[1] === 'PR_READY' || result[1] === 'PR_EXISTS')
          observe(key, e.ts, { step: 'pr_open', status: 'working', reason: 'opening the PR' }, { kind: 'task', feature: rf, id: rt });
        else observe(key, e.ts, { status: 'error', reason: `${result[1]}${result[2] ? `: ${result[2]}` : ''}` }, { kind: 'task', feature: rf, id: rt });
      }
      if (a) {
        a.stopped = true;
        for (const c of cards.values()) c.active.delete(e.agent_id);
      }
    }

    // A question or a plan approval waits on you until it is answered.
    if (e.hook === 'PreToolUse' && (e.tool === 'AskUserQuestion' || e.tool === 'ExitPlanMode'))
      ses.waiting = { kind: 'ask', tool_use_id: e.tool_use_id, target: target || (ses.feature && featureKey(ses.feature)) || ses.pending,
        reason: e.tool === 'ExitPlanMode' ? 'approve the plan' : detail.question || 'answer a question' };
  }

  // state.json observations, at the file's modification time (todo/resume tasks: baseline only).
  for (const [name, { state, mtime }] of Object.entries(states)) {
    const v = stateView(state);
    const kind = state && state.phase === 'task' ? 'task-run' : 'feature';
    const c = card(featureKey(name), { kind: 'feature', name });
    c.run = kind;
    c.state = state;
    if (v) c.obs.push({ ts: mtime || 0, step: v.step, status: v.status, reason: v.reason || null, gate: v.status === 'waiting' });
    for (const [id, t] of Object.entries((state && state.tasks) || {})) {
      const tv = taskStateView(t);
      const tc = card(taskKey(name, id), { kind: 'task', feature: name, id });
      tc.taskState = t;
      if (tv) tc.obs.push({ ts: tv.baseline ? 0 : mtime || 0, step: tv.step, status: tv.status, reason: tv.reason || null, gate: tv.status === 'waiting' });
    }
  }
  // Plan tasks with nothing else known start in "todo".
  for (const [name, tasks] of Object.entries(plans)) {
    for (const t of tasks || []) {
      const tc = card(taskKey(name, t.id), { kind: 'task', feature: name, id: t.id });
      tc.plan = t;
      tc.obs.push({ ts: -1, step: 'todo', status: 'idle' });
    }
  }

  // Fold each card's observations, newest last.
  const quietMs = (config.quiet_after_min || 10) * 60000;
  const hideMs = (config.hide_idle_after_hours || 24) * 3600000;
  const columnOf = {};
  for (const col of config.columns || []) for (const s of col.steps || []) columnOf[s] = col.id;
  const fold = (c) => {
    const r = { step: null, since: null, status: 'idle', reason: null, gate: false, agent: null, last: null };
    for (const o of c.obs.sort((a, b) => a.ts - b.ts)) {
      if (o.step && o.step !== r.step) { r.step = o.step; r.since = o.ts > 0 ? o.ts : null; }
      if (o.status !== undefined) { r.status = o.status; r.reason = o.reason == null ? null : o.reason; r.gate = !!o.gate; }
      if (o.ts > 0) r.last = Math.max(r.last || 0, o.ts);
    }
    // The agent badge: the newest subagent still running on the card (a lane only when nothing runs inside it).
    const running = [...c.active.values()].sort((a, b) => b.since - a.since);
    const lead = running.find((a) => a.type !== 'lane') || running[0];
    r.agent = lead ? { type: lead.type, model: lead.model } : null;
    // Quiet: working, but no event and no transcript write for quiet_after_min.
    let alive = r.last || 0;
    for (const p of c.transcripts) if (mtimes[p]) alive = Math.max(alive, mtimes[p]);
    r.active = alive || null;
    r.quiet = r.status === 'working' && alive > 0 && now - alive > quietMs;
    r.column = (r.step && columnOf[r.step]) || null;
    return r;
  };

  // Waiting overlays: what each session still waits for, applied to its card unless it is done or failed.
  const overlays = new Map();
  for (const s of sessions.values()) if (s.waiting && s.waiting.target) overlays.set(s.waiting.target, s.waiting);
  const overlay = (key, r) => {
    const w = overlays.get(key);
    if (!w || r.status === 'done' || r.status === 'error') return r;
    if (w.kind === 'ended') return r.status === 'working' ? { ...r, status: 'idle', reason: w.reason, quiet: false } : r;
    if (w.kind === 'stop' && r.status === 'waiting') return r; // the state's reason says more
    return { ...r, status: 'waiting', reason: w.reason, gate: false, quiet: false };
  };

  const features = [];
  for (const c of cards.values()) {
    if (c.kind !== 'feature' && c.kind !== 'pending') continue;
    if (c.kind === 'pending' && c.resolved) continue;
    const r = overlay(c.key, fold(c));
    if (c.kind === 'pending' && r.status !== 'waiting' && now - (r.active || 0) > hideMs) continue;
    const name = c.name;
    const inBuild = r.step === 'build' || (c.run === 'task-run' && r.step !== 'done');
    const tasks = [];
    if (name && inBuild) {
      for (const tc of cards.values()) {
        if (tc.kind !== 'task' || tc.feature !== name) continue;
        const tr = overlay(tc.key, fold(tc));
        const p = tc.plan || {}, ts = tc.taskState || {};
        tasks.push({ key: tc.key, id: tc.id, title: p.title || null, wave: p.wave == null ? null : p.wave, lane: p.lane || null,
          issue: p.issue || null, pr: ts.pr || null, reviews: tc.reviews, fix_rounds: ts.fix_rounds || 0, ...pick(tr) });
      }
      tasks.sort((a, b) => taskNum(a.id) - taskNum(b.id));
    }
    const st = c.state || {};
    features.push({ key: c.key, name, kind: c.kind === 'pending' ? 'pending' : c.run === 'task-run' ? 'task' : 'feature',
      skill: c.skill || null, session: c.session || null,
      phase: st.phase || null, state_status: st.status || null, wave: st.wave == null ? null : st.wave,
      fix_round: st.fix_round == null ? null : st.fix_round, ...pick(r),
      column: tasks.length ? null : r.column, tasks });
  }
  const rank = { waiting: 0, error: 1, working: 2, idle: 3, done: 4 };
  const worst = (f) => Math.min(rank[f.status] ?? 5, ...f.tasks.map((t) => rank[t.status] ?? 5));
  features.sort((a, b) => worst(a) - worst(b) || (b.active || 0) - (a.active || 0) || String(a.name).localeCompare(String(b.name)));

  const waiting = [];
  for (const f of features) {
    if (f.status === 'waiting') waiting.push({ feature: f.name, task: null, reason: f.reason, gate: f.gate });
    for (const t of f.tasks) if (t.status === 'waiting') waiting.push({ feature: f.name, task: t.id, reason: t.reason, gate: t.gate });
  }
  return {
    version: 1,
    generated: now,
    columns: (config.columns || []).map((c) => ({ id: c.id, title: c.title })),
    features,
    waiting,
  };
}

const pick = (r) => ({ step: r.step, column: r.column, status: r.status, reason: r.reason, gate: r.gate, since: r.since,
  agent: r.agent, quiet: r.quiet, active: r.active });
const taskNum = (id) => Number(String(id).replace(/\D/g, '')) || 0;

// mergeConfig(base, override): the project's .claude/office.json over the plugin's board.json. Steps merge
// by id (an override step replaces that step's rules); columns, when given, replace the whole list.
function mergeConfig(base, over) {
  if (!over || typeof over !== 'object') return base;
  const out = { ...base, ...over, steps: { ...(base.steps || {}) } };
  for (const [id, s] of Object.entries(over.steps || {})) out.steps[id] = { ...(base.steps || {})[id], ...s };
  out.columns = Array.isArray(over.columns) ? over.columns : base.columns;
  return out;
}

// parsePlan(markdown): the tasks of a plan.md (the format build-position.sh reads).
function parsePlan(md) {
  const tasks = [];
  let wave = null, cur = null;
  for (const line of String(md || '').split('\n')) {
    let m;
    if ((m = line.match(/^## Wave (\d+)/))) { cur = null; wave = Number(m[1]); continue; }
    if ((m = line.match(/^## (T\d+): *(.*)$/))) { cur = { id: m[1], title: m[2].trim() || null, wave, lane: null, issue: null }; tasks.push(cur); continue; }
    if (/^## /.test(line)) { cur = null; continue; }
    if (!cur) continue;
    if ((m = line.match(/^- \*\*Lane\*\*: *(.*)$/))) cur.lane = m[1].trim() || null;
    if ((m = line.match(/^- \*\*Issue\*\*: *(.*)$/))) cur.issue = m[1].trim() || null;
  }
  return tasks;
}

module.exports = { buildSnapshot, transcriptPaths, mergeConfig, parsePlan, stateView, taskStateView };
