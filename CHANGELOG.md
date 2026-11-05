# Changelog

## 1.6.0 - 2026-11-05

### Terminal UI and profiles

- Added the Node.js 20+ primary terminal UI with PowerShell fallback.
- Added profile-based account, model, reasoning, and policy management.
- Added OpenCode account/model discovery through the local CLI without storing credentials.
- Added local, API, and OAuth profile types with user-reported provider snapshots.
- Added per-launch continuous iteration limits and an explicit temporary provider snapshot-guard override.

### Execution and observability

- Added structured runner-to-UI telemetry, live safe activity indicators, current-iteration timing, per-iteration checkpoints, roadmap progress, and aggregate run summaries.
- Added task-ID detection for projects without an explicit `taskIdPattern`.
- Added `S`/`Ctrl+C` graceful stop and `X` emergency-stop hotkeys.
- Added automatic clearing of stale `STOP` and `ABORT` flags when a new UI run is explicitly started.
- Replaced raw startup exception output with guided failure cards and expanded preflight with a clean-working-tree check.

### Snapshot and cost accounting

- Added a direct pre-run provider-snapshot prompt for missing or stale cloud snapshots.
- Added optional local OpenCode cost estimation for USD API snapshots, with an explicit baseline and estimate-only labelling.
- Fixed UTC parsing of provider snapshot timestamps and restored threshold enforcement for snapshot profiles.

### Documentation and tests

- Updated the user guide, configuration reference, troubleshooting guide, and architecture overview for v1.6.
- Added Node regression coverage for profile snapshot/cost-estimate behaviour.

## 1.5.0 - 2026-11-03

- Added safe named-parameter CLI dispatch and read-only regression coverage with a call-recording OpenCode mock.
- Added invariant decimal money parsing, local application state, project isolation, configuration migration, and first-run setup.
- Added English UI/documentation baseline, logs, reports, Git verification, and controlled continuous iteration support.

## 1.4.0

Previous release. See repository history for original release notes.
