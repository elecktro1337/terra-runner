import test from 'node:test';
import assert from 'node:assert/strict';
import { completedIterationText } from '../lib/iteration-history.mjs';

test('summarizes a completed iteration with task, duration, and commit without pending counters', () => {
  const text = completedIterationText({
    iteration: 1, completedTaskIds: ['NTD-0010'], taskId: 'NTD-0010',
    taskTitle: '**NTD-0010 [P0]** - Implement fiscalisation endpoint and tests.',
    elapsedSeconds: 251, pending: 117, commits: [{ hash: '1234567890abcdef', subject: 'feat: fiscalisation' }]
  });
  assert.match(text, /^Iteration 1 · NTD-0010 — \[P0\] - Implement fiscalisation/);
  assert.match(text, /· 4m 11s · commit 1234567890ab$/);
  assert.doesNotMatch(text, /pending|\+1 task/);
});

test('uses safe fallbacks when an iteration makes no commit or task progress', () => {
  assert.equal(completedIterationText({ iteration: 2, elapsedSeconds: 3 }), 'Iteration 2 · no completed task · 0m 03s · no commit');
});
