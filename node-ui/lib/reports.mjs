import fs from 'node:fs/promises';
import path from 'node:path';

export function projectDataRoot(settings, project, configPath) {
  const configured = String(settings.logs?.root || './data/projects');
  const root = path.isAbsolute(configured) ? configured : path.resolve(path.dirname(configPath), configured);
  return path.join(root, project.id);
}

export async function latestIterationSummary(settings, project, configPath) {
  const logs = path.join(projectDataRoot(settings, project, configPath), 'logs');
  let entries;
  try { entries = await fs.readdir(logs, { recursive: true, withFileTypes: true }); } catch { return null; }
  const candidates = [];
  for (const entry of entries) if (entry.isFile() && entry.name.endsWith('.summary.json')) {
    const file = path.join(entry.parentPath || entry.path, entry.name);
    try { candidates.push({ file, stat: await fs.stat(file) }); } catch { }
  }
  candidates.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  if (!candidates.length) return null;
  try { return JSON.parse(await fs.readFile(candidates[0].file, 'utf8')); } catch { return null; }
}

export async function iterationSummariesSince(settings, project, configPath, sinceMs) {
  const logs = path.join(projectDataRoot(settings, project, configPath), 'logs');
  let entries;
  try { entries = await fs.readdir(logs, { recursive: true, withFileTypes: true }); } catch { return []; }
  const summaries = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith('.summary.json')) continue;
    const file = path.join(entry.parentPath || entry.path, entry.name);
    try {
      const stat = await fs.stat(file);
      if (stat.mtimeMs + 1000 < sinceMs) continue;
      summaries.push(JSON.parse(await fs.readFile(file, 'utf8')));
    } catch { }
  }
  return summaries.sort((a, b) => String(a.started || '').localeCompare(String(b.started || '')));
}

export async function dailyReports(settings, project, configPath) {
  const reports = path.join(projectDataRoot(settings, project, configPath), 'reports');
  try { return (await fs.readdir(reports)).filter(name => /^\d{4}-\d{2}-\d{2}\.md$/.test(name)).sort().reverse(); } catch { return []; }
}
