import test from 'node:test';
import assert from 'node:assert/strict';
import { humanActionCounts, humanActionDependencies, parseHumanActions } from '../lib/human-actions.mjs';

const roadmap = `- [ ] NTD-0100 technical task
  - Depends on: HUM-0001, HUM-0002

## Human actions

- [ ] **HUM-0001 [human]** — Publish approved DNS records.
  - Why: Repository cannot change DNS.
  - Do: Publish the approved SPF record.
  - Completion evidence: DNS provider confirmation.
  - Blocks: NTD-0100
- [x] **HUM-0002 [human]** — Approve policy.
  - Why: Approval is external.
  - Do: Record approval.
  - Completion evidence: Signed decision.
  - Blocks: NTD-0100`;

test('parses human actions and their visible detail', () => {
  const actions = parseHumanActions(roadmap);
  assert.equal(actions.length, 2);
  assert.deepEqual(humanActionCounts(roadmap), { open: 1, completed: 1, total: 2 });
  assert.deepEqual(actions[0].blocks, ['NTD-0100']);
  assert.equal(actions[0].completionEvidence, 'DNS provider confirmation.');
});

test('reads multiple human dependencies under a technical task', () => {
  assert.deepEqual(humanActionDependencies(roadmap, 'NTD-0100'), ['HUM-0001', 'HUM-0002']);
});
