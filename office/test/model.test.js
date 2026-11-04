'use strict';
// Unit tests of the office board model: node --test office/test/
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { buildSnapshot, mergeConfig, parsePlan, stateView, transcriptPaths } = require('../model');

const config = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'board.json'), 'utf8'));
const MIN = 60000;
const T0 = 1_800_000_000_000;
const at = (m) => T0 + m * MIN;
const models = { implementer: 'sonnet', 'code-reviewer': 'opus', 'ui-verifier': 'sonnet', 'spec-reviewer': 'opus' };

// ev(minute, fields): one event as office-event.sh writes it.
let n = 0;
const ev = (m, f) => ({ v: 1, ts: at(m), session: 's1', agent_id: null, agent_type: null, skill: null, feature: null, task: null,
  tool: null, tool_use_id: null, cwd: '/p', transcript: '/t/s1.jsonl', detail: {}, ...f, _n: n++ });
const skill = (m, s, args, f = {}) => ev(m, { hook: 'PreToolUse', tool: 'Skill', skill: `workez:${s}`, feature: args.split(' ')[0] || null, detail: { args }, ...f });
const launch = (m, type, prompt, f = {}) => ev(m, { hook: 'PreToolUse', tool: 'Agent',
  feature: (prompt.match(/([\w.-]+)\/plan\.md/) || [])[1] || null, task: (prompt.match(/\bT\d+\b/) || [])[0] || null,
  detail: { subagent_type: type, model: null, description: null }, ...f });
const start = (m, id, type, f = {}) => ev(m, { hook: 'SubagentStart', agent_id: id, agent_type: type, ...f });
const stop = (m, id, type, result = null, f = {}) => ev(m, { hook: 'SubagentStop', agent_id: id, agent_type: type, detail: { result, transcript: null }, ...f });
const snap = (o) => buildSnapshot({ config, agentModels: models, now: at(100), ...o });
const feat = (s, name) => s.features.find((f) => f.name === name);
const task = (s, name, id) => feat(s, name).tasks.find((t) => t.id === id);

const buildState = (tasks, status = 'in_progress') => ({ state: { feature: 'login', phase: 'build', status, handed_off: true, wave: 1, tasks }, mtime: at(1) });
const plan = { login: [{ id: 'T1', title: 'Form', wave: 1, lane: 'A', issue: '#11' }, { id: 'T2', title: 'API', wave: 1, lane: 'B', issue: '#12' }] };

test('stateView maps every phase/status the skills write', () => {
  assert.deepEqual(stateView({ phase: 'plan', status: 'done', handed_off: false }), { step: 'spec', status: 'working' });
  assert.equal(stateView({ phase: 'write-plan', status: 'done', handed_off: true }).status, 'waiting');
  assert.equal(stateView({ phase: 'build', status: 'waiting_review' }).status, 'waiting');
  assert.equal(stateView({ phase: 'build', status: 'blocked' }).status, 'error');
  assert.equal(stateView({ phase: 'build', status: 'done', handed_off: false }).step, 'verify');
  assert.equal(stateView({ phase: 'verify', status: 'failed' }).reason, 'verify failed: approve plan-fix.md');
  assert.deepEqual(stateView({ phase: 'task', status: 'done' }), { step: 'done', status: 'done' });
  assert.equal(stateView({ phase: 'nope', status: 'x' }), null);
  assert.equal(stateView(null), null);
});

test('phase 1: an unnamed card in Intent, waiting on a question, then resolved to the feature', () => {
  const events = [
    ev(0, { hook: 'UserPromptSubmit', skill: 'workez:plan-feature', feature: 'a', detail: { command: true } }),
    skill(0.1, 'plan-feature', 'a login page'),
    ev(5, { hook: 'PreToolUse', tool: 'AskUserQuestion', tool_use_id: 'q1', detail: { question: 'Approve the intent?' } }),
  ];
  let s = snap({ events });
  assert.equal(s.features.length, 1);
  assert.equal(s.features[0].kind, 'pending');
  assert.equal(s.features[0].column, 'intent');
  assert.equal(s.features[0].status, 'waiting');
  assert.equal(s.features[0].reason, 'Approve the intent?');
  assert.deepEqual(s.waiting, [{ feature: null, task: null, reason: 'Approve the intent?', gate: false }]);

  events.push(ev(6, { hook: 'PostToolUse', tool: 'AskUserQuestion', tool_use_id: 'q1' }));
  s = snap({ events });
  assert.equal(s.features[0].status, 'working');

  // plan-feature writes the state, the Stop hook hands off to design-feature with the name.
  events.push(skill(10, 'design-feature', 'login'));
  s = snap({ events, states: { login: { state: { feature: 'login', phase: 'plan', status: 'done', handed_off: true }, mtime: at(9) } } });
  assert.equal(s.features.length, 1, 'the unnamed card is gone');
  assert.equal(feat(s, 'login').column, 'spec');
  assert.equal(feat(s, 'login').since, at(9), 'in Spec since the state said phase 1 was done');
  assert.equal(feat(s, 'login').status, 'working');
});

