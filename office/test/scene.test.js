'use strict';
// Unit tests of the office scene (office/ui/scene.js): where each card stands, the Build bays, what it holds.
const test = require('node:test');
const assert = require('node:assert/strict');
const { sceneOf, placeOfFeature, placeOfTask, productOf } = require('../ui/scene');
const { frames } = require('../demo');

const NOW = 1_800_000_000_000;
const byTitle = (s, t) => s.chars.find((c) => c.tip.title === t);

test('a feature stands in the room of its step; approvals and merges go to your office', () => {
  assert.equal(placeOfFeature({ step: 'intent', status: 'working' }), 'intent');
  assert.equal(placeOfFeature({ step: 'spec', status: 'working' }), 'spec');
  assert.equal(placeOfFeature({ step: 'plan', status: 'waiting', gate: true, reason: 'approve the plan' }), 'you');
  assert.equal(placeOfFeature({ step: 'spec', status: 'waiting', gate: false, reason: 'Approve the spec?' }), 'you', 'an approval question');
  assert.equal(placeOfFeature({ step: 'spec', status: 'waiting', gate: false, reason: 'Claude needs your permission to use Bash' }), 'spec', 'a permission prompt stays');
  assert.equal(placeOfFeature({ step: 'verify', status: 'working', agent: { type: 'e2e-verifier' } }), 'e2e');
  assert.equal(placeOfFeature({ step: 'verify', status: 'working', agent: { type: 'code-reviewer' } }), 'vreview');
  assert.equal(placeOfFeature({ step: 'verify', status: 'working', agent: null }), 'checks');
  assert.equal(placeOfFeature({ step: 'done', status: 'done' }), 'done');
});

test('a task stands at its lane station; a PR to merge goes to your office', () => {
  assert.equal(placeOfTask({ step: 'todo', status: 'idle' }), 'queue');
  assert.equal(placeOfTask({ step: 'review', status: 'working' }), 'review');
  assert.equal(placeOfTask({ step: 'implement', status: 'error' }), 'implement', 'an error stays where it failed');
  assert.equal(placeOfTask({ step: 'pr_open', status: 'working' }), 'pr');
  assert.equal(placeOfTask({ step: 'pr_open', status: 'waiting', gate: true, reason: 'review and merge PR #31' }), 'you');
  assert.equal(placeOfTask({ step: 'pr_open', status: 'done' }), 'done');
});

test('the product each agent holds', () => {
  assert.equal(productOf({ place: 'intent' }).name, 'intent.md');
  assert.equal(productOf({ place: 'review' }).label, 'DIFF');
  assert.equal(productOf({ place: 'you', reason: 'review and merge PR #31' }).sub, '#31');
  assert.equal(productOf({ place: 'you', reason: 'verify passed: merge the final PR' }).sub, 'final');
  assert.equal(productOf({ place: 'you', reason: 'verify failed: approve plan-fix.md' }).name, 'plan-fix.md');
  assert.equal(productOf({ place: 'you', reason: 'approve the plan' }).name, 'plan.md');
});

test('Build: one bay per feature, the limit, stable bays, the hall grows', () => {
  const snap = frames(NOW)[0];
  const one = sceneOf(snap, { now: NOW, bayLimit: 1 });
  assert.deepEqual(one.building, ['login-page', 'billing-export', 'team-invites']);
  assert.equal(one.bays.length, 1);
  assert.equal(one.hidden.length, 2);
  assert.ok(!one.chars.some((c) => one.hidden.includes(c.feature) && ['queue', 'implement', 'review', 'ui_check', 'pr'].includes(c.place)),
    'tasks of a bay not shown are not drawn');
  assert.ok(one.waiting.length >= 3, 'the alert still lists every feature');

  const three = sceneOf(snap, { now: NOW, bayLimit: 3 });
  assert.equal(three.bays.length, 3);
  assert.ok(three.H > one.H, 'the hall grows with the bays');
  const t1 = byTitle(three, 'login-page · T1'), t2 = byTitle(three, 'login-page · T2');
  assert.ok(t2.y > t1.y, 'lane B is under lane A');

  const kept = sceneOf(frames(NOW)[1], { now: NOW, bayLimit: 1, prefer: ['login-page'] });
  assert.deepEqual(kept.bays, ['login-page'], 'a shown bay keeps its place');
});

test('two brainstorms in Plan sit side by side, each with its chat bubbles', () => {
  const s = sceneOf(frames(NOW)[0], { now: NOW, bayLimit: 1 });
  const plan = s.chars.filter((c) => c.place === 'intent');
  assert.equal(plan.length, 2);
  assert.notEqual(plan[0].x, plan[1].x);
  assert.ok(plan.every((c) => c.chat));
});

test('an empty snapshot draws the empty office', () => {
  const s = sceneOf({ features: [], waiting: [] }, { now: NOW });
  assert.equal(s.chars.length, 0);
  assert.equal(s.rooms.length, 8);
  assert.equal(s.H, 790 + 10);
});
