export function instanceDurationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}

export function instanceActivityText(instanceOrActivity, now = Date.now()) {
  const instance = typeof instanceOrActivity === 'object' && instanceOrActivity !== null ? instanceOrActivity : null;
  const text = String(instance ? instance.activity || '' : instanceOrActivity || '');
  const match = text.match(/^(Iteration\s+\d+):\s*(\d+(?:\.\d+)?)s$/i);
  if (!match) return text;
  const reportedSeconds = Number(match[2]);
  const startedAt = Date.parse(instance?.iterationStartedAt || '');
  const heartbeatAt = Date.parse(instance?.updatedAt || '');
  const elapsedSeconds = Number.isFinite(startedAt)
    ? Math.max(0, (now - startedAt) / 1000)
    : Number.isFinite(heartbeatAt)
      ? Math.max(reportedSeconds, reportedSeconds + ((now - heartbeatAt) / 1000))
      : reportedSeconds;
  return `${match[1]}: ${instanceDurationText(elapsedSeconds)}`;
}