test('the newest source wins: a state written after the skill moves the card on', () => {
  const events = [skill(10, 'design-feature', 'login')];
  const s = snap({ events, states: { login: { state: { feature: 'login', phase: 'design', status: 'done', handed_off: false }, mtime: at(30) } } });
  assert.equal(feat(s, 'login').step, 'plan');
  assert.equal(feat(s, 'login').since, at(30));
});

test('a feature agent moves the feature (spec-reviewer); a task agent without a task does not', () => {
  const events = [
    skill(1, 'design-feature', 'login'),
    launch(2, 'workez:spec-reviewer', 'Review specs/login/spec.md'),
    start(2.1, 'r1', 'workez:spec-reviewer'),
  ];
  const states = { login: { state: { feature: 'login', phase: 'plan', status: 'done', handed_off: true }, mtime: at(0) } };
  let s = snap({ events, states });
  assert.equal(feat(s, 'login').column, 'spec');
  assert.deepEqual(feat(s, 'login').agent, { type: 'spec-reviewer', model: 'opus' });
  events.push(stop(3, 'r1', 'workez:spec-reviewer'));
  s = snap({ events, states });
  assert.equal(feat(s, 'login').agent, null);

  const v = snap({ events: [skill(1, 'verify-feature', 'login'), launch(2, 'workez:code-reviewer', 'Review the whole feature login')],
    states: { login: { state: { feature: 'login', phase: 'build', status: 'done', handed_off: true }, mtime: at(0) } } });
  assert.equal(feat(v, 'login').column, 'verify');
});

test('build: two lanes, agents matched to their tasks, results', () => {
  const P = (t) => `Plan: /p/specs/login/plan.md, task ${t}`;
  const events = [
    skill(0, 'build-feature', 'login'),
    launch(1, undefined, `${P('T1')}, lane A`), launch(1, undefined, `${P('T2')}, lane B`),
    start(1.1, 'laneA', 'general-purpose'), start(1.1, 'laneB', 'general-purpose'),
    // Both lanes launch an implementer before either starts: matched in order.
    launch(2, 'workez:implementer', P('T1'), { agent_id: 'laneA', agent_type: 'general-purpose' }),
    launch(2, 'workez:implementer', P('T2'), { agent_id: 'laneB', agent_type: 'general-purpose' }),
    start(2.1, 'impA', 'workez:implementer'), start(2.2, 'impB', 'workez:implementer'),
    stop(20, 'impA', 'workez:implementer'),
    launch(21, 'workez:code-reviewer', P('T1'), { agent_id: 'laneA', agent_type: 'general-purpose' }),
    start(21.1, 'revA', 'workez:code-reviewer'),
  ];
  const states = { login: buildState({ T1: { status: 'todo' }, T2: { status: 'todo' } }) };
  let s = snap({ events, states, plans: plan });
  const f = feat(s, 'login');
  assert.equal(f.column, null, 'the feature is the row; its tasks are the cards');
  assert.equal(task(s, 'login', 'T1').column, 'review');
  assert.equal(task(s, 'login', 'T1').since, at(21));
  assert.deepEqual(task(s, 'login', 'T1').agent, { type: 'code-reviewer', model: 'opus' });
  assert.equal(task(s, 'login', 'T1').reviews, 1);
  assert.equal(task(s, 'login', 'T1').title, 'Form');
  assert.equal(task(s, 'login', 'T1').lane, 'A');
  assert.equal(task(s, 'login', 'T2').column, 'implement');
  assert.deepEqual(task(s, 'login', 'T2').agent, { type: 'implementer', model: 'sonnet' });

  // A permission prompt inside T2's implementer waits on you, until T2's next event.
  events.push(ev(30, { hook: 'Notification', agent_id: 'impB', agent_type: 'workez:implementer',
    detail: { type: 'permission_prompt', message: 'Claude needs your permission to use Bash' } }));
  s = snap({ events, states, plans: plan });
  assert.equal(task(s, 'login', 'T2').status, 'waiting');
  assert.equal(task(s, 'login', 'T2').reason, 'Claude needs your permission to use Bash');
  assert.equal(task(s, 'login', 'T1').status, 'working');
  events.push(ev(31, { hook: 'PreToolUse', tool: 'Agent', agent_id: 'impB', detail: {} }));
  s = snap({ events, states, plans: plan });
  assert.equal(task(s, 'login', 'T2').status, 'working');

  // The lanes return: T1 PR_READY, T2 BLOCKED.
  events.push(stop(40, 'revA', 'workez:code-reviewer'), stop(41, 'laneA', 'general-purpose', 'PR_READY /p/.claude/workflow/login/pr-T1.md'),
    stop(42, 'impB', 'workez:implementer'), stop(43, 'laneB', 'general-purpose', 'BLOCKED tests fail on main'));
  s = snap({ events, states, plans: plan });
  assert.equal(task(s, 'login', 'T1').column, 'pr_open');
  assert.equal(task(s, 'login', 'T1').status, 'working');
  assert.equal(task(s, 'login', 'T1').agent, null);
  assert.equal(task(s, 'login', 'T2').status, 'error');
  assert.equal(task(s, 'login', 'T2').reason, 'BLOCKED: tests fail on main');
  assert.equal(task(s, 'login', 'T2').column, 'implement', 'an error keeps the card where it failed');
});

