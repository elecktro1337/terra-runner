# Configuration reference

Terra Runner 2.3 stores normal configuration and runtime state in `%LOCALAPPDATA%\TerraRunner`. Use `-Portable` to keep state beside the installation.

## Dispatcher runtime and automatic OpenCode storage

Schema v10 includes `openCode.stores[]` with
`profiles[].authStoreId`. Runtime instance records, heartbeats and addressable
controls live next to the configuration under `runtime/`; they contain no
provider secrets or Terra budget/quota values.

Finished, failed, stopped, aborted, and orphaned instance manifests are disposable runtime records. Use **Development → Active instances** to remove one record or clear all terminal records. The cleanup also removes only that record's `STOP`/`ABORT` directory. It never removes active instance records, project logs, reports, control-state, OpenCode stores, or the configuration.

There is no global selected project or profile. Legacy `activeProjectId`, active profile/account fields, global model/budget/reasoning values and `projects[].defaultProfileId` are removed on save; Development explicitly selects a project and profile for each launch.

Cloud profiles remain global non-secret templates and retain their source
`authStoreId`. At the first Development launch for a project, Terra creates a
stable project-managed store under `opencode-stores/<project-store-id>/opencode.db`.
Before every later cloud launch it refreshes just the selected provider from
the profile source by piping `opencode auth export <provider>` directly into
`opencode auth import`. The export is never buffered by Terra, added to an
argument, configuration, log, error message, or temporary secret file.

The target DB is selected only for the runner and its worker through
`OPENCODE_DB`. Project-managed stores are diagnostic read-only entries in
System: they cannot be selected for login, linked to a profile, or manually
edited. Local profiles do not create a managed store. Existing profiles remain
on `legacy-shared` after migration; the first cloud launch performs the copy
without a manual re-login. If the source credential no longer exists, reconnect
that profile through normal OpenCode authentication and launch again.

Removing an inactive project configuration also permanently removes only that
project's managed DB and bootstrap lock. Project removal is refused while an
instance is active. Repositories, logs, reports, source profile stores, and
other projects' managed stores are not removed.

## Projects

Each project has a stable ID, absolute path, expected Git branch, roadmap filename, and progress filename. Paths may contain spaces and Unicode characters. Project logs, reports, run summaries, and control files are stored below `logs.root/<project-id>`.

`taskIdPattern` is optional. Without it, every Markdown checkbox is a roadmap task. When it is absent, Terra Runner still recognises conventional IDs such as `NTD-0109` in newly completed roadmap entries.

## Profiles

Profiles are stored under `openCode.profiles`. A profile holds non-secret account identity, model, reasoning variant, policy, optional provider snapshot, and limits. Terra Runner never stores an API key or OAuth token.

- `api`: a cloud API profile. It can use USD snapshots and hourly, daily, critical-minimum, or unlimited policies.
- `oauth-managed`: a cloud OAuth profile. It can use a manually observed quota snapshot and critical or freshness policies.
- `local`: local inference with no provider money or quota controls.

The Node UI imports accounts through `opencode auth list --format json` and models through `opencode models`. It uses OpenCode's normal account switch command at run time.

## Provider snapshots

A snapshot is a user-reported provider observation. It contains a unit (`usd` or `percent`), remaining amount, observation time, and a maximum acceptable age. It is not a provider API result.

For profiles using a snapshot guard, a main-window run, including dry run, fails closed when the snapshot is missing or stale. The UI asks for a fresh value immediately before that run rather than requiring manual JSON editing. Dispatcher instances do not read, write, or validate Terra budget or quota state.

For a continuous run only, the user may disable the provider snapshot guard. This temporary override bypasses provider snapshot freshness and threshold checks; it does not bypass Git, timeout, no-progress, error, or manual stop safeguards.

## Optional local OpenCode cost estimate

An API profile with a USD snapshot can enable `usageSource.costTracking` from the profile screen. The UI obtains an all-time local OpenCode cost baseline from `opencode stats --all --json`.

During later runs, Terra Runner calculates:

```text
estimated remaining = provider-reported snapshot - local OpenCode cost since baseline
```

This is a local estimate only. It may include usage from other projects recorded by the same OpenCode installation and must not be called provider balance. Saving a new provider snapshot disables this estimate until a new baseline is created.

## Continuous execution

The continuous iteration count is selected per launch and is not persisted in a profile. `0` means run until a normal safety condition stops execution; `1`–`1000` sets a limit for that one run.

During a Node UI run, `S` or `Ctrl+C` creates a project `STOP` request and lets the current iteration finish. `X` creates an `ABORT` request and ends the active iteration at the next runner poll. A new UI launch clears stale control flags before execution.

## Recovery and retries

Settings are written atomically. If active JSON is invalid, the UI offers the newest valid backup and preserves the invalid file as a timestamped `.corrupt-*` copy.

`execution.maxTransientRetries` and `execution.transientRetryDelaySeconds` control TLS/SSL and transient network recovery. `execution.maxPushRetries` and `execution.pushRetryDelaySeconds` control non-force Git push retries. Failed or exhausted safety checks stop development rather than launching another agent iteration.
