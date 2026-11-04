#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { spawn } from 'node:child_process';
import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { activeProfile, applyProfile, isLocalModel, migrateProfiles, profileFrom, profileTitle } from './lib/profiles.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const argValue = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : ''; };
const portable = args.includes('--portable');
const configPath = argValue('--config') || (portable ? path.join(root, 'terra-config.json') : path.join(process.env.LOCALAPPDATA || process.env.APPDATA || root, 'TerraRunner', 'terra-config.json'));
const rl = readline.createInterface({ input, output });
const cyan = s => `\x1b[36m${s}\x1b[0m`, green = s => `\x1b[32m${s}\x1b[0m`, yellow = s => `\x1b[33m${s}\x1b[0m`, dim = s => `\x1b[2m${s}\x1b[0m`, bold = s => `\x1b[1m${s}\x1b[0m`;

function clear() { if (output.isTTY) process.stdout.write('\x1Bc'); }
function line() { console.log(dim('──────────────────────────────────────────────────────────────────────────────')); }
async function ask(prompt) { return (await rl.question(prompt)).trim(); }
async function confirm(prompt) { return ['y', 'yes'].includes((await ask(`${prompt} [y/n]: `)).toLowerCase()); }
async function choose(title, choices) {
  console.log(`\n${bold(title)}`); choices.forEach((c, i) => console.log(`  ${i + 1}  ${c.label}`)); console.log('  0  Back');
  while (true) { const v = await ask('Choose an option: '); if (v === '0' || !v) return null; const choice = choices[Number(v) - 1]; if (choice) return choice.value; console.log(yellow('Choose one of the listed options.')); }
}
function command(command, commandArgs, cwd = root, inherited = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, { cwd, shell: false, stdio: inherited ? 'inherit' : ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    if (!inherited) { child.stdout.on('data', d => stdout += d); child.stderr.on('data', d => stderr += d); }
    child.once('error', reject); child.once('close', code => code === 0 ? resolve(stdout) : reject(new Error(`${command} exited with code ${code}${stderr ? `: ${stderr.trim()}` : ''}`)));
  });
}
async function save(settings) {
  await fs.mkdir(path.dirname(configPath), { recursive: true });
  const temporary = `${configPath}.${process.pid}.tmp`;
  await fs.writeFile(temporary, `${JSON.stringify(settings, null, 2)}\n`, 'utf8'); await fs.rename(temporary, configPath);
}
async function load() {
  try { const settings = JSON.parse(await fs.readFile(configPath, 'utf8')); settings.openCode ||= { accounts: [], activeAccountId: '', reasoning: {} }; settings.openCode.accounts ||= []; migrateProfiles(settings); return settings; }
  catch (error) { throw new Error(`Cannot load ${configPath}. Start the legacy setup wizard once or pass --config <file>. ${error.message}`); }
}
function parseModels(text) { return [...new Set(text.split(/\r?\n/).map(s => s.trim()).filter(s => /^[a-z0-9_.-]+\/.+/i.test(s)))]; }
async function refreshAccounts(settings) {
  const executable = settings.openCodeCommand || 'opencode';
  const raw = await command(executable, ['auth', 'list', '--format', 'json']); const providers = JSON.parse(raw);
  const accounts = [];
  for (const provider of providers) for (const connection of provider.connections || []) accounts.push({
    id: `${provider.id}:${connection.id}`, provider: provider.id, credentialId: connection.id, label: connection.label || provider.name || provider.id,
    authMethod: connection.method || '', usageKind: connection.method === 'oauth' ? 'oauth' : 'balance'
  });
  const oldLocal = settings.openCode.accounts.filter(a => a.authMethod === 'local');
  settings.openCode.accounts = [...accounts, ...oldLocal];
  const models = parseModels(await command(executable, ['models']));
  return { accounts, models };
}
function currentProject(settings) { return (settings.projects || [])[0]; }
function budgetText(settings, profile) {
  if (!profile) return 'No profile selected';
  if (profile.policy === 'local') return 'Local model — no provider limits';
  if (profile.policy === 'oauth-managed') return 'OAuth — usage and reset are managed by the provider';
  const b = settings.budget || {}; return `API spending limits — ${b.mode || 'daily'}${b.mode === 'balance' || b.mode === 'hybrid' ? `, floor $${Number(b.balance?.minimumUsd || 0).toFixed(2)}` : b.mode === 'daily' ? `, limit $${Number(b.dailyUsd || 0).toFixed(2)}` : ''}`;
}
function header(settings) {
  clear(); const project = currentProject(settings); const profile = activeProfile(settings);
  console.log(cyan(bold('TERRA RUNNER')) + dim('  v1.6 development UI'));
  console.log(dim('Local OpenCode development orchestrator')); line();
  console.log(`${bold('Project:')} ${project?.id || 'not selected'}${project?.branch ? `  ${dim('|')}  ${bold('Branch:')} ${project.branch}` : ''}`);
  console.log(`${bold('Path:')}    ${project?.path || 'not configured'}`);
  console.log(`${bold('Profile:')} ${profileTitle(profile)}`);
  console.log(`${bold('Limits:')}  ${budgetText(settings, profile)}`); line();
}
async function selectProfile(settings) {
  let inventory;
  try { inventory = await refreshAccounts(settings); await save(settings); console.log(green(`OpenCode refreshed: ${inventory.accounts.length} credential(s), ${inventory.models.length} model(s).`)); }
  catch (error) { console.log(yellow(`Could not refresh OpenCode: ${error.message}`)); inventory = { accounts: settings.openCode.accounts, models: [] }; }
  const profiles = migrateProfiles(settings);
  const choices = profiles.map(p => ({ label: `${p.id === settings.openCode.activeProfileId ? '* ' : '  '}${profileTitle(p)}`, value: p.id }));
  choices.push({ label: 'Create a profile from an OpenCode model', value: '__create' });
  const selected = await choose('Profiles', choices); if (!selected) return;
  if (selected !== '__create') { const p = profiles.find(p => p.id === selected); applyProfile(settings, p); await save(settings); console.log(green('Profile selected.')); await ask('Press Enter to continue'); return; }
  const models = inventory.models;
  if (!models.length) { console.log(yellow('No models were returned. Check OpenCode, then refresh again.')); await ask('Press Enter to continue'); return; }
  const filter = (await ask('Filter models (blank shows first 40): ')).toLowerCase(); const filtered = models.filter(m => !filter || m.toLowerCase().includes(filter)).slice(0, 80);
  const model = await choose('Select a model', filtered.map(m => ({ label: `${m}${isLocalModel(m) ? '  [local]' : ''}`, value: m }))); if (!model) return;
  let account = null;
  if (!isLocalModel(model)) {
    const provider = model.split('/')[0].toLowerCase(); const accounts = inventory.accounts.filter(a => a.provider.toLowerCase() === provider);
    if (!accounts.length) { console.log(yellow(`No saved ${provider} credential was found. Sign in with OpenCode first, then refresh.`)); await ask('Press Enter to continue'); return; }
    const accountId = await choose('Select the credential for this cloud model', accounts.map(a => ({ label: `${a.label} [${a.authMethod || 'unknown'}]`, value: a.id })));
    if (!accountId) return; account = accounts.find(a => a.id === accountId);
  }
  const reasoning = await choose('Reasoning level', [{ label: 'Provider default', value: '' }, ...['minimal', 'low', 'medium', 'high', 'xhigh'].map(v => ({ label: v, value: v }))]); if (reasoning === null) return;
  const showThinking = await confirm('Show reasoning blocks during the run?'); const p = profileFrom(model, account, reasoning, showThinking);
  settings.openCode.profiles.push(p); applyProfile(settings, p); await save(settings);
  console.log(green(`Profile created: ${profileTitle(p)}`)); await ask('Press Enter to continue');
}
function readAmount(value, fallback) {
  const normalized = String(value).trim().replace(',', '.'); const number = Number(normalized);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}
