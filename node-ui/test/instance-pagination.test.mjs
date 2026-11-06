import test from 'node:test';
import assert from 'node:assert/strict';
import { instancePage } from '../lib/instance-pagination.mjs';

test('paginates instance records and clamps a stale page after cleanup', () => {
  const records = Array.from({ length: 18 }, (_, index) => ({ id: index + 1 }));
  const first = instancePage(records, 0);
  assert.deepEqual(first.items.map(item => item.id), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual({ page: first.page, pageCount: first.pageCount, first: first.first, last: first.last, total: first.total }, { page: 0, pageCount: 3, first: 1, last: 8, total: 18 });
  const last = instancePage(records, 99);
  assert.deepEqual(last.items.map(item => item.id), [17, 18]);
  assert.equal(last.page, 2);
  assert.equal(instancePage([], 4).page, 0);
});