test('build: state PR states; todo in a newer state never moves a running task back', () => {
  const events = [launch(5, undefined, 'Plan /p/specs/login/plan.md T2 lane B'), start(5.1, 'laneB', 'general-purpose'),
    launch(6, 'workez:implementer', 'Plan /p/specs/login/plan.md T2', { agent_id: 'laneB' }), start(6.1, 'impB', 'workez:implementer')];
  const states = { login: { ...buildState({ T1: { status: 'waiting', pr: 31 }, T2: { status: 'todo' } }), mtime: at(50) } };
  const s = snap({ events, states, plans: plan });
  assert.equal(task(s, 'login', 'T1').column, 'pr_open');
  assert.equal(task(s, 'login', 'T1').status, 'waiting');
  assert.equal(task(s, 'login', 'T1').reason, 'review and merge PR #31');
  assert.equal(task(s, 'login', 'T2').column, 'implement');
  assert.deepEqual(s.waiting, [{ feature: 'login', task: 'T1', reason: 'review and merge PR #31', gate: true }]);

  const merged = snap({ states: { login: buildState({ T1: { status: 'done', pr: 31 }, T2: { status: 'closed', pr: 32 } }, 'blocked') }, plans: plan });
  assert.equal(task(merged, 'login', 'T1').column, 'done');
  assert.equal(task(merged, 'login', 'T2').status, 'error');
  assert.equal(task(merged, 'login', 'T2').reason, 'PR #32 closed without merge');
  assert.equal(feat(merged, 'login').status, 'error');
});

test('waiting overlays: a stopped session, a kept state reason, an ended session', () => {
  const states = { login: { state: { feature: 'login', phase: 'plan', status: 'done', handed_off: true }, mtime: at(0) } };
  let s = snap({ events: [skill(1, 'design-feature', 'login'), ev(20, { hook: 'Stop' })], states });
  assert.equal(feat(s, 'login').status, 'waiting');
  assert.equal(feat(s, 'login').reason, 'Claude stopped: your turn');
  assert.equal(feat(s, 'login').gate, false, 'a stopped session is not a workflow gate');

  s = snap({ events: [skill(1, 'design-feature', 'login'), ev(20, { hook: 'Stop' }), ev(25, { hook: 'UserPromptSubmit' })], states });
  assert.equal(feat(s, 'login').status, 'working');

  const waitingReview = { login: buildState({}, 'waiting_review') };
  s = snap({ events: [skill(1, 'build-feature', 'login'), ev(20, { hook: 'Stop' })], states: waitingReview });
  assert.equal(feat(s, 'login').reason, 'review and merge the open task PRs');
  assert.equal(feat(s, 'login').gate, true, 'waiting for the PR merges is a workflow gate');

  s = snap({ events: [skill(1, 'design-feature', 'login'), ev(20, { hook: 'SessionEnd', detail: { reason: 'logout' } })], states });
  assert.equal(feat(s, 'login').status, 'idle');
  assert.equal(feat(s, 'login').reason, 'session ended');
});

