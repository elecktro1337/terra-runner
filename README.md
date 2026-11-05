# Terra Runner 1.6

Terra Runner is a local Windows orchestrator for controlled OpenCode development. It runs one selected project at a time, checks Git and safety rules, records project-scoped evidence, and keeps OpenCode execution explicit.

## Start

Double-click `Terra Runner.cmd`.

The primary interface is the Node.js terminal UI (Node.js 20+). PowerShell 7 remains the execution engine. If Node.js is unavailable, the launcher opens the compatible PowerShell UI. Setup and profile editing never start OpenCode.

Normal settings and state live in `%LOCALAPPDATA%\TerraRunner`. `-Portable` keeps them beside the installation instead. Existing configuration is migrated with a timestamped backup; project logs and historical state are preserved.

## What the UI shows

The header identifies the selected project, branch, account type, model, reasoning level, provider snapshot, limits, and roadmap progress:

- total, completed, and remaining roadmap tasks;
- completed percentage;
- API cost-estimate status when enabled.

During a run, Terra Runner shows the selected roadmap task, safe live activity (inspection, file changes, Git, or verification), elapsed time for the current iteration, tool/check counts, and a checkpoint after every completed iteration. It does not display model reasoning text.

## Profiles, snapshots, and limits

A profile combines an OpenCode account, model, reasoning level, and execution policy.

- **API** profiles can use a USD snapshot and API limit policies: hourly cap, daily cap, critical minimum, or unlimited.
- **OAuth** profiles can use a provider-reported percentage or other quota snapshot and a critical threshold or freshness policy.
- **Local** profiles have no monetary or quota controls.

Terra Runner never reads or stores API keys or OAuth tokens. It imports account labels through `opencode auth list --format json`, selects accounts through OpenCode, and imports models through `opencode models`.

A provider snapshot is a user-entered observation, not a live provider query. When a required snapshot is missing or stale, the UI asks for it directly before development starts.

### Optional local OpenCode cost estimate

For an API profile with a USD snapshot, choose **Profiles → Configure local OpenCode cost estimate**. Terra Runner reads `opencode stats --all --json` once to set a baseline, then subtracts subsequently recorded local OpenCode cost from the provider-reported snapshot during later runs.

This is explicitly an estimate, not the provider's actual balance. It may include all usage recorded by the local OpenCode installation. Saving a new provider snapshot resets the estimate baseline; enable the option again to establish a new one.

## Running development

Choose **Development → Run one iteration** for one explicit agent run.

For **Run continuously**, choose the iteration limit at launch:

- `0` means continue until a normal safety stop, budget stop, roadmap completion, or user stop.
- `1`–`1000` limits only this run and is not saved in the profile.

The continuous launch also asks whether to use the provider snapshot guard. It is on by default. Disabling it is a temporary, clearly labelled override for that run; it bypasses provider snapshot freshness and threshold checks only. Other runner safety checks remain active.

While a run is active:

- `S` or `Ctrl+C` requests a stop after the current iteration.
- `X` requests an emergency stop of the current iteration.

Starting a new UI run automatically clears stale stop requests left by a previous run.

## Safe CLI commands

All public commands use named parameters. OpenCode starts only with an explicit execution command.

```powershell
pwsh -File .\terra-runner.ps1 -Project my-project -Once
pwsh -File .\terra-runner.ps1 -Project my-project -Continuous
pwsh -File .\terra-runner.ps1 -Project my-project -DryRun
pwsh -File .\terra-runner.ps1 -Project my-project -Status
pwsh -File .\terra-runner.ps1 -Project my-project -Report
```

`-Status`, `-Report`, preflight, configuration actions, cancelled menus, and an invocation without an execution command never launch `opencode run`.

## Tests

```powershell
npm run test:node
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\TerraRunner.Regression.Tests.ps1"
```

The test suites use local mocks and temporary repositories. They make no paid OpenCode requests.

## Upgrade to 1.6

Start Terra Runner once through the launcher. Existing configuration is migrated in place and legacy profile values are preserved. Review each cloud profile, set a fresh provider snapshot, and optionally enable the local OpenCode cost estimate for USD API snapshots. No project repository or OpenCode credential is modified by migration.

## Reference

- [Configuration reference](CONFIGURATION.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Architecture overview](ARCHITECTURE.md)
