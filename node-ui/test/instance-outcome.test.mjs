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
  const failed = instanceOutcome({ state: 'failed', stopReason: 'runner exit 1', error: 'Git working tree has uncommitted changes.' });
  assert.equal(failed.reason, 'Git working tree has uncommitted changes.');
});

test('labels no-roadmap-progress as a safety stop instead of normal completion', () => {
  const outcome = instanceOutcome(
    { state: 'finished' },
    { stoppedReason: 'no-roadmap-progress: 3 consecutive iteration(s) completed no roadmap task' },
    { available: true, completed: 12, pending: 3, total: 15 }
  );
  assert.equal(outcome.kind, 'stopped');
  assert.match(outcome.reason, /^Safety stop — 3 consecutive iteration/);
});

test('explains a safety stop only after roadmap and implementation progress are both absent', () => {
  const outcome = instanceOutcome(
    { state: 'stopped', stopReason: 'no-verified-implementation-progress: 3 consecutive iteration(s) made no roadmap, code, or test progress' },
    { stoppedReason: 'no-verified-implementation-progress: 3 consecutive iteration(s) made no roadmap, code, or test progress' },
    { available: true, completed: 3, pending: 2, total: 5 }
  );
  assert.match(outcome.reason, /^Safety stop — 3 consecutive iteration\(s\) made no roadmap, code, or test progress/);
});
