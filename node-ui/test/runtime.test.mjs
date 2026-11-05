import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { authStorePath, clearInstanceControls, createInstance, instanceControlPath, listInstances, normalizeRuntime, readInstance, requestInstanceControl, updateInstance } from '../lib/runtime.mjs';

async function fixture() { return fs.mkdtemp(path.join(os.tmpdir(), 'terra-runtime-')); }

test('v6 runtime migration assigns legacy auth storage and default project profile', () => {
  const settings = { openCode: { activeProfileId: 'p1', profiles: [{ id: 'p1', policy: 'api', usageSource: { reserve: 2 } }] }, projects: [{ id: 'one' }] };
  normalizeRuntime(settings);
  assert.equal(settings.openCode.stores[0].id, 'legacy-shared');
  assert.equal(settings.openCode.profiles[0].authStoreId, 'legacy-shared');
  assert.equal(settings.openCode.profiles[0].parallelReservation, 2);
  assert.equal(settings.projects[0].defaultProfileId, 'p1');
});

test('instance registry is atomic and its control files are addressable', async () => {
  const root = await fixture(); const config = path.join(root, 'terra-config.json');
  const instance = await createInstance(config, { id: 'project-a', path: 'C:\\work' }, { id: 'p1', model: 'openai/test', password: 'must-not-persist' }, null, 'coordinator');
  const loaded = await readInstance(config, instance.id);
  assert.equal(loaded.projectId, 'project-a'); assert.equal(loaded.profile.password, undefined);
  await requestInstanceControl(config, instance.id, 'STOP'); assert.equal(await fs.stat(instanceControlPath(config, instance.id, 'STOP')).then(() => true), true);
  await clearInstanceControls(config, instance.id); await assert.rejects(fs.stat(instanceControlPath(config, instance.id, 'STOP')));
  await updateInstance(config, instance.id, { state: 'running', activity: 'test' });
  assert.equal((await listInstances(config))[0].state, 'running');
});

test('authentication database path is derived from a safe storage ID', () => {
  assert.match(authStorePath('C:\\terra\\terra-config.json', 'team_a'), /opencode-stores[\\/]team_a[\\/]opencode\.db$/i);
  assert.throws(() => authStorePath('C:\\terra\\terra-config.json', '../secret'), /Unsafe/);
});
