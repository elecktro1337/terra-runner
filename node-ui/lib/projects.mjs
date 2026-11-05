export const PROJECT_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

export function normalizeProjects(settings) {
  const projects = Array.isArray(settings.projects) ? settings.projects : [];
  delete settings.activeProjectId;
  return projects;
}

export function validateProjectId(id, projects, currentId = '') {
  const value = String(id || '').trim();
  if (!PROJECT_ID.test(value)) return 'Use 1–64 letters, digits, dot, underscore, or hyphen; start with a letter or digit.';
  if (projects.some(project => project.id === value && project.id !== currentId)) return 'A project with this ID already exists.';
  return '';
}
