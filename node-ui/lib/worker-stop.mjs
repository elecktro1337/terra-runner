// OpenCode sometimes uses exit code 1 for an intentional terminal stop. The
// JSON event stream is more precise than that process exit code.
export function isCleanWorkerStopEventStream(text = '') {
  let lastFinish = null;
  for (const line of String(text).split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try { event = JSON.parse(line); } catch { return false; }
    if (String(event?.type || '').toLowerCase() === 'error') return false;
    if (['step_finish', 'step-finish'].includes(String(event?.type || '').toLowerCase())) lastFinish = event;
  }
  return Boolean(lastFinish && String(lastFinish?.part?.reason || '').toLowerCase() === 'stop');
}
