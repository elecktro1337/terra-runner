export function selectedRoadmapTaskFromEvent(event = {}) {
  if (event?.type !== 'text') return '';
  const part = event.part || {};
  const text = String(part.text || event.text || '');
  const match = text.match(/(?:^|\r?\n)\s*TERRA_SELECTED_TASK\s*:\s*([A-Z][A-Z0-9_-]*-\d{3,})\b/i);
  return match ? match[1].toUpperCase() : '';
}
