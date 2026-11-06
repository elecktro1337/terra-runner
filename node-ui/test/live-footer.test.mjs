import test from 'node:test';
import assert from 'node:assert/strict';
import { footerRows, LiveFooter, LiveStatusBlock, liveStatusRows } from '../lib/live-footer.mjs';

test('formats one pinned controls row and a separate status block', () => {
  assert.deepEqual(footerRows('Controls: [S] stop'), ['  Controls: [S] stop']);
  assert.deepEqual(liveStatusRows('Preparing iteration'), ['  Preparing iteration']);
  assert.deepEqual(liveStatusRows('Iteration 3 | NTD-0085 | Updating project files', 'Retry 1; next check in 30s'), [
    '  Iteration 3 | NTD-0085 | Updating project files  │  Retry 1; next check in 30s'
  ]);
});

test('keeps completed iteration history below the changing live status', () => {
  assert.deepEqual(liveStatusRows('Iteration 3 | tools', '', ['✓ Iteration 1 complete', '✓ Iteration 2 complete']), [
    '  Iteration 3 | tools', '  ✓ Iteration 1 complete', '  ✓ Iteration 2 complete'
  ]);
});

test('keeps the current task in the main status and pins a separate graceful-stop notice', () => {
  assert.deepEqual(liveStatusRows('Iteration 3 | NTD-0010 | Running verification', '', [], '! Stop requested. The current iteration will finish.'), [
    '  Iteration 3 | NTD-0010 | Running verification', '  ! Stop requested. The current iteration will finish.'
  ]);
});

test('reserves a visible row for a control notice before iteration history', () => {
  let written = '';
  const stream = { isTTY: true, rows: 16, write(value) { written += value; return true; } };
  const status = new LiveStatusBlock(stream, 10);
  status.render('Iteration 3 | ERP-0001 | tools', '', ['✓ Iteration 1', '✓ Iteration 2'], '! Stop requested.');
  assert.match(written, /Iteration 3 \| ERP-0001 \| tools/);
  assert.match(written, /! Stop requested\./);
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

test('status block keeps its changing details on one row and clears without writing normal output', () => {
  let written = '';
  const stream = { isTTY: true, rows: 30, write(value) { written += value; return true; } };
  const status = new LiveStatusBlock(stream, 11);
  status.render('Iteration 1 | task', '✓ Previous iteration complete');
  assert.equal(status.lastRow, 11);
  assert.match(written, /Iteration 1 \| task/);
  assert.match(written, /Iteration 1 \| task  │  ✓ Previous iteration complete/);
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
