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
import figlet from 'figlet';
import { clearInstanceControls, instanceRunnerFailure, readCoordinatorHeartbeat, readInstance, requestInstanceControl, updateInstance } from './lib/runtime.mjs';
import { activeProxyRoute } from './lib/proxy.mjs';
import { LiveFooter, LiveStatusBlock } from './lib/live-footer.mjs';
import { developmentHeaderRows } from './lib/run-display.mjs';
import { readRoadmapProgress } from './lib/roadmap.mjs';
import { completedIterationText } from './lib/iteration-history.mjs';
import { instanceOutcome } from './lib/instance-outcome.mjs';
import { latestIterationSummary, projectDataRoot } from './lib/reports.mjs';

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
const controls = chalk.gray('Controls: [S] stop after this iteration  |  [X] emergency stop current iteration  |  [Ctrl+C] safe stop');
function clear() { if (process.stdout.isTTY) process.stdout.write('\x1Bc'); }
function durationText(milliseconds) { const seconds = Math.max(0, Math.floor(milliseconds / 1000)); return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`; }
function limitSummary(profile = {}) {
  if (profile.policy === 'local') return 'not applicable';
  if (profile.policy === 'oauth-managed') return 'provider-managed';
  const policy = profile.limitPolicy || {};
  if (policy.mode === 'critical') return `minimum ${policy.amount ?? 0} ${profile.usageSource?.unit === 'usd' ? 'USD' : '%'}; reserve ${policy.reserve ?? 0}`;
  return policy.mode || 'not configured';
}
function activityFromEvent(event) {
  if (event?.type !== 'tool_use') return '';
  const part = event.part || {}; const state = part.state || {}; const input = state.input || {};
  const tool = String(part.tool || state.tool || 'tool').toLowerCase(); const command = String(input.command || '');
  if (/(phpunit|phpstan|phpcs|npm\s+(test|run)|pytest|composer\s+validate|php\s+-l|git\s+diff\s+--check)/i.test(command)) return 'Running verification';
  if (/^git\s/i.test(command)) return 'Checking Git state';
  if (/(write|edit|patch|apply)/.test(tool)) return 'Updating project files';
  if (/(read|list|glob|search|grep)/.test(tool)) return 'Inspecting project files';
  return 'Using OpenCode tools';
}
function globalHeader(settings, subtitle = 'PROJECT INSTANCE') {
  clear(); const route = activeProxyRoute(settings); const projects = Array.isArray(settings.projects) ? settings.projects : []; const profiles = Array.isArray(settings.openCode?.profiles) ? settings.openCode.profiles : [];
  console.log(chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' })));
  console.log(chalk.gray(`RUNNER  v2.3  ·  ${subtitle}`)); console.log(rule);
  console.log(`${chalk.bold('Workspace')} ${projects.length} project(s)  ${chalk.gray('│')}  ${profiles.length} profile(s)  ${chalk.gray('│')}  Proxy ${route ? route.name : 'Direct'}`); console.log(rule);
}
function renderRunHeader(settings, project, profile, command, roadmap) {
  clear();
  const rows = [chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' })), chalk.gray('RUNNER  v2.3  ·  Active development run  ·  Dispatcher instance'), rule, ...developmentHeaderRows({ project, profile, command, roadmap, includeTerraLimits: false }), rule];
  for (const row of rows) console.log(row);
  return rows.reduce((count, row) => count + String(row).split(/\r?\n/).length, 0);
}
async function pick(message, choices) { try { return await select({ message, choices: [...choices, { name: '← Back', value: null }], loop: false }); } catch (error) { if (error?.name === 'ExitPromptError') return null; throw error; } }
async function load() { const [settings, instance] = await Promise.all([fs.readFile(configPath, 'utf8').then(JSON.parse), readInstance(configPath, instanceId)]); if (!instance) throw new Error('The dispatcher instance record no longer exists.'); const project = (settings.projects || []).find(item => item.id === instance.projectId); if (!project) throw new Error(`Project '${instance.projectId}' was removed from the configuration.`); return { settings, instance, project }; }
async function show(settings, instance, project) {
  const [summary, roadmap] = await Promise.all([latestIterationSummary(settings, project, configPath), readRoadmapProgress(project)]);
  const outcome = instanceOutcome(instance, summary, roadmap);
  globalHeader(settings);
  for (const row of developmentHeaderRows({ project, profile: instance.profile || {}, command: 'Instance result', roadmap, includeTerraLimits: false })) console.log(row);
  console.log(`  ${chalk.bold.cyan('Location')}  ${chalk.gray(project.path)}`);
  console.log(`  State     ${instance.state}${instance.activity ? chalk.gray(` — ${instance.activity}`) : ''}`);
  console.log(`  Started   ${instance.createdAt}`);
  if (outcome) {
    const resultColor = outcome.kind === 'complete' ? chalk.green : outcome.kind === 'failed' || outcome.kind === 'aborted' ? chalk.red : chalk.yellow;
    console.log(`  Result    ${resultColor(outcome.reason)}`);
    if (outcome.roadmap) console.log(`  Roadmap   ${outcome.kind === 'complete' ? chalk.green(outcome.roadmap) : outcome.roadmap}`);
    if (outcome.task) console.log(`  Last task ${chalk.cyan(outcome.task)}`);
    if (outcome.duration) console.log(`  Duration  ${outcome.duration}`);
    if (outcome.commit) console.log(`  Commit    ${chalk.gray(outcome.commit)}`);
    console.log(`  Logs      ${chalk.gray(projectDataRoot(settings, project, configPath))}`);
  }
  console.log(rule);
}
async function safeUpdate(patch) { return updateInstance(configPath, instanceId, patch); }
async function request(kind) { await requestInstanceControl(configPath, instanceId, kind); await safeUpdate({ state: kind === 'ABORT' ? 'aborting' : 'stopping', activity: kind === 'ABORT' ? 'Emergency abort requested' : 'Finishing the current iteration' }); }
async function run(mode, limit = 1) {
  const { settings, instance, project } = await load();
  if (['stopping', 'aborting'].includes(instance.state)) {
    const aborted = instance.state === 'aborting';
    await safeUpdate({ state: aborted ? 'aborted' : 'stopped', runnerPid: null, activity: '', stopReason: aborted ? 'Emergency abort requested before the runner started.' : 'Stop requested before the runner started.' });
    return;
  }
  if (['running', 'starting'].includes(instance.state)) { console.log(chalk.yellow('This instance already has an active runner.')); return; }
  await clearInstanceControls(configPath, instanceId); await safeUpdate({ state: 'starting', runnerPid: null, activity: 'Preparing OpenCode' });
  const command = mode === 'continuous' ? `Run continuously${limit ? ` for up to ${limit} iteration(s)` : ''}` : 'Run one iteration';
  const roadmap = await readRoadmapProgress(project);
  const statusRow = renderRunHeader(settings, project, instance.profile || {}, command, roadmap);
  const footer = new LiveFooter(process.stdout, controls); const status = new LiveStatusBlock(process.stdout, statusRow, 1);
  const liveAttached = footer.enabled && status.enabled; let frame = 0; const frames = ['-', '\\', '|', '/']; let stage = mode === 'continuous' ? 'Preparing continuous development' : 'Preparing iteration'; let detail = roadmap.nextTask ? `Next task: ${roadmap.nextTask}` : 'Waiting for runner events…'; let iterationStarted = Date.now(); let eventFile = ''; let eventLines = 0; let toolCount = 0; let checkCount = 0; let activity = ''; let iterationLabel = ''; let notice = ''; let control = ''; const completedIterations = [];
  const statusText = () => `${chalk.cyan(frames[frame++ % frames.length])} ${stage} · ${durationText(Date.now() - iterationStarted)}`;
  const renderStatus = () => status.render(statusText(), notice || detail, completedIterations);
  if (liveAttached) { process.stdout.write('\x1b[?25l'); renderStatus(); footer.render(); }
  else { console.log(`  ${statusText()}`); console.log(`  ${controls}`); }
  const paint = liveAttached ? setInterval(renderStatus, 180) : null;
  const onResize = () => { renderStatus(); footer.render(); };
  if (liveAttached) process.stdout.on('resize', onResize);
  const eventWatch = setInterval(async () => {
    if (!eventFile) return;
    try {
      const lines = (await fs.readFile(eventFile, 'utf8')).split(/\r?\n/).filter(Boolean);
      for (const line of lines.slice(eventLines)) { try { const next = activityFromEvent(JSON.parse(line)); if (next) { toolCount++; if (next === 'Running verification') checkCount++; activity = next; } } catch { } }
      eventLines = lines.length;
      if (activity) stage = `${iterationLabel ? `${iterationLabel} | ` : ''}${activity}${toolCount ? ` | tools ${toolCount}${checkCount ? ` | checks ${checkCount}` : ''}` : ''}`;
    } catch { }
  }, 900);
  const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-UiEvents', '-ClearControlFlags', mode === 'continuous' ? '-Continuous' : '-Once'];
  if (mode === 'continuous') runnerArgs.push(limit > 0 ? '-MaxIterations' : '-UnlimitedIterations', String(limit || ''));
  const child = spawn('pwsh.exe', runnerArgs.filter(Boolean), { cwd: root, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  await safeUpdate({ state: 'running', runnerPid: child.pid, activity: 'OpenCode runner is active' });
  let buffer = ''; let stderr = '';
  const consume = async chunk => {
    const text = String(chunk); buffer += text;
    const lines = buffer.split(/\r?\n/); buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.startsWith('__TERRA_UI__')) continue;
      try {
        const event = JSON.parse(line.slice('__TERRA_UI__'.length));
        if (event.type === 'iteration-started') { eventFile = event.eventsFile || ''; eventLines = 0; toolCount = 0; checkCount = 0; activity = ''; iterationStarted = Date.now(); iterationLabel = event.total == null ? `Iteration ${event.iteration}` : `Iteration ${event.iteration} of ${event.total}`; stage = `${iterationLabel} | ${event.taskId || 'next roadmap task'} | ${event.pending} tasks pending`; detail = event.taskTitle ? `Task: ${event.taskTitle}` : ''; }
        if (event.type === 'iteration-heartbeat') { stage = `Iteration ${event.iteration} | working`; }
        if (event.type === 'iteration-finished') { completedIterations.push(`${event.stoppedReason ? chalk.yellow('!') : chalk.green('✓')} ${completedIterationText(event)}`); stage = 'Preparing next iteration'; detail = ''; }
        await safeUpdate({ state: 'running', activity: event.type === 'iteration-heartbeat' ? `Iteration ${event.iteration}: ${event.elapsedSeconds}s` : event.type, iteration: event.iteration ?? null });
      } catch { }
    }
  };
  child.stdout.on('data', data => void consume(data)); child.stderr.on('data', data => { stderr += String(data); });
  const requestRunControl = async kind => { if (control) return; control = kind; await request(kind); notice = chalk.yellow(kind === 'ABORT' ? '! Emergency stop requested. The current iteration will be terminated.' : '! Stop requested. The current iteration will finish, then development will stop.'); stage = kind === 'ABORT' ? 'Stopping current iteration' : 'Finishing current iteration'; if (liveAttached) renderStatus(); };
  const keyHandler = data => { const key = String(data).toLowerCase(); if (key === 's' || key === '\u0003') void requestRunControl('STOP'); if (key === 'x') void requestRunControl('ABORT'); };
  if (process.stdin.isTTY) { process.stdin.setRawMode?.(true); process.stdin.resume(); process.stdin.on('data', keyHandler); }
  await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); }).then(async code => {
    const current = await readInstance(configPath, instanceId); const aborted = current?.state === 'aborting'; const stopped = current?.state === 'stopping';
    const failed = !aborted && !stopped && code !== 0;
    const roadmapAfter = await readRoadmapProgress(project);
    const normalReason = roadmapAfter.available && roadmapAfter.pending === 0 ? `Roadmap complete — all ${roadmapAfter.total} task(s) are done.` : '';
    await safeUpdate({ state: aborted ? 'aborted' : stopped ? 'stopped' : code === 0 ? 'finished' : 'failed', runnerPid: null, activity: '', error: failed ? instanceRunnerFailure(stderr, code) : '', stopReason: aborted ? 'Emergency abort completed.' : stopped ? 'Graceful stop completed.' : code === 0 ? normalReason : `runner exit ${code}` });
  }).catch(async error => { await safeUpdate({ state: 'failed', runnerPid: null, error: error.message, activity: '' }); }).finally(() => {
    if (paint) clearInterval(paint); clearInterval(eventWatch); if (liveAttached) process.stdout.off('resize', onResize); status.clear(); footer.clear(); if (liveAttached) process.stdout.write('\x1b[?25h');
  });
  if (process.stdin.isTTY) { process.stdin.off('data', keyHandler); process.stdin.setRawMode?.(false); }
}
async function preflight() {
  const { settings, instance, project } = await load(); renderRunHeader(settings, project, instance.profile || {}, 'Dry run', await readRoadmapProgress(project)); const child = spawn('pwsh.exe', ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-DryRun'], { cwd: root, stdio: 'inherit' });
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
    const { settings, project } = await load(); await show(settings, initial, project);
    console.log(chalk.cyan(`Starting requested ${launch.command} run…`));
    if (launch.command === 'dry-run') await preflight(); else await run(launch.command, Number(launch.maxIterations || 0));
    await safeUpdate({ launch: { command: 'idle', maxIterations: 0 } });
  }
  while (true) {
    const { settings, instance, project } = await load(); await show(settings, instance, project);
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
