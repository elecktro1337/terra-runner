export const PROJECT_BOOTSTRAP_PROMPT_FILE = 'PROJECT-BOOTSTRAP-PROMPT.md';
export const PROJECT_BOOTSTRAP_MENU_VALUE = 'bootstrap-prompt';

export function projectMenuChoices(projects) {
  return [
    { name: 'Open default project bootstrap prompt', value: PROJECT_BOOTSTRAP_MENU_VALUE },
    ...(Array.isArray(projects) ? projects : []).map(project => ({ name: project.id, value: `project:${project.id}` })),
    { name: '+ Add project', value: 'add' }
  ];
}
