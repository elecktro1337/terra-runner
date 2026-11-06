function durationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}

export function formatInstanceTime(value) {
  if (!value) return 'unknown';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return `${date.toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'medium', hour12: false, timeZone: 'Europe/Moscow' })} MSK`;
}

function latestCommit(summary = {}) {
  const first = Array.isArray(summary?.commits) ? summary.commits[0] : null;
  if (!first) return '';
  const hash = typeof first === 'object' ? first.hash : String(first).split(/\s+/, 1)[0];
  const subject = typeof first === 'object' ? first.subject : '';
  return hash ? `${String(hash).slice(0, 12)}${subject ? `  ${subject}` : ''}` : '';
}

function formatSafetyReason(value) {
  const reason = String(value || '');
  const noProgress = reason.match(/^no-roadmap-progress:\s*(\d+)/i);
  if (noProgress) return `Safety stop — ${noProgress[1]} consecutive iteration(s) completed no roadmap task.`;
  const noImplementationProgress = reason.match(/^no-verified-implementation-progress:\s*(\d+)/i);
  if (noImplementationProgress) return `Safety stop — ${noImplementationProgress[1]} consecutive iteration(s) made no roadmap, code, or test progress.`;
  if (/^no-actionable-roadmap-task$/i.test(reason)) return 'Safety stop — OpenCode reported no actionable roadmap task.';
  if (/^roadmap-complete$/i.test(reason)) return 'Roadmap complete.';
  const docsOnly = reason.match(/^documentation-only-progress:\s*(\d+)/i);
  if (docsOnly) return `Safety stop — ${docsOnly[1]} consecutive iteration(s) changed no code or tests.`;
  return reason;
}

export function runTotals(summaries = []) {
  const taskIds = new Set(); let completedWithoutIds = 0; let iterations = 0;
  for (const summary of summaries) {
    if (!summary || typeof summary !== 'object') continue;
    iterations++;
    const ids = Array.isArray(summary.completedTaskIds) ? summary.completedTaskIds.filter(Boolean) : [];
    if (ids.length) ids.forEach(id => taskIds.add(String(id)));
    else completedWithoutIds += Math.max(0, Number(summary.doneAfter || 0) - Number(summary.doneBefore || 0));
  }
  return { iterations, completed: taskIds.size + completedWithoutIds };
}

export function instanceOutcome(instance = {}, summary = null, roadmap = {}, runSummaries = []) {
  const state = String(instance.state || '');
  if (!['finished', 'failed', 'stopped', 'aborted'].includes(state)) return null;
  const completed = Number(roadmap.completed || 0); const pending = Number(roadmap.pending || 0); const total = Number(roadmap.total || 0);
  let reason = String(instance.stopReason || '');
  let kind = state;
  if (state === 'finished') {
    if (roadmap.available && pending === 0) { kind = 'complete'; reason = `Roadmap complete — all ${total || completed} task(s) are done.`; }
    else if (summary?.noActionableTasksReported) { kind = 'paused'; reason = 'OpenCode reported no actionable roadmap task.'; }
    else if (summary?.stoppedReason) { kind = 'stopped'; reason = formatSafetyReason(summary.stoppedReason); }
    else if (!reason) reason = pending > 0 ? `Runner completed normally; ${pending} roadmap task(s) remain.` : 'Runner completed normally.';
  }
  // The runner records a terse process status as stopReason and a separately
  // redacted, actionable diagnosis as error. Prefer the diagnosis.
  if (state === 'failed') reason = String(instance.error || reason || 'Runner failed.');
  if (state === 'stopped' || state === 'aborted') reason = formatSafetyReason(reason || (state === 'aborted' ? 'Emergency abort completed.' : 'Graceful stop completed.'));
  const taskIds = Array.isArray(summary?.completedTaskIds) ? summary.completedTaskIds.filter(Boolean) : [];
  const run = runTotals(runSummaries);
  return {
    kind, reason,
    roadmap: roadmap.available ? `${completed}/${total} complete  |  ${pending} pending${total ? `  |  ${((completed / total) * 100).toFixed(1)}%` : ''}` : '',
    task: taskIds.join(', ') || String(summary?.plannedTaskId || ''),
    duration: summary?.elapsedSeconds == null ? '' : durationText(summary.elapsedSeconds),
    commit: latestCommit(summary),
    runCompletedTasks: run.completed,
    runIterations: run.iterations
  };
}

export function instanceReportRows({ instance = {}, project = {}, outcome = null, logsPath = '', chalk }) {
  const rows = [
    `  ${chalk.bold.cyan('Location')}  ${chalk.gray(project.path || '')}`,
    `  State     ${instance.state || 'unknown'}${instance.activity ? chalk.gray(` — ${instance.activity}`) : ''}`,
    `  Started   ${formatInstanceTime(instance.createdAt)}`
  ];
  if (['finished', 'failed', 'stopped', 'aborted', 'orphaned'].includes(String(instance.state || ''))) rows.push(`  Ended     ${formatInstanceTime(instance.endedAt || instance.updatedAt)}`);
  if (!outcome) return rows;
  const resultColor = outcome.kind === 'complete' ? chalk.green : outcome.kind === 'failed' || outcome.kind === 'aborted' ? chalk.red : chalk.yellow;
  rows.push(`  Result    ${resultColor(outcome.reason)}`);
  if (outcome.runIterations) rows.push(`  This run  ${outcome.runCompletedTasks ? chalk.green(`${outcome.runCompletedTasks} task(s) completed`) : 'no roadmap tasks completed'}  │  ${outcome.runIterations} iteration(s)`);
  if (outcome.task) rows.push(`  Last task ${chalk.cyan(outcome.task)}`);
  if (outcome.duration) rows.push(`  Duration  ${outcome.duration}`);
  if (outcome.commit) rows.push(`  Commit    ${chalk.gray(outcome.commit)}`);
  if (logsPath) rows.push(`  Logs      ${chalk.gray(logsPath)}`);
  return rows;
}
