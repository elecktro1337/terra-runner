import test from 'node:test';
import assert from 'node:assert/strict';
import { developmentHeaderRows, elapsedSecondsSince, profileSnapshotSummary } from '../lib/run-display.mjs';

const project = { id: 'example-project' };

test('formats complete API run context with snapshot and cost state', () => {
  const profile = { policy: 'api', model: 'openai/gpt', credentialLabel: 'OpenAI (API)', reasoningVariant: 'high', limits: { mode: 'daily' }, usageSource: { unit: 'usd', remaining: 12.5, observedAt: '2026-11-05T09:00:00.000Z', costTracking: { enabled: true } } };
  const rows = developmentHeaderRows({ project, profile, command: 'Run continuously', roadmap: { available: true, completed: 12, pending: 4, total: 16 }, limitText: 'Daily cap $5', now: Date.parse('2026-11-05T09:30:00.000Z') });
  assert.match(rows.join('\n'), /Project   example-project/);
  assert.match(rows.join('\n'), /Roadmap   12\/16 complete.*4 pending/);
  assert.match(rows.join('\n'), /75\.0%/);
  assert.match(rows.join('\n'), /OpenAI \(API\)/);
  assert.match(rows.join('\n'), /openai\/gpt/);
  assert.match(rows.join('\n'), /12.5 USD.*30 min ago/);
  assert.match(rows.join('\n'), /Daily cap \$5/);
  assert.match(rows.join('\n'), /local cost estimate enabled/);
  assert.match(rows.join('\n'), /Profile.*openai\/gpt/);
  assert.match(rows.join('\n'), /Reasoning high/);
  assert.equal(rows.length, 4);
});

test('formats OAuth and local context without API budget assumptions', () => {
  const oauth = developmentHeaderRows({ project, profile: { policy: 'oauth-managed', model: 'openai/gpt', credentialLabel: 'OpenAI OAuth', usageSource: { unit: 'percent', remaining: 71, observedAt: '' } }, command: 'Dry run' }).join('\n');
  const local = developmentHeaderRows({ project, profile: { policy: 'local', model: 'ollama/qwen', usageSource: {} }, command: 'One iteration' }).join('\n');
  assert.match(oauth, /Limits  provider-managed/);
  assert.match(oauth, /71 %/);
  assert.match(local, /Snapshot  not applicable/);
  assert.match(local, /Limits  not applicable/);
  assert.deepEqual(profileSnapshotSummary({ policy: 'local' }), { value: 'not applicable', age: '' });
});

test('omits Terra-only snapshot and limit fields for a dispatcher instance', () => {
  const rows = developmentHeaderRows({ project, profile: { policy: 'api', model: 'openai/gpt', credentialLabel: 'OpenAI (API)', reasoningVariant: 'medium', usageSource: { remaining: 50 } }, command: 'One iteration', roadmap: { available: true, completed: 2, pending: 3, total: 5 }, includeTerraLimits: false }).join('\n');
  assert.match(rows, /40\.0%/);
  assert.match(rows, /OpenAI \(API\).*openai\/gpt.*Reasoning medium/);
  assert.doesNotMatch(rows, /Snapshot|Limits|OpenCode/);
});

test('includes live run duration, last task, and last commit when supplied', () => {
  const rows = developmentHeaderRows({ project, profile: { policy: 'local', model: 'local/test' }, command: 'Run continuously', run: { elapsedSeconds: 367, lastTask: 'NTD-0146', lastCommit: { hash: 'abc123456789def', subject: 'feat(checkin): issue confirmation token' } } }).join('\n');
  assert.match(rows, /Run\s+6m 07s/);
  assert.match(rows, /Last task\s+NTD-0146/);
  assert.match(rows, /Last commit\s+abc123456789.*issue confirmation token/);
});

test('formats a long live run with hours, minutes, and seconds', () => {
  const rows = developmentHeaderRows({ project: { id: 'project-a' }, profile: {}, command: 'Continuous', roadmap: {}, includeTerraLimits: false, run: { elapsedSeconds: 4476, lastTask: '', lastCommit: null } });
  assert.match(rows.at(-1), /1h 14m 36s/);
});

test('calculates elapsed live-run time from persisted ISO timestamps', () => {
  const now = Date.parse('2026-11-06T12:05:07.000Z');
  assert.equal(elapsedSecondsSince('2026-11-06T12:00:00.000Z', now), 307);
  assert.equal(elapsedSecondsSince(now - 61_000, now), 61);
  assert.equal(elapsedSecondsSince('not-a-date', now), 0);
});
