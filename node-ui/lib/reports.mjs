import fs from 'node:fs/promises';
import path from 'node:path';

export function projectDataRoot(settings, project, configPath) {
  const configured = String(settings.logs?.root || './data/projects');
  const root = path.isAbsolute(configured) ? configured : path.resolve(path.dirname(configPath), configured);
  return path.join(root, project.id);
}

async function readSummary(filename) {
  const summary = JSON.parse(await fs.readFile(filename, 'utf8'));
  if (Array.isArray(summary.eventErrorTypes) || !summary.eventsFile) return summary;
  // Older summaries predate eventErrorTypes. Recover only the classified type
  // from the colocated event stream so the UI can explain a provider stop
  // without rendering provider bodies, credentials, or raw error text.
  try {
    const raw = await fs.readFile(path.join(path.dirname(filename), summary.eventsFile), 'utf8');
    const types = new Set();
    for (const line of raw.split(/\r?\n/)) {
      try {
        const event = JSON.parse(line);
        if (event?.type === 'error' && typeof event?.error?.type === 'string' && event.error.type) types.add(event.error.type);
      } catch { }
    }
    summary.eventErrorTypes = [...types];
  } catch { summary.eventErrorTypes = []; }
  return summary;
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
  try { return await readSummary(candidates[0].file); } catch { return null; }
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
      summaries.push(await readSummary(file));
    } catch { }
  }
  return summaries.sort((a, b) => String(a.started || '').localeCompare(String(b.started || '')));
}

export async function dailyReports(settings, project, configPath) {
  const reports = path.join(projectDataRoot(settings, project, configPath), 'reports');
  try { return (await fs.readdir(reports)).filter(name => /^\d{4}-\d{2}-\d{2}\.md$/.test(name)).sort().reverse(); } catch { return []; }
}
