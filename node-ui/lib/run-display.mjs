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
export function developmentHeaderRows({ project, profile, command, roadmap = {}, limitText = '', includeTerraLimits = true, now = Date.now() }) {
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
  return rows;
}
