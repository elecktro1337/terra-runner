import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceOutcome } from '../lib/instance-outcome.mjs';

test('explains that a finished continuous instance completed its roadmap', () => {
  const outcome = instanceOutcome(
    { state: 'finished' },
    { completedTaskIds: ['NTD-0010'], elapsedSeconds: 251, commits: [{ hash: '1234567890abcdef', subject: 'feat: fiscalisation' }] },
    { available: true, completed: 241, pending: 0, total: 241 }
  );
  assert.equal(outcome.kind, 'complete');
  assert.match(outcome.reason, /Roadmap complete/);
  assert.equal(outcome.roadmap, '241/241 complete  |  0 pending  |  100.0%');
  assert.equal(outcome.task, 'NTD-0010');
  assert.equal(outcome.duration, '4m 11s');
  assert.equal(outcome.commit, '1234567890ab  feat: fiscalisation');
});

test('explains normal completion with remaining work and preserves failures', () => {
  const normal = instanceOutcome({ state: 'finished' }, null, { available: true, completed: 12, pending: 3, total: 15 });
  assert.match(normal.reason, /3 roadmap task/);
  const failed = instanceOutcome({ state: 'failed', error: 'runner exit 1' });
  assert.equal(failed.reason, 'runner exit 1');
});
