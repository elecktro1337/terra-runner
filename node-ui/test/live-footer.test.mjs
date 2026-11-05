import test from 'node:test';
import assert from 'node:assert/strict';
import { footerRows, LiveFooter, LiveStatusBlock, liveStatusRows } from '../lib/live-footer.mjs';

test('formats one pinned controls row and a separate status block', () => {
  assert.deepEqual(footerRows('Controls: [S] stop'), ['  Controls: [S] stop']);
  assert.deepEqual(liveStatusRows('Preparing iteration', 'Waiting for runner events…'), [
    '  Preparing iteration', '  Waiting for runner events…'
  ]);
});

test('keeps completed iteration history below the changing live status', () => {
  assert.deepEqual(liveStatusRows('Iteration 3 | tools', '', ['✓ Iteration 1 complete', '✓ Iteration 2 complete']), [
    '  Iteration 3 | tools', '  Waiting for runner events…', '  ✓ Iteration 1 complete', '  ✓ Iteration 2 complete'
  ]);
});

test('keeps the current task visible while the status changes to a graceful stop', () => {
  assert.deepEqual(liveStatusRows('Finishing current iteration — stop requested', 'Task: NTD-0010'), [
    '  Finishing current iteration — stop requested', '  Task: NTD-0010'
  ]);
});

test('footer clears its former row before drawing at a resized terminal bottom', () => {
  let written = '';
  const stream = { isTTY: true, rows: 24, write(value) { written += value; return true; } };
  const footer = new LiveFooter(stream, 'Controls: [S] stop');
  footer.render();
  assert.equal(footer.lastRow, 23);
  const cleared = [];
  const original = footer.clearRowsAt.bind(footer);
  footer.clearRowsAt = (row, count) => { cleared.push([row, count]); return original(row, count); };
  stream.rows = 40;
  footer.render();
  assert.deepEqual(cleared, [[23, 1]]);
  assert.equal(footer.lastRow, 39);
  assert.match(written, /Controls: \[S\] stop/);
});

test('status block stays below the header and clears without writing normal output', () => {
  let written = '';
  const stream = { isTTY: true, rows: 30, write(value) { written += value; return true; } };
  const status = new LiveStatusBlock(stream, 11);
  status.render('Iteration 1 | task', '✓ Previous iteration complete');
  assert.equal(status.lastRow, 11);
  assert.match(written, /Iteration 1 \| task/);
  assert.match(written, /Previous iteration complete/);
  status.clear();
  assert.equal(status.visible, false);
});

test('does not emit cursor commands for a non-interactive stream', () => {
  let written = '';
  const stream = { isTTY: false, rows: 24, write(value) { written += value; } };
  const footer = new LiveFooter(stream, 'Controls');
  const status = new LiveStatusBlock(stream, 8);
  footer.render(); status.render('status', 'detail'); footer.clear(); status.clear();
  assert.equal(written, '');
});
