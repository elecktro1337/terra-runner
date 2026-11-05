function durationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}

function latestCommit(summary = {}) {
  const first = Array.isArray(summary?.commits) ? summary.commits[0] : null;
  if (!first) return '';
  const hash = typeof first === 'object' ? first.hash : String(first).split(/\s+/, 1)[0];
  const subject = typeof first === 'object' ? first.subject : '';
  return hash ? `${String(hash).slice(0, 12)}${subject ? `  ${subject}` : ''}` : '';
}

export function instanceOutcome(instance = {}, summary = null, roadmap = {}) {
  const state = String(instance.state || '');
  if (!['finished', 'failed', 'stopped', 'aborted'].includes(state)) return null;
  const completed = Number(roadmap.completed || 0); const pending = Number(roadmap.pending || 0); const total = Number(roadmap.total || 0);
  let reason = String(instance.stopReason || '');
  let kind = state;
  if (state === 'finished') {
    if (roadmap.available && pending === 0) { kind = 'complete'; reason = `Roadmap complete — all ${total || completed} task(s) are done.`; }
    else if (summary?.noActionableTasksReported) { kind = 'paused'; reason = 'OpenCode reported no actionable roadmap task.'; }
    else if (summary?.stoppedReason) { kind = 'stopped'; reason = String(summary.stoppedReason); }
    else if (!reason) reason = pending > 0 ? `Runner completed normally; ${pending} roadmap task(s) remain.` : 'Runner completed normally.';
  }
  if (state === 'failed') reason ||= String(instance.error || 'Runner failed.');
  if (state === 'stopped' || state === 'aborted') reason ||= state === 'aborted' ? 'Emergency abort completed.' : 'Graceful stop completed.';
  const taskIds = Array.isArray(summary?.completedTaskIds) ? summary.completedTaskIds.filter(Boolean) : [];
  return {
    kind, reason,
    roadmap: roadmap.available ? `${completed}/${total} complete  |  ${pending} pending${total ? `  |  ${((completed / total) * 100).toFixed(1)}%` : ''}` : '',
    task: taskIds.join(', ') || String(summary?.plannedTaskId || ''),
    duration: summary?.elapsedSeconds == null ? '' : durationText(summary.elapsedSeconds),
    commit: latestCommit(summary)
  };
}
