import fs from 'node:fs/promises';
import path from 'node:path';
import { isHumanActionLine } from './human-actions.mjs';

export function roadmapProgressFromText(text, taskIdPattern = '') {
  let matcher = null;
  try { matcher = taskIdPattern ? new RegExp(taskIdPattern) : null; }
  catch { return { available: false, completed: 0, pending: 0, total: 0, nextTask: '', error: 'invalid task ID pattern' }; }
  let completed = 0; let pending = 0; let nextTask = '';
  for (const line of String(text || '').split(/\r?\n/)) {
    const match = line.match(/^\s*-\s*\[([ xX])\]\s*(.*)$/);
    if (!match || isHumanActionLine(line) || (matcher && !matcher.test(line))) continue;
    if (match[1].toLowerCase() === 'x') completed++;
    else {
      pending++;
      if (!nextTask) nextTask = match[2].replace(/\s+/g, ' ').trim();
    }
  }
  return { available: true, completed, pending, total: completed + pending, nextTask, error: '' };
}

export async function readRoadmapProgress(project = {}) {
  try {
    const file = path.join(String(project.path || ''), String(project.roadmap || 'ROADMAP.md'));
    return roadmapProgressFromText(await fs.readFile(file, 'utf8'), String(project.taskIdPattern || ''));
  } catch (error) {
    return { available: false, completed: 0, pending: 0, total: 0, nextTask: '', error: error.code === 'ENOENT' ? 'roadmap file not found' : 'roadmap unavailable' };
  }
}
