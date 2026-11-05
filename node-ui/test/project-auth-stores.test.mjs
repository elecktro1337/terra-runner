import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ensureProjectAuthStore, projectAuthStorePath, projectManagedStore, projectManagedStoreId, removeProjectAuthStore } from '../lib/project-auth-stores.mjs';

async function fixture() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'terra-project-auth-'));
  const script = path.join(root, 'fake-auth.mjs'); const command = path.join(root, 'fake-opencode.cmd');
  await fs.writeFile(script, `import fs from 'node:fs/promises';\nconst [,,group,action] = process.argv;\nif (group !== 'auth') process.exit(2);\nif (action === 'export') { process.stdout.write('credential-payload-for-test'); process.exit(0); }\nif (action === 'import') { let value=''; process.stdin.setEncoding('utf8'); process.stdin.on('data', chunk => value += chunk); process.stdin.on('end', async () => { await fs.mkdir(requirePath(process.env.OPENCODE_DB), { recursive:true }); await fs.writeFile(process.env.OPENCODE_DB, 'db'); await fs.writeFile(process.env.OPENCODE_DB + '.received', value); }); process.stdin.on('end', () => setTimeout(() => process.exit(0), 20)); }\nfunction requirePath(file) { return file.slice(0, Math.max(file.lastIndexOf('\\\\'), file.lastIndexOf('/'))); }\n`, 'utf8');
  await fs.writeFile(command, `@echo off\r\nnode "%~dp0fake-auth.mjs" %*\r\n`, 'utf8');
  return { root, command };
}

function settings() { return { openCode: { stores: [{ id: 'legacy-shared', name: 'Legacy', kind: 'legacy-shared' }] } }; }
const cloud = { id: 'p', policy: 'oauth-managed', provider: 'openai', credentialId: 'credential-a', authStoreId: 'legacy-shared' };

test('creates deterministic per-project stores and pipes provider credentials without serializing them into settings', async () => {
  const { root, command } = await fixture(); const config = path.join(root, 'terra-config.json'); const state = settings();
  const result = await ensureProjectAuthStore({ settings: state, project: { id: 'alpha' }, profile: cloud, configPath: config, executable: command, cwd: root, listAccounts: async () => [{ provider: 'openai', credentialId: 'credential-a' }] });
  assert.equal(result.storeId, projectManagedStoreId('alpha')); assert.equal(result.created, true);
  const store = projectManagedStore(state, { id: 'alpha' }); assert.equal(store.kind, 'project-managed'); assert.equal(store.projectId, 'alpha');
  const db = projectAuthStorePath(config, result.storeId); assert.equal(await fs.readFile(`${db}.received`, 'utf8'), 'credential-payload-for-test');
  assert.doesNotMatch(JSON.stringify(state), /credential-payload-for-test/);
  assert.equal((await fs.readdir(path.dirname(db))).some(name => name.endsWith('.json')), false);
});

test('keeps projects isolated, skips local profiles, and removes only the deleted project store', async () => {
  const { root, command } = await fixture(); const config = path.join(root, 'terra-config.json'); const state = settings();
  const accountList = async () => [{ provider: 'openai', credentialId: 'credential-a' }];
  const alpha = { id: 'alpha' }; const beta = { id: 'beta' };
  const first = await ensureProjectAuthStore({ settings: state, project: alpha, profile: cloud, configPath: config, executable: command, cwd: root, listAccounts: accountList });
  const second = await ensureProjectAuthStore({ settings: state, project: beta, profile: cloud, configPath: config, executable: command, cwd: root, listAccounts: accountList });
  assert.notEqual(first.storeId, second.storeId);
  assert.deepEqual(await ensureProjectAuthStore({ settings: state, project: alpha, profile: { policy: 'local' }, configPath: config, executable: command, cwd: root, listAccounts: accountList }), { storeId: '', created: false });
  assert.equal(await removeProjectAuthStore(state, alpha, config), true);
  await assert.rejects(fs.stat(path.dirname(projectAuthStorePath(config, first.storeId))));
  assert.equal(await fs.stat(path.dirname(projectAuthStorePath(config, second.storeId))).then(() => true), true);
});

test('rejects unsafe managed-store paths and a missing source credential', async () => {
  assert.throws(() => projectAuthStorePath('C:\\terra\\config.json', '../secret'), /Unsafe/);
  const { root, command } = await fixture(); const state = settings();
  await assert.rejects(ensureProjectAuthStore({ settings: state, project: { id: 'alpha' }, profile: cloud, configPath: path.join(root, 'terra-config.json'), executable: command, cwd: root, listAccounts: async () => [] }), /selected credential/);
});
