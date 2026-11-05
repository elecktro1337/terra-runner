import test from 'node:test';
import assert from 'node:assert/strict';
import { roadmapProgressFromText } from '../lib/roadmap.mjs';

test('counts the same markdown task forms the runner uses and exposes the next task', () => {
  const roadmap = roadmapProgressFromText('- [x] NTD-1 done\n- [ ] NTD-2 next\n- [ ] NTD-3 later');
  assert.deepEqual(roadmap, { available: true, completed: 1, pending: 2, total: 3, nextTask: 'NTD-2 next', error: '' });
});

test('limits roadmap counts to the configured task pattern', () => {
  const roadmap = roadmapProgressFromText('- [x] NTD-1 done\n- [ ] OTHER-2 ignored\n- [ ] NTD-3 next', 'NTD-\\d+');
  assert.equal(roadmap.completed, 1);
  assert.equal(roadmap.pending, 1);
  assert.equal(roadmap.nextTask, 'NTD-3 next');
});
