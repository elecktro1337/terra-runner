import test from 'node:test';
import assert from 'node:assert/strict';
import { developmentHeaderRows, profileSnapshotSummary } from '../lib/run-display.mjs';

const project = { id: 'example-project' };

test('formats complete API run context with snapshot and cost state', () => {
  const profile = { policy: 'api', model: 'openai/gpt', credentialLabel: 'OpenAI (API)', reasoningVariant: 'high', limits: { mode: 'daily' }, usageSource: { unit: 'usd', remaining: 12.5, observedAt: '2026-11-05T09:00:00.000Z', costTracking: { enabled: true } } };
  const rows = developmentHeaderRows({ project, profile, command: 'Run continuously', limitText: 'Daily cap $5', now: Date.parse('2026-11-05T09:30:00.000Z') });
  assert.match(rows.join('\n'), /Project   example-project/);
  assert.match(rows.join('\n'), /OpenAI \(API\)/);
  assert.match(rows.join('\n'), /openai\/gpt/);
  assert.match(rows.join('\n'), /12.5 USD.*30 min ago/);
  assert.match(rows.join('\n'), /Daily cap \$5/);
  assert.match(rows.join('\n'), /local cost estimate enabled/);
});

test('formats OAuth and local context without API budget assumptions', () => {
  const oauth = developmentHeaderRows({ project, profile: { policy: 'oauth-managed', model: 'openai/gpt', credentialLabel: 'OpenAI OAuth', usageSource: { unit: 'percent', remaining: 71, observedAt: '' } }, command: 'Dry run' }).join('\n');
  const local = developmentHeaderRows({ project, profile: { policy: 'local', model: 'ollama/qwen', usageSource: {} }, command: 'One iteration' }).join('\n');
  assert.match(oauth, /Limits    provider-managed/);
  assert.match(oauth, /71 %/);
  assert.match(local, /Snapshot  not applicable/);
  assert.match(local, /Limits    not applicable/);
  assert.deepEqual(profileSnapshotSummary({ policy: 'local' }), { value: 'not applicable', age: '' });
});
