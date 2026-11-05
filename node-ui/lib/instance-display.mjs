export function instanceDurationText(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s`;
}

export function instanceActivityText(activity) {
  const text = String(activity || '');
  const match = text.match(/^(Iteration\s+\d+):\s*(\d+(?:\.\d+)?)s$/i);
  return match ? `${match[1]}: ${instanceDurationText(match[2])}` : text;
}
