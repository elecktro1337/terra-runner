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
function selectedProject(settings) { return settings.projects?.[0] || null; }
function limitSummary(profile) {
  if (!profile) return 'No profile selected'; if (profile.policy === 'local') return 'No provider limits'; if (profile.policy === 'oauth-managed') return profile.runControls?.maxIterations > 0 ? `Provider-managed OAuth · local guard ${profile.runControls.maxIterations} iteration(s)` : 'Provider-managed OAuth usage';
  const limits = profile.limits || {}; const floor = Number(limits.balance?.minimumUsd || 0).toFixed(2);
  return limits.mode === 'daily' ? `Daily $${Number(limits.dailyUsd || 0).toFixed(2)}` : limits.mode === 'hybrid' ? `Daily $${Number(limits.dailyUsd || 0).toFixed(2)} + floor $${floor}` : limits.mode === 'unlimited' ? 'Unlimited' : `Balance floor $${floor}`;
}
function usageSourceSummary(profile) {
  const source = profile?.usageSource || {}; if (source.kind === 'provider-managed') return 'Provider-managed (no local quota API)';
  if (source.kind === 'external-command') return `External read-only command: ${source.command || 'not configured'}`;
  if (source.kind === 'local-estimate') return 'Local OpenCode cost estimate'; return 'Not applicable';
}
function header(settings) {
  clear(); const project = selectedProject(settings); const profile = activeProfile(settings);
  console.log(chalk.cyan(figlet.textSync('Terra', { horizontalLayout: 'fitted' }))); console.log(chalk.gray('RUNNER  v1.6  ·  Local OpenCode development orchestrator')); console.log(rule);
  console.log(`${chalk.bold('Project')}  ${chalk.white(project?.id || 'not selected')}  ${chalk.gray('│')}  ${chalk.bold('Branch')}  ${project?.branch || 'not configured'}`); console.log(`${chalk.bold('Path')}     ${chalk.gray(project?.path || 'not configured')}`);
  console.log(`${chalk.bold('Profile')}  ${chalk.cyan(profile?.model || 'not selected')}`); console.log(`${chalk.bold('Policy')}   ${chalk.yellow(profile?.policy || 'not configured')}  ${chalk.gray('│')}  ${limitSummary(profile)}`); console.log(rule);
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
    const limitAction = profile.policy === 'oauth-managed' ? { name: 'Provider usage information', value: 'limits' } : { name: 'Configure limits', value: 'limits' };
    const action = await pick('Profile actions', [{ name: profile.id === settings.openCode.activeProfileId ? '● Active profile' : 'Use this profile', value: 'use' }, { name: 'Configure account type', value: 'type' }, { name: 'Configure reasoning', value: 'reasoning' }, limitAction, { name: 'Configure usage data source', value: 'source' }, { name: 'Configure local run guard', value: 'guard' }]);
    if (!action) return; if (action === 'use') { applyProfile(settings, profile); await save(settings); console.log(chalk.green('Active profile updated.')); await pause(); } if (action === 'type') await configureType(settings, profile); if (action === 'reasoning') await configureReasoning(settings, profile); if (action === 'limits') await configureLimits(settings, profile); if (action === 'source') await configureUsageSource(settings, profile); if (action === 'guard') await configureRunGuard(settings, profile);
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
    header(settings); console.log(chalk.bold('PROFILES')); const profiles = migrateProfiles(settings); const choice = await pick('Open a profile or create a new one', [...profiles.map(profile => ({ name: `${profile.id === settings.openCode.activeProfileId ? chalk.green('●') : ' '} ${profile.model}  ${chalk.gray(`— ${limitSummary(profile)}`)}`, value: profile.id })), { name: chalk.cyan('+ Create new profile'), value: '__create' }]);
    if (!choice) return; if (choice === '__create') await createProfile(settings); else await profileScreen(settings, profiles.find(profile => profile.id === choice));
  }
}
async function runRunner(settings, mode) { const profile = activeProfile(settings); if (!profile) { console.log(chalk.yellow('Create and select a profile first.')); return pause(); } applyProfile(settings, profile); await save(settings); const project = selectedProject(settings); if (!project) { console.log(chalk.red('No project is configured.')); return pause(); } if (mode !== 'dry' && !(await yesNo(mode === 'continuous' ? 'Start continuous development?' : 'Run one development iteration?'))) return; const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-Config', configPath, '-ShowProgress', mode === 'continuous' ? '-Continuous' : mode === 'dry' ? '-DryRun' : '-Once']; if (mode === 'continuous' && Number(profile.runControls?.maxIterations || 0) > 0) runnerArgs.push('-MaxIterations', String(profile.runControls.maxIterations)); try { await execute('pwsh.exe', runnerArgs, root, true); } catch (error) { console.log(chalk.yellow(`Runner ended: ${error.message}`)); } return pause(); }
async function developmentMenu(settings) { const action = await pick('Development', [{ name: 'Run one iteration', value: 'once' }, { name: 'Run continuously', value: 'continuous' }, { name: 'Validate project (dry run)', value: 'dry' }]); if (action) await runRunner(settings, action); }
async function main() { const settings = await load(); while (true) { header(settings); const action = await pick('Main menu', [{ name: 'Development', value: 'development' }, { name: 'Profiles', value: 'profiles' }, { name: 'Save configuration and exit', value: 'exit' }]); if (!action || action === 'exit') { await save(settings); return; } if (action === 'development') await developmentMenu(settings); if (action === 'profiles') await profilesMenu(settings); } }
main().catch(error => { console.error(chalk.red(`\nTerra Runner could not start: ${error.message}`)); process.exitCode = 1; });
