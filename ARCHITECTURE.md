# Terra Runner 2.2 architecture

## Dispatcher and project workspaces

`node-ui/index.mjs` is the central dispatcher. It owns a heartbeat and a
non-secret runtime registry beside `terra-config.json`. It has no global active
project: Development first selects a command, then a project and a run mode. Main-window mode invokes the
runner directly; dispatcher-instance mode writes an immutable command snapshot
and starts `node-ui/instance.mjs` in a separate terminal.

An instance uses its frozen profile, proxy route and OpenCode authentication
store. Isolated stores are set through `OPENCODE_DB`; workers use
`opencode run --standalone`, leaving Windows settings and OpenCode's shared
service unchanged. A project-scoped runner lock protects a Git worktree while
allowing different projects to run concurrently. Budget/quota state is used
only by main-window runs; dispatcher instances record untracked usage and do
not reserve or inspect provider limits.

Terra Runner separates presentation, execution, and persistent project evidence.

## Components

- `Terra Runner.cmd` selects the Node.js UI when Node.js 20+ is available and falls back to PowerShell UI otherwise.
- `node-ui/index.mjs` is the primary terminal UI. It manages projects and profiles, gathers safe OpenCode inventory, renders run telemetry, and starts PowerShell with named parameters.
- `node-ui/lib/profiles.mjs` normalises and applies non-secret profile settings.
- `node-ui/lib/reports.mjs` reads isolated project summaries and reports.
- `terra-runner.ps1` is the safety and orchestration engine. It validates Git, controls budgets and snapshots, writes summaries/reports, and manages stop files.
- `terra-worker.ps1` starts one non-interactive OpenCode session in the selected project and preserves the original JSONL event stream.
- `terra-core.psm1` provides configuration-location and invariant money helpers.

## Run flow

1. Node UI selects the project's default profile and command snapshot. In main-window mode it validates the required provider snapshot for one iteration, continuous runs and dry runs.
2. Node UI invokes `terra-runner.ps1` with the explicit project and profile parameters; it does not change the global selected profile.
3. The runner validates the project, Git branch, clean working tree, remote state and control flags. It validates limits only for main-window runs.
4. The runner emits compact `__TERRA_UI__` telemetry records only when requested by the Node UI.
5. Node reads safe tool-event metadata from the raw JSONL stream to render activity and verification counts. It does not render model reasoning content.
6. The runner writes immutable per-iteration JSON summaries and raw/readable event logs under the stable project ID.
7. Node renders checkpoints during continuous execution and keeps live status plus Stop/Abort controls in a fixed terminal footer; it aggregates new summaries at completion.

## State boundaries

Application installation contains scripts, templates, and the Node UI. Application configuration and state live under `%LOCALAPPDATA%\TerraRunner` unless portable mode is selected. Each project receives a separate data directory, so projects with identical display names cannot mix logs or financial state.

OpenCode credentials remain owned by OpenCode. Terra Runner stores only account IDs, labels, profile policy, and user-entered provider observations. A local OpenCode cost estimate is stored separately from the provider snapshot and is always labelled as an estimate.

## Safety boundaries

Only `-Once` and `-Continuous` start an agent. Status, reports, setup, preflight, cancelled prompts, and configuration edits are read-only with respect to OpenCode execution. `STOP` requests finish the current iteration; `ABORT` requests terminate it on the next poll. The UI clears stale flags only when the user explicitly starts a new run.
