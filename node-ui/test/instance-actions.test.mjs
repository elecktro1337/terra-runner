import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceActionPlan } from '../lib/instance-actions.mjs';

test('terminal instances expose only safe record actions', () => {
  const actions = instanceActionPlan({ state: 'stopped' }, { canFinalize: true });
  assert.deepEqual(actions.map(action => action.value), ['remove', 'refresh']);
  assert.equal(actions.some(action => action.value === 'stop' || action.value === 'abort' || action.value === 'finalize'), false);
});

test('active instances retain controls and expose finalization only when actionable', () => {
  assert.deepEqual(instanceActionPlan({ state: 'running' }).map(action => action.value), ['stop', 'abort', 'refresh']);
  assert.deepEqual(instanceActionPlan({ state: 'aborting' }, { canFinalize: true }).map(action => action.value), ['stop', 'abort', 'finalize', 'refresh']);
});
