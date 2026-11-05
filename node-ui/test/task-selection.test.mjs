import test from 'node:test';
import assert from 'node:assert/strict';
import { selectedRoadmapTaskFromEvent } from '../lib/task-selection.mjs';

test('extracts the worker-selected roadmap task only from an explicit marker', () => {
  assert.equal(selectedRoadmapTaskFromEvent({ type: 'text', part: { text: 'TERRA_SELECTED_TASK: NTD-0145\nStarting implementation.' } }), 'NTD-0145');
  assert.equal(selectedRoadmapTaskFromEvent({ type: 'text', part: { text: 'Discussing ERP-0001 without selecting it.' } }), '');
  assert.equal(selectedRoadmapTaskFromEvent({ type: 'tool_use', part: { text: 'TERRA_SELECTED_TASK: ERP-0001' } }), '');
});
