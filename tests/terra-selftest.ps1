# Offline integration smoke test. Creates and deletes a temporary Git repo + bare remote.
# Needs PowerShell 7 and Git; DOES NOT call a paid model.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runnerRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('terra-runner-test-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'repo'
$bare = Join-Path $tempRoot 'remote.git'
$fake = Join-Path $PSScriptRoot 'mock-opencode.ps1'
$cfgFile = Join-Path $tempRoot 'config.json'
try {
    [void][IO.Directory]::CreateDirectory($repo)
    & git init -q --bare $bare
    & git init -q -b codex/terra $repo
    & git -C $repo config user.email terra-runner@example.invalid
    & git -C $repo config user.name 'Terra Runner Mock'
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0001 [P0]** — Mock task`n")
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-PROGRESS.md'),"# Progress`n")
    & git -C $repo add NTD-ROADMAP.md NTD-PROGRESS.md
    & git -C $repo commit -qm 'Initial mock files'
    & git -C $repo remote add origin $bare
    & git -C $repo push -q -u origin codex/terra
    # Tests must never inherit a user's active budget mode or project settings.
    # Use the checked-in current configuration as the schema template. Runtime
    # values below are replaced with the isolated mock project and temp storage.
    $cfg = Get-Content -Raw -LiteralPath (Join-Path $runnerRoot 'terra-config.json') | ConvertFrom-Json -AsHashtable
    $cfg.projects[0].id = 'mock-project'
    $cfg.projects[0].path = $repo
    $cfg.openCodeCommand = $fake
    $cfg.budget.mode = 'daily'
    $cfg.logs.root = (Join-Path $tempRoot 'project-data')
    $cfg.execution.pollSeconds = 1
    $cfg.execution.maxIterationMinutes = 2
    $cfg.logs.maxIterationsPerProject = 1
    $cfg.logs.retainDays = 1
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    # Dry runs are validation only: they must not rotate user logs or touch budget snapshots.
    $rotationLogs = Join-Path $tempRoot 'project-data/mock-project/logs/rotation'
    [void][IO.Directory]::CreateDirectory($rotationLogs)
    $oldBundle = Join-Path $rotationLogs 'old.events.jsonl'
    $newBundle = Join-Path $rotationLogs 'new.events.jsonl'
    [IO.File]::WriteAllText($oldBundle,'old'); [IO.File]::WriteAllText($newBundle,'new')
    (Get-Item -LiteralPath $oldBundle).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-3)
    $protectedBudget = Join-Path $tempRoot 'project-data/budgets/protected.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $protectedBudget)); [IO.File]::WriteAllText($protectedBudget,'{}')
    $env:TERRA_MOCK_COST = '0.15'; $env:TERRA_MOCK_ALL_COST = '0.15'; $env:TERRA_MOCK_BROKEN_STATS = '0'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun
    if (-not (Test-Path -LiteralPath $oldBundle) -or -not (Test-Path -LiteralPath $newBundle) -or -not (Test-Path -LiteralPath $protectedBudget)) { throw 'Dry run modified logs or budget snapshots.' }
    Write-Host 'PASS: dry run leaves logs and budget snapshots unchanged.' -ForegroundColor Green
    # Local and OAuth quota accounts deliberately bypass money/stat accounting.
    $cfg.schemaVersion = 4
    $cfg.openCode = [ordered]@{ accounts=@(
        [ordered]@{ id='local/mock'; provider='local'; credentialId='mock'; label='Mock local'; authMethod='local'; usageKind='local'; quota=$null },
        [ordered]@{ id='openai/mock-oauth'; provider='openai'; credentialId='mock-oauth'; label='Mock OAuth'; authMethod='oauth'; usageKind='quota'; quota=[ordered]@{ configured=$true; unit='percent'; remaining=80; reserve=5; maxAgeMinutes=120; observedAt=(Get-Date).ToString('o') } }
    ); activeAccountId='local/mock'; reasoning=[ordered]@{ variant='high'; showThinking=$true } }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    $env:TERRA_MOCK_BROKEN_STATS = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun
    $cfg.openCode.activeAccountId = 'openai/mock-oauth'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Status
    Remove-Item Env:TERRA_MOCK_BROKEN_STATS -ErrorAction SilentlyContinue
    $cfg.Remove('openCode')
    $cfg.schemaVersion = 2
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    Write-Host 'PASS: local and OAuth quota profiles do not invoke money accounting.' -ForegroundColor Green
    # The global accounting lock blocks concurrent runners before they can launch an agent.
    $lockPath = Join-Path $tempRoot 'project-data/global-runner.lock'
    $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $locked = $false
        try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $locked = $true }
        if (-not $locked) { throw 'Runner did not reject a held global accounting lock.' }
    } finally { $lock.Dispose() }
    Write-Host 'PASS: global accounting lock blocks concurrent runner starts.' -ForegroundColor Green
    $cfg.logs.maxIterationsPerProject = 150
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    $env:TERRA_MOCK_COST = '0.15'
    $env:TERRA_MOCK_BROKEN_STATS = '0'
    $env:TERRA_MOCK_ALL_COST = '0.15'
    $env:TERRA_MOCK_TLS_TEXT = '1'
    $env:TERRA_MOCK_SKIP_PUSH = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once -ShowProgress
    Remove-Item Env:TERRA_MOCK_TLS_TEXT -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_SKIP_PUSH -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Runner returned non-zero exit code' }
    if (Test-Path -LiteralPath $oldBundle) { throw 'Iteration rotation did not remove expired selected-project logs.' }
    if (-not (Test-Path -LiteralPath $newBundle) -or -not (Test-Path -LiteralPath $protectedBudget)) { throw 'Iteration rotation touched retained logs or protected budget data.' }
    Write-Host 'PASS: project log rotation preserves budget snapshots.' -ForegroundColor Green
    $roadmapResult = Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')
    if ($roadmapResult -notmatch '\[x\]') { throw 'Mock task was not completed.' }
    $remoteHash = (& git -C $repo ls-remote --heads origin refs/heads/codex/terra) -split '\s+' | Select-Object -First 1
    $localHash = & git -C $repo rev-parse HEAD
    if ($remoteHash -ne $localHash) { throw 'Remote hash differs from local hash.' }
    $summaries = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json')
    if ($summaries.Count -ne 1) { throw 'Expected one project-specific iteration summary.' }
    $summary = Get-Content -Raw -LiteralPath $summaries[0].FullName | ConvertFrom-Json
    if (-not $summary.pushVerified -or $summary.doneAfter -ne 1) { throw 'Summary validation failed.' }
    if ($summary.transientNetworkFailure) { throw 'A successful text message mentioning TLS must not trigger retry logic.' }
    if ($summary.completedTaskIds -notcontains 'NTD-0001') { throw 'Missing completed TODO ID in iteration summary.' }
    if (-not $summary.commits -or $summary.commits.Count -lt 1) { throw 'Missing Git commit information in summary.' }
    if ($summary.toolErrors -ne 1) { throw 'Recovered tool error must be counted separately.' }
    $readable = Get-Content -LiteralPath ($summaries[0].FullName -replace '\.summary\.json$','.events.readable.jsonl') -Raw -Encoding UTF8
    if ($readable -notmatch 'Все') { throw 'Readable event log must repair CP866/UTF-8 mojibake.' }
    $dailyReport = Join-Path (Join-Path $tempRoot 'project-data/mock-project/reports') ((Get-Date -Format 'yyyy-MM-dd') + '.md')
    if (-not (Test-Path -LiteralPath $dailyReport)) { throw 'Missing daily project report.' }
    if ((Get-Content -Raw $dailyReport) -notmatch 'Iterations:') { throw 'Daily project report content missing.' }
    if ((Get-Content -Raw $dailyReport) -notmatch 'NTD-0001') { throw 'Daily report must contain task IDs.' }
    Write-Host 'PASS: readable logs, tool errors, and daily reports.' -ForegroundColor Green
    Write-Host 'PASS: one iteration, TODO update, commit, push and project log.' -ForegroundColor Green

    $env:TERRA_MOCK_COST = '5.01'
    $countBefore = @($summaries).Count
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countAfter = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countBefore -ne $countAfter) { throw 'Runner started an iteration above daily budget.' }
    Write-Host 'PASS: daily budget prevents new iterations.' -ForegroundColor Green

    $env:TERRA_MOCK_BROKEN_STATS = '1'
    $blocked = $false
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'Runner should reject unverifiable stats.' }
    Write-Host 'PASS: unparseable cost statistics fail closed.' -ForegroundColor Green

    # Balance mode is independent from the daily budget. Baseline the cumulative global usage,
    # then simulate accumulated charges from other projects and verify the minimum floor.
    $env:TERRA_MOCK_BROKEN_STATS = '0'
    $env:TERRA_MOCK_COST = '50.0'  # Deliberately above the daily limit.
    $env:TERRA_MOCK_ALL_COST = '20.0'
    $cfg.budget.mode = 'balance'
    $cfg.schemaVersion = 3 # No taskIdPattern: all Markdown checkbox tasks are actionable.
    $cfg.budget.balance.source = 'snapshot'
    $cfg.budget.balance.id = 'mock-user-balance'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -SetBalanceUsd 100.0
    $stateFile = Join-Path $tempRoot 'project-data/budgets/mock-user-balance.json'
    if (-not (Test-Path $stateFile)) { throw 'Balance snapshot was not created.' }
    $env:TERRA_MOCK_ALL_COST = '115.0' # 100 - (115 - 20) = $5; stop.
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countAfter = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countAfter -ne 1) { throw 'Balance floor should block new iterations.' }
    Write-Host 'PASS: $5 remaining balance stops even with daily checks disabled.' -ForegroundColor Green

    $env:TERRA_MOCK_ALL_COST = '95.0' # $25 left, should be allowed regardless of the day cost.
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [x] **NTD-0001** — Completed`n- [ ] **NTD-0002** — Next mock task`n")
    Add-Content -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md') -Value '- [ ] Generic checkbox task'
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add second pending task'
    & git -C $repo push -q origin codex/terra
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countAfter = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countAfter -ne 2) { throw 'Balance mode must allow iteration without daily cap.' }
    Write-Host 'PASS: balance mode executes regardless of daily cost.' -ForegroundColor Green

    # Hybrid: enough remaining on snapshot balance, but a daily limit still blocks.
    $cfg.budget.mode = 'hybrid'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countHybrid = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countHybrid -ne 2) { throw 'Hybrid mode did not enforce daily limit.' }
    Write-Host 'PASS: hybrid requires both budget conditions.' -ForegroundColor Green

    $env:TERRA_MOCK_ALL_COST = '19.0' # Usage moving backward MUST fail closed.
    $cfg.budget.mode = 'balance'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    $blocked = $false
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'Balance model must reject decreasing lifetime usage.' }
    Write-Host 'PASS: missing consistency in lifetime usage fails closed.' -ForegroundColor Green

    # NO_ACTIONABLE_TASKS must stop after one attempt even when roadmap checkboxes remain.
    $cfg.budget.mode = 'daily'
    $cfg.execution.maxConsecutiveNoProgress = 3
    $cfg.execution.maxTransientRetries = 2
    $cfg.execution.transientRetryDelaySeconds = 1
    $cfg.execution.pauseBetweenIterationsSeconds = 0
    $env:TERRA_MOCK_COST = '0.15'; $env:TERRA_MOCK_ALL_COST = '0.15'
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0101** — First pending task`n- [ ] **NTD-0102** — Second pending task`n")
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add pending tasks for advisory signal'
    # Copy the local test commit into the temporary bare repository so the
    # runner's remote-head verification sees the same revision.
    & git -C $bare fetch -q $repo codex/terra:refs/heads/codex/terra
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    $summaryDirectory = Join-Path $tempRoot 'project-data/mock-project/logs'
    $beforeNoAction = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_NO_ACTIONABLE = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 2
    Remove-Item Env:TERRA_MOCK_NO_ACTIONABLE -ErrorAction SilentlyContinue
    $afterNoAction = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterNoAction.Count -ne ($beforeNoAction + 1)) { throw 'NO_ACTIONABLE_TASKS did not stop before a second paid iteration.' }
    if ((Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')) -notmatch '\[ \]') { throw 'NO_ACTIONABLE_TASKS simulation unexpectedly changed the roadmap.' }
    $noActionSummary = Get-Content -Raw -LiteralPath ($afterNoAction | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName | ConvertFrom-Json
    if (-not $noActionSummary.noActionableTasksReported) { throw 'NO_ACTIONABLE_TASKS signal was not recorded.' }
    Write-Host 'PASS: NO_ACTIONABLE_TASKS stops before a second paid iteration.' -ForegroundColor Green

    # A TLS interruption must be checked and retried without counting as no progress.
    $beforeTls = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_TLS_ONCE = '1'
    $env:TERRA_MOCK_STATE_DIR = Join-Path $tempRoot 'mock-state'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 1
    Remove-Item Env:TERRA_MOCK_TLS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_TLS_TEXT -ErrorAction SilentlyContinue
    $afterTls = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterTls.Count -ne ($beforeTls + 2)) { throw 'TLS interruption was not retried as the same iteration.' }
    $tlsSummary = @($afterTls | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } | Where-Object { $_.transientNetworkFailure } | Select-Object -Last 1)
    if ($tlsSummary.Count -ne 1 -or $tlsSummary[0].consecutiveNoProgress -ne 1) { throw 'TLS interruption was not classified or incorrectly counted as no progress.' }
    if ((Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')) -notmatch '\[x\]') { throw 'Recovered TLS retry did not complete the pending task.' }
    Write-Host 'PASS: TLS failure waits for a connection check and retries the same iteration.' -ForegroundColor Green

    # An explicit project blocker must be shown and stop before an expensive retry loop.
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0201** — Blocked task`n")
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add blocked task'
    & git -C $bare fetch -q $repo codex/terra:refs/heads/codex/terra
    $beforeBlocked = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_BLOCKED = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 2
    Remove-Item Env:TERRA_MOCK_BLOCKED -ErrorAction SilentlyContinue
    $afterBlocked = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterBlocked.Count -ne ($beforeBlocked + 1)) { throw 'Explicit blocker should stop before a second paid iteration.' }
    $blockedSummary = Get-Content -Raw -LiteralPath ($afterBlocked | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName | ConvertFrom-Json
    if ($blockedSummary.noActionableTasksMessage -notmatch 'Docker daemon is unavailable') { throw 'Blocker reason was not preserved in the summary.' }
    Write-Host 'PASS: explicit roadmap blocker is displayed and stops safely.' -ForegroundColor Green
    Write-Host 'ALL OFFLINE SELF-TESTS PASSED' -ForegroundColor Green
}
finally {
    Remove-Item Env:TERRA_MOCK_COST -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_BROKEN_STATS -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_ALL_COST -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_NO_ACTIONABLE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_TLS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_BLOCKED -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
