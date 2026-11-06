# Terra Runner 2.4

Terra Runner is a local Windows orchestrator for controlled OpenCode development. The central application manages projects, profiles, models, proxy routes and running workspaces; a development command can run in the main window or in a separate project terminal.

- A project has one active workspace, preventing concurrent edits to the same Git worktree.
- Different projects can run in parallel with independent logs, controls and OpenCode environments.
- Development always chooses a command, project, and run mode explicitly. Main-window runs enforce the profile limits; separate dispatcher instances deliberately do not read or enforce Terra budget/quota snapshots.
- Every cloud project receives an automatic private OpenCode credential store through `OPENCODE_DB`; no second login or model setup is required after selecting an existing profile.
- If Windows or a worker stops during a Terra iteration, the next Development launch automatically checkpoints and pushes that interrupted Terra work before continuing.
- Closing the dispatcher requests a graceful Stop for every project workspace. `Development → Active instances` exposes an explicit emergency Abort.

## Start

Double-click `Terra Runner.cmd`.

The primary interface is the Node.js terminal UI (Node.js 20+), which is required for the dispatcher. PowerShell 7 remains the execution engine. Setup and profile editing never start OpenCode.

Normal settings and state live in `%LOCALAPPDATA%\TerraRunner`. `-Portable` keeps them beside the installation instead. Project logs, reports, and control state are kept separately from disposable terminal-instance records.

## What the UI shows

The central header contains only global application information. Development explicitly selects a project and profile for each launch; Reports is an all-project read-only summary.

During a run, Terra Runner shows roadmap completion and percentage, the task selected by the worker, safe live activity (inspection, file changes, Git, or verification), elapsed time for the current iteration, tool/check counts, and a bounded live journal of completed iterations. The live header refreshes while the run is active with total run duration, the last completed task, and the last commit. It does not display model reasoning text. In dispatcher-instance mode, only the frozen project/profile context is shown: Terra snapshot, budget, and cost-estimate fields are deliberately omitted because they are not enforced there.

## Project instructions

Every project has a `PROJECT-INSTRUCTIONS.md` alongside its roadmap and progress files. It is mandatory for Development and contains the project's own environment, Docker/Compose, testing, debugging, and architecture guidance. **Projects** provides explicit actions to open instructions, the roadmap, or progress in Notepad. Development never opens an existing instructions file automatically. If instructions are missing, it offers to create the empty template and open it; restart Development after saving it. The file may be new or modified when Development starts, but it must be the only local Git change: the worker stages and commits that existing file in a separate documentation commit before task work. A later committed update is read by the next continuous iteration. Project instructions supplement, but cannot weaken, Terra Runner's global safety policy, and the development agent never edits them.

### Optional integration harness

A project can additionally configure one project-owned PowerShell harness (for example, `tests/tools/terra-integration.ps1`) in **Projects**. The path is always repository-relative and optional; projects without one continue to use normal unit/static work. When present, Development and Dry run verify that the file exists, but Terra never runs it by itself. The worker receives only the relative path and invokes it for database, migration, Redis, queue, repository, or persistence evidence with `pwsh -NoProfile -ExecutionPolicy Bypass -File <harness> -Suite <id>`.

The harness owns any local `.env` loading, Compose health checks, and disposable test schemas. It must never print secrets, expose them in arguments or logs, touch production/staging, or remove containers/volumes it did not create. A failed harness means the required evidence is absent; it cannot be replaced by a fake check.

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

The main menu is **Development**, **Projects**, **Models & accounts**, **Reports**, **System**, and **Exit**. In **Development**, choose **One iteration**, **Dry run**, **Continuous**, or **Active instances**. A development launch always follows command → project → profile → run mode → (continuous parameters) → confirmation. **System → Run diagnostics** checks configuration, project folders, PowerShell, Node.js, the OpenCode command, and—when a route is active—one isolated HTTPS CONNECT through its temporary loopback bridge. It never starts OpenCode or a development run.

`← Back` always returns one menu level: an instance list returns to Development, proxy/auth-storage pages return to System, profile selection returns to project selection, run-mode selection returns to profile selection, and a blank continuous-iteration field returns to run-mode selection. Selecting a completed, failed, stopped, aborted, or orphaned record in **Development → Active instances** first shows its final project report: result, tasks completed in that launch, iteration count, last task, duration, commit, and log location. Terminal records offer only safe removal, refresh, and Back; Stop, Abort, and stalled-instance finalization are shown only when an active instance can actually accept them. Removal deletes only the runtime record and stale control files, never a project repository, log, report, or active instance.

Choose **Development → One iteration** for one explicit agent run. **Main window** keeps live progress and the selected profile's normal safety limits. **Dispatcher instance** opens the project in a separate terminal immediately with the selected command snapshot; it retains project locks, isolated OpenCode storage and proxy scope, but intentionally has no Terra budget, quota, or reservation checks.

For **Run continuously**, choose the iteration limit at launch:

- `0` means continue until a normal safety stop, budget stop, roadmap completion, or user stop. A larger roadmap item may span several commits: a clean, pushed code or test change counts as verified implementation progress even before its checkbox is completed.
- `1`–`1000` limits only this run and is not saved in the profile.

