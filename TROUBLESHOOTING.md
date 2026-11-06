# Troubleshooting

## Development did not start

The Node UI displays a short reason and next step instead of a PowerShell stack trace.

- **Uncommitted or untracked files**: commit, stash, or remove the project changes. Automated development starts only from a clean working tree, except for `PROJECT-INSTRUCTIONS.md` when it is the sole local change: the worker commits that unchanged file before task work.
- **Wrong Git branch**: switch to the branch configured for the selected project.
- **Local and remote branch heads differ**: review the branch and complete the normal non-force push or pull.
- **OpenCode was not found**: install OpenCode 2.x or correct its command path.
- **Snapshot missing or stale**: start the run again and enter a current provider observation when prompted.
- **Project authentication storage could not be prepared**: reconnect the selected profile through normal OpenCode authentication, then launch again. Terra will recreate the private project store automatically; do not copy tokens or database files by hand.
- **Project instructions file is required**: use **Projects → Open project instructions**. Terra can create its empty template when missing. Save it and start Development again; an existing instructions file is not opened automatically when a run starts.
- **Configured integration harness was not found**: correct or clear the optional PowerShell path in **Projects**. Do not substitute an `.env` command or put a password into Terra settings.
- **Uncommitted or untracked files after a crash**: start One iteration or Continuous normally. If they belong to an interrupted Terra run, its matching recovery marker causes Terra to checkpoint and non-force push them automatically. If no matching marker exists, the files may be manual work; review and resolve them yourself.

Use **Development → Dry run** to check the project path, branch, roadmap, progress file, instructions, OpenCode command, provider snapshot, and working-tree cleanliness without launching an agent.

## A WIP checkpoint stopped the run

Terra only creates a WIP checkpoint after a worker exits normally without a stream error and leaves a previously clean worktree dirty. The checkpoint runs the repository's normal commit hooks and does not mark a roadmap checkbox complete. If its diff check, hook, or push fails, inspect the reported reason and existing local work; Terra does not delete it. After the checkpoint is pushed, Continuous can safely use it as implementation progress on the next iteration.

## A previous stop blocks a new run

The UI clears old `STOP` and `ABORT` control files when the user explicitly starts a new run. If you use the PowerShell CLI directly, run `-ClearStop` after reviewing the prior run.

## S or Ctrl+C does not exit immediately

`S` and `Ctrl+C` request a graceful stop: the active iteration keeps running and Terra Runner exits before the next iteration. Use `X` only when the active iteration must be terminated at the next runner poll.

## Provider snapshot and cost estimate

A snapshot is not a live provider balance or quota API. Refresh it with a provider-reported value when required. The optional OpenCode cost estimate is local accounting and can differ from provider billing, especially when the local OpenCode installation is shared by multiple projects.

## OpenCode is not found

Install OpenCode 2.x, ensure `opencode` is available on `PATH`, then run preflight. Terra Runner requires OpenCode support for `run --agent --format json --auto`; local cost estimation additionally requires `stats --all --json`.

## Proxy diagnostic fails

**System → Run diagnostics** starts a temporary loopback-only bridge and makes
one HTTPS CONNECT request. The diagnostics screen displays a concise, redacted
reason; it does not show the PowerShell line number, proxy password, URL user
info, or authorization headers. `HTTP/1.1 200 Connection Established` followed
by a curl timeout means the upstream proxy accepted the tunnel but the target
request did not finish in time. Check the proxy host's outbound network/TLS
path, route policy, and any configured CA file; do not put credentials into
the Terra settings error report.

## Terminal display or hotkeys look wrong

Use Windows Terminal or a current PhpStorm terminal with Node.js 20+ and PowerShell 7. The Node UI uses ANSI rendering where supported. If terminal input does not support raw key handling, use the runner control commands instead.

## A dispatcher instance seems to have ended

Open **Development → Active instances** and select the terminal record. Terra shows the same result report as the project window, including the reason, tasks completed during that launch, iteration count, last task, duration, commit, and log location. A terminal record no longer has a runner process, so it deliberately offers only removal, refresh, and Back. Stop, Abort, and stalled finalization are reserved for actionable active records.

The list displays eight records per page. For an active run, press **Refresh**
to recalculate the current iteration's elapsed time from its saved start time;
older records without that timestamp continue from their most recent
heartbeat.

## Configuration is invalid

Do not overwrite the active file. Keep a copy for diagnosis, correct the JSON or restore a known-good configuration copy, then start the dispatcher again.
