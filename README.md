# Terra Runner 1.6 (development)

Terra Runner is a local Windows orchestrator for controlled OpenCode development cycles. It runs one selected project at a time, verifies Git state, records usage, and keeps project logs separate.

## Start

Double-click `Terra Runner.cmd`. The primary interface uses Node.js 20+ for a cleaner terminal experience; PowerShell 7 remains the execution engine. If Node.js is unavailable, the launcher opens the compatible PowerShell interface. Setup only saves settings and never starts OpenCode.

For a normal installation, settings and state are stored in `%LOCALAPPDATA%\TerraRunner`. An existing configuration beside the scripts is copied there with a timestamped backup. The original configuration is not overwritten. Use `-Portable` to retain installation-folder storage.

## Repository hygiene

Personal configuration, portable-mode state, logs, reports, balance snapshots, locks, IDE metadata, and Pester output are excluded by `.gitignore`. Existing local runtime data is deliberately preserved when it is removed from Git tracking.

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

## Accounts and reasoning

Use **Settings → OpenCode accounts and reasoning** to refresh and select saved OpenCode accounts by their existing labels. API-key accounts use balance limits; OAuth accounts use a user-reported quota snapshot; local profiles show no balance or quota at all. Credentials remain in OpenCode — Terra Runner stores only non-secret IDs and labels. The same screen configures a supported model reasoning variant and optional OpenCode thinking-block display.

## Project isolation

## Model profiles

The Node.js UI treats the model, OpenCode credential, reasoning level and safety policy as one profile. It imports credentials through `opencode auth list --format json` and models through `opencode models`, including Ollama models.

- **API key** profiles use the existing daily and/or estimated-balance limits. The estimate is not provider billing.
- **OAuth** profiles show provider-managed usage. Terra Runner neither requests a manual quota snapshot nor invents a remaining allowance.
- **Local** profiles have no monetary or quota controls.

Credentials stay in OpenCode; Terra Runner stores only identifiers and labels. Choose reasoning by name, not by a numeric code.

Each project has a stable ID and its own logs, reports, control state, and stop files. The selected project path is always absolute and may contain spaces or Unicode characters. Terra Runner never derives it from its own installation path.

## Tests

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-ui-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-ui-navigation-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-ui-workflow-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-ui-setup-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\terra-selftest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\TerraRunner.Regression.Tests.ps1"
```

The tests use a local mock OpenCode and temporary repositories. They make no paid requests.

## Upgrade from 1.4

Start the UI once and accept the automatic local copy migration. Review the generated settings before running development. Existing legacy files remain in place; copy any historical project data deliberately if it is required for reporting.

## Reference

- [Configuration reference](CONFIGURATION.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Architecture overview](ARCHITECTURE.md)
