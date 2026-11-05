# Terra Runner 2.3 architecture

## Dispatcher and project workspaces

`node-ui/index.mjs` is the central dispatcher. It owns a heartbeat and a
non-secret runtime registry beside `terra-config.json`. It has no global active
project or profile: Development first selects a command, project, profile and run mode. Main-window mode invokes the
runner directly; dispatcher-instance mode writes an immutable command snapshot
and starts `node-ui/instance.mjs` in a separate terminal.

An instance uses its frozen profile, proxy route and OpenCode authentication
store. For a cloud launch, the dispatcher lazily creates a project-managed
store and streams only the chosen provider from the profile source directly
from `opencode auth export` stdout to `opencode auth import` stdin. The secret
payload is not buffered, serialized, logged, or passed as an argument. The
effective store ID is frozen in the instance snapshot. Isolated stores are set through `OPENCODE_DB`; workers use
`opencode run --standalone`, leaving Windows settings and OpenCode's shared
service unchanged. A project-scoped runner lock protects a Git worktree while
allowing different projects to run concurrently. Budget/quota state is used
only by main-window runs; dispatcher instances record untracked usage and do
not reserve or inspect provider limits.

Terra Runner separates presentation, execution, and persistent project evidence.

## Components

- `Terra Runner.cmd` requires Node.js 20+ and starts the Node.js dispatcher; PowerShell 7 remains the execution engine and CLI host.
- `node-ui/index.mjs` is the primary terminal UI. It manages projects and profiles, gathers safe OpenCode inventory, renders run telemetry, and starts PowerShell with named parameters.
- `node-ui/lib/profiles.mjs` normalises and applies non-secret profile settings.
- `node-ui/lib/reports.mjs` reads isolated project summaries and reports.
- `terra-runner.ps1` is the safety and orchestration engine. It validates Git, controls budgets and snapshots, writes summaries/reports, and manages stop files.
- `terra-worker.ps1` starts one non-interactive OpenCode session in the selected project and preserves the original JSONL event stream.
- `terra-core.psm1` provides configuration-location and invariant money helpers.

## Run flow

1. Node UI selects a profile for this launch and creates the command snapshot. In main-window mode it validates that profile's provider snapshot for one iteration, continuous runs and dry runs.
2. Node UI invokes `terra-runner.ps1` with the explicit project and profile parameters; it does not change the global selected profile.
3. The runner validates the project, Git branch, clean working tree, remote state and control flags. It validates limits only for main-window runs.
4. The runner emits compact `__TERRA_UI__` telemetry records only when requested by the Node UI.
5. Node reads safe tool-event metadata from the raw JSONL stream to render activity and verification counts. It does not render model reasoning content.
6. The runner writes immutable per-iteration JSON summaries and raw/readable event logs under the stable project ID.
7. Node renders the selected run context and a bounded journal of completed iterations below the header, pins only Stop/Abort controls to the terminal bottom, and aggregates new summaries at completion.

## State boundaries

Application installation contains scripts, templates, and the Node UI. Application configuration and state live under `%LOCALAPPDATA%\TerraRunner` unless portable mode is selected. Each project receives a separate data directory, so projects with identical display names cannot mix logs or financial state.

OpenCode credentials remain owned by OpenCode. Terra Runner stores only account IDs, labels, profile policy, managed-store metadata, and user-entered provider observations. A local OpenCode cost estimate is stored separately from the provider snapshot and is always labelled as an estimate. A project-managed DB is deleted immediately when its inactive project configuration is removed; its source profile DB remains untouched.

Terminal instance records are runtime metadata, not historical evidence. `Development → Active instances` can remove one terminal record or clear all terminal records; it never removes an active, starting, stopping, or aborting instance. Logs, reports, and project control state remain separate and are not removed by this action.

## Safety boundaries

Only `-Once` and `-Continuous` start an agent. Status, reports, setup, preflight, cancelled prompts, and configuration edits are read-only with respect to OpenCode execution. `STOP` requests finish the current iteration; `ABORT` requests terminate it on the next poll. The UI clears stale flags only when the user explicitly starts a new run.