A main-window run applies the selected profile's provider-snapshot and limit policy. If a required snapshot is missing or stale, the UI requests a current provider-reported value before starting. Dispatcher instances deliberately do not apply Terra snapshot, budget, quota, or reservation checks. A runner stops when it has repeatedly produced neither a completed roadmap item nor a clean, pushed code/test change. It also stops when every remaining technical path is explicitly blocked by an unavailable external dependency; Terra will not fake evidence for a live service, approval, or manual test.

The development agent may prepare already-installed local development infrastructure needed for verification: for example, start Docker Desktop, project-scoped Compose services, and wait for their readiness. It may not install or reconfigure system software, request elevation, change network/security settings, touch production, or stop/delete resources it did not start for the project.

Before every main-window run, including **Dry run**, a missing or stale provider snapshot is requested directly and the original command continues after it is saved. While a run is active, the terminal shows the selected project/profile context and live status under the run header; only controls are pinned to the bottom line:

- `S` or `Ctrl+C` requests a stop after the current iteration.
- `X` requests an emergency stop of the current iteration.

Starting a new UI run automatically clears stale stop requests left by a previous run.

### Interrupted-run recovery

Before OpenCode starts an iteration, Terra writes a local durable marker with the
project, branch and base commit. If the process or computer stops and leaves
that marker plus a dirty worktree, the next **One iteration** or **Continuous**
launch verifies the branch history, creates a `chore(terra): recover interrupted
run …` checkpoint commit, pushes it normally, then continues. The recovery is
shown in the live status and recorded below the project data directory.

Terra never performs this automatic commit without its matching marker. A dirty
worktree without one can be manual work, so it remains blocked for review.

### WIP checkpoints

When an iteration exits successfully without an OpenCode stream error but leaves useful uncommitted work in a worktree that was clean at the start, Terra validates the staged diff, runs the repository's normal Git hooks/secret scanning through a standard commit, and pushes `wip(terra): checkpoint <task-id> <run-id>`. This preserves partial implementation without ticking a roadmap checkbox; Continuous treats the pushed checkpoint as implementation progress and proceeds to the next iteration. Any failed diff check, hook, provider/error event, abort, or unavailable push stops with the precise reason and leaves the work for review. The interrupted-run marker remains the fallback for process/computer failure.

### Human actions and blocked task chains

Roadmaps may contain a versioned `## Human actions` section. A human action is
an external prerequisite, not a development task: it has a `HUM-####` ID,
does not change roadmap progress, and records why it is needed, the exact
action, required completion evidence, and the technical task IDs it blocks.
Workers may request one only with the strict `TERRA_HUMAN_TASK` JSON marker.
After a clean, verified worker result Terra records the action, adds
`Depends on: HUM-####` below each affected task, commits and pushes that
roadmap-only change. It continues independent work. If no eligible technical
task remains, it pauses before another model iteration and shows the exact
human action. Use **Development → Human actions** to inspect it and, after a
non-secret evidence note, mark it complete in a separate pushed commit.

## Safe CLI commands

All public commands use named parameters. OpenCode starts only with an explicit execution command.

```powershell
pwsh -File .\terra-runner.ps1 -Project my-project -ProfileId my-profile -Once
pwsh -File .\terra-runner.ps1 -Project my-project -ProfileId my-profile -Continuous
pwsh -File .\terra-runner.ps1 -Project my-project -ProfileId my-profile -DryRun
pwsh -File .\terra-runner.ps1 -Project my-project -ProfileId my-profile -Status
pwsh -File .\terra-runner.ps1 -Project my-project -Report
```

In schema v12, model execution and `-Status` require `-ProfileId`; `-Report`, proxy commands and controls do not. `-Status`, `-Report`, preflight, configuration actions, cancelled menus, and an invocation without an execution command never launch `opencode run`.

## Tests

```powershell
npm run test:node
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\TerraRunner.Regression.Tests.ps1"
```

The test suites use local mocks and temporary repositories. They make no paid OpenCode requests.

## Upgrade to 2.4

On first dispatcher start, configuration is migrated to schema v12. Existing
legacy model, account, reasoning and budget values are preserved in profiles;
global profile/account selections and project default profiles are removed. Each
project receives the default instructions path `PROJECT-INSTRUCTIONS.md`; the
file itself is not created by migration and must be created before
Development starts. Existing projects receive an empty optional
`integrationHarness` setting; migration never creates or runs a harness.
The first Development launch of a cloud profile creates that project's private
store and streams only that provider's current OpenCode credential into it.
It does not copy credentials during migration and does not require another
login or model selection. Terra never writes the export to configuration,
arguments, logs, or a temporary secret file. Reconnect the source profile in
Models & accounts only if that normal OpenCode credential has been removed.

Start Terra Runner once through the launcher. Existing configuration is migrated in place and legacy profile values are preserved. Review each cloud profile, set a fresh provider snapshot, and optionally enable the local OpenCode cost estimate for USD API snapshots. No project repository or OpenCode credential is modified by migration.

## Reference

- [Configuration reference](CONFIGURATION.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Architecture overview](ARCHITECTURE.md)
