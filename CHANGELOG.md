# Terra Runner — changelog

## 1.4 — Interactive console

- `Terra Runner.cmd`: double-click launcher. Opens a console using PowerShell 7 without permanently changing execution policy.
- `terra-ui.ps1`: Russian-language interactive main menu, per-project selection/addition/editing, budget mode editor, balance snapshot/reconciliation, model and execution settings, log retention settings, status, report, stop/abort and clear-stop actions.
- Safe config writes: backup before save, validation and replacement of `terra-config.json` while preserving unknown keys.
- Interactive progress indicators: roadmap completion meter in the menu; optional per-iteration and overall PowerShell progress bars (`-ShowProgress`) and budget meter (`-ShowProgress`).
- Existing headless CLI commands and the v1.3 configuration schema remain supported.
- Menu shortcut T for both isolated offline self-tests. New offline UI self-test: `tests/terra-ui-selftest.ps1`.
- WARNING: the launcher uses `-ExecutionPolicy Bypass` only for its spawned PowerShell 7 process. Inspect trusted local files before running; system policy is not modified.

## 1.3 — Budget modes, structured logs and reporting

- Budget modes: `daily`, `balance`, `hybrid`, `unlimited`.
- Balance source may be a manually reconciled snapshot or an external command returning a fresh verified JSON observation.
- Project-scoped logs, readable UTF-8 event copies, tool-error detection, reports and progress checks.
- Global local OpenCode usage tracking with fail-closed parsing.
