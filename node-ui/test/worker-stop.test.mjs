import test from 'node:test';
import assert from 'node:assert/strict';
import { isCleanWorkerStopEventStream } from '../lib/worker-stop.mjs';

test('recognises OpenCode terminal stop independently of its process exit code', () => {
  assert.equal(isCleanWorkerStopEventStream('{"type":"text","part":{"text":"done"}}\n{"type":"step_finish","part":{"reason":"stop"}}\n'), true);
});

test('does not normalise an event stream with an OpenCode error', () => {
  assert.equal(isCleanWorkerStopEventStream('{"type":"error","error":{"message":"provider failure"}}\n{"type":"step_finish","part":{"reason":"stop"}}\n'), false);
});

test('does not normalise malformed or non-stop event streams', () => {
  assert.equal(isCleanWorkerStopEventStream('{not json}'), false);
  assert.equal(isCleanWorkerStopEventStream('{"type":"step_finish","part":{"reason":"tool-calls"}}'), false);
});
