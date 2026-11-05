export function profileSnapshotSummary(profile = {}, now = Date.now()) {
  if (profile.policy === 'local') return { value: 'not applicable', age: '' };
  const source = profile.usageSource || {};
  const unit = source.unit === 'usd' ? 'USD' : '%';
  const value = source.remaining == null ? 'snapshot required' : `${source.remaining} ${unit}`;
  const observed = Date.parse(source.observedAt || '');
  const age = Number.isFinite(observed) ? `${Math.max(0, (now - observed) / 60000).toFixed(0)} min ago` : 'not recorded';
  return { value, age };
}

export function developmentHeaderRows({ project, profile, command, roadmap = {}, limitText = '', now = Date.now() }) {
  const snapshot = profileSnapshotSummary(profile, now);
  const account = profile.credentialLabel || (profile.policy === 'local' ? 'Local inference' : 'not selected');
  const type = profile.policy === 'api' ? 'API' : profile.policy === 'oauth-managed' ? 'OAuth' : 'LOCAL';
  const reasoning = profile.reasoningVariant || 'provider default';
  const limits = limitText || (profile.policy === 'local' ? 'not applicable' : profile.policy === 'oauth-managed' ? 'provider-managed' : profile.limits?.mode || 'not configured');
  const estimate = profile.usageSource?.costTracking?.enabled ? 'local cost estimate enabled' : profile.policy === 'api' && profile.usageSource?.unit === 'usd' ? 'local cost estimate is off' : 'not applicable';
  const roadmapText = roadmap.available
    ? `${roadmap.completed}/${roadmap.total} complete  |  ${roadmap.pending} pending`
    : roadmap.error || 'not available';
  return [
    `  Project   ${project.id}  |  Command  ${command}`,
    `  Roadmap   ${roadmapText}`,
    `  Account   ${account}  |  Type  ${type}`,
    `  Model     ${profile.model || 'not selected'}`,
    `  Reasoning ${reasoning}`,
    `  Snapshot  ${snapshot.value}${snapshot.age ? `  |  ${snapshot.age}` : ''}`,
    `  Limits    ${limits}  |  OpenCode  ${estimate}`
  ];
}
