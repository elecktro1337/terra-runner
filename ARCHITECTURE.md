# Architecture overview

`terra-ui.ps1` is the interactive configuration and navigation layer. It sends only named command parameters to `terra-runner.ps1`.

`terra-runner.ps1` validates configuration, Git state, budgets, locks, project controls, logging, and reports. It starts a separate `terra-worker.ps1` process only for explicit `-Once` or `-Continuous` commands.

`terra-worker.ps1` runs OpenCode in the selected project directory and preserves raw events. `terra-core.psm1` provides decimal money parsing and configuration-location helpers.

Application configuration/state lives independently from the installation. Project data is separated by stable project ID. Balance snapshots are stored outside rotating iteration logs.
