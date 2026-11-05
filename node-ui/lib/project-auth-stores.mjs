import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';

const STORE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

export function projectManagedStoreId(projectId) {
  const digest = crypto.createHash('sha256').update(String(projectId), 'utf8').digest('hex').slice(0, 24);
  return `project-${digest}`;
}

export function projectManagedStore(settings, project) {
  const stores = settings.openCode?.stores || [];
  return stores.find(store => store.kind === 'project-managed' && store.projectId === project.id) || null;
}

export function isProjectManagedStore(store) { return store?.kind === 'project-managed'; }

export function projectAuthStorePath(configPath, storeId) {
  if (!STORE_ID.test(String(storeId))) throw new Error('Unsafe project authentication store ID.');
  return path.join(path.dirname(path.resolve(configPath)), 'opencode-stores', storeId, 'opencode.db');
}

function launch(executable, args, cwd, env, acceptsStdin = false) {
  const batch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(executable);
  const stdio = [acceptsStdin ? 'pipe' : 'ignore', 'pipe', 'pipe'];
  if (!batch) return spawn(executable, args, { cwd, shell: false, stdio, env: { ...process.env, ...env } });
  const quote = value => `"${String(value).replace(/"/g, '""')}"`;
  const commandLine = `"${quote(executable)} ${args.map(quote).join(' ')}"`;
  return spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', commandLine], { cwd, shell: false, windowsVerbatimArguments: true, stdio, env: { ...process.env, ...env } });
}

function waitFor(child) {
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => code === 0 ? resolve() : reject(new Error('OpenCode authentication command failed.')));
  });
}

async function withLock(configPath, storeId, action) {
  const lock = path.join(path.dirname(path.resolve(configPath)), 'runtime', 'auth-store-locks', `${storeId}.lock`);
  const deadline = Date.now() + 30000;
  await fs.mkdir(path.dirname(lock), { recursive: true });
  while (true) {
    try { await fs.mkdir(lock, { recursive: false }); break; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (Date.now() >= deadline) throw new Error('Timed out while preparing the project authentication store.');
      await sleep(150);
    }
  }
  try { return await action(); }
  finally { await fs.rm(lock, { recursive: true, force: true }); }
}

async function streamProviderCredentials({ executable, cwd, provider, sourceEnv, targetEnv }) {
  const exporter = launch(executable, ['auth', 'export', provider], cwd, sourceEnv);
  const importer = launch(executable, ['auth', 'import'], cwd, targetEnv, true);
  // Credentials are intentionally piped process-to-process. Do not collect,
  // decode, print, or persist the export stream in Terra Runner.
  exporter.stdout.pipe(importer.stdin);
  exporter.stderr.resume(); importer.stdout.resume(); importer.stderr.resume();
  try { await Promise.all([waitFor(exporter), waitFor(importer)]); }
  catch {
    exporter.kill(); importer.kill();
    throw new Error('Project authentication setup failed. Reconnect the selected OpenCode profile and try again.');
  }
}

export async function ensureProjectAuthStore({ settings, project, profile, configPath, executable, cwd, listAccounts }) {
  if (profile.policy === 'local') return { storeId: '', created: false };
  const provider = String(profile.provider || '').trim(); const credentialId = String(profile.credentialId || '').trim();
  if (!provider || !credentialId) throw new Error('The selected profile has no OpenCode credential.');
  const sourceStoreId = String(profile.authStoreId || 'legacy-shared');
  const source = (settings.openCode?.stores || []).find(store => store.id === sourceStoreId);
  if (!source || isProjectManagedStore(source)) throw new Error('The selected profile authentication source is unavailable.');
  const existing = projectManagedStore(settings, project);
  const storeId = existing?.id || projectManagedStoreId(project.id);
  const targetDb = projectAuthStorePath(configPath, storeId);
  const sourceEnv = sourceStoreId === 'legacy-shared' ? {} : { OPENCODE_DB: projectAuthStorePath(configPath, sourceStoreId) };
  const targetEnv = { OPENCODE_DB: targetDb };
  try {
    await withLock(configPath, storeId, async () => {
      await fs.mkdir(path.dirname(targetDb), { recursive: true });
      await streamProviderCredentials({ executable, cwd, provider, sourceEnv, targetEnv });
      const accounts = await listAccounts(targetEnv);
      if (!accounts.some(account => account.provider === provider && account.credentialId === credentialId)) {
        throw new Error('The selected credential is no longer available in the source OpenCode profile.');
      }
    });
  } catch (error) {
    if (!existing) await fs.rm(path.dirname(targetDb), { recursive: true, force: true });
    throw error;
  }
  if (!existing) {
    settings.openCode.stores.push({ id: storeId, name: `Project ${project.id} (managed)`, kind: 'project-managed', projectId: project.id });
  }
  return { storeId, created: !existing };
}

export async function removeProjectAuthStore(settings, project, configPath) {
  const store = projectManagedStore(settings, project);
  if (!store) return false;
  await fs.rm(path.dirname(projectAuthStorePath(configPath, store.id)), { recursive: true, force: true });
  settings.openCode.stores = settings.openCode.stores.filter(item => item.id !== store.id);
  try { await fs.rm(path.join(path.dirname(path.resolve(configPath)), 'runtime', 'auth-store-locks', `${store.id}.lock`), { recursive: true, force: true }); } catch { }
  return true;
}
