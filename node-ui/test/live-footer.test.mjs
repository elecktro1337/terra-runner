import test from 'node:test';
import assert from 'node:assert/strict';
import { footerRows, LiveFooter } from '../lib/live-footer.mjs';

test('formats stable status and controls rows', () => {
  assert.deepEqual(footerRows('Preparing iteration · 0m 09s', 'Controls: [S] stop'), [
    '  Preparing iteration · 0m 09s', '  Controls: [S] stop'
  ]);
});

test('renders and clears a footer only on a usable TTY', () => {
  let written = '';
  const stream = { isTTY: true, rows: 24, write(value) { written += value; return true; } };
  const footer = new LiveFooter(stream, 'Controls: [S] stop');
  footer.render('Preparing iteration'); footer.clear();
  assert.match(written, /Preparing iteration/);
  assert.match(written, /Controls: \[S\] stop/);
  assert.equal(footer.visible, false);
});

test('does not emit cursor commands for a non-interactive stream', () => {
  let written = '';
  const footer = new LiveFooter({ isTTY: false, rows: 24, write(value) { written += value; } }, 'Controls');
  footer.render('status'); footer.persist('checkpoint'); footer.clear();
  assert.equal(written, '\ncheckpoint\n');
});
