const TERMINAL_STATES = new Set(['finished', 'failed', 'stopped', 'aborted', 'orphaned']);

// Keep the dispatcher menu honest: terminal records have no process left to
// control, so presenting disabled controls is only noise.
export function instanceActionPlan(instance = {}, { canFinalize = false } = {}) {
  if (TERMINAL_STATES.has(String(instance.state || ''))) {
    return [
      { name: 'Remove this completed record', value: 'remove' },
      { name: 'Refresh', value: 'refresh' }
    ];
  }

  const actions = [
    { name: 'Request graceful stop', value: 'stop' },
    { name: 'Emergency abort', value: 'abort', destructive: true }
  ];
  if (canFinalize) actions.push({ name: instance.state === 'aborting' ? 'Finalize stalled abort' : 'Finalize stalled instance', value: 'finalize', attention: true });
  actions.push({ name: 'Refresh', value: 'refresh' });
  return actions;
}

export function projectWindowActionPlan(instance = {}) {
  const actions = [
    { name: 'Run one development iteration', value: 'once' },
    { name: 'Start Autopilot', value: 'continuous' },
    { name: 'Dry run', value: 'preflight' }
  ];
  if (!TERMINAL_STATES.has(String(instance.state || ''))) {
    actions.push(
      { name: 'Request graceful stop', value: 'stop' },
      { name: 'Emergency abort', value: 'abort', destructive: true }
    );
  }
  actions.push({ name: 'Close project window', value: 'close' });
  return actions;
}
