# Terra Runner 1.5

Terra Runner is a local Windows orchestrator for controlled OpenCode development cycles. It runs one selected project at a time, verifies Git state, records usage, and keeps project logs separate.

## Start

Double-click `Terra Runner.cmd`. PowerShell 7 is required. On first launch, Terra Runner opens Setup Wizard; setup only saves settings and never starts OpenCode.

For a normal installation, settings and state are stored in `%LOCALAPPDATA%\TerraRunner`. An existing configuration beside the scripts is copied there with a timestamped backup. The original configuration is not overwritten. Use `-Portable` to retain installation-folder storage.

## Safe commands

All commands use named parameters; positional parameters are rejected. OpenCode starts only with an explicit command:

```powershell
pwsh -File .\terra-runner.ps1 -Project my-project -Once
pwsh -File .\terra-runner.ps1 -Project my-project -Continuous
pwsh -File .\terra-runner.ps1 -Project my-project -DryRun
pwsh -File .\terra-runner.ps1 -Project my-project -Status
pwsh -File .\terra-runner.ps1 -Project my-project -Report
```

`-Status`, `-Report`, configuration actions, cancelled menus, and an invocation without an execution command never launch `opencode run`.

## Money and budgets

User-entered money accepts `96.11` or `96,11`, is parsed with invariant decimal arithmetic, and is displayed as `$96.11`. Amounts with both separators, exponent notation, whitespace, negative values, NaN, Infinity, and overflow are rejected.

OpenCode usage is not a provider balance. A snapshot balance is an estimate: recorded balance minus the change in local all-time OpenCode usage. Limited modes fail closed when required usage information is unavailable.

## Project isolation

Each project has a stable ID and its own logs, reports, control state, and stop files. The selected project path is always absolute and may contain spaces or Unicode characters. Terra Runner never derives it from its own installation path.

## Tests

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-ui-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-selftest.ps1
Invoke-Pester .\tests\TerraRunner.Regression.Tests.ps1
```

The tests use a local mock OpenCode and temporary repositories. They make no paid requests.

## Upgrade from 1.4

Start the UI once and accept the automatic local copy migration. Review the generated settings before running development. Existing legacy files remain in place; copy any historical project data deliberately if it is required for reporting.
