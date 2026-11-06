import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PROJECT_BOOTSTRAP_MENU_VALUE, PROJECT_BOOTSTRAP_PROMPT_FILE, projectMenuChoices } from '../lib/project-bootstrap.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('ships a complete project bootstrap prompt with the Terra documentation contract', async () => {
  const text = await fs.readFile(path.join(root, PROJECT_BOOTSTRAP_PROMPT_FILE), 'utf8');
  for (const required of ['PREFIX-ROADMAP.md', 'PREFIX-PROGRESS.md', 'PROJECT-INSTRUCTIONS.md', 'Запрос пользователя', 'fenced Markdown-блока', '## A. Продукт, границы и термины', '## B. Архитектурные решения и инварианты', '## C. Матрица модулей', '## D. Definition of Done', '## E. Поэтапный TODO', '## Entry template']) assert.match(text, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('exposes the global bootstrap prompt before project-specific choices', () => {
  const choices = projectMenuChoices([{ id: 'ntd-terra' }, { id: 'erranix-erp' }]);
  assert.deepEqual(choices.map(choice => choice.value), [PROJECT_BOOTSTRAP_MENU_VALUE, 'project:ntd-terra', 'project:erranix-erp', 'add']);
  assert.equal(choices[0].name, 'Open default project bootstrap prompt');
});

test('wires the bootstrap prompt into the Projects root menu', async () => {
  const ui = await fs.readFile(path.join(root, 'node-ui', 'index.mjs'), 'utf8');
  assert.match(ui, /projectMenuChoices\(projects\)/);
  assert.match(ui, /action === PROJECT_BOOTSTRAP_MENU_VALUE/);
  assert.match(ui, /openProjectBootstrapPrompt/);
});
