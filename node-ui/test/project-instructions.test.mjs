import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_PROJECT_INSTRUCTIONS, normalizeProjects, validateProjectInstructionsPath } from '../lib/projects.mjs';

test('migrates existing projects to the mandatory default instructions file', () => {
  const settings = { schemaVersion: 10, projects: [{ id: 'one' }] };
  normalizeProjects(settings);
  assert.equal(settings.projects[0].instructions, DEFAULT_PROJECT_INSTRUCTIONS);
});

test('retains safe project-relative instructions paths and rejects escapes', () => {
  const settings = { projects: [{ id: 'one', instructions: 'docs/agent-rules.md' }, { id: 'two', instructions: '../outside.md' }] };
  normalizeProjects(settings);
  assert.equal(settings.projects[0].instructions, 'docs/agent-rules.md');
  assert.equal(settings.projects[1].instructions, DEFAULT_PROJECT_INSTRUCTIONS);
  assert.match(validateProjectInstructionsPath('C:\\temp\\rules.md'), /relative/);
  assert.match(validateProjectInstructionsPath('../rules.md'), /must not leave/);
});
