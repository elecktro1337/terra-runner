# Changelog

## 2.3.0 - 2026-11-05

- Removed global active profile/account state and project default profiles; every Development launch now explicitly selects a profile.
- Made schema v9 execution and status CLI require `-ProfileId`, while non-execution commands remain profile-free.
- Removed profile-specific header fields and simplified profile management to editing only.
- Stabilized the main-window Development display: the selected profile context appears during a run, live status stays below it, and only controls are pinned to the terminal bottom.

## 2.2.0 - 2026-11-05

- Removed the hidden global selected project; Development now owns project selection and Reports shows all projects.
- Made stale/missing provider snapshot prompts consistent for main-window dry runs.
- Moved proxy testing to Development and made System diagnostics global.
- Replaced the scrolling live control hint with a fixed status/control terminal footer.

## 2.1.0 - 2026-11-05

- Restored one unified Development flow: command, project, then main-window or dispatcher-instance mode.
- Added automatic command handoff to separate project terminals and moved instance controls to Development.
- Disabled Terra budget, quota, snapshot and reservation controls for dispatcher instances; main-window runs retain them.
- Removed the parallel reservation ledger and compacted instance snapshots.

## 2.0.0 - 2026-11-05

- Added the central dispatcher, separate project terminals and the instances dashboard.
- Added profile-scoped OpenCode authentication stores, immutable launch snapshots and addressable instance controls.
- Replaced the long-held global runner lock with a project-worktree lock and parallel reservation ledger.

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
