# Terra Runner 2.2

Terra Runner is a local Windows orchestrator for controlled OpenCode development. The central application manages projects, profiles, models, proxy routes and running workspaces; a development command can run in the main window or in a separate project terminal.

- A project has one active workspace, preventing concurrent edits to the same Git worktree.
- Different projects can run in parallel with independent logs, controls and OpenCode environments.
- Development always chooses a command, project, and run mode explicitly. Main-window runs enforce the profile limits; separate dispatcher instances deliberately do not read or enforce Terra budget/quota snapshots.
- Isolated OpenCode credential stores use `OPENCODE_DB`; the legacy shared store remains available only for safe single-cloud-workspace migration.
- Closing the dispatcher requests a graceful Stop for every project workspace. `Development → Active instances` exposes an explicit emergency Abort.

## Start

Double-click `Terra Runner.cmd`.

The primary interface is the Node.js terminal UI (Node.js 20+), which is required for the dispatcher. PowerShell 7 remains the execution engine. Setup and profile editing never start OpenCode.

Normal settings and state live in `%LOCALAPPDATA%\TerraRunner`. `-Portable` keeps them beside the installation instead. Existing configuration is migrated with a timestamped backup; project logs and historical state are preserved.

## What the UI shows

The central header contains only global profile and account information. A project is selected explicitly only from Development, where the selected project and its default profile are shown before confirmation. Reports is an all-project read-only summary.

During a run, Terra Runner shows the selected roadmap task, safe live activity (inspection, file changes, Git, or verification), elapsed time for the current iteration, tool/check counts, and a checkpoint after every completed iteration. It does not display model reasoning text.

## Profiles, snapshots, and limits

A profile combines an OpenCode account, model, reasoning level, and execution policy.

- **API** profiles can use a USD snapshot and API limit policies: hourly cap, daily cap, critical minimum, or unlimited.
- **OAuth** profiles can use a provider-reported percentage or other quota snapshot and a critical threshold or freshness policy.
- **Local** profiles have no monetary or quota controls.

Terra Runner never reads or stores API keys or OAuth tokens. It imports account labels through `opencode auth list --format json`, selects accounts through OpenCode, and imports models through `opencode models`.

A provider snapshot is a user-entered observation, not a live provider query. When a required snapshot is missing or stale, the UI asks for it directly before a main-window development run starts. Separate dispatcher instances deliberately do not inspect snapshots or Terra limits.

### Optional local OpenCode cost estimate

For an API profile with a USD snapshot, choose **Profiles → Configure local OpenCode cost estimate**. Terra Runner reads `opencode stats --all --json` once to set a baseline, then subtracts subsequently recorded local OpenCode cost from the provider-reported snapshot during later runs.

This is explicitly an estimate, not the provider's actual balance. It may include all usage recorded by the local OpenCode installation. Saving a new provider snapshot resets the estimate baseline; enable the option again to establish a new one.

## Running development

The main menu is **Development**, **Projects**, **Models & accounts**, **Reports**, **System**, and **Exit**. In **Development**, choose **One iteration**, **Dry run**, **Continuous**, **Active instances**, or **Proxy test**. A development launch always follows command → project → run mode → (continuous parameters) → confirmation.

Choose **Development → One iteration** for one explicit agent run. **Main window** keeps live progress and the selected profile's normal safety limits. **Dispatcher instance** opens the project in a separate terminal immediately with the selected command snapshot; it retains project locks, isolated OpenCode storage and proxy scope, but intentionally has no Terra budget, quota, or reservation checks.

For **Run continuously**, choose the iteration limit at launch:

- `0` means continue until a normal safety stop, budget stop, roadmap completion, or user stop.
- `1`–`1000` limits only this run and is not saved in the profile.

The continuous launch also asks whether to use the provider snapshot guard. It is on by default. Disabling it is a temporary, clearly labelled override for that run; it bypasses provider snapshot freshness and threshold checks only. Other runner safety checks remain active.

Before every main-window run, including **Dry run**, a missing or stale provider snapshot is requested directly and the original command continues after it is saved. While a run is active, the terminal keeps its status and controls in a fixed two-line footer:

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

## Upgrade to 2.2

On first dispatcher start, configuration is migrated to schema v8. Existing
profiles are attached to a `Legacy shared OpenCode` storage and selected as the
default profile for existing projects. The obsolete global selected-project value
is removed. Create an isolated authentication storage,
sign in through the dispatcher, then assign it to each cloud profile before
running multiple cloud projects in parallel.

Start Terra Runner once through the launcher. Existing configuration is migrated in place and legacy profile values are preserved. Review each cloud profile, set a fresh provider snapshot, and optionally enable the local OpenCode cost estimate for USD API snapshots. No project repository or OpenCode credential is modified by migration.

## Reference

- [Configuration reference](CONFIGURATION.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Architecture overview](ARCHITECTURE.md)
