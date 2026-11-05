function durationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}

function compact(value, maximum) {
  const text = String(value || '').replace(/[*_`]/g, '').replace(/\s+/g, ' ').trim();
  return text.length > maximum ? `${text.slice(0, Math.max(0, maximum - 1)).trimEnd()}…` : text;
}

function commitHash(event) {
  const first = Array.isArray(event?.commits) ? event.commits[0] : null;
  if (!first) return 'no commit';
  const hash = typeof first === 'object' ? first.hash : String(first).split(/\s+/, 1)[0];
  return hash ? `commit ${String(hash).slice(0, 12)}` : 'no commit';
}

export function completedIterationText(event = {}) {
  const completed = Array.isArray(event.completedTaskIds) ? event.completedTaskIds.filter(Boolean) : [];
  const taskId = completed[0] || event.taskId || 'no completed task';
  const more = completed.length > 1 ? ` +${completed.length - 1}` : '';
  let title = compact(event.taskTitle, 42);
  if (taskId !== 'no completed task' && title.toLowerCase().startsWith(String(taskId).toLowerCase())) title = title.slice(String(taskId).length).replace(/^\s*[-—:]?\s*/, '');
  const task = title ? `${taskId}${more} — ${title}` : `${taskId}${more}`;
  return `Iteration ${event.iteration ?? '?'} · ${task} · ${durationText(event.elapsedSeconds)} · ${commitHash(event)}`;
}
