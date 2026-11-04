# End-to-end UI workflow using only temporary files and the offline OpenCode mock.
# No real OpenCode iteration, paid request, or user configuration is used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$mock = Join-Path $PSScriptRoot 'mock-opencode.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('terra-ui-workflow-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'project'
$extraRepo = Join-Path $tempRoot 'extra-project'
$bare = Join-Path $tempRoot 'origin.git'
$config = Join-Path $tempRoot 'terra-config.json'
$answers = [System.Collections.Generic.Queue[string]]::new()

function global:Clear-Host { }
function global:Read-Host([string]$Prompt) {
    if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $answers.Dequeue()
}

try {
    [void][IO.Directory]::CreateDirectory($repo)
    [void][IO.Directory]::CreateDirectory($extraRepo)
    & git init -q --bare $bare
    & git init -q -b codex/terra $repo
    & git -C $repo config user.email terra-runner@example.invalid
    & git -C $repo config user.name 'Terra Runner UI Mock'
    [IO.File]::WriteAllText((Join-Path $repo 'ROADMAP.md'),"- [ ] Mock task`n")
    [IO.File]::WriteAllText((Join-Path $repo 'PROGRESS.md'),"# Progress`n")
    & git -C $repo add ROADMAP.md PROGRESS.md
    & git -C $repo commit -qm 'test: initial UI project'
    & git -C $repo remote add origin $bare
    & git -C $repo push -q -u origin codex/terra

    $settings = [ordered]@{
        schemaVersion=2; openCodeCommand=$mock; agent='build'; model='test/model'
        projects=@([ordered]@{ id='ui-project'; path=$repo; branch='codex/terra'; roadmap='ROADMAP.md'; progress='PROGRESS.md' })
        budget=[ordered]@{ mode='daily'; dailyUsd=5.0; reserveUsd=0.5; emergencyStopUsd=4.95; allowUnlimited=$false; requireGlobalOpenCodeStats=$true; stopOnZeroCostWithTokens=$true; balance=[ordered]@{ source='snapshot'; id='ui-account'; minimumUsd=1.0; iterationReserveUsd=0.5; maxAgeMinutes=5; command=''; arguments=@() } }
        execution=[ordered]@{ pollSeconds=1; maxIterationMinutes=2; maxIterationsPerRun=3; maxConsecutiveNoProgress=2; maxConsecutiveDocumentationOnly=2; maxToolErrorsPerIteration=15; pauseBetweenIterationsSeconds=1; maxRawLogMiB=1 }
        logs=[ordered]@{ root=(Join-Path $tempRoot 'state'); retainDays=7; maxIterationsPerProject=10; maxTotalMiBPerProject=10; reportRetainDays=7 }
    }
    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config -Encoding utf8
    $env:TERRA_MOCK_COST = '0.15'; $env:TERRA_MOCK_ALL_COST = '0.15'

    # Development: actual UI dispatch for dry run and status.
    # Projects: add, remove, then edit the legacy project with defaults.
    # Budget/settings/reports/control: exercise all non-destructive selections.
    foreach ($answer in @(
        '1','3','','4','','0',
        '2','a',$extraRepo,'extra-project','codex/terra','ROADMAP.md','PROGRESS.md','','r','y','e','','','','','','0',
        '3','1','2','2','8','1','3','2','0.5','4','100','y','','5','','0',
        '4','1','','test/model-updated','','2','2','5','1','3','2','3','4','0',
        '5','1','','2','2026-11-03','','0',
        's','','a','y','','0'
    )) { $answers.Enqueue($answer) }

    & (Join-Path $root 'terra-ui.ps1') -Config $config
    if ($answers.Count -ne 0) { throw 'The UI did not consume the expected workflow inputs.' }
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    if ($saved.projects.Count -ne 1 -or $saved.projects[0].id -ne 'ui-project') { throw 'Project add/remove workflow failed.' }
    if (-not $saved.projects[0].Contains('taskIdPattern')) { throw 'Legacy project edit did not add taskIdPattern.' }
    if ($saved.budget.mode -ne 'balance' -or [double]$saved.budget.dailyUsd -ne 8 -or [double]$saved.budget.balance.minimumUsd -ne 2) { throw 'Budget workflow did not persist settings.' }
    if ($saved.model -ne 'test/model-updated' -or [int]$saved.execution.maxIterationsPerRun -ne 2) { throw 'Settings workflow did not persist settings.' }
    $projectState = Join-Path $tempRoot 'state/ui-project'
    if (-not (Test-Path -LiteralPath (Join-Path $projectState 'STOP')) -or -not (Test-Path -LiteralPath (Join-Path $projectState 'ABORT'))) { throw 'Stop/abort workflow did not create both control files.' }
    if (-not (Test-Path -LiteralPath (Join-Path $projectState 'reports/2026-11-03.md'))) { throw 'Report workflow did not create the requested report.' }
    # Account picker must work with the PowerShell mock shim as well as the npm .cmd shim used in production.
    $answers.Clear()
    foreach ($answer in @('4','5','r','','1','','q','1','80','5','120','','0','0','0')) { $answers.Enqueue($answer) }
    & (Join-Path $root 'terra-ui.ps1') -Config $config
    if ($answers.Count -ne 0) { throw 'The account picker did not consume the expected workflow inputs.' }
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    if ($saved.openCode.activeAccountId -ne 'openai/mock-oauth' -or $saved.openCode.accounts.Count -ne 2 -or -not $saved.openCode.accounts[0].quota.configured) { throw 'OpenCode account or quota selection was not persisted.' }
    Write-Host 'PASS: actual UI workflow covers development, projects, budgets, settings, reports, and controls.' -ForegroundColor Green
}
finally {
    Remove-Item Env:TERRA_MOCK_COST,Env:TERRA_MOCK_ALL_COST -ErrorAction SilentlyContinue
    Remove-Item Function:global:Clear-Host -ErrorAction SilentlyContinue
    Remove-Item Function:global:Read-Host -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
