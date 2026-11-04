#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { spawn } from 'node:child_process';
import inquirer from 'inquirer';
import chalk from 'chalk';
import figlet from 'figlet';
import ora from 'ora';
import { activeProfile, applyProfile, isLocalModel, migrateProfiles, profileFrom } from './lib/profiles.mjs';
import { activeProject, normalizeProjects, validateProjectId } from './lib/projects.mjs';
import { dailyReports, latestIterationSummary, iterationSummariesSince, projectDataRoot } from './lib/reports.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const valueOf = name => { const i = args.indexOf(name); return i < 0 ? '' : args[i + 1]; };
const configPath = valueOf('--config') || (args.includes('--portable') ? path.join(root, 'terra-config.json') : path.join(process.env.LOCALAPPDATA || process.env.APPDATA || root, 'TerraRunner', 'terra-config.json'));
const rule = chalk.gray('─'.repeat(78));
const input = options => inquirer.prompt([{ type: 'input', name: 'value', ...options }]).then(answer => answer.value);
const confirm = options => inquirer.prompt([{ type: 'confirm', name: 'value', ...options }]).then(answer => answer.value);
const select = options => inquirer.prompt([{ type: 'list', name: 'value', ...options }]).then(answer => answer.value);
function clear() { if (process.stdout.isTTY) process.stdout.write('\x1Bc'); }
function pause() { return input({ message: 'Press Enter to continue' }); }
async function pick(message, choices) {
  try { return await select({ message, choices: [...choices, { name: '← Back', value: null }], loop: false, pageSize: 14 }); }
  catch (error) { if (error?.name === 'ExitPromptError') return null; throw error; }
}
async function yesNo(message) { try { return await confirm({ message, default: false }); } catch { return false; } }
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
async function execute(name, commandArgs, cwd = root, inherited = false) {
  const executable = await resolveCommand(name);
  return new Promise((resolve, reject) => {
    const batch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(executable);
    // Windows npm CLIs are .cmd files. Pass the nested command unchanged to
    // cmd.exe; Node's normal Windows escaping otherwise turns quotes literal.
    const quote = value => `"${String(value).replace(/"/g, '""')}"`;
    const commandLine = `"${quote(executable)} ${commandArgs.map(quote).join(' ')}"`;
    const child = batch
      ? spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', commandLine], { cwd, shell: false, windowsVerbatimArguments: true, stdio: inherited ? 'inherit' : ['ignore', 'pipe', 'pipe'] })
      : spawn(executable, commandArgs, { cwd, shell: false, stdio: inherited ? 'inherit' : ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    if (!inherited) { child.stdout.on('data', data => stdout += data); child.stderr.on('data', data => stderr += data); }
    child.once('error', reject); child.once('close', code => code === 0 ? resolve(stdout) : reject(new Error(`${executable} exited with code ${code}${stderr ? `: ${stderr.trim()}` : ''}`)));
  });
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
  const planned = [...new Map(runs.filter(run => run?.plannedTaskId).map(run => [run.plannedTaskId, run.plannedTaskTitle || ''])).entries()];
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
  if (planned.length) console.log(`  ${chalk.gray('Work plan')}   ${planned.map(([id, title]) => title ? `${id} - ${title}` : id).join(' | ')}`);
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
async function runWithTui(runnerArgs, settings, project, mode) {
  const executable = await resolveCommand('pwsh.exe');
  const previousSummaryId = (await latestIterationSummary(settings, project, configPath))?.id || '';
  const started = Date.now(); let stdout = ''; let stderr = ''; let stage = mode === 'continuous' ? 'Preparing continuous development' : 'Preparing iteration';
  let eventFile = ''; let eventLines = 0; let toolCount = 0; let checkCount = 0; let activity = ''; let iterationLabel = '';
  const spinner = ora({ text: `${stage} · 0m 00s`, color: 'cyan' }).start();
  const update = setInterval(() => { spinner.text = `${stage} · ${durationText(Date.now() - started)}`; }, 1000);
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
  try {
    const result = await new Promise((resolve, reject) => {
      const child = spawn(executable, runnerArgs, { cwd: root, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
      let buffer = '';
      const handleLine = line => {
        if (line.startsWith('__TERRA_UI__')) {
          try {
            const event = JSON.parse(line.slice('__TERRA_UI__'.length));
            if (event.type === 'iteration-started') {
              eventFile = event.eventsFile || ''; eventLines = 0; toolCount = 0; checkCount = 0; activity = '';
              iterationLabel = event.total == null ? `Iteration ${event.iteration}` : `Iteration ${event.iteration} of ${event.total}`;
              stage = `${iterationLabel} | ${event.taskId || 'next roadmap task'} | ${event.pending} tasks pending`;
            }
            if (event.type === 'iteration-finished') stage = 'Writing verified iteration summary';
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
    clearInterval(update); clearInterval(liveUpdate);
    if (result.code === 0) spinner.succeed(`Development run finished · ${durationText(Date.now() - started)}`);
    else spinner.fail(`Development runner exited with code ${result.code}`);
    const summaries = (await iterationSummariesSince(settings, project, configPath, started)).filter(summary => summary.id !== previousSummaryId);
    if (summaries.length) showRunOverview(summaries, settings, project);
    else if (result.code !== 0) console.log(chalk.red((result.stderr || result.stdout || 'No iteration summary was written.').trim()));
    return result.code === 0;
  } catch (error) {
    clearInterval(update); clearInterval(liveUpdate); spinner.fail('Development runner could not start.'); console.log(chalk.red(error.message)); return false;
  }
}
async function load() { try { const settings = JSON.parse(await fs.readFile(configPath, 'utf8')); settings.openCode ||= { accounts: [], activeAccountId: '', reasoning: {} }; settings.openCode.accounts ||= []; migrateProfiles(settings); return settings; } catch (error) { throw new Error(`Cannot load ${configPath}. Run the legacy setup wizard once or pass --config <file>. ${error.message}`); } }
async function save(settings) { await fs.mkdir(path.dirname(configPath), { recursive: true }); const temp = `${configPath}.${process.pid}.tmp`; await fs.writeFile(temp, `${JSON.stringify(settings, null, 2)}\n`, 'utf8'); await fs.rename(temp, configPath); }
function parseModels(text) { return [...new Set(text.split(/\r?\n/).map(v => v.trim()).filter(v => /^[a-z0-9_.-]+\/.+/i.test(v)))]; }
async function refreshOpenCode(settings) {
  const spinner = ora('Reading OpenCode accounts and models…').start();
  try {
    const executable = settings.openCodeCommand || 'opencode'; const raw = await execute(executable, ['auth', 'list', '--format', 'json']); const providers = JSON.parse(raw); const accounts = [];
    for (const provider of providers) for (const credential of provider.connections || []) accounts.push({ id: `${provider.id}:${credential.id}`, provider: provider.id, credentialId: credential.id, label: credential.label || provider.name || provider.id, authMethod: credential.method || '', usageKind: credential.method === 'oauth' ? 'oauth' : 'balance' });
    const models = parseModels(await execute(executable, ['models'])); settings.openCode.accounts = [...accounts, ...settings.openCode.accounts.filter(account => account.authMethod === 'local')];
    spinner.succeed(`OpenCode refreshed: ${accounts.length} account(s), ${models.length} model(s).`); return { accounts, models };
  } catch (error) { spinner.fail('OpenCode refresh failed.'); throw error; }
}
function selectedProject(settings) { return activeProject(settings); }
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
  clear(); const project = selectedProject(settings); const profile = activeProfile(settings);
  console.log(chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' }))); console.log(chalk.gray('RUNNER  v1.6  ·  Local OpenCode development orchestrator')); console.log(rule);
  const account = settings.openCode?.accounts?.find(item => item.id === settings.openCode?.activeAccountId); const snapshot = profile?.usageSource || {}; const unit = snapshot.unit === 'usd' ? 'USD' : '%';
  const balance = profile?.policy === 'local' ? 'not applicable' : snapshot.remaining == null ? 'snapshot required' : `${snapshot.remaining} ${unit}`;
  const age = snapshot.observedAt ? `${Math.max(0, (Date.now() - Date.parse(snapshot.observedAt)) / 60000).toFixed(0)} min ago` : 'not recorded';
  console.log(`${chalk.bold('Project')}   ${chalk.white(project?.id || 'not selected')}  ${chalk.gray('│')}  ${chalk.bold('Branch')}  ${project?.branch || 'not configured'}`); console.log(`${chalk.bold('Path')}      ${chalk.gray(project?.path || 'not configured')}`);
  console.log(`${chalk.bold('Account')}   ${account?.label || profile?.credentialLabel || 'not selected'}  ${chalk.gray('│')}  ${profileKindLabel(profile || {})}`); console.log(`${chalk.bold('Model')}     ${chalk.cyan(profile?.model || 'not selected')}  ${chalk.gray('│')}  Reasoning ${profile?.reasoningVariant || 'provider default'}`);
  console.log(`${chalk.bold('Snapshot')}  ${balance}  ${chalk.gray(`│ ${age}`)}`); console.log(`${chalk.bold('Limits')}    ${chalk.yellow(limitSummary(profile))}`); console.log(rule);
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
async function configureRunGuard(settings, profile) {
  const current = Number(profile.runControls?.maxIterations || 0);
  console.log(chalk.yellow('\nThis is a local safety guard, not a provider quota.'));
  console.log(chalk.gray('It stops continuous development after the selected number of iterations. Enter 0 to leave it unlimited.'));
  const value = numberValue(await input({ message: 'Maximum iterations in one continuous run', default: String(current) }), current);
  profile.runControls = { ...(profile.runControls || {}), maxIterations: Math.floor(value) };
  await save(settings); console.log(chalk.green('Local run guard saved.')); return pause();
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
  const project = selectedProject(settings);
  const spinner = ora('Reading local OpenCode lifetime usage...').start();
  try {
    const raw = await execute(settings.openCodeCommand || 'opencode', ['stats', '--all', '--json'], project?.path || root);
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
async function configureType(settings, profile) {
  const policy = await pick('Profile type', [{ name: 'API key — local spending limits', value: 'api' }, { name: 'OAuth — provider-managed usage', value: 'oauth-managed' }, { name: 'Local model — no limits', value: 'local' }]); if (!policy) return;
  if (policy === 'local') { profile.policy = 'local'; profile.credentialId = ''; profile.credentialLabel = 'No credential (local inference)'; }
  else {
    let inventory; try { inventory = await refreshOpenCode(settings); } catch (error) { console.log(chalk.red(error.message)); return pause(); }
    const accounts = inventory.accounts.filter(account => account.provider.toLowerCase() === profile.provider); if (!accounts.length) { console.log(chalk.yellow(`No ${profile.provider} OpenCode credential is available.`)); return pause(); }
    const id = await pick('Credential', accounts.map(account => ({ name: `${account.label}  ${chalk.gray(`[${account.authMethod || 'unknown'}]`)}`, value: account.id }))); if (!id) return; const account = accounts.find(item => item.id === id); profile.policy = policy; profile.credentialId = account.credentialId; profile.credentialLabel = account.label;
  }
  if (profile.policy === 'api' && !profile.limits) profile.limits = structuredClone(settings.budget || {}); if (profile.id === settings.openCode.activeProfileId) applyProfile(settings, profile); await save(settings);
}
async function profileScreen(settings, profile) {
  while (true) {
    header(settings); console.log(chalk.bold('PROFILE DETAILS')); console.log(`  Model      ${chalk.cyan(profile.model)}`); console.log(`  Account    ${profile.credentialLabel || 'Not selected'}`); console.log(`  Type       ${profile.policy}`); console.log(`  Reasoning  ${profile.reasoningVariant || 'provider default'}`); console.log(`  Limits     ${limitSummary(profile)}`); console.log(`  Data       ${usageSourceSummary(profile)}\n`);
    const canDelete = settings.openCode.profiles.length > 1;
    const actions = [{ name: profile.id === settings.openCode.activeProfileId ? '● Active profile' : 'Use this profile', value: 'use' }, { name: 'Configure account type', value: 'type' }, { name: 'Configure reasoning', value: 'reasoning' }];
    if (profile.policy !== 'local') actions.push({ name: 'Configure provider snapshot', value: 'snapshot' }, { name: 'Configure limits', value: 'policy' });
    if (profile.policy === 'api' && profile.usageSource?.unit === 'usd') actions.push({ name: 'Configure local OpenCode cost estimate', value: 'cost-estimate' });
    actions.push({ name: 'Configure local run guard', value: 'guard' });
    if (canDelete) actions.push({ name: chalk.red('Remove this profile'), value: 'remove' });
    const action = await pick('Profile actions', actions);
    if (!action) return; if (action === 'use') { applyProfile(settings, profile); await save(settings); console.log(chalk.green('Active profile updated.')); await pause(); } if (action === 'type') await configureType(settings, profile); if (action === 'reasoning') await configureReasoning(settings, profile); if (action === 'snapshot') await configureSnapshot(settings, profile); if (action === 'policy') await configureLimitPolicy(settings, profile); if (action === 'cost-estimate') await configureOpenCodeCostEstimate(settings, profile); if (action === 'guard') await configureRunGuard(settings, profile);
    if (action === 'remove' && await yesNo(`Remove profile '${profile.model}'? This does not disconnect or delete the OpenCode account.`)) {
      settings.openCode.profiles = settings.openCode.profiles.filter(item => item.id !== profile.id);
      if (settings.openCode.activeProfileId === profile.id) applyProfile(settings, settings.openCode.profiles[0]);
      await save(settings); console.log(chalk.green('Profile removed.')); await pause(); return;
    }
  }
}
async function createProfile(settings) {
  let inventory; try { inventory = await refreshOpenCode(settings); } catch (error) { console.log(chalk.red(error.message)); return pause(); }
  const filter = (await input({ message: 'Filter models (leave blank to browse)', default: '' })).toLowerCase(); const models = inventory.models.filter(model => !filter || model.toLowerCase().includes(filter)); const model = await pick('Choose model', models.slice(0, 120).map(value => ({ name: `${value}${isLocalModel(value) ? chalk.green('  local') : ''}`, value }))); if (!model) return;
  let account = null; if (!isLocalModel(model)) { const provider = model.split('/')[0].toLowerCase(); const accounts = inventory.accounts.filter(item => item.provider.toLowerCase() === provider); if (!accounts.length) { console.log(chalk.yellow(`No saved ${provider} credential is available.`)); return pause(); } const id = await pick('Choose account', accounts.map(item => ({ name: `${item.label}  ${chalk.gray(`[${item.authMethod || 'unknown'}]`)}`, value: item.id }))); if (!id) return; account = accounts.find(item => item.id === id); }
  const profile = profileFrom(model, account); if (profile.policy === 'api') profile.limits = structuredClone(settings.budget || {}); settings.openCode.profiles.push(profile); await save(settings); await profileScreen(settings, profile);
}
async function profilesMenu(settings) {
  while (true) {
    header(settings); console.log(chalk.bold('PROFILES')); const profiles = migrateProfiles(settings); const choice = await pick('Open a profile or create a new one', [...profiles.map(profile => ({ name: `${profile.id === settings.openCode.activeProfileId ? chalk.green('●') : ' '} ${profileKindLabel(profile)} ${profile.model}  ${chalk.gray(`— ${limitSummary(profile)}`)}`, value: profile.id })), { name: chalk.cyan('+ Create new profile'), value: '__create' }]);
    if (!choice) return; if (choice === '__create') await createProfile(settings); else await profileScreen(settings, profiles.find(profile => profile.id === choice));
  }
}
async function runPreflight(settings) { header(settings); console.log(chalk.bold('PROJECT PREFLIGHT')); const project = selectedProject(settings); const profile = activeProfile(settings); const checks = [];
  try { await fs.stat(project.path); checks.push(['Project directory', true, project.path]); } catch { checks.push(['Project directory', false, 'not found']); }
  try { const branch = (await execute('git', ['-C', project.path, 'branch', '--show-current'])).trim(); checks.push(['Git branch', branch === project.branch, branch || 'detached HEAD']); } catch { checks.push(['Git branch', false, 'Git unavailable']); }
  for (const [name, file] of [['Roadmap', project.roadmap], ['Progress file', project.progress]]) { try { await fs.access(path.join(project.path, file)); checks.push([name, true, file]); } catch { checks.push([name, false, `${file} missing`]); } }
  try { checks.push(['OpenCode command', true, await resolveCommand(settings.openCodeCommand || 'opencode')]); } catch (error) { checks.push(['OpenCode command', false, error.message]); }
  const fresh = snapshotFreshness(profile); checks.push(['Provider snapshot', fresh.ok, fresh.detail]);
  for (const [name, ok, detail] of checks) console.log(`  ${ok ? chalk.green('✓') : chalk.red('×')} ${chalk.bold(name)}  ${detail}`); return pause(); }
async function runRunner(settings, mode) {
  const profile = activeProfile(settings);
  if (!profile) { console.log(chalk.yellow('Create and select a profile first.')); return pause(); }
  let freshness = snapshotFreshness(profile);
  if (!freshness.ok) {
    if (!(await refreshSnapshotBeforeRun(settings, profile, freshness))) return;
    freshness = snapshotFreshness(profile);
    if (!freshness.ok) { console.log(chalk.red(`Snapshot is still not ready: ${freshness.detail}`)); return pause(); }
  }
  applyProfile(settings, profile); await save(settings);
  const project = selectedProject(settings);
  if (!project) { console.log(chalk.red('No project is configured.')); return pause(); }
  if (!(await yesNo(mode === 'continuous' ? 'Start continuous development?' : 'Run one development iteration?'))) return;
  const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-Config', configPath, '-UiEvents', mode === 'continuous' ? '-Continuous' : '-Once'];
  if (mode === 'continuous') {
    const limit = Number(profile.runControls?.maxIterations || 0);
    if (limit > 0) runnerArgs.push('-MaxIterations', String(limit)); else runnerArgs.push('-UnlimitedIterations');
  }
  await runWithTui(runnerArgs, settings, project, mode);
  return pause();
}
async function developmentMenu(settings) { const action = await pick('Development', [{ name: 'Run one iteration', value: 'once' }, { name: 'Run continuously', value: 'continuous' }, { name: 'Project preflight (no agent)', value: 'preflight' }]); if (action === 'preflight') await runPreflight(settings); else if (action) await runRunner(settings, action); }
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
  const updated = { id, path: projectPath, branch, roadmap, progress };
  if (isNew) projects.push(updated); else Object.assign(project, updated);
  settings.activeProjectId = id; await save(settings); console.log(chalk.green(`Project '${id}' saved and selected.`)); return pause();
}
async function projectsMenu(settings) {
  while (true) {
    header(settings); console.log(chalk.bold('PROJECTS')); const projects = normalizeProjects(settings);
    const action = await pick('Select a project or manage its configuration', [
      ...projects.map(project => ({ name: `${project.id === settings.activeProjectId ? chalk.green('●') : ' '} ${project.id}  ${chalk.gray(`— ${project.path}`)}`, value: `project:${project.id}` })),
      { name: chalk.cyan('+ Add project'), value: 'add' }
    ]);
    if (!action) return;
    if (action === 'add') { await editProject(settings, { path: '', branch: '', roadmap: '', progress: '' }, true); continue; }
    const project = projects.find(item => item.id === action.slice('project:'.length)); if (!project) continue;
    const detail = await pick(`Project: ${project.id}`, [
      { name: project.id === settings.activeProjectId ? '● Selected project' : 'Use this project', value: 'use' }, { name: 'Edit project configuration', value: 'edit' }, { name: chalk.red('Remove project configuration'), value: 'remove' }
    ]);
    if (detail === 'use') { settings.activeProjectId = project.id; await save(settings); console.log(chalk.green(`Selected '${project.id}'.`)); await pause(); }
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
  const project = selectedProject(settings); if (!project) return pause(); const latest = await latestIterationSummary(settings, project, configPath); const reports = await dailyReports(settings, project, configPath);
  header(settings); console.log(chalk.bold('REPORTS')); if (latest) {
    const result = Number(latest.exitCode) === 0 && !latest.stoppedReason ? chalk.green('successful') : chalk.yellow(latest.stoppedReason || `exit ${latest.exitCode}`);
    console.log(`  Last run     ${latest.id || 'unknown'}  ${result}`); console.log(`  Finished     ${latest.ended || 'unknown'}`); console.log(`  Tasks        ${(latest.completedTaskIds || []).join(', ') || 'none'}`); console.log(`  Files        code ${latest.codeFilesChanged || 0} · tests ${latest.testFilesChanged || 0} · docs ${latest.documentationFilesChanged || 0}`); console.log(`  Cost/tokens  ${latest.costDeltaUSD == null ? 'not available' : `$${Number(latest.costDeltaUSD).toFixed(4)}`} · ${latest.totalTokensAfter == null ? 'n/a' : Number(latest.totalTokensAfter).toLocaleString('en-US')}`);
  } else console.log(chalk.gray('  No iteration summaries are available for this project.'));
  console.log(`  Daily reports ${reports.length ? reports.slice(0, 5).join(', ') : 'none'}`);
  const action = await pick('Reports', [{ name: 'Generate current daily report', value: 'report' }, { name: 'Show runner status', value: 'status' }]); if (!action) return;
  const flag = action === 'report' ? '-Report' : '-Status'; const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-Config', configPath, flag];
  try { await execute('pwsh.exe', runnerArgs, root, true); } catch (error) { console.log(chalk.yellow(`Report command ended: ${error.message}`)); } return pause();
}
async function systemMenu(settings) {
  const action = await pick('System', [{ name: 'Run diagnostics (read-only)', value: 'diagnostics' }, { name: 'Refresh OpenCode accounts and models', value: 'refresh' }, { name: 'Show configuration path', value: 'config' }]); if (!action) return;
  if (action === 'config') { console.log(`\n${configPath}`); return pause(); }
  if (action === 'diagnostics') {
    header(settings); console.log(chalk.bold('SYSTEM DIAGNOSTICS')); const project = selectedProject(settings); const checks = [];
    checks.push({ label: 'Configuration', ok: true, detail: configPath });
    try { await fs.stat(project?.path || ''); checks.push({ label: 'Project directory', ok: true, detail: project.path }); } catch { checks.push({ label: 'Project directory', ok: false, detail: project?.path || 'not configured' }); }
    try { const branch = (await execute('git', ['-C', project.path, 'branch', '--show-current'])).trim(); checks.push({ label: 'Git branch', ok: branch === project.branch, detail: branch || 'detached HEAD' }); } catch { checks.push({ label: 'Git branch', ok: false, detail: 'Git is not available for this project' }); }
    for (const [label, file] of [['Roadmap', project?.roadmap], ['Progress file', project?.progress]]) {
      try { await fs.access(path.join(project.path, file)); checks.push({ label, ok: true, detail: file }); } catch { checks.push({ label, ok: false, detail: file || 'not configured' }); }
    }
    try { const executable = await resolveCommand(settings.openCodeCommand || 'opencode'); checks.push({ label: 'OpenCode command', ok: true, detail: executable }); } catch (error) { checks.push({ label: 'OpenCode command', ok: false, detail: error.message }); }
    for (const check of checks) console.log(`  ${check.ok ? chalk.green('✓') : chalk.red('×')} ${chalk.bold(check.label)}  ${check.detail}`);
    return pause();
  }
  try { await refreshOpenCode(settings); await save(settings); } catch (error) { console.log(chalk.red(error.message)); } return pause();
}
async function main() { const settings = await load(); while (true) { header(settings); const action = await pick('Main menu', [{ name: 'Development', value: 'development' }, { name: 'Profiles', value: 'profiles' }, { name: 'Projects', value: 'projects' }, { name: 'Reports', value: 'reports' }, { name: 'System', value: 'system' }, { name: 'Save configuration and exit', value: 'exit' }]); if (!action || action === 'exit') { await save(settings); return; } if (action === 'development') await developmentMenu(settings); if (action === 'profiles') await profilesMenu(settings); if (action === 'projects') await projectsMenu(settings); if (action === 'reports') await reportsMenu(settings); if (action === 'system') await systemMenu(settings); } }
main().catch(error => { console.error(chalk.red(`\nTerra Runner could not start: ${error.message}`)); process.exitCode = 1; });
