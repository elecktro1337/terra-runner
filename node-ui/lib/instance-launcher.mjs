export function instanceTerminalLauncher({ comSpec = 'cmd.exe', title, nodePath, instancePath, configPath, instanceId }) {
  return {
    command: comSpec,
    args: ['/d', '/c', 'start', String(title), 'cmd.exe', '/d', '/c', String(nodePath), String(instancePath), '--config', String(configPath), '--instance', String(instanceId)],
    env: { FORCE_COLOR: '1' }
  };
}
