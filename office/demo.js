'use strict';
// Scripted snapshots for `node office/server.js --demo`: several features at once, in every room, so the
// office page can be tried without a project. Same shape as office/model.js produces.

const MIN = 60000;

function frames(now = Date.now()) {
  const ago = (m) => now - m * MIN;
  const agent = (type, model) => ({ type, model });
  const task = (feature, id, o) => ({ key: `task:${feature}/${id}`, id, title: null, wave: 1, lane: 'A', issue: null, pr: null, reviews: 0,
    fix_rounds: 0, step: 'todo', column: null, status: 'idle', reason: null, gate: false, since: null, agent: null, quiet: false, active: null, ...o });
  const feature = (name, o) => ({ key: name ? `feature:${name}` : `pending:${o.session}`, name, kind: name ? 'feature' : 'pending', skill: null,
    session: o.session || null, phase: null, state_status: null, wave: null, fix_round: null, step: 'intent', column: null, status: 'working',
    reason: null, gate: false, since: ago(3), agent: null, quiet: false, active: ago(0), tasks: [], ...o });

  const base = () => [
    feature(null, { session: 'demo-1', skill: 'workez:plan-feature', step: 'intent', since: ago(3) }),
    feature('export-pdf', { skill: 'workez:plan-feature', step: 'intent', since: ago(1) }),
    feature('checkout-flow', { step: 'spec', status: 'waiting', reason: 'Approve the spec? 3 open questions', since: ago(6) }),
    feature('login-page', { step: 'build', phase: 'build', state_status: 'in_progress', wave: 1, since: ago(40), tasks: [
      task('login-page', 'T1', { title: 'Login form', issue: '#11', step: 'review', status: 'working', agent: agent('code-reviewer', 'opus'), reviews: 2, since: ago(12) }),
      task('login-page', 'T2', { title: 'Session API', lane: 'B', issue: '#12', step: 'implement', status: 'waiting', reason: 'Claude needs your permission to use Bash', agent: agent('implementer', 'sonnet'), since: ago(4) }),
      task('login-page', 'T3', { title: 'Remember me', wave: 2, issue: '#13', step: 'todo', status: 'idle' }),
    ] }),
    feature('billing-export', { step: 'build', phase: 'build', state_status: 'in_progress', wave: 1, since: ago(90), tasks: [
      task('billing-export', 'T1', { title: 'CSV export', issue: '#21', step: 'implement', status: 'error', reason: 'BLOCKED: tests fail on main', since: ago(41) }),
      task('billing-export', 'T2', { title: 'Export button', lane: 'B', issue: '#22', pr: 28, step: 'done', status: 'done', since: ago(60) }),
      task('billing-export', 'T3', { title: 'Export history', lane: 'B', issue: '#23', step: 'ui_check', status: 'working', agent: agent('ui-verifier', 'sonnet'), since: ago(6) }),
    ] }),
    feature('team-invites', { step: 'build', phase: 'build', state_status: 'in_progress', wave: 1, since: ago(15), tasks: [
      task('team-invites', 'T1', { title: 'Invite form', issue: '#61', step: 'implement', status: 'working', agent: agent('implementer', 'sonnet'), since: ago(9) }),
    ] }),
    feature('dark-toggle', { kind: 'task', step: 'build', phase: 'task', state_status: 'waiting_review', since: ago(125), tasks: [
      task('dark-toggle', 'T1', { title: 'Theme toggle', issue: '#39', pr: 40, step: 'pr_open', status: 'waiting', gate: true, reason: 'review and merge PR #40', since: ago(125) }),
    ] }),
    feature('search-filters', { step: 'verify', phase: 'verify', state_status: 'in_progress', agent: agent('e2e-verifier', 'sonnet'), quiet: true, since: ago(18) }),
    feature('fix-footer-typo', { kind: 'task', step: 'done', status: 'done', since: ago(1440) }),
  ];

  // Each frame changes a few cards, as the real events would.
  const edit = (fs, name, id, o) => {
    const f = fs.find((x) => x.name === name);
    Object.assign(id ? f.tasks.find((t) => t.id === id) : f, o);
    return fs;
  };
  const f1 = edit(edit(base(), 'login-page', 'T2', { status: 'working', reason: null }), 'login-page', 'T1', { step: 'ui_check', agent: agent('ui-verifier', 'sonnet'), since: ago(0) });
  let f2 = edit(base(), 'checkout-flow', null, { step: 'plan', status: 'working', reason: null, since: ago(0) });
  f2 = edit(edit(f2, 'login-page', 'T1', { step: 'pr_open', status: 'working', reason: 'opening the PR', agent: agent('lane', 'sonnet'), since: ago(0) }),
    'login-page', 'T2', { step: 'review', status: 'working', reason: null, agent: agent('code-reviewer', 'opus'), reviews: 1, since: ago(0) });
  let f3 = edit(base(), 'checkout-flow', null, { step: 'plan', status: 'waiting', gate: true, reason: 'approve the plan', since: ago(0) });
  f3 = edit(f3, 'login-page', 'T1', { step: 'pr_open', status: 'waiting', gate: true, pr: 31, reason: 'review and merge PR #31', since: ago(0) });
  f3 = edit(f3, 'search-filters', null, { status: 'waiting', gate: true, quiet: false, agent: null, reason: 'verify passed: merge the final PR', since: ago(0) });
  const f4 = edit(base(), 'checkout-flow', null, { step: 'issues', status: 'working', reason: null, agent: agent('github-ops', 'haiku'), since: ago(0) });

  return [base(), f1, f2, f3, f4].map((features) => ({
    version: 1, generated: now, columns: [], features,
    waiting: features.flatMap((f) => [
      ...(f.status === 'waiting' ? [{ feature: f.name, task: null, reason: f.reason, gate: f.gate }] : []),
      ...f.tasks.filter((t) => t.status === 'waiting').map((t) => ({ feature: f.name, task: t.id, reason: t.reason, gate: t.gate })),
    ]),
  }));
}

module.exports = { frames };
