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
$fixture = Join-Path $PSScriptRoot 'fixtures/terra-config.json'
try {
    [void][IO.Directory]::CreateDirectory($repo)
    & git init -q --bare $bare
    & git init -q -b codex/terra $repo
    & git -C $repo config user.email terra-runner@example.invalid
    & git -C $repo config user.name 'Terra Runner Mock'
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0001 [P0]** — Проверить UTF-8 заголовок задачи`n")
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-PROGRESS.md'),"# Progress`n")
    [IO.File]::WriteAllText((Join-Path $repo 'PROJECT-INSTRUCTIONS.md'),"# Project instructions`n`nUse the project verification commands before completion.`n")
    & git -C $repo add NTD-ROADMAP.md NTD-PROGRESS.md PROJECT-INSTRUCTIONS.md
    & git -C $repo commit -qm 'Initial mock files'
    & git -C $repo remote add origin $bare
    & git -C $repo push -q -u origin codex/terra
    # Tests must never inherit a user's active budget mode or project settings.
    # The checked-in fixture is the schema template; runtime values below are
    # replaced with the isolated mock project and temporary storage.
    $cfg = Get-Content -Raw -LiteralPath $fixture | ConvertFrom-Json -AsHashtable
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
    $env:TERRA_MOCK_CALL_LOG = Join-Path $tempRoot 'mock-opencode.calls.log'
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
    # A project worktree lock blocks a duplicate runner without blocking another project.
    $lockPath = Join-Path $tempRoot 'project-data/mock-project/project-runner.lock'
    $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $locked = $false
        try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $locked = $true }
        if (-not $locked) { throw 'Runner did not reject a held project lock.' }
    } finally { $lock.Dispose() }
    Write-Host 'PASS: project lock blocks duplicate runner starts.' -ForegroundColor Green
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
    if ((Get-Content -LiteralPath $env:TERRA_MOCK_CALL_LOG -Raw) -notmatch 'Project instructions') { throw 'Committed project instructions were not passed to the worker prompt.' }
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

    # Instructions are mandatory, but may be the only pending Git change: the
    # development worker owns committing that existing user-authored file.
    # Restore each local probe before the remaining scenarios.
    $instructions = Join-Path $repo 'PROJECT-INSTRUCTIONS.md'
    Move-Item -LiteralPath $instructions -Destination ($instructions + '.missing')
    $missingInstructions = $false
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $missingInstructions = $_.Exception.Message -match 'instructions file is required' }
    Move-Item -LiteralPath ($instructions + '.missing') -Destination $instructions
    if (-not $missingInstructions) { throw 'Missing project instructions did not block a dry run.' }
    Add-Content -LiteralPath $instructions -Value 'Uncommitted instruction change.'
    $dirtyInstructionsAllowed = $true
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $dirtyInstructionsAllowed = $false }
    & git -C $repo checkout -- PROJECT-INSTRUCTIONS.md
    if (-not $dirtyInstructionsAllowed) { throw 'Dirty project instructions unexpectedly blocked a dry run.' }
    & git -C $repo rm --cached -q PROJECT-INSTRUCTIONS.md
    $untrackedInstructionsAllowed = $true
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $untrackedInstructionsAllowed = $false }
    & git -C $repo add PROJECT-INSTRUCTIONS.md
    if (-not $untrackedInstructionsAllowed) { throw 'Untracked project instructions unexpectedly blocked a dry run.' }
    [IO.File]::WriteAllText((Join-Path $repo 'UNRELATED-LOCAL-CHANGE.md'),'must block development')
    $unrelatedChangeBlocked = $false
    try { & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -DryRun } catch { $unrelatedChangeBlocked = $_.Exception.Message -match 'working tree has uncommitted/untracked changes' }
    Remove-Item -LiteralPath (Join-Path $repo 'UNRELATED-LOCAL-CHANGE.md') -Force
    if (-not $unrelatedChangeBlocked) { throw 'An unrelated local change did not block a dry run.' }
    Write-Host 'PASS: project instructions may be the only uncommitted Git change.' -ForegroundColor Green

    # The runner reads instructions afresh for every worker. A clean commit
    # made between iterations must appear in the next worker prompt.
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0002** — Instructions refresh task`n")
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add task for instruction refresh'
    & git -C $repo push -q origin codex/terra
    $env:TERRA_MOCK_UPDATE_INSTRUCTIONS_ONCE = '1'
    $env:TERRA_MOCK_STATE_DIR = Join-Path $tempRoot 'instruction-state'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 2
    Remove-Item Env:TERRA_MOCK_UPDATE_INSTRUCTIONS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    if ((Get-Content -LiteralPath $env:TERRA_MOCK_CALL_LOG -Raw) -notmatch 'Updated instruction: use the refreshed check') { throw 'The next worker did not receive the newly committed project instructions.' }
    Write-Host 'PASS: committed project instruction updates apply to the next iteration.' -ForegroundColor Green

    # A durable marker permits safe automatic recovery only for an interrupted
    # Terra run, not for arbitrary dirty worktrees.
    $recoveryHead = (& git -C $repo rev-parse HEAD).Trim()
    $recoveryMarker = Join-Path $tempRoot 'project-data/mock-project/recovery/inflight.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $recoveryMarker))
    [ordered]@{ project='mock-project'; runId='interrupted-0001'; branch='codex/terra'; baseHead=$recoveryHead; startedAt=(Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recoveryMarker -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $repo 'RECOVERY-CHECKPOINT.md'),'interrupted Terra work')
    $env:TERRA_MOCK_COST = '5.01'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    if (Test-Path -LiteralPath $recoveryMarker) { throw 'Interrupted Terra recovery marker was not cleared after a pushed checkpoint.' }
    if ((& git -C $repo status --porcelain)) { throw 'Interrupted Terra recovery left the working tree dirty.' }
    if ((& git -C $repo log -1 --pretty=%s) -notmatch '^chore\(terra\): recover interrupted run interrupted-0001$') { throw 'Interrupted Terra recovery commit message is missing.' }
    $recoveryRemote = (& git -C $repo ls-remote --heads origin refs/heads/codex/terra) -split '\s+' | Select-Object -First 1
    if ($recoveryRemote -ne (& git -C $repo rev-parse HEAD)) { throw 'Interrupted Terra recovery commit was not pushed.' }
    Write-Host 'PASS: interrupted Terra work is checkpointed and pushed before a new run.' -ForegroundColor Green

    $env:TERRA_MOCK_COST = '5.01'
    # The instruction-refresh continuous run above creates its own iteration
    # summaries. Count the live directory rather than the earlier snapshot.
    $countBefore = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
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
    $countBeforeBalance = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_ALL_COST = '119.0' # 100 - (119 - 20) = $1; below the $1 + $0.5 launch reserve.
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countAfter = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countAfter -ne $countBeforeBalance) { throw 'Balance floor should block new iterations.' }
    Write-Host 'PASS: $5 remaining balance stops even with daily checks disabled.' -ForegroundColor Green

    $env:TERRA_MOCK_ALL_COST = '95.0' # $25 left, should be allowed regardless of the day cost.
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [x] **NTD-0001** — Completed`n- [ ] **NTD-0002** — Next mock task`n")
    Add-Content -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md') -Value '- [ ] Generic checkbox task'
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add second pending task'
    & git -C $repo push -q origin codex/terra
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countAfter = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countAfter -ne ($countBeforeBalance + 1)) { throw 'Balance mode must allow iteration without daily cap.' }
    Write-Host 'PASS: balance mode executes regardless of daily cost.' -ForegroundColor Green

    # Hybrid: enough remaining on snapshot balance, but a daily limit still blocks.
    $cfg.budget.mode = 'hybrid'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    $countHybrid = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'project-data/mock-project/logs') -Recurse -Filter '*.summary.json').Count
    if ($countHybrid -ne $countAfter) { throw 'Hybrid mode did not enforce daily limit.' }
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

    # A larger roadmap task can span several commits. Code/test changes must
    # keep Continuous moving even before that task's checkbox is completed.
    $beforeImplementationProgress = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_IMPLEMENTATION_PROGRESS = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 3
    Remove-Item Env:TERRA_MOCK_IMPLEMENTATION_PROGRESS -ErrorAction SilentlyContinue
    $afterImplementationProgress = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterImplementationProgress.Count -ne ($beforeImplementationProgress + 3)) { throw 'Verified implementation progress should continue through the requested iterations.' }
    $implementationSummary = Get-Content -Raw -LiteralPath ($afterImplementationProgress | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName | ConvertFrom-Json
    if (-not $implementationSummary.implementationProgress -or $implementationSummary.consecutiveNoProgress -ne 0 -or $implementationSummary.stoppedReason) { throw 'Code/test progress was incorrectly treated as no roadmap progress.' }
    Write-Host 'PASS: code/test progress keeps continuous development running without a roadmap checkbox.' -ForegroundColor Green

    # A successful worker can leave an incomplete implementation for the next
    # iteration. Terra must checkpoint it with ordinary hooks, push it, and
    # count it as progress without ticking a roadmap item.
    $beforeWip = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $roadmapBeforeWip = Get-Content -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md') -Raw
    $env:TERRA_MOCK_UNCOMMITTED_PROGRESS = '1'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Once
    Remove-Item Env:TERRA_MOCK_UNCOMMITTED_PROGRESS -ErrorAction SilentlyContinue
    $afterWip = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterWip.Count -ne ($beforeWip + 1)) { throw 'WIP checkpoint did not produce a summary.' }
    if ((& git -C $repo status --porcelain)) { throw 'WIP checkpoint left the worktree dirty.' }
    $wipSummary = Get-Content -Raw -LiteralPath ($afterWip | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName | ConvertFrom-Json
    if (-not $wipSummary.checkpointCommit -or -not $wipSummary.implementationProgress -or $wipSummary.completedTaskIds.Count -ne 0) { throw 'WIP checkpoint summary is incomplete or marked a roadmap task complete.' }
    if ((& git -C $repo log -1 --pretty=%s) -notmatch '^wip\(terra\): checkpoint NTD-\d{4} ') { throw 'WIP checkpoint commit message is missing.' }
    if ((Get-Content -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md') -Raw) -cne $roadmapBeforeWip) { throw 'WIP checkpoint unexpectedly modified the roadmap.' }
    Write-Host 'PASS: clean partial work becomes a pushed WIP checkpoint without a roadmap tick.' -ForegroundColor Green

    # A TLS interruption must be checked and retried without counting as no progress.
    $beforeTls = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_TLS_ONCE = '1'
    $env:TERRA_MOCK_STATE_DIR = Join-Path $tempRoot 'mock-state'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 1
    Remove-Item Env:TERRA_MOCK_TLS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_UPDATE_INSTRUCTIONS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_TLS_TEXT -ErrorAction SilentlyContinue
    $afterTls = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterTls.Count -ne ($beforeTls + 2)) { throw 'TLS interruption was not retried as the same iteration.' }
    $tlsSummary = @($afterTls | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } | Where-Object { $_.transientNetworkFailure } | Select-Object -Last 1)
    if ($tlsSummary.Count -ne 1 -or $tlsSummary[0].consecutiveNoProgress -ne 0) { throw 'TLS interruption was not classified or incorrectly counted as no progress.' }
    if ((Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')) -notmatch '\[x\]') { throw 'Recovered TLS retry did not complete the pending task.' }
    Write-Host 'PASS: TLS failure waits for a connection check and retries the same iteration.' -ForegroundColor Green

    # A narrowly identified provider response interruption must retry the same
    # Continuous iteration only after the failed worker left a clean, pushed
    # repository. The fake fails once with the production event shape, then
    # completes normally without calling a model.
    [IO.File]::WriteAllText((Join-Path $repo 'NTD-ROADMAP.md'),"- [ ] **NTD-0150** — Provider retry task`n")
    & git -C $repo add NTD-ROADMAP.md | Out-Null
    & git -C $repo commit -qm 'test: add provider retry task'
    & git -C $bare fetch -q $repo codex/terra:refs/heads/codex/terra
    $cfg.execution.maxTransientProviderRetries = 1
    $cfg.execution.transientProviderRetryDelaySeconds = 1
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    $beforeProviderRetry = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json').Count
    $env:TERRA_MOCK_PROVIDER_INVALID_OUTPUT_ONCE = '1'
    $env:TERRA_MOCK_STATE_DIR = Join-Path $tempRoot 'mock-provider-state'
    & (Join-Path $runnerRoot 'terra-runner.ps1') -Project mock-project -Config $cfgFile -Continuous -MaxIterations 1
    Remove-Item Env:TERRA_MOCK_PROVIDER_INVALID_OUTPUT_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    $afterProviderRetry = @(Get-ChildItem -LiteralPath $summaryDirectory -Recurse -Filter '*.summary.json')
    if ($afterProviderRetry.Count -ne ($beforeProviderRetry + 2)) { throw 'Transient provider interruption was not retried as the same iteration.' }
    $providerFailureSummary = @($afterProviderRetry | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } | Where-Object { $_.transientProviderFailure -eq 'provider.invalid-output' } | Select-Object -Last 1)
    if ($providerFailureSummary.Count -ne 1 -or $providerFailureSummary[0].transientNetworkFailure -or $providerFailureSummary[0].transientProviderMessage -ne 'provider response interruption') { throw 'Provider interruption was not classified independently of network recovery or was not redacted.' }
    if ((Get-Content -Raw -LiteralPath (Join-Path $repo 'NTD-ROADMAP.md')) -notmatch '\[x\]') { throw 'Provider retry did not complete the pending task.' }
    Write-Host 'PASS: transient provider interruption retries one continuous iteration safely.' -ForegroundColor Green

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
    Remove-Item Env:TERRA_MOCK_CALL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_NO_ACTIONABLE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_IMPLEMENTATION_PROGRESS -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_TLS_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_PROVIDER_INVALID_OUTPUT_ONCE -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_STATE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:TERRA_MOCK_BLOCKED -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
