'use strict';
// Reads what the board needs from a project and the plugin, for model.js. Read-only; a missing or broken
// file is skipped, never an error.
//
//   findProject(start)        the nearest folder at or above start with .claude/workflow.json (not $HOME)
//   loadInputs(project, opts) {events, states, plans, config, mtimes, agentModels} for buildSnapshot
//   snapshot(project, opts)   buildSnapshot(loadInputs(...)) with now = opts.now || Date.now()

const fs = require('fs');
const path = require('path');
const os = require('os');
const { buildSnapshot, transcriptPaths, mergeConfig, parsePlan } = require('./model');

const PLUGIN = path.resolve(__dirname, '..');
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const readText = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { return null; } };
const mtimeOf = (f) => { try { return fs.statSync(f).mtimeMs; } catch { return null; } };
const list = (d) => { try { return fs.readdirSync(d); } catch { return []; } };

function findProject(start) {
  const home = path.resolve(os.homedir());
  let d = path.resolve(start || process.cwd());
  for (;;) {
    if (d !== home && fs.existsSync(path.join(d, '.claude', 'workflow.json'))) return d;
    const up = path.dirname(d);
    if (up === d) return null;
    d = up;
  }
}

// Events of the last maxAgeDays (by file modification time), every parsable line.
function readEvents(dir, maxAgeDays, now) {
  const events = [];
  for (const f of list(dir)) {
    if (!/^events-.*\.jsonl$/.test(f)) continue;
    const p = path.join(dir, f);
    const m = mtimeOf(p);
    if (m == null || now - m > maxAgeDays * 86400000) continue;
    for (const line of (readText(p) || '').split('\n')) {
      if (!line.trim()) continue;
      try { const e = JSON.parse(line); if (e && e.v === 1) events.push(e); } catch { /* a broken line is skipped */ }
    }
  }
  return events;
}

// The model of each plugin agent, from the "model:" line of agents/<name>.md.
function readAgentModels(dir) {
  const out = {};
  for (const f of list(dir)) {
    if (!f.endsWith('.md')) continue;
    const m = (readText(path.join(dir, f)) || '').match(/^---\n[\s\S]*?^model: *(\S+)[\s\S]*?^---/m);
    if (m) out[f.replace(/\.md$/, '')] = m[1];
  }
  return out;
}

function loadInputs(project, opts = {}) {
  const now = opts.now || Date.now();
  const wf = path.join(project, '.claude', 'workflow');
  const cfg = readJson(path.join(project, '.claude', 'workflow.json')) || {};
  const docs = path.join(project, typeof cfg.docs_dir === 'string' ? cfg.docs_dir : 'specs');

  const states = {}, plans = {};
  for (const name of list(wf)) {
    if (name === 'office') continue;
    const f = path.join(wf, name, 'state.json');
    const state = readJson(f);
    if (!state) continue;
    states[name] = { state, mtime: mtimeOf(f) };
    // A feature's plan (and fix plan) in docs_dir; a build-task's next to its state.
    const md = [path.join(docs, name, 'plan.md'), path.join(docs, name, 'plan-fix.md'), path.join(wf, name, 'plan.md')]
      .map(readText).filter(Boolean).join('\n');
    const tasks = parsePlan(md);
    if (tasks.length) plans[name] = tasks;
  }

  const events = readEvents(path.join(wf, 'office'), opts.maxAgeDays || 7, now);
  const mtimes = {};
  for (const p of transcriptPaths(events)) { const m = mtimeOf(p); if (m != null) mtimes[p] = m; }
  const config = mergeConfig(readJson(path.join(PLUGIN, 'office', 'board.json')) || {},
    readJson(path.join(project, '.claude', 'office.json')));
  return { events, states, plans, config, now, mtimes, agentModels: readAgentModels(path.join(PLUGIN, 'agents')) };
}

const snapshot = (project, opts) => buildSnapshot(loadInputs(project, opts));

module.exports = { findProject, loadInputs, snapshot, readEvents, readAgentModels };
