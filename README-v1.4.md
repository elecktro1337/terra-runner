# Terra Runner 1.4 legacy notes

This file documents the v1.4 generation for users upgrading an existing installation. The current product documentation is [README.md](README.md).

## Upgrade safely

1. Stop any running Terra Runner process.
2. Back up the existing Terra Runner directory before replacing program files.
3. Start `Terra Runner.cmd` once after upgrading.
4. When prompted, allow the application to copy the legacy configuration to `%LOCALAPPDATA%\\TerraRunner`. The original configuration remains untouched.
5. Review the selected project and settings. Run **Dry run** before starting a real iteration.

Terra Runner 1.5 does not require user projects to be beside the installation directory. Each selected project is stored with an absolute path and a stable project ID.

## Data retained from v1.4

- Existing configuration fields are retained during migration whenever they are still supported.
- Existing prompt templates are preserved.
- Logs, reports, and balance snapshots are not deleted by the migration.
- Project data remains separated by project ID.

## Important differences in 1.5

- Informational commands never start OpenCode. Only explicit **Run one iteration** or **Start continuous development** actions may do so.
- Money input accepts either `96.11` or `96,11`, and balance values are displayed with two decimal places.
- The UI, reports, and current documentation are English.
- Project logs and reports are isolated from the application installation directory by default.

For configuration details, see [CONFIGURATION.md](CONFIGURATION.md). For problems during startup or migration, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
