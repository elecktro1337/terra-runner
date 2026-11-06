import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceActivityText, instanceDurationText } from '../lib/instance-display.mjs';

test('formats instance heartbeat seconds as compact minutes and seconds', () => {
  assert.equal(instanceDurationText(900), '15m 00s');
  assert.equal(instanceActivityText('Iteration 1: 900s'), 'Iteration 1: 15m 00s');
  assert.equal(instanceActivityText('Iteration 2: 200s'), 'Iteration 2: 3m 20s');
});

test('continues an active iteration duration from its persisted start time', () => {
  const now = Date.parse('2026-11-07T12:00:00.000Z');
  assert.equal(instanceActivityText({ activity: 'Iteration 23: 200s', iterationStartedAt: '2026-11-07T11:55:00.000Z', updatedAt: '2026-11-07T11:58:20.000Z' }, now), 'Iteration 23: 5m 00s');
  assert.equal(instanceActivityText({ activity: 'Iteration 11: 880s', updatedAt: '2026-11-07T11:59:40.000Z' }, now), 'Iteration 11: 15m 00s');
});

test('preserves non-heartbeat instance activity text', () => {
  assert.equal(instanceActivityText('Opening project terminal'), 'Opening project terminal');
});
