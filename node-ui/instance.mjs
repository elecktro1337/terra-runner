#!/usr/bin/env node
// Project-scoped Terra Runner 2.3 terminal. The central dispatcher creates this
// process; it deliberately receives only an instance ID, never credentials.
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import inquirer from 'inquirer';
import chalk from 'chalk';
import { clearInstanceControls, readCoordinatorHeartbeat, readInstance, requestInstanceControl, updateInstance } from './lib/runtime.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const valueOf = name => { const index = args.indexOf(name); return index < 0 ? '' : args[index + 1]; };
const configPath = valueOf('--config');
const instanceId = valueOf('--instance');
if (!configPath || !/^[a-f0-9-]{36}$/i.test(instanceId)) throw new Error('Use --config <file> --instance <uuid>.');
const input = options => inquirer.prompt([{ type: 'input', name: 'value', ...options }]).then(answer => answer.value);
const select = options => inquirer.prompt([{ type: 'list', name: 'value', ...options }]).then(answer => answer.value);
const confirm = options => inquirer.prompt([{ type: 'confirm', name: 'value', ...options }]).then(answer => answer.value);
const rule = chalk.gray('─'.repeat(76));
function clear() { if (process.stdout.isTTY) process.stdout.write('\x1Bc'); }
async function pick(message, choices) { try { return await select({ message, choices: [...choices, { name: '← Back', value: null }], loop: false }); } catch (error) { if (error?.name === 'ExitPromptError') return null; throw error; } }
async function load() { const [settings, instance] = await Promise.all([fs.readFile(configPath, 'utf8').then(JSON.parse), readInstance(configPath, instanceId)]); if (!instance) throw new Error('The dispatcher instance record no longer exists.'); const project = (settings.projects || []).find(item => item.id === instance.projectId); if (!project) throw new Error(`Project '${instance.projectId}' was removed from the configuration.`); return { settings, instance, project }; }
function show(instance, project) {
  clear(); console.log(chalk.cyan.bold('TERRA RUNNER 2.3  ·  PROJECT INSTANCE')); console.log(rule);
  console.log(`  Project   ${chalk.white(project.id)}  ${chalk.gray(project.path)}`);
  console.log(`  Model     ${chalk.cyan(instance.profile?.model || 'not configured')}`);
  console.log(`  State     ${instance.state}${instance.activity ? chalk.gray(` — ${instance.activity}`) : ''}`);
  console.log(`  Started   ${instance.createdAt}`); if (instance.stopReason) console.log(`  Stop      ${chalk.yellow(instance.stopReason)}`); if (instance.error) console.log(`  Error     ${chalk.red(instance.error)}`);
  console.log(rule);
}
async function safeUpdate(patch) { return updateInstance(configPath, instanceId, patch); }
async function request(kind) { await requestInstanceControl(configPath, instanceId, kind); await safeUpdate({ state: kind === 'ABORT' ? 'aborting' : 'stopping', activity: kind === 'ABORT' ? 'Emergency abort requested' : 'Finishing the current iteration' }); }
async function run(mode, limit = 1) {
  const { instance } = await load();
  if (['stopping', 'aborting'].includes(instance.state)) {
    const aborted = instance.state === 'aborting';
    await safeUpdate({ state: aborted ? 'aborted' : 'stopped', runnerPid: null, activity: '', stopReason: aborted ? 'Emergency abort requested before the runner started.' : 'Stop requested before the runner started.' });
    return;
  }
  if (['running', 'starting'].includes(instance.state)) { console.log(chalk.yellow('This instance already has an active runner.')); return; }
  await clearInstanceControls(configPath, instanceId); await safeUpdate({ state: 'starting', runnerPid: null, activity: 'Preparing OpenCode' });
  const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-UiEvents', '-ClearControlFlags', mode === 'continuous' ? '-Continuous' : '-Once'];
  if (mode === 'continuous') runnerArgs.push(limit > 0 ? '-MaxIterations' : '-UnlimitedIterations', String(limit || ''));
  const child = spawn('pwsh.exe', runnerArgs.filter(Boolean), { cwd: root, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  await safeUpdate({ state: 'running', runnerPid: child.pid, activity: 'OpenCode runner is active' });
  let buffer = '';
  const consume = async chunk => {
    const text = String(chunk); buffer += text;
    const lines = buffer.split(/\r?\n/); buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.startsWith('__TERRA_UI__')) { process.stdout.write(`${line}\n`); continue; }
      try { const event = JSON.parse(line.slice('__TERRA_UI__'.length)); await safeUpdate({ state: 'running', activity: event.type === 'iteration-heartbeat' ? `Iteration ${event.iteration}: ${event.elapsedSeconds}s` : event.type, iteration: event.iteration ?? null }); } catch { }
    }
  };
  child.stdout.on('data', data => void consume(data)); child.stderr.on('data', data => process.stderr.write(data));
  const keyHandler = data => { const key = String(data).toLowerCase(); if (key === 's' || key === '\u0003') void request('STOP'); if (key === 'x') void request('ABORT'); };
  if (process.stdin.isTTY) { process.stdin.setRawMode?.(true); process.stdin.resume(); process.stdin.on('data', keyHandler); }
  await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); }).then(async code => {
    const current = await readInstance(configPath, instanceId); const aborted = current?.state === 'aborting'; const stopped = current?.state === 'stopping';
    await safeUpdate({ state: aborted ? 'aborted' : stopped ? 'stopped' : code === 0 ? 'finished' : 'failed', runnerPid: null, activity: '', stopReason: aborted ? 'Emergency abort completed.' : stopped ? 'Graceful stop completed.' : code === 0 ? '' : `runner exit ${code}` });
  }).catch(async error => { await safeUpdate({ state: 'failed', runnerPid: null, error: error.message, activity: '' }); });
  if (process.stdin.isTTY) { process.stdin.off('data', keyHandler); process.stdin.setRawMode?.(false); }
}
async function preflight() {
  const { instance } = await load(); const child = spawn('pwsh.exe', ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-DryRun'], { cwd: root, stdio: 'inherit' });
  await new Promise(resolve => child.once('close', resolve));
}
async function heartbeatWatch() {
  const instance = await readInstance(configPath, instanceId); if (!instance || ['finished', 'failed', 'stopped', 'aborted'].includes(instance.state)) return;
  const coordinator = await readCoordinatorHeartbeat(configPath); const age = coordinator?.updatedAt ? Date.now() - Date.parse(coordinator.updatedAt) : Infinity;
  if (!coordinator || coordinator.id !== instance.coordinatorId || age > 20000) await request('STOP');
}
const watch = setInterval(() => void heartbeatWatch(), 5000); watch.unref();
async function main() {
  const initial = await readInstance(configPath, instanceId);
  if (!initial) throw new Error('The dispatcher instance record no longer exists.');
  if (['stopping', 'aborting'].includes(initial.state)) {
    const aborted = initial.state === 'aborting';
    await safeUpdate({ state: aborted ? 'aborted' : 'stopped', windowPid: process.pid, runnerPid: null, activity: '', stopReason: aborted ? 'Emergency abort requested before the project window opened.' : 'Stop requested before the project window opened.' });
    return;
  }
  await safeUpdate({ state: 'idle', windowPid: process.pid, activity: '' });
  const launch = initial?.launch || { command: 'idle', maxIterations: 0 };
  if (['once', 'continuous', 'dry-run'].includes(launch.command)) {
    const { project } = await load(); show(initial, project);
    console.log(chalk.cyan(`Starting requested ${launch.command} run…`));
    if (launch.command === 'dry-run') await preflight(); else await run(launch.command, Number(launch.maxIterations || 0));
    await safeUpdate({ launch: { command: 'idle', maxIterations: 0 } });
  }
  while (true) {
    const { instance, project } = await load(); show(instance, project);
    const action = await pick('Project instance', [
      { name: 'Run one development iteration', value: 'once' }, { name: 'Run continuously', value: 'continuous' }, { name: 'Dry run', value: 'preflight' },
      { name: 'Request graceful stop', value: 'stop' }, { name: chalk.red('Emergency abort'), value: 'abort' }, { name: 'Close project window', value: 'close' }
    ]);
    if (!action || action === 'close') { if (['running', 'starting', 'stopping', 'aborting'].includes(instance.state)) { console.log(chalk.yellow('Request Stop or Abort before closing this active project window.')); await input({ message: 'Press Enter to continue' }); continue; } await safeUpdate({ state: 'stopped', activity: 'Project window closed' }); return; }
    if (action === 'once') await run('once');
    if (action === 'continuous') { const raw = String(await input({ message: 'Iterations (0 = until a safety stop)', default: '0' })).trim(); const limit = /^\d+$/.test(raw) ? Number(raw) : 0; await run('continuous', limit); }
    if (action === 'preflight') await preflight(); if (action === 'stop') await request('STOP'); if (action === 'abort') await request('ABORT');
    if (action !== 'once' && action !== 'continuous') await input({ message: 'Press Enter to continue' });
  }
}
main().catch(async error => { try { await safeUpdate({ state: 'failed', error: error.message, activity: '' }); } catch { } console.error(chalk.red(`Terra project instance failed: ${error.message}`)); process.exitCode = 1; });