async function configureActivePolicy(settings) {
  const profile = activeProfile(settings); if (!profile) return;
  if (profile.policy === 'local') {
    console.log(green('This is a local model profile. Terra Runner does not display or enforce provider balance or quota limits.'));
    await ask('Press Enter to continue'); return;
  }
  if (profile.policy === 'oauth-managed') {
    console.log(yellow('This profile uses OAuth. Usage allowance, reset windows and any limits are managed by the provider.'));
    console.log(dim('Terra Runner will not ask for a made-up quota snapshot or subtract usage locally.')); await ask('Press Enter to continue'); return;
  }
  const budget = settings.budget ||= {}; budget.balance ||= {};
  const mode = await choose('API spending policy', [
    { label: 'Daily spending limit', value: 'daily' }, { label: 'Minimum balance floor', value: 'balance' },
    { label: 'Daily limit and balance floor', value: 'hybrid' }, { label: 'Unlimited (requires confirmation)', value: 'unlimited' }
  ]); if (!mode) return;
  if (mode === 'unlimited' && !(await confirm('Disable local API spending limits for this profile?'))) return;
  budget.mode = mode; budget.allowUnlimited = mode === 'unlimited';
  if (mode === 'daily' || mode === 'hybrid') {
    budget.dailyUsd = readAmount(await ask(`Daily limit [${Number(budget.dailyUsd ?? 5).toFixed(2)}]: `), Number(budget.dailyUsd ?? 5));
    budget.reserveUsd = readAmount(await ask(`Daily safety reserve [${Number(budget.reserveUsd ?? .5).toFixed(2)}]: `), Number(budget.reserveUsd ?? .5));
  }
  if (mode === 'balance' || mode === 'hybrid') {
    budget.balance.minimumUsd = readAmount(await ask(`Minimum balance [${Number(budget.balance.minimumUsd ?? 5).toFixed(2)}]: `), Number(budget.balance.minimumUsd ?? 5));
    budget.balance.iterationReserveUsd = readAmount(await ask(`Next-run reserve [${Number(budget.balance.iterationReserveUsd ?? .5).toFixed(2)}]: `), Number(budget.balance.iterationReserveUsd ?? .5));
  }
  await save(settings); console.log(green('API spending policy saved for the active API profile.')); await ask('Press Enter to continue');
}
async function runRunner(settings, mode) {
  const profile = activeProfile(settings); if (!profile) { console.log(yellow('Create and select a model profile first.')); await ask('Press Enter to continue'); return; }
  applyProfile(settings, profile); await save(settings); const project = currentProject(settings);
  if (!project) { console.log(yellow('No project is configured.')); return; }
  if (mode !== 'dry' && !(await confirm(mode === 'continuous' ? 'Start continuous development?' : 'Run one development iteration?'))) return;
  const runnerArgs = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'terra-runner.ps1'), '-Project', project.id, '-Config', configPath, '-ShowProgress'];
  runnerArgs.push(mode === 'continuous' ? '-Continuous' : mode === 'dry' ? '-DryRun' : '-Once');
  try { await command('pwsh.exe', runnerArgs, root, true); } catch (error) { console.log(yellow(`Runner ended: ${error.message}`)); }
  await ask('Press Enter to continue');
}
async function main() {
  try {
    const settings = await load();
    while (true) {
      header(settings);
      const action = await choose('Development', [
        { label: 'Run one iteration', value: 'once' }, { label: 'Run continuously', value: 'continuous' }, { label: 'Validate project (dry run)', value: 'dry' },
        { label: 'Profiles, models, accounts and reasoning', value: 'profiles' }, { label: 'Configure active profile limits', value: 'limits' }, { label: 'Save configuration and exit', value: 'exit' }
      ]);
      if (!action || action === 'exit') { await save(settings); break; }
      if (action === 'profiles') await selectProfile(settings); else if (action === 'limits') await configureActivePolicy(settings); else await runRunner(settings, action);
    }
  } finally { rl.close(); }
}
main().catch(error => { console.error(`\n${yellow('Terra Runner could not start:')} ${error.message}`); process.exitCode = 1; });
