import test from 'node:test';
import assert from 'node:assert/strict';
import { applyProfile, isLocalModel, migrateProfiles, policyFor, profileFrom, splitModelVariant } from '../lib/profiles.mjs';

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
test('applying an OAuth profile replaces a legacy manual quota policy', () => {
  const settings = { openCode: { accounts: [{ id: 'openai:c', provider: 'openai', credentialId: 'c', quota: { configured: true } }], profiles: [] } };
  const profile = profileFrom('openai/gpt-5.6-terra', { provider: 'openai', credentialId: 'c', label: 'Codex', authMethod: 'oauth' });
  settings.openCode.profiles.push(profile);
  applyProfile(settings, profile);
  assert.equal(settings.openCode.accounts[0].usageKind, 'oauth');
  assert.equal('quota' in settings.openCode.accounts[0], false);
});
