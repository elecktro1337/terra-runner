# Troubleshooting

## Development did not start

The Node UI displays a short reason and next step instead of a PowerShell stack trace.

- **Uncommitted or untracked files**: commit, stash, or remove the project changes. Automated development starts only from a clean working tree.
- **Wrong Git branch**: switch to the branch configured for the selected project.
- **Local and remote branch heads differ**: review the branch and complete the normal non-force push or pull.
- **OpenCode was not found**: install OpenCode 2.x or correct its command path.
- **Snapshot missing or stale**: start the run again and enter a current provider observation when prompted.

Use **Development → Project preflight** to check the project path, branch, roadmap, progress file, OpenCode command, provider snapshot, and working-tree cleanliness without launching an agent.

## A previous stop blocks a new run

The UI clears old `STOP` and `ABORT` control files when the user explicitly starts a new run. If you use the PowerShell CLI directly, run `-ClearStop` after reviewing the prior run.

## S or Ctrl+C does not exit immediately

`S` and `Ctrl+C` request a graceful stop: the active iteration keeps running and Terra Runner exits before the next iteration. Use `X` only when the active iteration must be terminated at the next runner poll.

## Provider snapshot and cost estimate

A snapshot is not a live provider balance or quota API. Refresh it with a provider-reported value when required. The optional OpenCode cost estimate is local accounting and can differ from provider billing, especially when the local OpenCode installation is shared by multiple projects.

## OpenCode is not found

Install OpenCode 2.x, ensure `opencode` is available on `PATH`, then run preflight. Terra Runner requires OpenCode support for `run --agent --format json --auto`; local cost estimation additionally requires `stats --all --json`.

## Terminal display or hotkeys look wrong

Use Windows Terminal or a current PhpStorm terminal with Node.js 20+ and PowerShell 7. The Node UI uses ANSI rendering where supported. If terminal input does not support raw key handling, use the runner control commands instead.

## Configuration is invalid

Do not overwrite the active file. Keep a copy for diagnosis, correct the JSON or restore a known-good configuration copy, then start the dispatcher again.
