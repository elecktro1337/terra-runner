import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_PROJECT_INSTRUCTIONS, normalizeProjects, validateProjectInstructionsPath, validateProjectIntegrationHarnessPath } from '../lib/projects.mjs';

test('migrates existing projects to the mandatory default instructions file', () => {
  const settings = { schemaVersion: 10, projects: [{ id: 'one' }] };
  normalizeProjects(settings);
  assert.equal(settings.projects[0].instructions, DEFAULT_PROJECT_INSTRUCTIONS);
  assert.equal(settings.projects[0].integrationHarness, '');
});

test('keeps a safe optional PowerShell integration harness and clears unsafe paths', () => {
  const settings = { schemaVersion: 11, projects: [
    { id: 'safe', integrationHarness: 'tests/tools/terra-integration.ps1' },
    { id: 'escape', integrationHarness: '../secrets.ps1' },
    { id: 'wrong-type', integrationHarness: 'tests/run.cmd' }
  ] };
  normalizeProjects(settings);
  assert.equal(settings.projects[0].integrationHarness, 'tests/tools/terra-integration.ps1');
  assert.equal(settings.projects[1].integrationHarness, '');
  assert.equal(settings.projects[2].integrationHarness, '');
  assert.match(validateProjectIntegrationHarnessPath('C:\\tools\\run.ps1'), /relative/);
  assert.match(validateProjectIntegrationHarnessPath('tests/run.cmd'), /PowerShell/);
});

test('retains safe project-relative instructions paths and rejects escapes', () => {
  const settings = { projects: [{ id: 'one', instructions: 'docs/agent-rules.md' }, { id: 'two', instructions: '../outside.md' }] };
  normalizeProjects(settings);
  assert.equal(settings.projects[0].instructions, 'docs/agent-rules.md');
  assert.equal(settings.projects[1].instructions, DEFAULT_PROJECT_INSTRUCTIONS);
  assert.match(validateProjectInstructionsPath('C:\\temp\\rules.md'), /relative/);
  assert.match(validateProjectInstructionsPath('../rules.md'), /must not leave/);
});
