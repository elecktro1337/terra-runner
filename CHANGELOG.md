# Changelog

## Unreleased

- Raised configuration to schema v12 and added an optional, repository-relative project integration harness. Workers receive only the harness path and the standard suite command; the harness owns local secrets and Compose lifecycle.
- Added immediate WIP checkpoints for successful, clean partial work. Terra validates the staged diff, uses normal Git hooks, pushes `wip(terra): checkpoint …`, keeps roadmap checkboxes unchanged, and lets Continuous continue from that implementation progress.
- Tightened worker task markers: only a complete ID that exists as a roadmap checkbox can be displayed.
- Made current dispatcher-iteration durations derive from a persisted start timestamp; legacy records advance from their latest heartbeat when refreshed.
- Paginated **Development → Active instances** in groups of eight, with explicit next/previous navigation and safe page clamping after cleanup.
- Made proxy diagnostics extract a redacted, readable CONNECT failure reason instead of displaying a truncated PowerShell source-location trace.
- Kept live iteration activity and retry/checkpoint details on one compact status row while retaining a separate graceful-stop notice.
- Expanded `PROJECT-BOOTSTRAP-PROMPT.md` into a detailed English-only, evidence-first template and **Projects → Open default project bootstrap prompt**. It guides any model to inspect a repository and return downloadable (or complete fenced) roadmap, progress, and instructions Markdown files in the NTD/ERP-compatible contract.

- Terminal instance reports now show local MSK start and end times. New records persist an immutable end timestamp; legacy records fall back to their final update timestamp. Coordinator-watchdog stops retain their specific heartbeat cause instead of being indistinguishable from a manual stop.
- Continuous runs now retry a narrowly classified transient provider interruption (including `provider.invalid-output` / “response ended unexpectedly”) up to three times with bounded exponential backoff. A retry requires a clean, published Git state; One iteration and all other error classes continue to stop safely.
- Refresh the live Development header every second and after every iteration with roadmap counts, run duration, last task, and last commit; fixed dispatcher instances calculating the duration from a persisted ISO timestamp.
- Close the dispatcher terminal window when its project-instance Node process exits instead of leaving a `cmd` prompt behind.
- Live Development now waits for an explicit worker task-selection marker instead of labelling every iteration with the first unchecked roadmap item.
- Permit a new or edited project-instructions file as the sole local Git change; the worker commits that unchanged file separately before task work.
- Fixed project-instance results: the roadmap is shown once, and the result now includes completed tasks and iteration count for the current launch.
- Temporary OpenCode and Git TLS/network failures now keep the instance waiting for reconnection instead of ending the development run; Stop and Abort remain available during the wait.
- Completed instance records now show the same final report as their project window in **Development → Active instances**. Terminal records no longer display disabled Stop, Abort, or stalled-finalization actions.
- Fixed Development opening existing project instructions on every launch. **Projects** now has explicit actions to open instructions, roadmap, and progress files.
- Iteration history now pairs a completed or worker-selected task ID with that task's own roadmap title, instead of reusing the first unchecked item's title when an external blocker caused a later task to be selected.
- The selected task now appears in the compact live iteration status itself; the UI no longer reserves a separate `Task:` row during normal execution.
- A completed project-instance window now hides Stop and Abort controls and preserves its terminal result when the window is closed.

## 2.4.0 - 2026-11-05

- Added mandatory per-project `PROJECT-INSTRUCTIONS.md` files with safe paths, explicit UI creation/opening, and per-iteration worker prompt composition. A new, staged, or modified instructions file is accepted when it is the sole local change and is committed unchanged before task work.

## 2.3.6 - 2026-11-05

- Formatted active-instance heartbeat durations as minutes and seconds instead of raw seconds.
- Forced UTF-8 for PowerShell UI-event pipes so non-ASCII roadmap task titles remain readable in Node live screens.

## 2.3.5 - 2026-11-05

- Granted the development agent a bounded local-infrastructure capability: it can start and await already-installed local development dependencies such as Docker Desktop and project-scoped Compose services, while remaining prohibited from installation, elevation, system/network reconfiguration, production access, and destructive cleanup outside resources it started.

## 2.3.4 - 2026-11-05

- Continuous development now treats clean, pushed code or test changes as verified progress even before a larger roadmap checkbox is completed; it no longer stops after useful multi-commit implementation work.
- Strengthened task selection so an external block on the first unchecked item cannot produce `NO_ACTIONABLE_TASKS` before OpenCode has searched every independent technical path.

## 2.3.3 - 2026-11-05

- Moved the active-route HTTPS CONNECT check from Development into System diagnostics, alongside configuration, project-folder, PowerShell, Node.js, and OpenCode checks; diagnostics never start a model.
- Fixed PowerShell proxy-route validation attempting to assign to the read-only automatic `$Host` variable.

## 2.3.2 - 2026-11-05

- Added durable interrupted-run recovery markers and automatic non-force recovery commits for matching Terra-owned dirty worktrees.
- Recovery verifies project, branch and Git ancestry, validates the staged diff, pushes the checkpoint, records its commit, and never auto-commits a dirty worktree without a valid Terra marker.
- Added live recovery status plus offline regression coverage for marker-based checkpoint and push recovery.

## 2.3.1 - 2026-11-05

- Raised configuration to schema v10 and added lazy project-managed OpenCode stores for cloud Development launches.
- Automatically synchronizes only the selected provider from a profile source into its project store with a streaming OpenCode export/import pipeline; credentials never enter Terra configuration, logs, command arguments, or temporary secret files.
- Uses the effective project store for both main-window runs and frozen dispatcher instances, allowing concurrent projects to use one source account without the legacy shared-store block.
- Made managed stores diagnostic read-only in System and remove a project's managed DB and bootstrap lock when its inactive configuration is deleted.
- Added Node and PowerShell regression coverage for v10 migration, streaming bootstrap isolation, store cleanup, and runner store validation.

## 2.3.0 - 2026-11-05

- Removed global active profile/account state and project default profiles; every Development launch now explicitly selects a profile.
- Made schema v9 execution and status CLI require `-ProfileId`, while non-execution commands remain profile-free.
- Removed profile-specific header fields and simplified profile management to editing only.
- Stabilized the main-window Development display: the selected profile context appears during a run, live status stays below it, and only controls are pinned to the terminal bottom.
- Fixed dispatcher-instance terminal launch quoting, terminal Stop/Abort states, stale-instance finalization, and the shared header in Development/System screens.
- Made Back navigation return to the immediate parent menu, retained a bounded live journal of completed continuous iterations, compacted and colorized active-run context, and hid non-enforced Terra limit/snapshot fields in dispatcher instances.
- Added safe removal of terminal instance records and retired the unused PowerShell TUI and its legacy UI self-tests.

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
