export const PROJECT_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
export const DEFAULT_PROJECT_INSTRUCTIONS = 'PROJECT-INSTRUCTIONS.md';

export function validateProjectInstructionsPath(value) {
  const filename = String(value || '').trim();
  if (!filename) return 'Enter an instructions filename.';
  if (/^(?:[A-Za-z]:[\\/]|[\\/])/.test(filename)) return 'Instructions must be a relative path inside the project.';
  if (filename.split(/[\\/]+/).some(part => part === '..')) return 'Instructions path must not leave the project directory.';
  if (/[\0]/.test(filename)) return 'Instructions filename is invalid.';
  return '';
}

export function validateProjectIntegrationHarnessPath(value) {
  const filename = String(value || '').trim();
  if (!filename) return '';
  if (/^(?:[A-Za-z]:[\\/]|[\\/])/.test(filename)) return 'Integration harness must be a relative path inside the project.';
  if (filename.split(/[\\/]+/).some(part => part === '..')) return 'Integration harness path must not leave the project directory.';
  if (/[\0]/.test(filename)) return 'Integration harness path is invalid.';
  if (!/\.ps1$/i.test(filename)) return 'Integration harness must be a PowerShell .ps1 file.';
  return '';
}

export function normalizeProjects(settings) {
  const projects = Array.isArray(settings.projects) ? settings.projects : [];
  delete settings.activeProjectId;
  for (const project of projects) {
    if (!project || typeof project !== 'object') continue;
    const candidate = String(project?.instructions || '').trim();
    project.instructions = validateProjectInstructionsPath(candidate) ? DEFAULT_PROJECT_INSTRUCTIONS : candidate;
    const harness = String(project?.integrationHarness || '').trim();
    project.integrationHarness = validateProjectIntegrationHarnessPath(harness) ? '' : harness;
  }
  return projects;
}

export function validateProjectId(id, projects, currentId = '') {
  const value = String(id || '').trim();
  if (!PROJECT_ID.test(value)) return 'Use 1–64 letters, digits, dot, underscore, or hyphen; start with a letter or digit.';
  if (projects.some(project => project.id === value && project.id !== currentId)) return 'A project with this ID already exists.';
  return '';
}
