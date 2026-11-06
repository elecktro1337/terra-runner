const HUMAN_ITEM = /^\s*-\s*\[([ xX])\]\s+\*\*(HUM-\d{4,})\s+\[human\]\*\*\s*[—-]\s*(.*)$/i;
const TECHNICAL_ITEM = /^\s*-\s*\[([ xX])\]\s*(.*)$/;

export function isHumanActionLine(line = '') {
  return HUMAN_ITEM.test(String(line));
}

export function parseHumanActions(text = '') {
  const lines = String(text).split(/\r?\n/); const actions = [];
  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(HUMAN_ITEM); if (!match) continue;
    const action = { id: match[2].toUpperCase(), completed: match[1].toLowerCase() === 'x', summary: match[3].trim(), why: '', do: '', completionEvidence: '', blocks: [], line: index };
    for (let child = index + 1; child < lines.length; child++) {
      if (TECHNICAL_ITEM.test(lines[child]) || /^\s*#{1,2}\s+/.test(lines[child])) break;
      const detail = lines[child].match(/^\s+-\s+(Why|Do|Completion evidence|Blocks):\s*(.*)$/i);
      if (!detail) continue;
      const key = detail[1].toLowerCase(); const value = detail[2].trim();
      if (key === 'why') action.why = value;
      if (key === 'do') action.do = value;
      if (key === 'completion evidence') action.completionEvidence = value;
      if (key === 'blocks') action.blocks = value.match(/[A-Z][A-Z0-9_-]*-\d{2,}/gi)?.map(id => id.toUpperCase()) || [];
    }
    actions.push(action);
  }
  return actions;
}

export function humanActionCounts(text = '') {
  const actions = parseHumanActions(text);
  return { open: actions.filter(action => !action.completed).length, completed: actions.filter(action => action.completed).length, total: actions.length };
}

export function humanActionDependencies(text = '', taskId = '') {
  const lines = String(text).split(/\r?\n/); const wanted = String(taskId).toUpperCase();
  for (let index = 0; index < lines.length; index++) {
    const item = lines[index].match(TECHNICAL_ITEM); if (!item || isHumanActionLine(lines[index])) continue;
    const id = item[2].match(/[A-Z][A-Z0-9_-]*-\d{2,}/i)?.[0]?.toUpperCase();
    if (id !== wanted) continue;
    const ids = [];
    for (let child = index + 1; child < lines.length; child++) {
      if (TECHNICAL_ITEM.test(lines[child]) || /^\s*#{1,2}\s+/.test(lines[child])) break;
      const match = lines[child].match(/^\s+-\s+Depends on:\s*(.*)$/i);
      if (match) ids.push(...(match[1].match(/HUM-\d{4,}/gi) || []).map(value => value.toUpperCase()));
    }
    return [...new Set(ids)];
  }
  return [];
}
