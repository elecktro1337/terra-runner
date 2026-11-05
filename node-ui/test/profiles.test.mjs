import test from 'node:test';
import assert from 'node:assert/strict';
import { defaultApiLimits, isLocalModel, migrateProfiles, policyFor, profileFrom, splitModelVariant } from '../lib/profiles.mjs';
import { normalizeProjects, validateProjectId } from '../lib/projects.mjs';
import { projectDataRoot } from '../lib/reports.mjs';
import { DIRECT_ROUTE_ID, activeProxyRoute, noProxyValue, normalizeProxy, validateProxyRoute } from '../lib/proxy.mjs';

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
  assert.equal('model' in settings, false);
  assert.equal('activeAccountId' in settings.openCode, false);
  assert.equal('reasoning' in settings.openCode, false);
});
test('keeps an open profile reference valid across dashboard normalization', () => {
  const profile = profileFrom('openai/gpt', { authMethod: 'key' });
  const settings = { openCode: { profiles: [profile], accounts: [] } };
  migrateProfiles(settings);
  profile.usageSource.remaining = 28.41;
  assert.equal(settings.openCode.profiles[0].usageSource.remaining, 28.41);
});
test('repairs an early profile snapshot from the saved account inventory', () => {
  const profile = { id: 'p', model: 'openai/gpt', provider: 'openai', credentialId: 'c', policy: 'api', usageSource: { kind: 'snapshot', unit: 'percent', remaining: null } };
  const settings = { openCode: { profiles: [profile], accounts: [{ provider: 'openai', credentialId: 'c', quota: { configured: true, unit: 'usd', remaining: 28.41, reserve: .5, maxAgeMinutes: 60, observedAt: '2026-11-04T00:00:00Z' } }] } };
  migrateProfiles(settings);
  assert.equal(profile.usageSource.remaining, 28.41);
  assert.equal(profile.usageSource.unit, 'usd');
});
test('migrates legacy API profiles with their existing budget limits', () => {
  const settings = { budget: { mode: 'balance', balance: { minimumUsd: 5 } }, openCode: { activeProfileId: 'api', profiles: [{ id: 'api', model: 'openai/gpt', policy: 'api' }], accounts: [] } };
  const [profile] = migrateProfiles(settings);
  assert.equal(profile.limits.mode, 'balance');
  assert.equal(profile.limits.balance.minimumUsd, 5);
  assert.equal('budget' in settings, false);
  assert.equal('activeProfileId' in settings.openCode, false);
});
test('keeps a local run guard independently from provider usage', () => {
  const settings = { openCode: { profiles: [{ id: 'oauth', model: 'openai/gpt', policy: 'oauth-managed', runControls: { maxIterations: 7 } }], accounts: [] } };
  const [profile] = migrateProfiles(settings);
  assert.equal(profile.runControls.maxIterations, 7);
});
test('creates safe API limits without a global budget', () => {
  const limits = defaultApiLimits();
  assert.equal(limits.mode, 'daily');
  assert.equal(limits.dailyUsd, 5);
});
test('creates snapshots for cloud profiles without storing credentials', () => {
  const oauth = profileFrom('openai/gpt', { authMethod: 'oauth' });
  const api = profileFrom('openai/gpt', { authMethod: 'key' });
  const local = profileFrom('ollama/qwen3');
  assert.equal(oauth.usageSource.kind, 'snapshot');
  assert.equal(api.usageSource.kind, 'snapshot');
  assert.equal(local.usageSource.kind, 'none');
});
test('removes the obsolete global active project and validates project IDs', () => {
  const settings = { activeProjectId: 'b', projects: [{ id: 'a' }, { id: 'b' }] };
  assert.deepEqual(normalizeProjects(settings), settings.projects);
  assert.equal('activeProjectId' in settings, false);
  assert.match(validateProjectId('bad id', settings.projects), /Use/);
  assert.match(validateProjectId('a', settings.projects), /already exists/);
});
test('derives an isolated project data root from the stable project ID', () => {
  assert.match(projectDataRoot({ logs: { root: './data/projects' } }, { id: 'alpha' }, 'C:/Tools/Terra/terra-config.json'), /data[\\/]projects[\\/]alpha$/);
});
test('migrates proxy settings to a direct route without exposing a secret', () => {
  const settings = {}; const proxy = normalizeProxy(settings);
  assert.equal(proxy.activeRouteId, DIRECT_ROUTE_ID); assert.equal(activeProxyRoute(settings), null);
});
test('validates proxy routes and retains loopback exclusions', () => {
  const route = { name: 'LAN', protocol: 'socks5', host: '192.168.0.124', port: 1080, noProxy: ['internal.test'] };
  assert.equal(validateProxyRoute(route), ''); assert.match(noProxyValue(route), /127\.0\.0\.1/); assert.match(noProxyValue(route), /internal\.test/);
  assert.match(validateProxyRoute({ ...route, port: 0 }), /Port/);
});
