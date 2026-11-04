# Configuration reference

Terra Runner 1.5 stores a normal installation in `%LOCALAPPDATA%\TerraRunner`. Use `-Portable` to keep configuration beside the scripts.

## Projects

Each project has an ID, absolute path, Git branch, roadmap, and progress file. Paths may contain spaces and Unicode. Logs, reports, control state, and stop files are stored under `logs.root/<project-id>`.

`taskIdPattern` is optional. Without it, every Markdown checkbox is a roadmap task. With it, completed IDs are added to reports. Legacy NTD projects use `NTD-\d{4,}`.

## Budget

`daily`, `balance`, `hybrid`, and `unlimited` are supported. User-entered amounts accept `.` or `,` and are stored using invariant JSON numbers. A snapshot balance is an estimate based on local OpenCode usage; it is not provider billing.

## OpenCode accounts, quotas, and local models

Open **Settings → OpenCode accounts and reasoning → Refresh accounts from OpenCode**. Terra Runner reads `opencode auth list --format json` and presents saved provider/credential labels; it never reads, exports, or stores API keys or OAuth tokens. Selecting an account calls OpenCode's normal `auth switch` command.

- API-key accounts use the existing USD balance modes and local OpenCode usage accounting.
- OAuth accounts use a separately configured, provider-reported quota snapshot. Set its unit (percent, requests, or sessions), remaining quota, reserve, and validity period. It is intentionally never displayed as USD or called a balance. OpenCode currently exposes no general quota API, so Terra Runner does not invent provider quota usage; an expired snapshot fails closed until reconciled.
- Local profiles have no balance or quota UI and do not require `opencode stats --json`. Select **Use the selected model as a local/no-limit profile** when OpenCode cannot classify the provider automatically.

Reasoning is a model variant. Choose it in the same menu; Terra Runner appends `#low`, `#medium`, `#high`, and so on to the selected model and can pass OpenCode's `--thinking` display flag. Unsupported variants are rejected by OpenCode before an agent run.

## Recovery

Settings are written atomically and backups are retained in `config-backups`. If the active JSON is invalid, Terra Runner offers the newest valid backup. Accepting recovery preserves the invalid file as a timestamped `.corrupt-*` copy.

## Transient connection retries

`execution.maxTransientRetries` defaults to `3` and `execution.transientRetryDelaySeconds` defaults to `30`. When an OpenCode event or worker error indicates a TLS, SSL, or transient network failure, Terra Runner waits, checks OpenCode usage statistics without launching an agent, and retries the interrupted iteration only after that check succeeds. It stops safely if connection checks or the retry limit are exhausted.

`execution.maxPushRetries` and `execution.pushRetryDelaySeconds` also default to `3` and `30`. When an agent leaves local commits unpublished because of a transient remote failure, Terra Runner retries a normal non-force `git push` before starting another paid iteration. A non-transient rejection, diverged history, or exhausted retry limit stops development safely.
