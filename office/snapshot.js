#!/usr/bin/env node
'use strict';
// Prints the office board of a project as text (or the snapshot as JSON). Read-only; never calls a model.
//   node office/snapshot.js [--project <dir>] [--json]
// The project is the nearest folder at or above the current one with .claude/workflow.json.

const { findProject, snapshot } = require('./load');

function ago(ms, now) {
  if (!ms) return '';
  const m = Math.max(0, Math.round((now - ms) / 60000));
  return m < 60 ? `${m}m` : m < 1440 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}` : `${Math.floor(m / 1440)}d`;
}

const MARK = { working: '●', waiting: '!', done: '✓', error: '✗', idle: '·' };

// One card as a line: mark, status, column, agent, time in step, reason.
function cardLine(c, cols, now) {
  const col = c.column ? cols[c.column] || c.column : '-';
  const agent = c.agent ? `${c.agent.type}${c.agent.model ? `·${c.agent.model}` : ''}` : '';
  const status = c.quiet ? `${c.status} (quiet)` : c.status;
  return [`${MARK[c.status] || '?'} ${status}`.padEnd(18), col.padEnd(10), agent.padEnd(22), ago(c.since, now).padEnd(6), c.reason || '']
    .join(' ').trimEnd();
}

function render(s) {
  const cols = Object.fromEntries(s.columns.map((c) => [c.id, c.title]));
  const out = [];
  if (!s.features.length) out.push('Nothing on the board yet.');
  for (const f of s.features) {
    const name = f.name || `(new ${f.skill ? f.skill.replace(/^workez:/, '') : 'feature'}, session ${String(f.session).slice(0, 8)})`;
    const phase = f.phase ? `${f.phase} / ${f.state_status}` : f.step || '';
    out.push(`${name}  ${phase}${f.wave != null ? `  wave ${f.wave}` : ''}`);
    if (!f.tasks.length || f.status !== 'working') out.push(`  ${''.padEnd(6)}${cardLine(f, cols, s.generated)}`);
    for (const t of f.tasks) {
      const label = `${t.id}${t.lane ? `/${t.lane}` : ''}`.padEnd(6);
      const extra = [t.title, t.pr ? `PR #${t.pr}` : null, t.reviews ? `${t.reviews} review${t.reviews > 1 ? 's' : ''}` : null]
        .filter(Boolean).join(' · ');
      out.push(`  ${label}${cardLine(t, cols, s.generated)}${extra ? `  [${extra}]` : ''}`);
    }
    out.push('');
  }
  out.push(s.waiting.length
    ? `Waiting on you: ${s.waiting.map((w) => `${w.feature || 'new feature'}${w.task ? ` ${w.task}` : ''} (${w.reason})`).join('; ')}`
    : 'Nothing waits on you.');
  return out.join('\n');
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const at = args.indexOf('--project');
  const project = at >= 0 ? args[at + 1] : findProject(process.cwd());
  if (!project) {
    console.error('office: no .claude/workflow.json here or above (use --project <dir>)');
    process.exit(2);
  }
  const s = snapshot(project);
  console.log(args.includes('--json') ? JSON.stringify(s, null, 2) : render(s));
}

module.exports = { render };
