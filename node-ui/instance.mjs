#!/usr/bin/env node
// Project-scoped Terra Runner 2.4 terminal. The central dispatcher creates this
// process; it deliberately receives only an instance ID, never credentials.
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import inquirer from 'inquirer';
import chalk from 'chalk';
import figlet from 'figlet';
import { clearInstanceControls, instanceRunnerFailure, isTerminalInstance, readInstance, requestInstanceControl, updateInstance } from './lib/runtime.mjs';
import { activeProxyRoute } from './lib/proxy.mjs';
import { LiveFooter, LiveHeaderBlock, LiveStatusBlock } from './lib/live-footer.mjs';
import { developmentHeaderRows, elapsedSecondsSince } from './lib/run-display.mjs';
import { readRoadmapProgress } from './lib/roadmap.mjs';
import { completedIterationText } from './lib/iteration-history.mjs';
import { instanceOutcome, instanceReportRows } from './lib/instance-outcome.mjs';
import { iterationSummariesSince, latestIterationSummary, projectDataRoot } from './lib/reports.mjs';
import { selectedRoadmapTaskFromEvent } from './lib/task-selection.mjs';
import { projectWindowActionPlan } from './lib/instance-actions.mjs';
import { isCleanWorkerStopEventStream } from './lib/worker-stop.mjs';

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
async function cleanWorkerStopFromFile(filename) {
  if (!filename) return false;
  try { return isCleanWorkerStopEventStream(await fs.readFile(filename, 'utf8')); } catch { return false; }
}
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
  console.log(chalk.gray(`RUNNER  v2.4  ·  ${subtitle}`)); console.log(rule);
  console.log(`${chalk.bold('Workspace')} ${projects.length} project(s)  ${chalk.gray('│')}  ${profiles.length} profile(s)  ${chalk.gray('│')}  Proxy ${route ? route.name : 'Direct'}`); console.log(rule);
}
function renderRunHeader(settings, project, profile, command, roadmap) {
  clear();
  const prefix = [chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' })), chalk.gray('RUNNER  v2.4  ·  Active development run  ·  Dispatcher instance'), rule];
  const dynamic = developmentHeaderRows({ project, profile, command, roadmap, includeTerraLimits: false, run: { elapsedSeconds: 0, lastTask: '', lastCommit: null } });
  const rows = [...prefix, ...dynamic, rule];
  for (const row of rows) console.log(row);
  return { statusRow: rows.reduce((count, row) => count + String(row).split(/\r?\n/).length, 0), liveHeaderRow: Math.max(0, prefix.reduce((count, row) => count + String(row).split(/\r?\n/).length, 0) - 1), command };
}
async function pick(message, choices) { try { return await select({ message, choices: [...choices, { name: '← Back', value: null }], loop: false }); } catch (error) { if (error?.name === 'ExitPromptError') return null; throw error; } }
async function load() { const [settings, instance] = await Promise.all([fs.readFile(configPath, 'utf8').then(JSON.parse), readInstance(configPath, instanceId)]); if (!instance) throw new Error('The dispatcher instance record no longer exists.'); const project = (settings.projects || []).find(item => item.id === instance.projectId); if (!project) throw new Error(`Project '${instance.projectId}' was removed from the configuration.`); return { settings, instance, project }; }
async function show(settings, instance, project) {
  const runSince = Date.parse(instance.runStartedAt || instance.createdAt || '') || 0;
  const [summary, roadmap, runSummaries] = await Promise.all([latestIterationSummary(settings, project, configPath), readRoadmapProgress(project), iterationSummariesSince(settings, project, configPath, runSince)]);
  const outcome = instanceOutcome(instance, summary, roadmap, runSummaries);
  globalHeader(settings);
  for (const row of developmentHeaderRows({ project, profile: instance.profile || {}, command: 'Instance result', roadmap, includeTerraLimits: false })) console.log(row);
  for (const row of instanceReportRows({ instance, project, outcome, logsPath: projectDataRoot(settings, project, configPath), chalk })) console.log(row);
  console.log(rule);
}
async function safeUpdate(patch) { return updateInstance(configPath, instanceId, patch); }
async function request(kind, reason = '') { await requestInstanceControl(configPath, instanceId, kind); await safeUpdate({ state: kind === 'ABORT' ? 'aborting' : 'stopping', activity: kind === 'ABORT' ? 'Emergency abort requested' : 'Finishing the current iteration', ...(reason ? { stopReason: reason } : {}) }); }
async function run(mode, limit = 1) {
  const { settings, instance, project } = await load();
  if (['stopping', 'aborting'].includes(instance.state)) {
    const aborted = instance.state === 'aborting';
    await safeUpdate({ state: aborted ? 'aborted' : 'stopped', runnerPid: null, activity: '', stopReason: aborted ? 'Emergency abort requested before the runner started.' : 'Stop requested before the runner started.' });
    return;
  }
  if (['running', 'starting'].includes(instance.state)) { console.log(chalk.yellow('This instance already has an active runner.')); return; }
  const runStartedAt = new Date().toISOString();
  await clearInstanceControls(configPath, instanceId); await safeUpdate({ state: 'starting', runnerPid: null, activity: 'Preparing OpenCode', runStartedAt });
  const command = mode === 'continuous' ? `Run continuously${limit ? ` for up to ${limit} iteration(s)` : ''}` : 'Run one iteration';
  const roadmap = await readRoadmapProgress(project);
  const header = renderRunHeader(settings, project, instance.profile || {}, command, roadmap);
  const footer = new LiveFooter(process.stdout, controls); const status = new LiveStatusBlock(process.stdout, header.statusRow, 1); const liveHeader = new LiveHeaderBlock(process.stdout, header.liveHeaderRow);
  const liveAttached = footer.enabled && status.enabled; let frame = 0; const frames = ['-', '\\', '|', '/']; let stage = mode === 'continuous' ? 'Preparing continuous development' : 'Preparing iteration'; let detail = ''; let iterationStarted = Date.now(); let eventFile = ''; let eventLines = 0; let toolCount = 0; let checkCount = 0; let activity = ''; let iterationLabel = ''; let selectedTask = ''; let control = ''; let controlNotice = ''; let liveRoadmap = roadmap; let lastTask = ''; let lastCommit = null; const completedIterations = [];
  const statusText = () => `${chalk.cyan(frames[frame++ % frames.length])} ${stage} · ${durationText(Date.now() - iterationStarted)}`;
  const renderStatus = () => status.render(statusText(), detail, completedIterations, controlNotice);
  const renderHeader = () => liveHeader.render([...developmentHeaderRows({ project, profile: instance.profile || {}, command: header.command, roadmap: liveRoadmap, includeTerraLimits: false, run: { elapsedSeconds: elapsedSecondsSince(runStartedAt), lastTask, lastCommit } }), rule]);
  if (liveAttached) { process.stdout.write('\x1b[?25l'); renderHeader(); renderStatus(); footer.render(); }
  else { console.log(`  ${statusText()}`); console.log(`  ${controls}`); }
  const paint = liveAttached ? setInterval(renderStatus, 180) : null;
  const headerUpdate = liveAttached ? setInterval(renderHeader, 1000) : null;
  const onResize = () => { renderHeader(); renderStatus(); footer.render(); };
  if (liveAttached) process.stdout.on('resize', onResize);
  const eventWatch = setInterval(async () => {
    if (!eventFile) return;
    try {
      const lines = (await fs.readFile(eventFile, 'utf8')).split(/\r?\n/).filter(Boolean);
      for (const line of lines.slice(eventLines)) { try { const event = JSON.parse(line); const task = selectedRoadmapTaskFromEvent(event); if (task) { selectedTask = task; detail = ''; } const next = activityFromEvent(event); if (next) { toolCount++; if (next === 'Running verification') checkCount++; activity = next; } } catch { } }
      eventLines = lines.length;
      if (activity) stage = `${iterationLabel ? `${iterationLabel} | ` : ''}${selectedTask ? `${selectedTask} | ` : ''}${activity}${toolCount ? ` | tools ${toolCount}${checkCount ? ` | checks ${checkCount}` : ''}` : ''}`;
    } catch { }
  }, 900);
  const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-UiEvents', '-ClearControlFlags', mode === 'continuous' ? '-Continuous' : '-Once'];
  if (mode === 'continuous') runnerArgs.push(limit > 0 ? '-MaxIterations' : '-UnlimitedIterations', String(limit || ''));
  const child = spawn('pwsh.exe', runnerArgs.filter(Boolean), { cwd: root, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  await safeUpdate({ state: 'running', runnerPid: child.pid, activity: 'OpenCode runner is active' });
  let buffer = ''; let stderr = ''; let runnerFailure = '';
  const consume = async chunk => {
    const text = String(chunk); buffer += text;
    const lines = buffer.split(/\r?\n/); buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.startsWith('__TERRA_UI__')) continue;
      try {
        const event = JSON.parse(line.slice('__TERRA_UI__'.length));
        if (event.type === 'iteration-started') { eventFile = event.eventsFile || ''; eventLines = 0; toolCount = 0; checkCount = 0; activity = ''; selectedTask = ''; iterationStarted = Date.now(); iterationLabel = event.total == null ? `Iteration ${event.iteration}` : `Iteration ${event.iteration} of ${event.total}`; stage = `${iterationLabel} | selecting actionable task | ${event.pending} tasks pending`; detail = ''; }
        if (event.type === 'recovery-finished') { stage = 'Recovered interrupted Terra work'; detail = `Recovery commit ${event.recoveryCommit || 'created and pushed'}`; }
        if (event.type === 'network-waiting') { stage = `Waiting for ${event.source || 'network'} connection`; detail = `Retry ${event.attempt || 1}; next check in ${event.delaySeconds || '?'}s`; }
        if (event.type === 'provider-retry-waiting') { stage = 'Waiting before provider retry'; detail = `Retry ${event.attempt || 1}/${event.maximumAttempts || '?'}; next attempt in ${event.delaySeconds || '?'}s`; }
        if (event.type === 'runner-failed') runnerFailure = String(event.reason || 'runner-internal-error');
        if (event.type === 'iteration-heartbeat') { stage = `Iteration ${event.iteration} | working`; }
        if (event.type === 'iteration-finished') { completedIterations.push(`${event.stoppedReason ? chalk.yellow('!') : chalk.green('✓')} ${completedIterationText(event)}`); lastTask = (Array.isArray(event.completedTaskIds) && event.completedTaskIds.find(Boolean)) || selectedTask || event.taskId || lastTask; lastCommit = Array.isArray(event.commits) ? event.commits[0] || lastCommit : lastCommit; stage = control ? 'Finalizing requested stop' : 'Preparing next iteration'; detail = ''; void readRoadmapProgress(project).then(next => { liveRoadmap = next; if (liveAttached) renderHeader(); }); if (liveAttached) renderHeader(); }
        const instanceActivity = event.type === 'iteration-heartbeat' ? `Iteration ${event.iteration}: ${event.elapsedSeconds}s` : event.type === 'network-waiting' ? `Waiting for ${event.source || 'network'} connection` : event.type === 'provider-retry-waiting' ? 'Waiting before provider retry' : event.type;
        await safeUpdate({ state: 'running', activity: instanceActivity, iteration: event.iteration ?? null });
      } catch { }
    }
  };
  child.stdout.on('data', data => void consume(data)); child.stderr.on('data', data => { stderr += String(data); });
  const requestRunControl = async kind => { if (control) return; control = kind; await request(kind); const message = kind === 'ABORT' ? 'Emergency abort requested' : 'Stop requested'; controlNotice = chalk.yellow(`! ${message}. ${kind === 'ABORT' ? 'The current iteration will be terminated.' : 'The current iteration will finish, then development will stop.'}`); if (liveAttached) renderStatus(); else console.log(`  ${controlNotice}`); };
  const keyHandler = data => { const key = String(data).toLowerCase(); if (key === 's' || key === '\u0003') void requestRunControl('STOP'); if (key === 'x') void requestRunControl('ABORT'); };
  if (process.stdin.isTTY) { process.stdin.setRawMode?.(true); process.stdin.resume(); process.stdin.on('data', keyHandler); }
  await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); }).then(async code => {
    const current = await readInstance(configPath, instanceId); const aborted = current?.state === 'aborting'; const stopped = current?.state === 'stopping';
    // A runner can fail while serialising its report after OpenCode has already
    // emitted its authoritative clean terminal event. Preserve that verified
    // agent outcome instead of labelling the project run as a provider failure.
    const cleanWorkerStop = code !== 0 && await cleanWorkerStopFromFile(eventFile);
    const effectiveCode = cleanWorkerStop ? 0 : code;
    const failed = !aborted && !stopped && effectiveCode !== 0;
    const [roadmapAfter, summaryAfter] = await Promise.all([readRoadmapProgress(project), latestIterationSummary(settings, project, configPath)]);
    const normalReason = cleanWorkerStop ? 'OpenCode ended with a verified clean stop event.' : roadmapAfter.available && roadmapAfter.pending === 0 ? `Roadmap complete — all ${roadmapAfter.total} task(s) are done.` : String(summaryAfter?.stoppedReason || '');
    const safetyStopped = effectiveCode === 0 && (cleanWorkerStop || (Boolean(summaryAfter?.stoppedReason) && summaryAfter.stoppedReason !== 'roadmap-complete'));
    await safeUpdate({ state: aborted ? 'aborted' : stopped || safetyStopped ? 'stopped' : effectiveCode === 0 ? 'finished' : 'failed', runnerPid: null, activity: '', error: failed ? (runnerFailure || instanceRunnerFailure(stderr, code)) : '', stopReason: aborted ? 'Emergency abort completed.' : stopped ? String(current?.stopReason || 'Graceful stop completed.') : effectiveCode === 0 ? normalReason : `runner exit ${code}` });
  }).catch(async error => { await safeUpdate({ state: 'failed', runnerPid: null, error: error.message, activity: '' }); }).finally(() => {
    if (paint) clearInterval(paint); if (headerUpdate) clearInterval(headerUpdate); clearInterval(eventWatch); if (liveAttached) process.stdout.off('resize', onResize); liveHeader.clear(); status.clear(); footer.clear(); if (liveAttached) process.stdout.write('\x1b[?25h');
  });
  if (process.stdin.isTTY) { process.stdin.off('data', keyHandler); process.stdin.setRawMode?.(false); }
}
async function preflight() {
  const { settings, instance, project } = await load(); renderRunHeader(settings, project, instance.profile || {}, 'Dry run', await readRoadmapProgress(project)); const child = spawn('pwsh.exe', ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', instance.projectId, '-Config', configPath, '-InstanceId', instanceId, '-DryRun'], { cwd: root, stdio: 'inherit' });
  await new Promise(resolve => child.once('close', resolve));
}
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
    const action = await pick('Project instance', projectWindowActionPlan(instance).map(item => ({ ...item, name: item.destructive ? chalk.red(item.name) : item.name })));
    if (!action || action === 'close') { if (['running', 'starting', 'stopping', 'aborting'].includes(instance.state)) { console.log(chalk.yellow('Request Stop or Abort before closing this active project window.')); await input({ message: 'Press Enter to continue' }); continue; } if (!isTerminalInstance(instance)) await safeUpdate({ state: 'stopped', activity: 'Project window closed' }); return; }
    if (action === 'once') await run('once');
    if (action === 'continuous') { const raw = String(await input({ message: 'Iterations (0 = until a safety stop)', default: '0' })).trim(); const limit = /^\d+$/.test(raw) ? Number(raw) : 0; await run('continuous', limit); }
    if (action === 'preflight') await preflight(); if (action === 'stop') await request('STOP'); if (action === 'abort') await request('ABORT');
    if (action !== 'once' && action !== 'continuous') await input({ message: 'Press Enter to continue' });
  }
}
main().catch(async error => { try { await safeUpdate({ state: 'failed', error: error.message, activity: '' }); } catch { } console.error(chalk.red(`Terra project instance failed: ${error.message}`)); process.exitCode = 1; });
