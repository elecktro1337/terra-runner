# Changelog

## 1.5.0 - 2026-11-03

- Fixed unsafe UI-to-runner argument forwarding. Commands are dispatched with named parameters and positional binding is disabled at public boundaries.
- Made agent execution opt-in: only `-Once` and `-Continuous` may start OpenCode.
- Added invariant decimal parsing for user-entered money; both decimal separators are accepted and balances use two fractional digits.
- Added regression coverage with a call-recording OpenCode mock for read-only commands.
- Added `%LOCALAPPDATA%\TerraRunner` configuration storage, legacy copy migration, portable mode, and a first-run configuration wizard.
- Added configuration schema version 3 and resolved relative log paths against the active configuration file.
- Started the English localization: user documentation and agent prompt are now English.

## 1.4.0

Previous release. See repository history for the original release notes.
