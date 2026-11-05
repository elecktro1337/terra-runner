import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceTerminalLauncher } from '../lib/instance-launcher.mjs';

test('builds cmd start arguments without embedding quote characters in the window title', () => {
  const launcher = instanceTerminalLauncher({ comSpec: 'C:\\Windows\\System32\\cmd.exe', title: 'Terra ntd-terra', nodePath: 'C:\\Program Files\\nodejs\\node.exe', instancePath: 'C:\\work\\node-ui\\instance.mjs', configPath: 'C:\\Users\\name\\Terra Runner\\terra-config.json', instanceId: '11111111-1111-1111-1111-111111111111' });
  assert.equal(launcher.command, 'C:\\Windows\\System32\\cmd.exe');
  assert.deepEqual(launcher.args.slice(0, 7), ['/d', '/c', 'start', 'Terra ntd-terra', 'cmd.exe', '/d', '/c']);
  assert.equal(launcher.args.includes('/s'), false);
  assert.equal(launcher.env.FORCE_COLOR, '1');
  assert.equal(launcher.args[3].includes('"'), false);
  assert.deepEqual(launcher.args.slice(7), ['C:\\Program Files\\nodejs\\node.exe', 'C:\\work\\node-ui\\instance.mjs', '--config', 'C:\\Users\\name\\Terra Runner\\terra-config.json', '--instance', '11111111-1111-1111-1111-111111111111']);
});
