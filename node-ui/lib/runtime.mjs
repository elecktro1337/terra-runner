import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const TERMINAL = new Set(['finished', 'failed', 'aborted', 'stopped', 'orphaned']);

export function runtimeRoot(configPath) { return path.join(path.dirname(path.resolve(configPath)), 'runtime'); }
export function instancesRoot(configPath) { return path.join(runtimeRoot(configPath), 'instances'); }
export function instancePath(configPath, id) { return path.join(instancesRoot(configPath), `${id}.json`); }
export function instanceControlPath(configPath, id, kind) {
  if (!/^[a-f0-9-]{36}$/i.test(String(id)) || !['STOP', 'ABORT'].includes(kind)) throw new Error('Unsafe instance control path.');
  return path.join(runtimeRoot(configPath), 'controls', id, kind);
}
export function authStorePath(configPath, id) {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(String(id))) throw new Error('Unsafe OpenCode store ID.');
  return path.join(path.dirname(path.resolve(configPath)), 'opencode-stores', id, 'opencode.db');
}
export function isTerminalInstance(instance) { return TERMINAL.has(String(instance?.state || '')); }
export function sanitizeProfile(profile) {
  const copy = structuredClone(profile || {});
  delete copy.password; delete copy.passwordProtected; delete copy.secret; delete copy.token;
  return copy;
}
export function normalizeRuntime(settings) {
  settings.openCode ||= {};
  settings.openCode.stores = Array.isArray(settings.openCode.stores) ? settings.openCode.stores : [];
  if (!settings.openCode.stores.some(store => store.id === 'legacy-shared')) {
    settings.openCode.stores.unshift({ id: 'legacy-shared', name: 'Legacy shared OpenCode', kind: 'legacy-shared' });
  }
  for (const profile of settings.openCode.profiles || []) {
    if (!profile.authStoreId) profile.authStoreId = profile.policy === 'local' ? '' : 'legacy-shared';
    if (profile.parallelReservation == null) profile.parallelReservation = Number(profile.policy === 'local' ? 0 : profile.usageSource?.reserve ?? profile.limits?.balance?.iterationReserveUsd ?? 0.5);
  }
  const valid = new Set((settings.openCode.profiles || []).map(profile => profile.id));
  for (const project of settings.projects || []) if (!valid.has(project.defaultProfileId)) project.defaultProfileId = settings.openCode.activeProfileId && valid.has(settings.openCode.activeProfileId) ? settings.openCode.activeProfileId : '';
  return settings;
}
async function writeJson(filename, value) {
  await fs.mkdir(path.dirname(filename), { recursive: true });
  const temp = `${filename}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await fs.writeFile(temp, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await fs.rename(temp, filename);
}
export async function readInstance(configPath, id) {
  try { return JSON.parse(await fs.readFile(instancePath(configPath, id), 'utf8')); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
export async function listInstances(configPath) {
  try {
    const files = await fs.readdir(instancesRoot(configPath));
    const result = await Promise.all(files.filter(name => name.endsWith('.json')).map(async name => {
      try { return JSON.parse(await fs.readFile(path.join(instancesRoot(configPath), name), 'utf8')); } catch { return null; }
    }));
    return result.filter(Boolean).sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}
export async function createInstance(configPath, project, profile, proxyRoute, coordinatorId) {
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const instance = {
    id, projectId: project.id, projectPath: project.path, state: 'launching', createdAt: now, updatedAt: now,
    coordinatorId, coordinatorHeartbeatAt: now, profile: sanitizeProfile(profile), proxyRoute: proxyRoute ? structuredClone(proxyRoute) : null,
    runnerPid: null, windowPid: null, iteration: null, activity: '', stopReason: '', error: '', logsPath: ''
  };
  await writeJson(instancePath(configPath, id), instance);
  return instance;
}
export async function updateInstance(configPath, id, patch) {
  const current = await readInstance(configPath, id);
  if (!current) throw new Error(`Instance '${id}' was not found.`);
  const next = { ...current, ...patch, updatedAt: new Date().toISOString() };
  await writeJson(instancePath(configPath, id), next);
  return next;
}
export async function requestInstanceControl(configPath, id, kind) {
  const control = instanceControlPath(configPath, id, kind);
  await fs.mkdir(path.dirname(control), { recursive: true });
  await fs.writeFile(control, `${kind} requested at ${new Date().toISOString()}\n`, 'utf8');
  return control;
}
export async function clearInstanceControls(configPath, id) {
  await Promise.all(['STOP', 'ABORT'].map(async kind => { try { await fs.unlink(instanceControlPath(configPath, id, kind)); } catch (error) { if (error.code !== 'ENOENT') throw error; } }));
}
export async function writeCoordinatorHeartbeat(configPath, coordinatorId) {
  await writeJson(path.join(runtimeRoot(configPath), 'coordinator.json'), { id: coordinatorId, pid: process.pid, updatedAt: new Date().toISOString() });
}
export async function readCoordinatorHeartbeat(configPath) {
  try { return JSON.parse(await fs.readFile(path.join(runtimeRoot(configPath), 'coordinator.json'), 'utf8')); } catch { return null; }
}
export async function removeCoordinatorHeartbeat(configPath, coordinatorId) {
  const file = path.join(runtimeRoot(configPath), 'coordinator.json'); const current = await readCoordinatorHeartbeat(configPath);
  if (current?.id === coordinatorId) { try { await fs.unlink(file); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
}
