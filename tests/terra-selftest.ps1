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
    # Rotation is limited to the selected project's logs and must never remove budget snapshots.
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
    if (Test-Path -LiteralPath $oldBundle) { throw 'Rotation did not remove expired selected-project logs.' }
    if (-not (Test-Path -LiteralPath $newBundle) -or -not (Test-Path -LiteralPath $protectedBudget)) { throw 'Rotation touched retained logs or protected budget data.' }
    Write-Host 'PASS: project log rotation preserves budget snapshots.' -ForegroundColor Green
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
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once -ShowProgress
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Runner returned non-zero exit code' }
    $roadmapResult = Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')
    if ($roadmapResult -notmatch '\[x\]') { throw 'Mock task was not completed.' }
    $remoteHash = (& git -C $repo ls-remote --heads origin refs/heads/codex/terra) -split '\s+' | Select-Object -First 1
    $localHash = & git -C $repo rev-parse HEAD
    if ($remoteHash -ne $localHash) { throw 'Remote hash differs from local hash.' }
    $summaries = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json')
    if ($summaries.Count -ne 1) { throw 'Expected one project-specific iteration summary.' }
    $summary = Get-Content -Raw -LiteralPath $summaries[0].FullName | ConvertFrom-Json
    if (-not $summary.pushVerified -or $summary.doneAfter -ne 1) { throw 'Summary validation failed.' }
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
    Write-Host 'ALL OFFLINE SELF-TESTS PASSED' -ForegroundColor Green
}
finally {
    Remove-Item Env:TERRA_MOCK_COST -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_BROKEN_STATS -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_ALL_COST -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
