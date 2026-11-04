# Configuration reference

Terra Runner 1.5 stores a normal installation in `%LOCALAPPDATA%\TerraRunner`. Use `-Portable` to keep configuration beside the scripts.

## Projects

Each project has an ID, absolute path, Git branch, roadmap, and progress file. Paths may contain spaces and Unicode. Logs, reports, control state, and stop files are stored under `logs.root/<project-id>`.

`taskIdPattern` is optional. Without it, every Markdown checkbox is a roadmap task. With it, completed IDs are added to reports. Legacy NTD projects use `NTD-\d{4,}`.

## Budget

`daily`, `balance`, `hybrid`, and `unlimited` are supported. User-entered amounts accept `.` or `,` and are stored using invariant JSON numbers. A snapshot balance is an estimate based on local OpenCode usage; it is not provider billing.

## Recovery

Settings are written atomically and backups are retained in `config-backups`. If the active JSON is invalid, Terra Runner offers the newest valid backup. Accepting recovery preserves the invalid file as a timestamped `.corrupt-*` copy.

## Transient connection retries

`execution.maxTransientRetries` defaults to `3` and `execution.transientRetryDelaySeconds` defaults to `30`. When an OpenCode event or worker error indicates a TLS, SSL, or transient network failure, Terra Runner waits, checks OpenCode usage statistics without launching an agent, and retries the interrupted iteration only after that check succeeds. It stops safely if connection checks or the retry limit are exhausted.

`execution.maxPushRetries` and `execution.pushRetryDelaySeconds` also default to `3` and `30`. When an agent leaves local commits unpublished because of a transient remote failure, Terra Runner retries a normal non-force `git push` before starting another paid iteration. A non-transient rejection, diverged history, or exhausted retry limit stops development safely.
