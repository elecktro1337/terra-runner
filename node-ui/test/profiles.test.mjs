import test from 'node:test';
import assert from 'node:assert/strict';
import { applyProfile, isLocalModel, migrateProfiles, policyFor, profileFrom, splitModelVariant } from '../lib/profiles.mjs';
import { activeProject, validateProjectId } from '../lib/projects.mjs';
import { projectDataRoot } from '../lib/reports.mjs';

test('recognizes local model providers', () => {
  assert.equal(isLocalModel('ollama/qwen3-coder-64k:30b'), true);
  assert.equal(isLocalModel('openai/gpt-5.6-terra'), false);
});
test('maps OAuth to provider-managed usage and API keys to spending limits', () => {
  assert.equal(policyFor('openai/gpt', { authMethod: 'oauth' }), 'oauth-managed');
  assert.equal(policyFor('openai/gpt', { authMethod: 'key' }), 'api');
});
test('keeps a reasoning variant out of the model identifier', () => {
  assert.deepEqual(splitModelVariant('openai/gpt-5.6-terra#medium'), { model: 'openai/gpt-5.6-terra', reasoningVariant: 'medium' });
  const profile = profileFrom('openai/gpt-5.6-terra#medium', { authMethod: 'key' }, 'medium');
  assert.equal(profile.model, 'openai/gpt-5.6-terra');
  assert.equal(profile.reasoningVariant, 'medium');
});
test('migrates a legacy selected OAuth account without a manual quota', () => {
  const settings = { model: 'openai/gpt', openCode: { activeAccountId: 'oauth', accounts: [{ id: 'oauth', authMethod: 'oauth', credentialId: 'c', label: 'Codex' }], reasoning: {} } };
  const profiles = migrateProfiles(settings);
  assert.equal(profiles[0].policy, 'oauth-managed');
  assert.equal(profiles[0].credentialId, 'c');
});
test('applying a local profile creates a local no-limit account', () => {
  const settings = { openCode: { accounts: [], profiles: [] } };
  const profile = profileFrom('ollama/qwen3-coder-64k:30b');
  settings.openCode.profiles.push(profile);
  applyProfile(settings, profile);
  assert.equal(settings.openCode.accounts[0].usageKind, 'local');
});
test('applying a cloud profile uses the unified snapshot policy', () => {
  const settings = { openCode: { accounts: [{ id: 'openai:c', provider: 'openai', credentialId: 'c', quota: { configured: true } }], profiles: [] } };
  const profile = profileFrom('openai/gpt-5.6-terra', { provider: 'openai', credentialId: 'c', label: 'Codex', authMethod: 'oauth' });
  settings.openCode.profiles.push(profile);
  applyProfile(settings, profile);
  assert.equal(settings.openCode.accounts[0].usageKind, 'quota');
  assert.equal(settings.openCode.accounts[0].quota.configured, false);
});
test('applies a configured percentage snapshot to the active account', () => {
  const settings = { openCode: { accounts: [{ id: 'openai:c', provider: 'openai', credentialId: 'c' }], profiles: [] } };
  const profile = profileFrom('openai/gpt', { provider: 'openai', credentialId: 'c', authMethod: 'key' });
  profile.usageSource = { kind: 'snapshot', unit: 'percent', remaining: 42, reserve: 5, maxAgeMinutes: 60, observedAt: '2026-11-04T12:00:00Z' };
  settings.openCode.profiles.push(profile); applyProfile(settings, profile);
  assert.equal(settings.openCode.accounts[0].quota.remaining, 42);
  assert.equal(settings.openCode.accounts[0].quota.configured, true);
});
test('preserves the optional local OpenCode cost-estimate baseline', () => {
  const settings = { openCode: { accounts: [{ id: 'openai:c', provider: 'openai', credentialId: 'c' }], profiles: [] } };
  const profile = profileFrom('openai/gpt', { provider: 'openai', credentialId: 'c', authMethod: 'key' });
  profile.usageSource = { kind: 'snapshot', unit: 'usd', remaining: 28.41, reserve: .5, maxAgeMinutes: 60, observedAt: '2026-11-05T12:00:00Z', costTracking: { enabled: true, baselineAllTimeCostUsd: 12.3456, baselineObservedAt: '2026-11-05T12:00:00Z' } };
  settings.openCode.profiles.push(profile); applyProfile(settings, profile);
  assert.equal(settings.openCode.accounts[0].quota.trackOpenCodeCosts, true);
  assert.equal(settings.openCode.accounts[0].quota.costBaselineAllTimeUsd, 12.3456);
});
test('keeps an open profile reference valid across dashboard normalization', () => {
  const profile = profileFrom('openai/gpt', { authMethod: 'key' });
  const settings = { openCode: { activeProfileId: profile.id, profiles: [profile], accounts: [] } };
  migrateProfiles(settings);
  profile.usageSource.remaining = 28.41;
  assert.equal(settings.openCode.profiles[0].usageSource.remaining, 28.41);
});
test('repairs an early profile snapshot from the saved active account', () => {
  const profile = { id: 'p', model: 'openai/gpt', provider: 'openai', credentialId: 'c', policy: 'api', usageSource: { kind: 'snapshot', unit: 'percent', remaining: null } };
  const settings = { openCode: { activeProfileId: 'p', profiles: [profile], accounts: [{ provider: 'openai', credentialId: 'c', quota: { configured: true, unit: 'usd', remaining: 28.41, reserve: .5, maxAgeMinutes: 60, observedAt: '2026-11-04T00:00:00Z' } }] } };
  migrateProfiles(settings);
  assert.equal(profile.usageSource.remaining, 28.41);
  assert.equal(profile.usageSource.unit, 'usd');
});
test('migrates legacy API profiles with their existing budget limits', () => {
  const settings = { budget: { mode: 'balance', balance: { minimumUsd: 5 } }, openCode: { activeProfileId: 'api', profiles: [{ id: 'api', model: 'openai/gpt', policy: 'api' }], accounts: [] } };
  const [profile] = migrateProfiles(settings);
  assert.equal(profile.limits.mode, 'balance');
  assert.equal(profile.limits.balance.minimumUsd, 5);
});
test('keeps a local run guard independently from provider usage', () => {
  const settings = { openCode: { activeProfileId: 'oauth', profiles: [{ id: 'oauth', model: 'openai/gpt', policy: 'oauth-managed', runControls: { maxIterations: 7 } }], accounts: [] } };
  const [profile] = migrateProfiles(settings);
  assert.equal(profile.runControls.maxIterations, 7);
});
test('creates snapshots for cloud profiles without storing credentials', () => {
  const oauth = profileFrom('openai/gpt', { authMethod: 'oauth' });
  const api = profileFrom('openai/gpt', { authMethod: 'key' });
  const local = profileFrom('ollama/qwen3');
  assert.equal(oauth.usageSource.kind, 'snapshot');
  assert.equal(api.usageSource.kind, 'snapshot');
  assert.equal(local.usageSource.kind, 'none');
});
test('keeps an explicit active project and validates project IDs', () => {
  const settings = { activeProjectId: 'b', projects: [{ id: 'a' }, { id: 'b' }] };
  assert.equal(activeProject(settings).id, 'b');
  assert.match(validateProjectId('bad id', settings.projects), /Use/);
  assert.match(validateProjectId('a', settings.projects), /already exists/);
});
test('derives an isolated project data root from the stable project ID', () => {
  assert.match(projectDataRoot({ logs: { root: './data/projects' } }, { id: 'alpha' }, 'C:/Tools/Terra/terra-config.json'), /data[\\/]projects[\\/]alpha$/);
});
