import chalk from 'chalk';

export function profileSnapshotSummary(profile = {}, now = Date.now()) {
  if (profile.policy === 'local') return { value: 'not applicable', age: '' };
  const source = profile.usageSource || {};
  const unit = source.unit === 'usd' ? 'USD' : '%';
  const value = source.remaining == null ? 'snapshot required' : `${source.remaining} ${unit}`;
  const observed = Date.parse(source.observedAt || '');
  const age = Number.isFinite(observed) ? `${Math.max(0, (now - observed) / 60000).toFixed(0)} min ago` : 'not recorded';
  return { value, age };
}
function durationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}
export function elapsedSecondsSince(startedAt, now = Date.now()) {
  const started = typeof startedAt === 'number' ? startedAt : Date.parse(String(startedAt || ''));
  return Number.isFinite(started) ? Math.max(0, (now - started) / 1000) : 0;
}
function compact(value, maximum = 44) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  return text.length > maximum ? `${text.slice(0, Math.max(0, maximum - 1)).trimEnd()}…` : text;
}
function commitText(commit) {
  if (!commit) return '—';
  const hash = typeof commit === 'object' ? commit.hash : String(commit).split(/\s+/, 1)[0];
  const subject = typeof commit === 'object' ? commit.subject : '';
  return `${String(hash || '').slice(0, 12)}${subject ? `  ${compact(subject)}` : ''}` || '—';
}
export function developmentHeaderRows({ project, profile, command, roadmap = {}, limitText = '', includeTerraLimits = true, run = null, now = Date.now() }) {
  const snapshot = profileSnapshotSummary(profile, now);
  const account = profile.credentialLabel || (profile.policy === 'local' ? 'Local inference' : 'not selected');
  const type = profile.policy === 'api' ? 'API' : profile.policy === 'oauth-managed' ? 'OAuth' : 'LOCAL';
  const reasoning = profile.reasoningVariant || 'provider default';
  const limits = limitText || (profile.policy === 'local' ? 'not applicable' : profile.policy === 'oauth-managed' ? 'provider-managed' : profile.limits?.mode || 'not configured');
  const estimate = profile.usageSource?.costTracking?.enabled ? 'local cost estimate enabled' : profile.policy === 'api' && profile.usageSource?.unit === 'usd' ? 'local cost estimate is off' : 'not applicable';
  const completed = Number(roadmap.completed || 0); const total = Number(roadmap.total || 0); const pending = Number(roadmap.pending || 0);
  const percent = total > 0 ? `${((completed / total) * 100).toFixed(1)}%` : '—';
  const roadmapText = roadmap.available
    ? `${chalk.green(`${completed}/${total} complete`)}  ${chalk.gray('│')}  ${chalk.yellow(`${pending} pending`)}  ${chalk.gray('│')}  ${chalk.cyan(percent)}`
    : chalk.yellow(roadmap.error || 'not available');
  const rows = [
    `  ${chalk.bold.cyan('Project')}   ${chalk.white(project.id)}  ${chalk.gray('│')}  ${chalk.bold.cyan('Command')}  ${chalk.yellow(command)}`,
    `  ${chalk.bold.cyan('Roadmap')}   ${roadmapText}`,
    `  ${chalk.bold.cyan('Profile')}   ${chalk.white(account)} ${chalk.gray(`(${type})`)}  ${chalk.gray('│')}  ${chalk.cyan(profile.model || 'not selected')}  ${chalk.gray('│')}  ${chalk.bold('Reasoning')} ${chalk.magenta(reasoning)}`
  ];
  if (includeTerraLimits) rows.push(`  ${chalk.bold.cyan('Snapshot')}  ${chalk.yellow(snapshot.value)}${snapshot.age ? chalk.gray(`  │  ${snapshot.age}`) : ''}  ${chalk.gray('│')}  ${chalk.bold.cyan('Limits')}  ${chalk.yellow(limits)}  ${chalk.gray('│')}  OpenCode ${chalk.white(estimate)}`);
  if (run) rows.push(`  ${chalk.bold.cyan('Run')}       ${chalk.white(durationText(run.elapsedSeconds))}  ${chalk.gray('│')}  ${chalk.bold.cyan('Last task')}  ${chalk.cyan(run.lastTask || '—')}  ${chalk.gray('│')}  ${chalk.bold.cyan('Last commit')}  ${chalk.gray(commitText(run.lastCommit))}`);
  return rows;
}
