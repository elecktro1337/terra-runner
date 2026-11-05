import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceActivityText, instanceDurationText } from '../lib/instance-display.mjs';

test('formats instance heartbeat seconds as compact minutes and seconds', () => {
  assert.equal(instanceDurationText(900), '15m 00s');
  assert.equal(instanceActivityText('Iteration 1: 900s'), 'Iteration 1: 15m 00s');
  assert.equal(instanceActivityText('Iteration 2: 200s'), 'Iteration 2: 3m 20s');
});

test('preserves non-heartbeat instance activity text', () => {
  assert.equal(instanceActivityText('Opening project terminal'), 'Opening project terminal');
});
