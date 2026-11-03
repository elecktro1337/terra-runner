# Troubleshooting

## OpenCode is not found

Install OpenCode 2.x, ensure `opencode` is on `PATH`, then use **Validate project**. Terra Runner requires `run --agent --format json --auto` and `stats --json`.

## Configuration is invalid

Start the UI. It offers the newest valid backup. Declining recovery leaves all files unchanged; review `config-backups` and the timestamped `.corrupt-*` copy.

## Runner says another instance holds the lock

Only one runner may use shared OpenCode accounting at a time. Wait for the active run to finish, then inspect the selected project's logs. Do not delete an active lock file.

## Budget stops development

Daily and balance modes fail closed when usage cannot be verified. Check the displayed reason, reconcile a real provider balance when appropriate, and remember that local usage is an estimate rather than a provider balance.

## Terminal display

Use PowerShell 7. Windows Terminal offers the best ANSI rendering; the UI falls back to standard console output when advanced styling is unavailable.