test('quiet: working with no event and no transcript write for quiet_after_min', () => {
  const states = { login: { state: { feature: 'login', phase: 'plan', status: 'done', handed_off: true }, mtime: at(0) } };
  const events = [skill(70, 'design-feature', 'login')];
  assert.equal(feat(snap({ events, states }), 'login').quiet, true, '30 minutes without a sign');
  assert.equal(feat(snap({ events, states, mtimes: { '/t/s1.jsonl': at(95) } }), 'login').quiet, false, 'the transcript moved');
  assert.equal(feat(snap({ events: [skill(95, 'design-feature', 'login')], states }), 'login').quiet, false);
  assert.deepEqual(transcriptPaths([start(1, 'a1', 'x')]).sort(), ['/t/s1.jsonl', '/t/s1/subagents/agent-a1.jsonl']);
});

test('unnamed cards disappear after hide_idle_after_hours without activity', () => {
  const s = buildSnapshot({ config, now: at(25 * 60), events: [skill(0, 'build-task', 'add a toggle'), ev(1, { hook: 'SessionEnd' })] });
  assert.equal(s.features.length, 0);
});

test('build-task: a task run shows its T1 card until done', () => {
  const states = { 'dark-toggle': { state: { feature: 'dark-toggle', phase: 'task', status: 'waiting_review', handed_off: true,
    tasks: { T1: { status: 'waiting', pr: 40 } } }, mtime: at(3) } };
  const s = snap({ states, plans: { 'dark-toggle': [{ id: 'T1', title: 'Toggle', wave: null, lane: 'A', issue: '#9' }] } });
  const f = feat(s, 'dark-toggle');
  assert.equal(f.kind, 'task');
  assert.equal(f.tasks[0].column, 'pr_open');
  const done = snap({ states: { 'dark-toggle': { state: { feature: 'dark-toggle', phase: 'task', status: 'done' }, mtime: at(3) } } });
  assert.equal(feat(done, 'dark-toggle').column, 'done');
});

test('features waiting on you come first; bad events are ignored', () => {
  const s = snap({ events: [null, 'x', { ts: 'no' }, { v: 1, ts: at(1), hook: 'Weird' }], states: {
    a: { state: { feature: 'a', phase: 'build', status: 'in_progress', handed_off: true }, mtime: at(1) },
    b: { state: { feature: 'b', phase: 'verify', status: 'waiting_merge', handed_off: true }, mtime: at(1) },
  } });
  assert.deepEqual(s.features.map((f) => f.name), ['b', 'a']);
  assert.deepEqual(s.columns.map((c) => c.id), config.columns.map((c) => c.id));
});

test('mergeConfig: steps merge by id, columns replace the list', () => {
  const m = mergeConfig(config, { quiet_after_min: 3, steps: { review: { agents: ['my:reviewer'] } },
    columns: [{ id: 'build', title: 'Build', steps: ['todo', 'implement', 'review', 'ui_check'] }] });
  assert.equal(m.quiet_after_min, 3);
  assert.deepEqual(m.steps.review, { level: 'task', agents: ['my:reviewer'] });
  assert.equal(m.steps.implement.level, 'task');
  assert.equal(m.columns.length, 1);
  assert.equal(mergeConfig(config, null), config);
  const s = buildSnapshot({ config: m, now: at(100), events: [launch(1, 'my:reviewer', 'Plan /p/specs/login/plan.md T1')],
    states: { login: buildState({ T1: { status: 'todo' } }) } });
  assert.equal(task(s, 'login', 'T1').column, 'build');
});

test('parsePlan reads waves, tasks, lanes and issues', () => {
  const md = ['# Plan: login', 'Status: approved.', '## Wave 1', '## T1: Login form', '- **Lane**: A', '- **Issue**: #11',
    '- **Branch**: `feat/11-form`', '## T2: API', '- **Lane**: B', '## Wave 2', '## T3: Glue', '- **Lane**: A (solo)', '## Test plan', '- **Lane**: X'].join('\n');
  assert.deepEqual(parsePlan(md), [
    { id: 'T1', title: 'Login form', wave: 1, lane: 'A', issue: '#11' },
    { id: 'T2', title: 'API', wave: 1, lane: 'B', issue: null },
    { id: 'T3', title: 'Glue', wave: 2, lane: 'A (solo)', issue: null },
  ]);
  assert.deepEqual(parsePlan(null), []);
});
