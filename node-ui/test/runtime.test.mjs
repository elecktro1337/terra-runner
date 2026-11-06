import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { authStorePath, canFinalizeStalledInstance, clearInstanceControls, clearTerminalInstances, createInstance, deleteTerminalInstance, instanceControlPath, instanceRunnerFailure, listInstances, normalizeRuntime, readInstance, requestInstanceControl, updateInstance } from '../lib/runtime.mjs';

async function fixture() { return fs.mkdtemp(path.join(os.tmpdir(), 'terra-runtime-')); }

test('v9 to v10 runtime migration assigns legacy auth storage without eagerly creating project stores', () => {
  const settings = { schemaVersion: 9, openCode: { profiles: [{ id: 'p1', policy: 'api', usageSource: { reserve: 2 }, parallelReservation: 2 }] }, projects: [{ id: 'one', defaultProfileId: 'p1' }] };
  normalizeRuntime(settings);
  assert.equal(settings.openCode.stores[0].id, 'legacy-shared');
  assert.equal(settings.openCode.stores.filter(store => store.kind === 'project-managed').length, 0);
  assert.equal(settings.openCode.profiles[0].authStoreId, 'legacy-shared');
  assert.equal(settings.openCode.profiles[0].parallelReservation, undefined);
  assert.equal(settings.projects[0].defaultProfileId, undefined);
});

test('instance registry stores a command snapshot without profile limit fields', async () => {
  const root = await fixture(); const config = path.join(root, 'terra-config.json');
  const instance = await createInstance(config, { id: 'project-a', path: 'C:\\work' }, { id: 'p1', model: 'openai/test', password: 'must-not-persist', limits: { dailyUsd: 5 }, usageSource: { remaining: 10 } }, null, { command: 'continuous', maxIterations: 3 });
  const loaded = await readInstance(config, instance.id);
  assert.equal(loaded.projectId, 'project-a'); assert.equal(loaded.profile.password, undefined); assert.equal(loaded.profile.limits, undefined); assert.deepEqual(loaded.launch, { command: 'continuous', maxIterations: 3 });
  await requestInstanceControl(config, instance.id, 'STOP'); assert.equal(await fs.stat(instanceControlPath(config, instance.id, 'STOP')).then(() => true), true);
  await clearInstanceControls(config, instance.id); await assert.rejects(fs.stat(instanceControlPath(config, instance.id, 'STOP')));
  await updateInstance(config, instance.id, { state: 'running', activity: 'test' });
  assert.equal((await listInstances(config))[0].state, 'running');
  const terminal = await updateInstance(config, instance.id, { state: 'stopped', activity: '' });
  assert.match(terminal.endedAt, /^\d{4}-\d{2}-\d{2}T/);
});

test('authentication database path is derived from a safe storage ID', () => {
  assert.match(authStorePath('C:\\terra\\terra-config.json', 'team_a'), /opencode-stores[\\/]team_a[\\/]opencode\.db$/i);
  assert.throws(() => authStorePath('C:\\terra\\terra-config.json', '../secret'), /Unsafe/);
});

test('only an active state without a live runner can be finalized as stalled', () => {
  assert.equal(canFinalizeStalledInstance({ state: 'aborting', runnerPid: null }), true);
  assert.equal(canFinalizeStalledInstance({ state: 'launching', runnerPid: 0 }), true);
  assert.equal(canFinalizeStalledInstance({ state: 'running', runnerPid: null }), false);
  assert.equal(canFinalizeStalledInstance({ state: 'aborting', runnerPid: process.pid }), false);
});

test('redacts runner stderr into a safe actionable instance failure', () => {
  assert.match(instanceRunnerFailure('Exception: Git working tree has uncommitted/untracked changes.', 1), /Commit, stash, or remove/);
  assert.match(instanceRunnerFailure('opaque provider output api_key=secret', 1), /Runner exited with code 1/);
  assert.doesNotMatch(instanceRunnerFailure('opaque provider output api_key=secret', 1), /secret/);
});

test('removes only terminal instance records and preserves active instances', async () => {
  const root = await fixture(); const config = path.join(root, 'terra-config.json');
  const terminal = await createInstance(config, { id: 'finished', path: 'C:\\finished' }, { id: 'p1' }, null, {});
  const active = await createInstance(config, { id: 'running', path: 'C:\\running' }, { id: 'p1' }, null, {});
  await updateInstance(config, terminal.id, { state: 'finished' }); await updateInstance(config, active.id, { state: 'running' });
  assert.equal(await deleteTerminalInstance(config, terminal.id), true);
  await assert.rejects(deleteTerminalInstance(config, active.id), /Only a completed/);
  const another = await createInstance(config, { id: 'failed', path: 'C:\\failed' }, { id: 'p1' }, null, {}); await updateInstance(config, another.id, { state: 'failed' });
  assert.equal(await clearTerminalInstances(config), 1);
  assert.equal((await listInstances(config)).length, 1);
  assert.equal((await listInstances(config))[0].projectId, 'running');
});
