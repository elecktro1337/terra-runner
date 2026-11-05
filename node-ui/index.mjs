#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import inquirer from 'inquirer';
import chalk from 'chalk';
import figlet from 'figlet';
import ora from 'ora';
import { activeProfile, applyProfile, isLocalModel, migrateProfiles, profileFrom } from './lib/profiles.mjs';
import { normalizeProjects, validateProjectId } from './lib/projects.mjs';
import { dailyReports, latestIterationSummary, iterationSummariesSince, projectDataRoot } from './lib/reports.mjs';
import { DIRECT_ROUTE_ID, PROXY_PROTOCOLS, activeProxyRoute, normalizeProxy, redactedRoute, validateProxyRoute } from './lib/proxy.mjs';
import { authStorePath, cleanupLegacyReservations, createInstance, isTerminalInstance, listInstances, normalizeRuntime, requestInstanceControl, updateInstance, writeCoordinatorHeartbeat, removeCoordinatorHeartbeat } from './lib/runtime.mjs';
import { LiveFooter } from './lib/live-footer.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const valueOf = name => { const i = args.indexOf(name); return i < 0 ? '' : args[i + 1]; };
const configPath = valueOf('--config') || (args.includes('--portable') ? path.join(root, 'terra-config.json') : path.join(process.env.LOCALAPPDATA || process.env.APPDATA || root, 'TerraRunner', 'terra-config.json'));
const rule = chalk.gray('─'.repeat(78));
const input = options => inquirer.prompt([{ type: 'input', name: 'value', ...options }]).then(answer => answer.value);
const secretInput = options => inquirer.prompt([{ type: 'password', name: 'value', mask: '*', ...options }]).then(answer => answer.value);
const confirm = options => inquirer.prompt([{ type: 'confirm', name: 'value', ...options }]).then(answer => answer.value);
const select = options => inquirer.prompt([{ type: 'list', name: 'value', ...options }]).then(answer => answer.value);
function clear() { if (process.stdout.isTTY) process.stdout.write('\x1Bc'); }
function pause() { return input({ message: 'Press Enter to continue' }); }
async function pick(message, choices) {
  try { return await select({ message, choices: [...choices, { name: '← Back', value: null }], loop: false, pageSize: 14 }); }
  catch (error) { if (error?.name === 'ExitPromptError') return null; throw error; }
}
async function yesNo(message, defaultValue = false) { try { return await confirm({ message, default: defaultValue }); } catch { return false; } }
async function resolveCommand(name) {
  if (path.isAbsolute(name) || /[\\/]/.test(name)) return name;
  if (process.platform !== 'win32') return name;
  const npmShim = path.join(process.env.APPDATA || '', 'npm', `${name}.cmd`);
  try { await fs.access(npmShim); return npmShim; } catch { }
  const locations = await new Promise((resolve, reject) => {
    const child = spawn('where.exe', [name], { cwd: root, shell: false, stdio: ['ignore', 'pipe', 'pipe'] }); let stdout = '';
    child.stdout.on('data', chunk => stdout += chunk); child.once('error', reject);
    child.once('close', code => code === 0 ? resolve(stdout) : reject(new Error(`Command '${name}' was not found on PATH.`)));
  });
  return locations.split(/\r?\n/).map(line => line.trim()).find(Boolean);
}
async function execute(name, commandArgs, cwd = root, inherited = false, extraEnv = null) {
  const executable = await resolveCommand(name);
  return new Promise((resolve, reject) => {
    const batch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(executable);
    // Windows npm CLIs are .cmd files. Pass the nested command unchanged to
    // cmd.exe; Node's normal Windows escaping otherwise turns quotes literal.
    const quote = value => `"${String(value).replace(/"/g, '""')}"`;
    const commandLine = `"${quote(executable)} ${commandArgs.map(quote).join(' ')}"`;
    const child = batch
      ? spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', commandLine], { cwd, shell: false, windowsVerbatimArguments: true, stdio: inherited ? 'inherit' : ['ignore', 'pipe', 'pipe'], env: extraEnv ? { ...process.env, ...extraEnv } : process.env })
      : spawn(executable, commandArgs, { cwd, shell: false, stdio: inherited ? 'inherit' : ['ignore', 'pipe', 'pipe'], env: extraEnv ? { ...process.env, ...extraEnv } : process.env });
    let stdout = '', stderr = '';
    if (!inherited) { child.stdout.on('data', data => stdout += data); child.stderr.on('data', data => stderr += data); }
    child.once('error', reject); child.once('close', code => code === 0 ? resolve(stdout) : reject(new Error(`${executable} exited with code ${code}${stderr ? `: ${stderr.trim()}` : ''}`)));
  });
}
async function protectSecret(value) {
  return new Promise((resolve, reject) => { const child = spawn('pwsh.exe', ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-secret.ps1'), '-Action', 'Protect'], { stdio: ['pipe', 'pipe', 'pipe'] }); let out = '', err = ''; child.stdout.on('data', data => out += data); child.stderr.on('data', data => err += data); child.once('error', reject); child.once('close', code => code === 0 ? resolve(out.trim()) : reject(new Error(err.trim() || 'Could not protect proxy password.'))); child.stdin.end(value); });
}
function durationText(milliseconds) {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}
function showRunSummary(summary, settings, project) {
  const completed = Array.isArray(summary?.completedTaskIds) ? summary.completedTaskIds : [];
  const changed = Number(summary?.doneAfter || 0) - Number(summary?.doneBefore || 0);
  const exit = Number(summary?.exitCode ?? -1);
  const success = exit === 0 && !summary?.stoppedReason;
  console.log(`\n${success ? chalk.green.bold('ITERATION COMPLETE') : chalk.yellow.bold('ITERATION FINISHED WITH WARNINGS')}`);
  console.log(rule);
  console.log(`  ${chalk.gray('Duration')}    ${durationText(Number(summary?.elapsedSeconds || 0) * 1000)}`);
  console.log(`  ${chalk.gray('Roadmap')}     ${changed > 0 ? chalk.green(`+${changed} completed`) : 'no tasks completed'}  │  ${summary?.pendingAfter ?? '?'} pending`);
  console.log(`  ${chalk.gray('Tasks')}       ${completed.length ? chalk.cyan(completed.join(', ')) : 'none recorded'}`);
  console.log(`  ${chalk.gray('Changes')}     ${summary?.codeFilesChanged ?? 0} code  │  ${summary?.testFilesChanged ?? 0} test files  │  ${summary?.documentationFilesChanged ?? 0} docs`);
  console.log(`  ${chalk.gray('Verification')} ${summary?.verificationCommandsObserved ?? 0} command(s) observed${Number(summary?.verificationCommandErrors || 0) ? chalk.yellow(` │ ${summary.verificationCommandErrors} reported error(s)`) : ''}`);
  if (Number(summary?.toolErrors || 0)) console.log(`  ${chalk.yellow('Attention')}   ${summary.toolErrors} tool error(s); inspect the iteration log before relying on the result.`);
  if (summary?.stoppedReason) console.log(`  ${chalk.yellow('Stop reason')} ${summary.stoppedReason}`);
  if (summary?.pushVerified === false) console.log(`  ${chalk.yellow('Git')}         push was not verified`);
  console.log(`  ${chalk.gray('Logs')}        ${path.join(projectDataRoot(settings, project, configPath), 'logs')}`);
  console.log(rule);
}
function showRunOverview(runs, settings, project) {
  const summary = runs.at(-1) || {};
  const completed = [...new Set(runs.flatMap(run => Array.isArray(run?.completedTaskIds) ? run.completedTaskIds : []))];
  const taskCount = runs.reduce((total, run) => total + Math.max(0, Number(run?.doneAfter || 0) - Number(run?.doneBefore || 0)), 0);
  const elapsed = runs.reduce((total, run) => total + Number(run?.elapsedSeconds || 0), 0);
  const code = runs.reduce((total, run) => total + Number(run?.codeFilesChanged || 0), 0);
  const tests = runs.reduce((total, run) => total + Number(run?.testFilesChanged || 0), 0);
  const docs = runs.reduce((total, run) => total + Number(run?.documentationFilesChanged || 0), 0);
  const checks = runs.reduce((total, run) => total + Number(run?.verificationCommandsObserved || 0), 0);
  const checkErrors = runs.reduce((total, run) => total + Number(run?.verificationCommandErrors || 0), 0);
  const toolErrors = runs.reduce((total, run) => total + Number(run?.toolErrors || 0), 0);
  const success = runs.every(run => Number(run?.exitCode ?? -1) === 0 && !run?.stoppedReason);
  console.log(`\n${success ? chalk.green.bold('DEVELOPMENT RUN COMPLETE') : chalk.yellow.bold('DEVELOPMENT RUN FINISHED WITH WARNINGS')}`);
  console.log(rule);
  console.log(`  ${chalk.gray('Iterations')} ${runs.length} completed`);
  console.log(`  ${chalk.gray('Duration')}    ${durationText(elapsed * 1000)}`);
  console.log(`  ${chalk.gray('Roadmap')}     ${taskCount ? chalk.green(`+${taskCount} completed`) : 'no tasks completed'} | ${summary.pendingAfter ?? '?'} pending`);
  console.log(`  ${chalk.gray('Tasks')}       ${completed.length ? chalk.cyan(completed.join(', ')) : 'no task ID recorded'}`);
  console.log(`  ${chalk.gray('Changes')}     ${code} code | ${tests} test files | ${docs} docs`);
  console.log(`  ${chalk.gray('Verification')} ${checks} command(s) observed${checkErrors ? chalk.yellow(` | ${checkErrors} reported error(s)`) : ''}`);
  if (summary.quotaEstimatedSpendUSD != null) console.log(`  ${chalk.gray('Estimate')}    provider snapshot ${summary.quotaReportedRemaining} ${summary.quotaUnit} | local OpenCode spend $${Number(summary.quotaEstimatedSpendUSD).toFixed(4)} | estimated ${summary.quotaRemaining} ${summary.quotaUnit}`);
  if (toolErrors) console.log(`  ${chalk.yellow('Attention')}   ${toolErrors} tool error(s); inspect the iteration log before relying on the result.`);
  if (summary.stoppedReason) console.log(`  ${chalk.yellow('Stop reason')} ${summary.stoppedReason}`);
  console.log(`  ${chalk.gray('Logs')}        ${path.join(projectDataRoot(settings, project, configPath), 'logs')}`);
  console.log(rule);
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
function iterationCheckpointText(event) {
  const tasks = Array.isArray(event.completedTaskIds) && event.completedTaskIds.length ? event.completedTaskIds.join(', ') : event.completedCount ? `+${event.completedCount} roadmap task(s)` : 'no roadmap task completed';
  const commit = Array.isArray(event.commits) && event.commits.length ? event.commits.map(item => item.hash ? `${item.hash} ${item.subject || ''}`.trim() : String(item)).join(', ') : 'no commit recorded';
  const stopped = event.stoppedReason ? ` | ${event.stoppedReason}` : '';
  const cost = event.costDeltaUSD == null ? '' : ` | $${Number(event.costDeltaUSD).toFixed(4)}`;
  const total = Number(event.totalRoadmap || 0); const done = Number(event.doneAfter || 0);
  const roadmap = total ? ` | roadmap ${done}/${total} (${((done / total) * 100).toFixed(1)}%)` : '';
  return `Iteration ${event.iteration} complete | ${tasks} | ${durationText(Number(event.elapsedSeconds || 0) * 1000)}${cost}${roadmap} | ${commit}${stopped}`;
}
function showRunnerFailure(output) {
  const text = String(output || ''); let title = 'DEVELOPMENT DID NOT START'; let reason = 'Terra Runner could not start the development run.'; let action = 'Open the project logs or run Project preflight, then try again.'; let detail = '';
  if (/working tree has uncommitted\/untracked changes/i.test(text)) {
    reason = 'The project has uncommitted or untracked files.';
    action = 'Review the changes, then commit, stash, or remove them before starting automated development.';
  } else if (/local and remote branch heads differ/i.test(text)) {
    reason = 'The local Git branch does not match the configured remote branch.';
    action = 'Review the branch and resolve the pending push or pull before starting again.';
  } else if (/snapshot is stale|snapshot is not configured/i.test(text)) {
    reason = 'The provider balance or quota snapshot is missing or no longer current.';
    action = 'Start the run again and enter an updated provider snapshot when prompted.';
  } else if (/OpenCode command .* not found/i.test(text)) {
    reason = 'OpenCode could not be found.';
    action = 'Check the OpenCode installation and command path in the configuration.';
  } else if (/wrong Git branch/i.test(text)) {
    reason = 'The checked-out Git branch does not match this project profile.';
    action = 'Switch to the configured branch, then start again.';
  } else if (/STOP flag exists|ABORT flag exists/i.test(text)) {
    reason = 'A previous development run left a stop request behind.';
    action = 'Start the run from the Node interface again; it now clears stale control flags automatically.';
  } else {
    const lines = text.split(/\r?\n/).map(line => line.trim().replace(/^\|\s?/, '')).filter(line => line && !/^Line \|$|^~+$|^Exception:$/.test(line));
    detail = lines.reverse().find(line => !/^(at |CategoryInfo|FullyQualifiedErrorId|\+ CategoryInfo)/i.test(line)) || '';
  }
  console.log(`\n${chalk.red.bold(title)}`); console.log(rule);
  console.log(`  ${chalk.bold('Reason')}  ${reason}`); if (detail) console.log(`  ${chalk.bold('Detail')}  ${detail.slice(0, 360)}`); console.log(`  ${chalk.bold('Next step')} ${action}`); console.log(rule);
}
async function runWithTui(runnerArgs, settings, project, mode) {
  const executable = await resolveCommand('pwsh.exe');
  const previousSummaryId = (await latestIterationSummary(settings, project, configPath))?.id || '';
  const started = Date.now(); let iterationStarted = started; let stdout = ''; let stderr = ''; let stage = mode === 'continuous' ? 'Preparing continuous development' : mode === 'dry-run' ? 'Preparing dry run' : 'Preparing iteration';
  let eventFile = ''; let eventLines = 0; let toolCount = 0; let checkCount = 0; let activity = ''; let iterationLabel = ''; let control = '';
  const interactive = Boolean(process.stdin.isTTY);
  const controls = chalk.gray('Controls: [S] stop after this iteration  |  [X] emergency stop current iteration  |  [Ctrl+C] safe stop');
  const footer = new LiveFooter(process.stdout, controls);
  const spinnerFrames = ['-', '\\', '|', '/']; let frame = 0;
  const statusText = () => `${chalk.cyan(spinnerFrames[frame++ % spinnerFrames.length])} ${stage} · ${durationText(Date.now() - iterationStarted)}`;
  const renderFooter = () => footer.render(statusText());
  const footerAttached = footer.enabled;
  if (footerAttached) { process.stdout.write('\x1b[?25l'); renderFooter(); }
  else { console.log(rule); console.log(chalk.gray(`  ${controls}`)); }
  const update = setInterval(renderFooter, 180);
  const onResize = () => renderFooter();
  if (footerAttached) process.stdout.on('resize', onResize);
  const liveUpdate = setInterval(async () => {
    if (!eventFile) return;
    try {
      const lines = (await fs.readFile(eventFile, 'utf8')).split(/\r?\n/).filter(Boolean);
      for (const line of lines.slice(eventLines)) {
        try { const next = activityFromEvent(JSON.parse(line)); if (next) { toolCount++; if (next === 'Running verification') checkCount++; activity = next; } } catch { }
      }
      eventLines = lines.length;
      const counters = toolCount ? ` | tools ${toolCount}${checkCount ? ` | checks ${checkCount}` : ''}` : '';
      if (activity) stage = `${iterationLabel ? `${iterationLabel} | ` : ''}${activity}${counters}`;
    } catch { }
  }, 900);
  const requestControl = async kind => {
    if (control) return;
    control = kind;
    const file = path.join(projectDataRoot(settings, project, configPath), kind === 'abort' ? 'ABORT' : 'STOP');
    try {
      await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, `${kind} requested by user at ${new Date().toISOString()}\n`, 'utf8');
      const message = kind === 'abort' ? 'Emergency stop requested. The current iteration will be terminated.' : 'Stop requested. The current iteration will finish, then development will stop.';
      footer.persist(chalk.yellow(`! ${message}`)); stage = kind === 'abort' ? 'Stopping current iteration' : 'Finishing current iteration'; renderFooter();
    } catch (error) { control = ''; footer.persist(chalk.red(`x Could not request stop: ${error.message}`)); renderFooter(); }
  };
  const onInput = data => { const key = String(data).toLowerCase(); if (key === 's' || key === '\u0003') void requestControl('stop'); if (key === 'x') void requestControl('abort'); };
  const onSigint = () => { void requestControl('stop'); };
  if (interactive) { process.stdin.setRawMode?.(true); process.stdin.resume(); process.stdin.on('data', onInput); process.on('SIGINT', onSigint);
  }
  const cleanupControls = () => { if (!interactive) return; process.stdin.off('data', onInput); process.off('SIGINT', onSigint); process.stdin.setRawMode?.(false); };
  try {
    const result = await new Promise((resolve, reject) => {
      const child = spawn(executable, runnerArgs, { cwd: root, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
      let buffer = '';
      const handleLine = line => {
        if (line.startsWith('__TERRA_UI__')) {
          try {
            const event = JSON.parse(line.slice('__TERRA_UI__'.length));
            if (event.type === 'iteration-started') {
              eventFile = event.eventsFile || ''; eventLines = 0; toolCount = 0; checkCount = 0; activity = ''; iterationStarted = Date.now();
              iterationLabel = event.total == null ? `Iteration ${event.iteration}` : `Iteration ${event.iteration} of ${event.total}`;
              stage = `${iterationLabel} | ${event.taskId || 'next roadmap task'} | ${event.pending} tasks pending`;
            }
              if (event.type === 'iteration-finished') { footer.persist(`${event.stoppedReason ? chalk.yellow('!') : chalk.green('✓')} ${iterationCheckpointText(event)}`); stage = 'Preparing next iteration'; renderFooter(); }
          } catch { }
          return;
        }
        const match = line.match(/^Iteration (\d+)\/(\d+).*pending tasks:\s*(\d+)/i);
        if (match && runnerArgs.includes('-UnlimitedIterations')) return;
        if (match) stage = `Iteration ${match[1]} of ${match[2]} · ${match[3]} tasks pending`;
        if (/^Iteration finished:/i.test(line)) stage = 'Verifying iteration result';
        if (/^Daily project report:/i.test(line)) stage = 'Writing project report';
      };
      child.stdout.on('data', chunk => { const text = chunk.toString(); stdout += text; buffer += text; const lines = buffer.split(/\r?\n/); buffer = lines.pop(); lines.forEach(handleLine); });
      child.stderr.on('data', chunk => { stderr += chunk.toString(); });
      child.once('error', reject); child.once('close', code => resolve({ code, stdout, stderr }));
    });
    clearInterval(update); clearInterval(liveUpdate); cleanupControls(); if (footerAttached) process.stdout.off('resize', onResize); footer.clear(); if (footerAttached) process.stdout.write('\x1b[?25h');
    if (result.code === 0) console.log(chalk.green(`✓ Development run finished · ${durationText(Date.now() - started)}`));
    else console.log(chalk.red('x Development run could not start.'));
    const summaries = (await iterationSummariesSince(settings, project, configPath, started)).filter(summary => summary.id !== previousSummaryId);
    if (summaries.length) showRunOverview(summaries, settings, project);
    else if (result.code !== 0) showRunnerFailure(result.stderr || result.stdout);
    return result.code === 0;
  } catch (error) {
    clearInterval(update); clearInterval(liveUpdate); cleanupControls(); if (footerAttached) process.stdout.off('resize', onResize); footer.clear(); if (footerAttached) process.stdout.write('\x1b[?25h'); console.log(chalk.red(`x Development runner could not start: ${error.message}`)); return false;
  }
}
async function load() { try { const settings = JSON.parse(await fs.readFile(configPath, 'utf8')); settings.openCode ||= { accounts: [], activeAccountId: '', reasoning: {} }; settings.openCode.accounts ||= []; migrateProfiles(settings); normalizeRuntime(settings); normalizeProxy(settings); return settings; } catch (error) { throw new Error(`Cannot load ${configPath}. Run the setup wizard once or pass --config <file>. ${error.message}`); } }
async function save(settings) { settings.schemaVersion = 8; migrateProfiles(settings); normalizeProjects(settings); normalizeRuntime(settings); normalizeProxy(settings); await fs.mkdir(path.dirname(configPath), { recursive: true }); const temp = `${configPath}.${process.pid}.tmp`; await fs.writeFile(temp, `${JSON.stringify(settings, null, 2)}\n`, 'utf8'); await fs.rename(temp, configPath); }
function parseModels(text) { return [...new Set(text.split(/\r?\n/).map(v => v.trim()).filter(v => /^[a-z0-9_.-]+\/.+/i.test(v)))]; }
function storeEnvironment(storeId) { return storeId && storeId !== 'legacy-shared' ? { OPENCODE_DB: authStorePath(configPath, storeId) } : null; }
function authStore(settings, id) { return (settings.openCode?.stores || []).find(store => store.id === id) || null; }
async function refreshOpenCode(settings, storeId = 'legacy-shared') {
  const spinner = ora('Reading OpenCode accounts and models…').start();
  try {
    const executable = settings.openCodeCommand || 'opencode'; const env = storeEnvironment(storeId); const raw = await execute(executable, ['auth', 'list', '--format', 'json'], root, false, env); const providers = JSON.parse(raw); const accounts = [];
    for (const provider of providers) for (const credential of provider.connections || []) accounts.push({ id: `${provider.id}:${credential.id}`, provider: provider.id, credentialId: credential.id, label: credential.label || provider.name || provider.id, authMethod: credential.method || '', usageKind: credential.method === 'oauth' ? 'oauth' : 'balance' });
    const models = parseModels(await execute(executable, ['models'], root, false, env)); if (storeId === 'legacy-shared') settings.openCode.accounts = [...accounts, ...settings.openCode.accounts.filter(account => account.authMethod === 'local')];
    spinner.succeed(`OpenCode refreshed: ${accounts.length} account(s), ${models.length} model(s).`); return { accounts, models };
  } catch (error) { spinner.fail('OpenCode refresh failed.'); throw error; }
}
function limitSummary(profile) {
  if (!profile) return 'No profile selected'; if (profile.policy === 'local') return 'No provider limits';
  const snapshot = profile.usageSource || {}; if (snapshot.remaining == null) return 'Snapshot required before development';
  const unit = snapshot.unit === 'usd' ? 'USD' : '%'; const policy = profile.limitPolicy || {};
  if (policy.mode === 'critical') return `Minimum ${policy.amount ?? 0} ${unit}; next-run reserve ${policy.reserve ?? snapshot.reserve ?? 0} ${unit}`;
  if (policy.mode === 'hourly') return `Hourly cap $${policy.amount}`;
  if (policy.mode === 'daily') return `Daily cap $${policy.amount}`;
  if (policy.mode === 'refresh-hourly') return 'Fresh snapshot required hourly'; if (policy.mode === 'refresh-daily') return 'Fresh snapshot required daily'; return 'Unlimited';
}
function usageSourceSummary(profile) {
  const source = profile?.usageSource || {}; if (source.kind !== 'snapshot') return 'Not applicable';
  const unit = source.unit === 'usd' ? 'USD' : 'percent'; const value = source.remaining == null ? 'not set' : `${source.remaining} ${unit}`;
  return `Snapshot: ${value}; reserve ${source.reserve ?? 0} ${unit}; refresh within ${source.maxAgeMinutes ?? 120} min`;
}
function snapshotFreshness(profile) {
  if (!profile || profile.policy === 'local' || profile.limitPolicy?.mode === 'unlimited') return { ok: true, detail: 'not required' };
  const snapshot = profile.usageSource || {}; if (snapshot.remaining == null || !snapshot.observedAt) return { ok: false, detail: 'snapshot is not configured' };
  const observed = Date.parse(snapshot.observedAt); const maxAge = Number(snapshot.maxAgeMinutes || 120); const age = (Date.now() - observed) / 60000;
  if (!Number.isFinite(observed) || age < -2 || age > maxAge) return { ok: false, detail: `snapshot is stale (${Math.max(0, age).toFixed(1)} min; refresh interval ${maxAge} min)` };
  return { ok: true, detail: `fresh (${age.toFixed(1)} min old)` };
}
function profileKindLabel(profile) {
  if (profile.policy === 'local') return chalk.green('[LOCAL]');
  if (profile.policy === 'oauth-managed') return chalk.magenta('[OAUTH]');
  return chalk.yellow('[API]');
}
function header(settings) {
  clear(); const profile = activeProfile(settings);
  console.log(chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' }))); console.log(chalk.gray('RUNNER  v2.2  ·  Local OpenCode development orchestrator')); console.log(rule);
  const account = settings.openCode?.accounts?.find(item => item.id === settings.openCode?.activeAccountId); const snapshot = profile?.usageSource || {}; const unit = snapshot.unit === 'usd' ? 'USD' : '%';
  const balance = profile?.policy === 'local' ? 'not applicable' : snapshot.remaining == null ? 'snapshot required' : `${snapshot.remaining} ${unit}`;
  const age = snapshot.observedAt ? `${Math.max(0, (Date.now() - Date.parse(snapshot.observedAt)) / 60000).toFixed(0)} min ago` : 'not recorded';
  console.log(`${chalk.bold('Account')}   ${account?.label || profile?.credentialLabel || 'not selected'}  ${chalk.gray('│')}  ${profileKindLabel(profile || {})}  ${chalk.gray('│')}  ${chalk.cyan(profile?.model || 'not selected')}  ${chalk.gray('│')}  Reasoning ${profile?.reasoningVariant || 'provider default'}`);
  console.log(`${chalk.bold('Snapshot')}  ${balance}  ${chalk.gray(`│ ${age}`)}`); console.log(`${chalk.bold('Limits')}    ${chalk.yellow(limitSummary(profile))}`);
  if (snapshot.costTracking?.enabled) console.log(`${chalk.bold('OpenCode')}  local cost estimate enabled`);
  else if (profile?.policy === 'api' && snapshot.unit === 'usd') console.log(`${chalk.bold('OpenCode')}  local cost estimate is off`);
  console.log(rule);
}
function numberValue(raw, fallback) { const parsed = Number(String(raw).trim().replace(',', '.')); return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback; }
async function configureLimits(settings, profile) {
  if (profile.policy === 'local') { console.log(chalk.green('\nLocal profile: no balance or quota limits are shown or enforced.')); return pause(); }
  if (profile.policy === 'oauth-managed') { console.log(chalk.yellow('\nOAuth profile: usage, allowance and reset windows are managed by the provider.')); console.log(chalk.gray('No manual quota snapshot is stored or enforced by Terra Runner.')); return pause(); }
  const limits = structuredClone(profile.limits || settings.budget || {}); limits.balance ||= {};
  const mode = await pick('API spending policy', [{ name: 'Daily spending limit', value: 'daily' }, { name: 'Minimum balance floor', value: 'balance' }, { name: 'Daily limit and balance floor', value: 'hybrid' }, { name: 'Unlimited (requires confirmation)', value: 'unlimited' }]); if (!mode) return;
  if (mode === 'unlimited' && !(await yesNo('Disable local API spending limits for this profile?'))) return;
  limits.mode = mode; limits.allowUnlimited = mode === 'unlimited';
  if (mode === 'daily' || mode === 'hybrid') { limits.dailyUsd = numberValue(await input({ message: 'Daily limit (USD)', default: String(limits.dailyUsd ?? 5) }), Number(limits.dailyUsd ?? 5)); limits.reserveUsd = numberValue(await input({ message: 'Daily safety reserve (USD)', default: String(limits.reserveUsd ?? .5) }), Number(limits.reserveUsd ?? .5)); }
  if (mode === 'balance' || mode === 'hybrid') { limits.balance.minimumUsd = numberValue(await input({ message: 'Minimum balance (USD)', default: String(limits.balance.minimumUsd ?? 5) }), Number(limits.balance.minimumUsd ?? 5)); limits.balance.iterationReserveUsd = numberValue(await input({ message: 'Next-run reserve (USD)', default: String(limits.balance.iterationReserveUsd ?? .5) }), Number(limits.balance.iterationReserveUsd ?? .5)); }
  profile.limits = limits; if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings); console.log(chalk.green('Profile limits saved.')); return pause();
}
async function configureSnapshot(settings, profile) {
  if (profile.policy === 'local') { console.log(chalk.green('\nLocal profile: snapshots and provider limits are not applicable.')); return pause(); }
  const current = profile.usageSource?.kind === 'snapshot' ? profile.usageSource : { unit: 'percent', remaining: null, reserve: 5, maxAgeMinutes: 120 };
  const unit = await pick('Balance/quota snapshot unit', [{ name: 'Percent remaining (0–100)', value: 'percent' }, { name: 'Money remaining (USD)', value: 'usd' }]); if (!unit) return;
  const defaultRemaining = current.remaining == null ? (unit === 'percent' ? 100 : 0) : current.remaining;
  const remaining = numberValue(await input({ message: unit === 'percent' ? 'Provider-reported remaining percent' : 'Provider-reported remaining USD', default: String(defaultRemaining) }), Number(defaultRemaining));
  if (unit === 'percent' && remaining > 100) { console.log(chalk.yellow('Percent cannot exceed 100.')); return pause(); }
  const maxAgeMinutes = numberValue(await input({ message: 'Snapshot refresh interval (minutes)', default: String(current.maxAgeMinutes ?? 120) }), Number(current.maxAgeMinutes ?? 120));
  if (maxAgeMinutes < 1) { console.log(chalk.yellow('Refresh interval must be at least one minute.')); return pause(); }
  profile.usageSource = { kind: 'snapshot', unit, remaining, reserve: current.reserve ?? 0, maxAgeMinutes, observedAt: new Date().toISOString(), costTracking: { enabled: false, baselineAllTimeCostUsd: null, baselineObservedAt: '' } };
  if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings);
  const persisted = JSON.parse(await fs.readFile(configPath, 'utf8')); const saved = persisted.openCode?.profiles?.find(item => item.id === profile.id)?.usageSource;
  if (!saved || Number(saved.remaining) !== remaining || saved.unit !== unit) throw new Error('Snapshot save verification failed. Reopen the profile before starting development.');
  console.log(chalk.green('Provider snapshot saved.')); if (current.costTracking?.enabled) console.log(chalk.gray('The local OpenCode cost estimate was reset; enable it again to establish a new baseline.')); return pause();
}
function openCodeCostFromStats(value) {
  if (!value || typeof value !== 'object') return null;
  for (const key of ['totalCost', 'total_cost', 'totalUSD', 'cost']) {
    const candidate = Number(value[key]); if (Number.isFinite(candidate) && candidate >= 0) return candidate;
  }
  for (const key of ['totals', 'usage', 'stats']) { const nested = openCodeCostFromStats(value[key]); if (nested != null) return nested; }
  return null;
}
async function configureOpenCodeCostEstimate(settings, profile) {
  if (profile.policy === 'local') { console.log(chalk.green('Local models have no provider balance estimate.')); return pause(); }
  if (profile.usageSource?.unit !== 'usd') { console.log(chalk.yellow('This option needs a USD provider snapshot. Set the snapshot unit to USD first.')); return pause(); }
  console.log(chalk.bold('LOCAL OPENCODE COST ESTIMATE'));
  console.log(chalk.gray('This subtracts locally recorded OpenCode spend from your last provider-reported USD snapshot.'));
  console.log(chalk.gray('It is an estimate, not a provider balance, and it covers all OpenCode usage recorded by this installation.'));
  if (!(await yesNo('Enable this estimate for the active snapshot?'))) return;
  const spinner = ora('Reading local OpenCode lifetime usage...').start();
  try {
    const raw = await execute(settings.openCodeCommand || 'opencode', ['stats', '--all', '--json'], root);
    const cost = openCodeCostFromStats(JSON.parse(raw));
    if (cost == null) throw new Error('OpenCode did not return a usable lifetime cost.');
    profile.usageSource.costTracking = { enabled: true, baselineAllTimeCostUsd: cost, baselineObservedAt: new Date().toISOString() };
    if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile);
    await save(settings); spinner.succeed(`Cost estimate enabled from local OpenCode baseline $${cost.toFixed(4)}.`);
  } catch (error) { spinner.fail('Cost estimate was not enabled.'); console.log(chalk.red(error.message)); }
  return pause();
}
async function refreshSnapshotBeforeRun(settings, profile, reason) {
  header(settings);
  console.log(chalk.bold.cyan('PROVIDER SNAPSHOT REQUIRED'));
  console.log(chalk.gray('Enter the current provider-reported balance or quota to continue safely.'));
  console.log(`  ${chalk.yellow(reason.detail)}`);
  const current = profile.usageSource?.kind === 'snapshot' ? profile.usageSource : { unit: 'percent', remaining: null, reserve: 0, maxAgeMinutes: 120 };
  let unit = current.unit === 'usd' ? 'usd' : 'percent';
  if (current.remaining == null) {
    unit = await pick('Snapshot unit', [{ name: 'Money remaining (USD)', value: 'usd' }, { name: 'Quota remaining (percent)', value: 'percent' }]);
    if (!unit) return false;
  }
  const label = unit === 'usd' ? 'Provider-reported remaining USD' : 'Provider-reported remaining percent';
  const raw = await input({ message: label, default: current.remaining == null ? '' : String(current.remaining) });
  const remaining = numberValue(raw, NaN);
  if (!Number.isFinite(remaining) || (unit === 'percent' && remaining > 100)) {
    console.log(chalk.yellow(unit === 'percent' ? 'Enter a number from 0 to 100.' : 'Enter a non-negative USD amount.'));
    await pause();
    return false;
  }
  profile.usageSource = { kind: 'snapshot', unit, remaining, reserve: current.reserve ?? 0, maxAgeMinutes: Number(current.maxAgeMinutes ?? 120), observedAt: new Date().toISOString(), costTracking: { enabled: false, baselineAllTimeCostUsd: null, baselineObservedAt: '' } };
  try {
    if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile);
    await save(settings);
    const persisted = JSON.parse(await fs.readFile(configPath, 'utf8'));
    const saved = persisted.openCode?.profiles?.find(item => item.id === profile.id)?.usageSource;
    if (!saved || Number(saved.remaining) !== remaining || saved.unit !== unit) throw new Error('The saved snapshot could not be verified.');
  } catch (error) {
    console.log(chalk.red(`Snapshot was not saved: ${error.message}`));
    await pause();
    return false;
  }
  console.log(chalk.green(`Snapshot updated: ${remaining} ${unit === 'usd' ? 'USD' : '%'}.`));
  return true;
}
async function configureLimitPolicy(settings, profile) {
  if (profile.policy === 'local') return pause();
  const choices = profile.policy === 'api'
    ? [{ name: 'Hourly USD cap', value: 'hourly' }, { name: 'Daily USD cap', value: 'daily' }, { name: 'Critical balance snapshot', value: 'critical' }, { name: 'Unlimited', value: 'unlimited' }]
    : [{ name: 'Critical quota snapshot', value: 'critical' }, { name: 'Require snapshot every hour', value: 'refresh-hourly' }, { name: 'Require snapshot every day', value: 'refresh-daily' }, { name: 'Unlimited', value: 'unlimited' }];
  const mode = await pick('Limit policy', choices); if (!mode) return;
  if (mode === 'unlimited' && !(await yesNo('Disable provider limits for this profile?'))) return;
  let amount = Number(profile.limitPolicy?.amount || 0);
  if (mode === 'hourly' || mode === 'daily') amount = numberValue(await input({ message: `${mode === 'hourly' ? 'Hourly' : 'Daily'} USD cap`, default: String(amount || 5) }), amount || 5);
  if (mode === 'critical') {
    const unit = profile.usageSource?.unit === 'usd' ? 'USD' : 'percent';
    const suggested = profile.limitPolicy?.configured ? amount : 0;
    amount = numberValue(await input({ message: `Minimum allowed ${unit}`, default: String(suggested) }), suggested);
    if (unit === 'percent' && amount > 100) { console.log(chalk.yellow('Percent cannot exceed 100.')); return pause(); }
    const reserveSuggested = Number(profile.limitPolicy?.reserve ?? profile.usageSource?.reserve ?? (unit === 'USD' ? 0.5 : 5));
    const reserve = numberValue(await input({ message: `Next-run reserve (${unit})`, default: String(reserveSuggested) }), reserveSuggested);
    if (unit === 'percent' && amount + reserve > 100) { console.log(chalk.yellow('Minimum plus reserve cannot exceed 100 percent.')); return pause(); }
    profile.limitPolicy = { mode, amount, reserve, configured: true }; if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings); console.log(chalk.green(`Limit policy saved: minimum ${amount}, next-run reserve ${reserve}.`)); return pause();
  }
  profile.limitPolicy = { mode, amount, reserve: null, configured: true }; if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings); console.log(chalk.green(`Limit policy saved: ${mode}.`)); return pause();
}
async function configureUsageSource(settings, profile) {
  if (profile.policy === 'local') { console.log(chalk.green('\nLocal profile: no provider usage or balance source is needed.')); return pause(); }
  if (profile.policy === 'oauth-managed') {
    console.log(chalk.yellow('\nOAuth usage is managed by the provider. Terra Runner does not receive a personal quota API or store OAuth tokens.'));
    console.log(chalk.gray('Use the provider Usage page for allowance and reset details; use the local run guard for automatic stopping.')); return pause();
  }
  const selected = await pick('API balance data source', [
    { name: 'Local OpenCode cost estimate (existing balance snapshot)', value: 'local-estimate' },
    { name: 'External read-only command (provider/API adapter)', value: 'external-command' }
  ]); if (!selected) return;
  profile.limits ||= {}; profile.limits.balance ||= {};
  if (selected === 'local-estimate') {
    profile.usageSource = { kind: 'local-estimate', command: '', arguments: [] }; profile.limits.balance.source = 'snapshot';
  } else {
    console.log(chalk.gray('\nThe command must write exactly one JSON object: {"balanceUsd": 12.34, "observedAt": "2026-11-04T12:00:00Z"}.'));
    console.log(chalk.gray('Use a separate read-only provider credential or environment variable. Do not paste an OAuth token into Terra Runner.'));
    const command = (await input({ message: 'Read-only command path or name' })).trim(); if (!command) { console.log(chalk.yellow('No command was saved.')); return pause(); }
    const rawArguments = (await input({ message: 'Arguments as a JSON array', default: '[]' })).trim(); let commandArgs;
    try { commandArgs = JSON.parse(rawArguments); if (!Array.isArray(commandArgs) || !commandArgs.every(value => typeof value === 'string')) throw new Error(); } catch { console.log(chalk.red('Arguments must be a JSON array of strings.')); return pause(); }
    const maxAgeMinutes = numberValue(await input({ message: 'Maximum reading age in minutes', default: String(profile.limits.balance.maxAgeMinutes ?? 5) }), Number(profile.limits.balance.maxAgeMinutes ?? 5));
    profile.usageSource = { kind: 'external-command', command, arguments: commandArgs }; profile.limits.balance = { ...profile.limits.balance, source: 'command', command, arguments: commandArgs, maxAgeMinutes };
  }
  if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings); console.log(chalk.green('Usage data source saved.')); return pause();
}
async function configureReasoning(settings, profile) { const variant = await pick('Reasoning level', [{ name: 'Provider default', value: '' }, ...['minimal', 'low', 'medium', 'high', 'xhigh'].map(value => ({ name: value, value }))]); if (variant === null) return; profile.reasoningVariant = variant; profile.showThinking = await yesNo('Show OpenCode thinking blocks during development?'); if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings); }
async function pickAuthStore(settings, current = 'legacy-shared') { return pick('OpenCode authentication storage', (settings.openCode.stores || []).map(store => ({ name: `${store.id === current ? '● ' : ''}${store.name}${store.kind === 'legacy-shared' ? chalk.yellow('  legacy / single-project') : ''}`, value: store.id }))); }
async function configureType(settings, profile) {
  const policy = await pick('Profile type', [{ name: 'API key — local spending limits', value: 'api' }, { name: 'OAuth — provider-managed usage', value: 'oauth-managed' }, { name: 'Local model — no limits', value: 'local' }]); if (!policy) return;
  if (policy === 'local') { profile.policy = 'local'; profile.credentialId = ''; profile.credentialLabel = 'No credential (local inference)'; }
  else {
    const storeId = await pickAuthStore(settings, profile.authStoreId); if (!storeId) return;
    let inventory; try { inventory = await refreshOpenCode(settings, storeId); } catch (error) { console.log(chalk.red(error.message)); return pause(); }
    const accounts = inventory.accounts.filter(account => account.provider.toLowerCase() === profile.provider); if (!accounts.length) { console.log(chalk.yellow(`No ${profile.provider} OpenCode credential is available.`)); return pause(); }
    const id = await pick('Credential', accounts.map(account => ({ name: `${account.label}  ${chalk.gray(`[${account.authMethod || 'unknown'}]`)}`, value: account.id }))); if (!id) return; const account = accounts.find(item => item.id === id); profile.policy = policy; profile.credentialId = account.credentialId; profile.credentialLabel = account.label; profile.authStoreId = storeId;
  }
  if (profile.policy === 'api' && !profile.limits) profile.limits = structuredClone(settings.budget || {}); if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings);
}
async function profileScreen(settings, profile) {
  while (true) {
    header(settings); console.log(chalk.bold('PROFILE DETAILS')); console.log(`  Model      ${chalk.cyan(profile.model)}`); console.log(`  Account    ${profile.credentialLabel || 'Not selected'}`); console.log(`  Storage    ${authStore(settings, profile.authStoreId)?.name || profile.authStoreId || 'not applicable'}`); console.log(`  Type       ${profile.policy}`); console.log(`  Reasoning  ${profile.reasoningVariant || 'provider default'}`); console.log(`  Limits     ${limitSummary(profile)} ${chalk.gray('(main-window runs only)')}`); console.log(`  Data       ${usageSourceSummary(profile)}\n`);
    const canDelete = settings.openCode.profiles.length > 1;
    const actions = [{ name: profile.id === settings.openCode.activeProfileId ? '● Active profile' : 'Use this profile', value: 'use' }, { name: 'Configure account type', value: 'type' }, { name: 'Configure reasoning', value: 'reasoning' }];
    if (profile.policy !== 'local') actions.push({ name: 'Configure provider snapshot', value: 'snapshot' }, { name: 'Configure limits', value: 'policy' });
    if (profile.policy === 'api' && profile.usageSource?.unit === 'usd') actions.push({ name: 'Configure local OpenCode cost estimate', value: 'cost-estimate' });
    if (canDelete) actions.push({ name: chalk.red('Remove this profile'), value: 'remove' });
    const action = await pick('Profile actions', actions);
    if (!action) return; if (action === 'use') { applyProfile(settings, profile); await save(settings); console.log(chalk.green('Active profile updated.')); await pause(); } if (action === 'type') await configureType(settings, profile); if (action === 'reasoning') await configureReasoning(settings, profile); if (action === 'snapshot') await configureSnapshot(settings, profile); if (action === 'policy') await configureLimitPolicy(settings, profile); if (action === 'cost-estimate') await configureOpenCodeCostEstimate(settings, profile);
    if (action === 'remove' && await yesNo(`Remove profile '${profile.model}'? This does not disconnect or delete the OpenCode account.`)) {
      settings.openCode.profiles = settings.openCode.profiles.filter(item => item.id !== profile.id);
      if (settings.openCode.activeProfileId === profile.id) applyProfile(settings, settings.openCode.profiles[0]);
      await save(settings); console.log(chalk.green('Profile removed.')); await pause(); return;
    }
  }
}
async function createProfile(settings) {
  const storeId = await pickAuthStore(settings); if (!storeId) return;
  let inventory; try { inventory = await refreshOpenCode(settings, storeId); } catch (error) { console.log(chalk.red(error.message)); return pause(); }
  const filter = (await input({ message: 'Filter models (leave blank to browse)', default: '' })).toLowerCase(); const models = inventory.models.filter(model => !filter || model.toLowerCase().includes(filter)); const model = await pick('Choose model', models.slice(0, 120).map(value => ({ name: `${value}${isLocalModel(value) ? chalk.green('  local') : ''}`, value }))); if (!model) return;
  let account = null; if (!isLocalModel(model)) { const provider = model.split('/')[0].toLowerCase(); const accounts = inventory.accounts.filter(item => item.provider.toLowerCase() === provider); if (!accounts.length) { console.log(chalk.yellow(`No saved ${provider} credential is available.`)); return pause(); } const id = await pick('Choose account', accounts.map(item => ({ name: `${item.label}  ${chalk.gray(`[${item.authMethod || 'unknown'}]`)}`, value: item.id }))); if (!id) return; account = accounts.find(item => item.id === id); }
  const profile = profileFrom(model, account); profile.authStoreId = profile.policy === 'local' ? '' : storeId; if (profile.policy === 'api') profile.limits = structuredClone(settings.budget || {}); settings.openCode.profiles.push(profile); await save(settings); await profileScreen(settings, profile);
}
async function profilesMenu(settings) {
  while (true) {
    header(settings); console.log(chalk.bold('PROFILES')); const profiles = migrateProfiles(settings); const choice = await pick('Open a profile or create a new one', [...profiles.map(profile => ({ name: `${profile.id === settings.openCode.activeProfileId ? chalk.green('●') : ' '} ${profileKindLabel(profile)} ${profile.model}  ${chalk.gray(`— ${limitSummary(profile)}`)}`, value: profile.id })), { name: chalk.cyan('+ Create new profile'), value: '__create' }]);
    if (!choice) return; if (choice === '__create') await createProfile(settings); else await profileScreen(settings, profiles.find(profile => profile.id === choice));
  }
}
async function authStoresMenu(settings) {
  while (true) {
    header(settings); console.log(chalk.bold('OPENCODE AUTHENTICATION STORAGES')); console.log(chalk.gray('Credentials remain in OpenCode databases, never in Terra configuration.'));
    const stores = settings.openCode.stores || [];
    const choice = await pick('Open or create storage', [...stores.map(store => ({ name: `${store.name}  ${chalk.gray(`[${store.id}]${store.kind === 'legacy-shared' ? ' legacy / shared' : ''}`)}`, value: store.id })), { name: chalk.cyan('+ Create isolated storage'), value: '__create' }]);
    if (!choice) return;
    if (choice === '__create') {
      const id = String(await input({ message: 'Storage ID (letters, digits, dot, underscore, hyphen)' })).trim(); const name = String(await input({ message: 'Display name', default: id })).trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(id) || stores.some(store => store.id === id)) { console.log(chalk.red('Storage ID is invalid or already exists.')); await pause(); continue; }
      settings.openCode.stores.push({ id, name: name || id, kind: 'isolated' }); await fs.mkdir(path.dirname(authStorePath(configPath, id)), { recursive: true }); await save(settings); console.log(chalk.green(`Storage '${name || id}' created. Use Authenticate before assigning it to a profile.`)); await pause(); continue;
    }
    const store = authStore(settings, choice); if (!store) continue;
    const action = await pick(`Storage: ${store.name}`, [
      { name: 'Authenticate / add OpenCode account', value: 'login' }, { name: 'Refresh accounts and models', value: 'refresh' },
      ...(store.kind === 'legacy-shared' ? [] : [{ name: chalk.yellow('Unlink from Terra configuration (credentials stay on disk)'), value: 'unlink' }])
    ]);
    if (action === 'login') { try { if (store.kind !== 'legacy-shared') await fs.mkdir(path.dirname(authStorePath(configPath, store.id)), { recursive: true }); await execute(settings.openCodeCommand || 'opencode', ['auth', 'login'], root, true, storeEnvironment(store.id)); } catch (error) { console.log(chalk.red(error.message)); } await pause(); }
    if (action === 'refresh') { try { await refreshOpenCode(settings, store.id); console.log(chalk.green('Storage refreshed.')); } catch (error) { console.log(chalk.red(error.message)); } await pause(); }
    if (action === 'unlink' && await yesNo(`Unlink '${store.name}'? Existing profiles using it must be reassigned first.`)) { if ((settings.openCode.profiles || []).some(profile => profile.authStoreId === store.id)) { console.log(chalk.yellow('Reassign or remove the profiles using this storage first.')); await pause(); } else { settings.openCode.stores = stores.filter(item => item.id !== store.id); await save(settings); } }
  }
}
async function chooseRunIterationLimit() {
  while (true) {
    const raw = String(await input({ message: 'Iterations for this run (0 = until a safety stop)', default: '0' })).trim();
    if (/^\d+$/.test(raw) && Number(raw) <= 1000) return Number(raw);
    console.log(chalk.yellow('Enter a whole number from 0 to 1000.'));
  }
}
const coordinatorId = crypto.randomUUID();
async function chooseProject(settings) {
  const projects = normalizeProjects(settings); if (!projects.length) return null;
  const id = await pick('Project', projects.map(project => { const profile = (settings.openCode.profiles || []).find(item => item.id === project.defaultProfileId); return { name: `${project.id}  ${chalk.gray(`— ${profile?.model || 'default profile not assigned'}`)}`, value: project.id }; }));
  return projects.find(item => item.id === id) || null;
}
async function chooseDevelopmentProject(settings) {
  const project = await chooseProject(settings); if (!project) return null; const profile = (settings.openCode.profiles || []).find(item => item.id === project.defaultProfileId);
  if (!profile) { console.log(chalk.yellow(`Project '${project.id}' has no default profile. Assign one in Projects before development.`)); await pause(); return null; }
  return { project, profile };
}
async function chooseDevelopmentTarget() { return pick('Run mode', [{ name: 'Main window — limits and live control', value: 'main' }, { name: 'Dispatcher instance — separate terminal, no Terra limits', value: 'instance' }]); }
async function startDispatcherInstance(settings, project, profile, launch) {
  const running = await listInstances(configPath);
  if (running.some(instance => instance.projectId === project.id && !isTerminalInstance(instance))) { console.log(chalk.yellow(`Project '${project.id}' already has an active workspace.`)); return pause(); }
  if (profile.policy !== 'local' && profile.authStoreId === 'legacy-shared' && running.some(instance => !isTerminalInstance(instance) && instance.profile?.policy !== 'local')) { console.log(chalk.yellow('The legacy shared OpenCode storage is global. Create an isolated authentication storage before running multiple cloud projects.')); return pause(); }
  if (profile.policy !== 'local' && profile.authStoreId !== 'legacy-shared') { try { await fs.access(authStorePath(configPath, profile.authStoreId)); } catch { console.log(chalk.yellow(`Authentication storage '${profile.authStoreId}' is not initialized. Open System → OpenCode authentication storages and sign in.`)); return pause(); } }
  const route = activeProxyRoute(settings); const instance = await createInstance(configPath, project, profile, route, coordinatorId, launch);
  const command = `"${process.execPath}" "${path.join(root, 'node-ui', 'instance.mjs')}" --config "${configPath}" --instance "${instance.id}"`;
  const launcher = spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `start "Terra ${project.id}" cmd.exe /d /k "${command}"`], { cwd: root, detached: true, stdio: 'ignore', windowsHide: false });
  launcher.unref(); await updateInstance(configPath, instance.id, { state: 'launching', activity: 'Opening project terminal' });
  console.log(chalk.green(`Project instance '${project.id}' is opening in a separate terminal.`)); return pause();
}
async function runInMainWindow(settings, command, project, profile, maxIterations) {
  const snapshotRelevant = profile.policy !== 'local' && profile.limitPolicy?.mode !== 'unlimited';
  if (snapshotRelevant) { let freshness = snapshotFreshness(profile); if (!freshness.ok) { if (!(await refreshSnapshotBeforeRun(settings, profile, freshness))) return; freshness = snapshotFreshness(profile); if (!freshness.ok) { console.log(chalk.red(`Snapshot is still not ready: ${freshness.detail}`)); return pause(); } } }
  const args = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-ProfileId', profile.id, '-Config', configPath];
  if (command === 'dry-run') args.push('-DryRun'); else { args.push('-UiEvents', '-ClearControlFlags', command === 'continuous' ? '-Continuous' : '-Once'); if (command === 'continuous') args.push(maxIterations > 0 ? '-MaxIterations' : '-UnlimitedIterations', ...(maxIterations > 0 ? [String(maxIterations)] : [])); }
  const label = command === 'dry-run' ? 'Run a dry run' : command === 'continuous' ? `Run continuously${maxIterations ? ` for up to ${maxIterations} iteration(s)` : ''}` : 'Run one iteration';
  if (!(await yesNo(`${label} for '${project.id}' in the main window?`))) return;
  clear(); console.log(chalk.bold('DEVELOPMENT')); console.log(rule); console.log(`  Project  ${chalk.white(project.id)}`); console.log(`  Profile  ${chalk.cyan(profile.model)}  ${chalk.gray(`(${profile.credentialLabel || profile.policy})`)}`); console.log(`  Command  ${label}`); console.log(rule);
  await runWithTui(args, settings, project, command); return pause();
}
async function testProxyForProject(settings, project) {
  if (!(await yesNo(`Test the active proxy route for '${project.id}' without starting a model?`))) return;
  header(settings); console.log(chalk.bold('PROXY TEST')); console.log(rule); console.log(`  Project  ${project.id}`); console.log(chalk.gray('  Testing HTTPS CONNECT through the active route…')); console.log(rule);
  const args = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-Config', configPath, '-ProxyTest'];
  try { await execute('pwsh.exe', args, root, true); } catch (error) { console.log(chalk.red(error.message)); }
  return pause();
}
async function developmentMenu(settings) {
  const command = await pick('Development', [{ name: 'One iteration', value: 'once' }, { name: 'Dry run', value: 'dry-run' }, { name: 'Continuous', value: 'continuous' }, { name: 'Active instances', value: 'instances' }, { name: 'Proxy test', value: 'proxy-test' }]);
  if (!command) return; if (command === 'instances') return instancesMenu();
  if (command === 'proxy-test') { const project = await chooseProject(settings); if (project) await testProxyForProject(settings, project); return; }
  const selected = await chooseDevelopmentProject(settings); if (!selected) return;
  const target = await chooseDevelopmentTarget(); if (!target) return;
  const maxIterations = command === 'continuous' ? await chooseRunIterationLimit() : 1;
  const launch = { command, maxIterations };
  if (target === 'instance') { if (!(await yesNo(`Open '${selected.project.id}' in a separate terminal and start ${command}?`))) return; return startDispatcherInstance(settings, selected.project, selected.profile, launch); }
  return runInMainWindow(settings, command, selected.project, selected.profile, maxIterations);
}
async function instancesMenu() {
  while (true) {
    const instances = await listInstances(configPath); clear(); console.log(chalk.bold('ACTIVE AND RECENT PROJECT INSTANCES')); console.log(rule);
    if (!instances.length) console.log(chalk.gray('  No project windows have been opened yet.'));
    const choice = await pick('Open an instance', instances.map(instance => ({ name: `${isTerminalInstance(instance) ? chalk.gray('○') : chalk.green('●')} ${instance.projectId}  ${chalk.gray(instance.profile?.model || '')}  ${instance.state}${instance.activity ? ` — ${instance.activity}` : ''}`, value: instance.id })));
    if (!choice) return; const instance = instances.find(item => item.id === choice); if (!instance) continue;
    const action = await pick(`Instance: ${instance.projectId}`, [
      { name: 'Request graceful stop', value: 'stop', disabled: isTerminalInstance(instance) }, { name: chalk.red('Emergency abort'), value: 'abort', disabled: isTerminalInstance(instance) }, { name: 'Refresh', value: 'refresh' }
    ]);
    if (action === 'stop' || action === 'abort') { const kind = action === 'abort' ? 'ABORT' : 'STOP'; await requestInstanceControl(configPath, instance.id, kind); await updateInstance(configPath, instance.id, { state: action === 'abort' ? 'aborting' : 'stopping', activity: action === 'abort' ? 'Emergency abort requested by dispatcher' : 'Graceful stop requested by dispatcher' }); }
  }
}
async function stopAllInstances() {
  const instances = await listInstances(configPath); const active = instances.filter(instance => !isTerminalInstance(instance));
  for (const instance of active) { await requestInstanceControl(configPath, instance.id, 'STOP'); await updateInstance(configPath, instance.id, { state: 'stopping', activity: 'Dispatcher is shutting down' }); }
  if (active.length) console.log(chalk.yellow(`Graceful Stop requested for ${active.length} project instance(s). They will also stop if the dispatcher heartbeat expires.`));
}
async function readProjectId(message, projects, currentId = '') {
  while (true) { const id = (await input({ message, default: currentId })).trim(); const error = validateProjectId(id, projects, currentId); if (!error) return id; console.log(chalk.yellow(error)); }
}
async function detectBranch(projectPath, fallback = '') {
  try { return (await execute('git', ['-C', projectPath, 'branch', '--show-current'])).trim() || fallback; } catch { return fallback; }
}
async function editProject(settings, project, isNew = false) {
  const projects = normalizeProjects(settings); console.log(chalk.bold(isNew ? '\nNEW PROJECT' : '\nEDIT PROJECT'));
  const id = await readProjectId('Project ID', projects, isNew ? '' : project.id);
  const projectPath = (await input({ message: 'Absolute project path', default: project.path || '' })).trim();
  try { if (!path.isAbsolute(projectPath)) throw new Error(); const state = await fs.stat(projectPath); if (!state.isDirectory()) throw new Error(); } catch { console.log(chalk.red('The project path must be an existing absolute directory.')); return pause(); }
  const detected = await detectBranch(projectPath, project.branch || '');
  const branch = (await input({ message: 'Git branch', default: detected })).trim();
  const roadmap = (await input({ message: 'Roadmap filename', default: project.roadmap || 'ROADMAP.md' })).trim();
  const progress = (await input({ message: 'Progress filename', default: project.progress || 'PROGRESS.md' })).trim();
  const profiles = settings.openCode.profiles || [];
  const profileId = profiles.length ? await pick('Default profile for this project', profiles.map(profile => ({ name: `${profile.model}${profile.id === project.defaultProfileId ? '  (current)' : ''}`, value: profile.id }))) : '';
  if (!profileId && profiles.length) return;
  const updated = { id, path: projectPath, branch, roadmap, progress, defaultProfileId: profileId || '' };
  if (isNew) projects.push(updated); else Object.assign(project, updated);
  await save(settings); console.log(chalk.green(`Project '${id}' saved.`)); return pause();
}
async function projectsMenu(settings) {
  while (true) {
    header(settings); console.log(chalk.bold('PROJECTS')); const projects = normalizeProjects(settings);
    const action = await pick('Manage project configuration', [
      ...projects.map(project => { const profile = (settings.openCode.profiles || []).find(item => item.id === project.defaultProfileId); return { name: `${project.id}  ${chalk.gray(`— ${profile?.model || 'no default profile'}`)}`, value: `project:${project.id}` }; }),
      { name: chalk.cyan('+ Add project'), value: 'add' }
    ]);
    if (!action) return;
    if (action === 'add') { await editProject(settings, { path: '', branch: '', roadmap: '', progress: '' }, true); continue; }
    const project = projects.find(item => item.id === action.slice('project:'.length)); if (!project) continue;
    const detail = await pick(`Project: ${project.id}`, [
      { name: 'Edit project configuration', value: 'edit' }, { name: chalk.red('Remove project configuration'), value: 'remove' }
    ]);
    if (detail === 'edit') await editProject(settings, project);
    if (detail === 'remove') {
      if (projects.length === 1) { console.log(chalk.yellow('Keep at least one project configured.')); await pause(); continue; }
      if (await yesNo(`Remove only the '${project.id}' project configuration? Its files, Git repository, logs, and reports will remain untouched.`)) {
        settings.projects = projects.filter(item => item.id !== project.id); normalizeProjects(settings); await save(settings); console.log(chalk.green('Project configuration removed.')); await pause();
      }
    }
  }
}
async function reportsMenu(settings) {
  const projects = normalizeProjects(settings);
  const rows = await Promise.all(projects.map(async project => ({ project, latest: await latestIterationSummary(settings, project, configPath), reports: await dailyReports(settings, project, configPath) })));
  header(settings); console.log(chalk.bold('REPORTS · ALL PROJECTS')); console.log(rule);
  if (!rows.length) console.log(chalk.gray('  No projects are configured.'));
  for (const row of rows) {
    const latest = row.latest;
    const result = !latest ? chalk.gray('no iterations') : Number(latest.exitCode) === 0 && !latest.stoppedReason ? chalk.green('successful') : chalk.yellow(latest.stoppedReason || `exit ${latest.exitCode}`);
    console.log(`  ${chalk.bold(row.project.id)}  ${result}  ${chalk.gray(latest?.ended || 'no completed run')}`);
    console.log(`    Daily reports: ${row.reports.length ? row.reports.slice(0, 3).join(', ') : 'none'}`);
  }
  console.log(rule); return pause();
}
async function editProxyRoute(settings, route = null) {
  const current = route || { id: crypto.randomUUID(), name: '', protocol: 'http', host: '', port: 8080, username: '', passwordProtected: '', caFile: '', noProxy: [] };
  current.name = String(await input({ message: 'Route name', default: current.name })).trim();
  current.protocol = await pick('Upstream protocol', PROXY_PROTOCOLS.map(value => ({ name: value.toUpperCase(), value }))) || current.protocol;
  current.host = String(await input({ message: 'Proxy host or IP', default: current.host })).trim();
  current.port = Number(String(await input({ message: 'Port', default: String(current.port || '') })).trim());
  current.username = String(await input({ message: 'Username (blank for none)', default: current.username })).trim();
  const password = await secretInput({ message: current.passwordProtected ? 'Password (blank keeps existing; enter ! to clear)' : 'Password (blank for none)' });
  if (password === '!') current.passwordProtected = ''; else if (password) current.passwordProtected = await protectSecret(password);
  current.caFile = String(await input({ message: 'PEM CA file (blank for system trust)', default: current.caFile })).trim();
  if (current.caFile) { try { if (!(await fs.stat(current.caFile)).isFile()) throw new Error(); } catch { console.log(chalk.red('PEM CA file was not found.')); return pause(); } }
  current.noProxy = String(await input({ message: 'Additional NO_PROXY entries, comma-separated', default: current.noProxy.join(',') })).split(',').map(value => value.trim()).filter(Boolean);
  const error = validateProxyRoute(current); if (error) { console.log(chalk.red(error)); return pause(); }
  const proxy = normalizeProxy(settings); if (!route) proxy.routes.push(current); await save(settings); console.log(chalk.green(`Proxy route '${current.name}' saved.`)); return pause();
}
async function proxyRoutesMenu(settings) {
  while (true) {
    const proxy = normalizeProxy(settings); const active = activeProxyRoute(settings);
    header(settings); console.log(chalk.bold('PROXY ROUTES')); console.log(`  Active  ${active ? redactedRoute(active) : 'Direct (no proxy)'}\n`);
    const choice = await pick('Select or manage a route', [{ name: `${proxy.activeRouteId === DIRECT_ROUTE_ID ? '●' : ' '} Direct`, value: DIRECT_ROUTE_ID }, ...proxy.routes.map(route => ({ name: `${route.id === proxy.activeRouteId ? '●' : ' '} ${route.name}  ${chalk.gray(redactedRoute(route))}`, value: route.id })), { name: chalk.cyan('+ Add proxy route'), value: 'add' }]);
    if (!choice) return;
    if (choice === 'add') { await editProxyRoute(settings); continue; }
    if (choice === DIRECT_ROUTE_ID) { proxy.activeRouteId = DIRECT_ROUTE_ID; await save(settings); console.log(chalk.green('Direct route selected.')); await pause(); continue; }
    const route = proxy.routes.find(item => item.id === choice); const action = await pick(`Proxy route: ${route.name}`, [{ name: 'Use this route', value: 'use' }, { name: 'Edit route', value: 'edit' }, { name: chalk.red('Delete route'), value: 'delete' }]);
    if (action === 'use') { proxy.activeRouteId = route.id; await save(settings); console.log(chalk.green(`Selected ${route.name}.`)); await pause(); }
    if (action === 'edit') await editProxyRoute(settings, route);
    if (action === 'delete' && await yesNo(`Delete '${route.name}'?`)) { proxy.routes = proxy.routes.filter(item => item.id !== route.id); if (proxy.activeRouteId === route.id) proxy.activeRouteId = DIRECT_ROUTE_ID; await save(settings); }
  }
}
async function systemMenu(settings) {
  const action = await pick('System', [{ name: 'OpenCode authentication storages', value: 'auth-stores' }, { name: 'Proxy routes', value: 'proxy' }, { name: 'Run diagnostics (read-only)', value: 'diagnostics' }, { name: 'Refresh legacy OpenCode accounts and models', value: 'refresh' }, { name: 'Show configuration path', value: 'config' }]); if (!action) return;
  if (action === 'auth-stores') return authStoresMenu(settings);
  if (action === 'proxy') return proxyRoutesMenu(settings);
  if (action === 'config') { console.log(`\n${configPath}`); return pause(); }
  if (action === 'diagnostics') {
    header(settings); console.log(chalk.bold('SYSTEM DIAGNOSTICS')); const checks = [];
    checks.push({ label: 'Configuration', ok: true, detail: configPath });
    checks.push({ label: 'Configured projects', ok: normalizeProjects(settings).length > 0, detail: `${normalizeProjects(settings).length}` });
    try { const executable = await resolveCommand('pwsh.exe'); checks.push({ label: 'PowerShell', ok: true, detail: executable }); } catch (error) { checks.push({ label: 'PowerShell', ok: false, detail: error.message }); }
    try { const executable = await resolveCommand(settings.openCodeCommand || 'opencode'); checks.push({ label: 'OpenCode command', ok: true, detail: executable }); } catch (error) { checks.push({ label: 'OpenCode command', ok: false, detail: error.message }); }
    for (const check of checks) console.log(`  ${check.ok ? chalk.green('✓') : chalk.red('×')} ${chalk.bold(check.label)}  ${check.detail}`);
    return pause();
  }
  try { await refreshOpenCode(settings); await save(settings); } catch (error) { console.log(chalk.red(error.message)); } return pause();
}
async function main() {
  const settings = await load(); await save(settings); await cleanupLegacyReservations(configPath); await writeCoordinatorHeartbeat(configPath, coordinatorId);
  const heartbeat = setInterval(() => void writeCoordinatorHeartbeat(configPath, coordinatorId), 5000);
  try {
    while (true) {
      header(settings); const action = await pick('Terra Runner', [
        { name: 'Development', value: 'development' }, { name: 'Projects', value: 'projects' }, { name: 'Models and accounts', value: 'profiles' },
        { name: 'Reports', value: 'reports' }, { name: 'System', value: 'system' }, { name: 'Stop all and exit', value: 'exit' }
      ]);
      if (!action || action === 'exit') { await save(settings); await stopAllInstances(); return; }
      if (action === 'development') await developmentMenu(settings); if (action === 'profiles') await profilesMenu(settings); if (action === 'projects') await projectsMenu(settings); if (action === 'reports') await reportsMenu(settings); if (action === 'system') await systemMenu(settings);
    }
  } finally { clearInterval(heartbeat); await removeCoordinatorHeartbeat(configPath, coordinatorId); }
}
process.on('SIGINT', () => { process.exitCode = 0; });
main().catch(error => { console.error(chalk.red(`\nTerra Runner could not start: ${error.message}`)); process.exitCode = 1; });
