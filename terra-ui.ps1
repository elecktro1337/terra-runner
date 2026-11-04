<#
  Terra Runner 1.5 interactive console.
  The UI owns configuration and navigation. The runner owns development execution.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$SelfTest,
    [switch]$Portable,
    [string]$Config = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or newer is required.' }

$script:Version = '1.5.0'
$script:Root = $PSScriptRoot
$script:Runner = Join-Path $script:Root 'terra-runner.ps1'
$script:Settings = $null
$script:ProjectId = ''
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
Import-Module (Join-Path $script:Root 'terra-core.psm1') -Force -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($Config) -and -not $Portable) {
    $script:ConfigFile = Join-Path (Get-TerraAppDataRoot -InstallRoot $script:Root) 'terra-config.json'
} else {
    $script:ConfigFile = Resolve-TerraConfigPath -Config $Config -Portable:$Portable -InstallRoot $script:Root
}

try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
try { [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
try { $Host.UI.RawUI.WindowTitle = "Terra Runner $($script:Version) | OpenCode" } catch { }

function Write-Line([string]$Text = '', [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Write-Rule { Write-Line ('─' * 78) 'DarkGray' }
function Pause-Menu { [void](Read-Host 'Press Enter to continue') }
function Read-Choice([string]$Prompt) { return ([string](Read-Host $Prompt)).Trim().ToLowerInvariant() }
function Confirm([string]$Prompt) { return ((Read-Choice "$Prompt [y/n]") -in @('y','yes')) }

function Read-Text([string]$Prompt, [string]$Current = '', [bool]$Required = $false) {
    while ($true) {
        $hint = if ($Current) { " [$Current]" } else { '' }
        $value = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Current) { return $Current }
            if (-not $Required) { return '' }
            Write-Line 'A value is required.' 'Yellow'; continue
        }
        return $value.Trim()
    }
}
function Read-Integer([string]$Prompt, [int]$Current, [int]$Minimum = 0, [int]$Maximum = 1000000) {
    while ($true) {
        $value = Read-Host "$Prompt [$Current]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
        $number = 0
        if ([int]::TryParse($value.Trim(),[ref]$number) -and $number -ge $Minimum -and $number -le $Maximum) { return $number }
        Write-Line "Enter a whole number from $Minimum to $Maximum." 'Yellow'
    }
}
function Read-Money([string]$Prompt, [decimal]$Current, [decimal]$Minimum = 0) {
    while ($true) {
        $value = Read-Host "$Prompt [$(Format-TerraMoney $Current)]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
        try { return (ConvertTo-TerraMoney -Text $value -Minimum $Minimum) }
        catch { Write-Line $_.Exception.Message 'Yellow' }
    }
}
function Read-SettingMember($Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-ConfigRoot { return (Split-Path -Parent $script:ConfigFile) }
function Get-StorageRoot {
    $root = [string]$script:Settings.logs.root
    if (-not [IO.Path]::IsPathRooted($root)) { $root = Join-Path (Get-ConfigRoot) $root }
    return $root
}
function Get-ProjectDataRoot { return (Join-Path (Get-StorageRoot) $script:ProjectId) }
function Get-SelectedProject {
    $matches = @($script:Settings.projects | Where-Object { $_.id -eq $script:ProjectId })
    if ($matches.Count -ne 1) { throw "Selected project '$($script:ProjectId)' is not configured." }
    return $matches[0]
}
function Get-RoadmapCounts($Project) {
    $path = Join-Path ([string]$Project.path) ([string]$Project.roadmap)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $done = 0; $pending = 0
    foreach ($line in [IO.File]::ReadLines($path)) {
        if ($line -match '^\s*-\s*\[[xX]\]') { $done++ }
        elseif ($line -match '^\s*-\s*\[ \]') { $pending++ }
    }
    return [pscustomobject]@{ Done=$done; Pending=$pending; Total=($done + $pending) }
}
function Get-LatestSummary {
    $logs = Join-Path (Get-ProjectDataRoot) 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { return $null }
    $file = Get-ChildItem -LiteralPath $logs -Recurse -File -Filter '*.summary.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $file) { return $null }
    try { return (Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50) } catch { return $null }
}
function Get-LatestCompletedTask {
    $logs = Join-Path (Get-ProjectDataRoot) 'logs'
    if (Test-Path -LiteralPath $logs -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $logs -Recurse -File -Filter '*.summary.json' | Sort-Object LastWriteTimeUtc -Descending)) {
            try { $summary = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50 }
            catch { continue }
            foreach ($taskId in @(Read-SettingMember $summary 'completedTaskIds')) {
                if (-not [string]::IsNullOrWhiteSpace([string]$taskId)) { return [string]$taskId }
            }
        }
    }
    # Some agents commit a verified task but do not produce a roadmap-diff ID in the runner summary.
    # The local commit subject is a read-only, project-scoped fallback for the dashboard only.
    try {
        $project = Get-SelectedProject
        foreach ($subject in @(& git -C ([string]$project.path) log -n 250 --format=%s 2>$null)) {
            $match = [regex]::Match([string]$subject, '(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]*-\d{3,}(?![A-Za-z0-9])')
            if ($match.Success) { return $match.Value }
        }
    } catch { }
    return $null
}
function Get-HeaderBudgetText($Budget, $LastSummary) {
    $balance = Read-SettingMember $LastSummary 'balanceAfterUSD'
    if ($null -eq $balance) { $balance = Read-SettingMember $LastSummary 'balanceBeforeUSD' }
    $balanceText = if ($null -ne $balance) { Format-TerraMoney ([decimal]$balance) } else { 'unavailable' }
    $limit = switch ([string]$Budget.mode) {
        'daily' { "Daily limit $(Format-TerraMoney ([decimal]$Budget.dailyUsd))" }
        'balance' { "Balance floor $(Format-TerraMoney ([decimal]$Budget.balance.minimumUsd))" }
        'hybrid' { "Hybrid: daily $(Format-TerraMoney ([decimal]$Budget.dailyUsd)); floor $(Format-TerraMoney ([decimal]$Budget.balance.minimumUsd))" }
        'unlimited' { 'Unlimited' }
        default { 'Unknown limit' }
    }
    return "Balance: $balanceText | $limit"
}

function Save-Settings {
    $dir = Get-ConfigRoot
    [void][IO.Directory]::CreateDirectory($dir)
    $backupDir = Join-Path $dir 'config-backups'
    [void][IO.Directory]::CreateDirectory($backupDir)
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $backupDir ('terra-config-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')) -Force
    }
    $script:Settings.schemaVersion = 3
    $json = ConvertTo-Json -InputObject $script:Settings -Depth 60
    $validated = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 60
    if (-not $validated.projects -or -not $validated.budget -or -not $validated.execution -or -not $validated.logs) { throw 'Configuration validation failed.' }
    $temporary = $script:ConfigFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($json + "`n"),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$script:ConfigFile,$true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    @(Get-ChildItem -LiteralPath $backupDir -File -Filter 'terra-config-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 20) | Remove-Item -Force
    Write-Line 'Settings saved successfully.' 'Green'
}
function Test-SettingsShape($Settings) {
    return ($null -ne $Settings -and $Settings.projects -and @($Settings.projects).Count -gt 0 -and $Settings.budget -and $Settings.execution -and $Settings.logs)
}
function Get-LatestValidConfigBackup {
    $backupDir = Join-Path (Get-ConfigRoot) 'config-backups'
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) { return $null }
    foreach ($file in @(Get-ChildItem -LiteralPath $backupDir -File -Filter 'terra-config-*.json' | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $settings = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
            if (Test-SettingsShape $settings) { return $file }
        } catch { }
    }
    return $null
}
function Restore-LatestConfigBackup {
    $backup = Get-LatestValidConfigBackup
    if ($null -eq $backup) { return $false }
    Write-Line "The active configuration is invalid. Latest valid backup: $($backup.FullName)" 'Yellow'
    Write-Line "Backup timestamp: $($backup.LastWriteTime.ToString('u'))" 'Yellow'
    if (-not (Confirm 'Restore this backup?')) { return $false }
    $corrupt = $script:ConfigFile + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) { Move-Item -LiteralPath $script:ConfigFile -Destination $corrupt -Force }
    Copy-Item -LiteralPath $backup.FullName -Destination $script:ConfigFile -Force
    Write-Line "Configuration restored. Corrupt copy: $corrupt" 'Green'
    return $true
}
function Load-Settings {
    try { $script:Settings = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60 }
    catch {
        if (-not (Restore-LatestConfigBackup)) { throw "Configuration is invalid. No restore was performed; backups are in '$(Join-Path (Get-ConfigRoot) 'config-backups')'." }
        $script:Settings = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
    }
    if (-not (Test-SettingsShape $script:Settings)) { throw 'Configuration is incomplete.' }
    if ([int]$script:Settings.schemaVersion -lt 3) { $script:Settings.schemaVersion = 3 }
    if (-not $script:ProjectId -or @($script:Settings.projects | Where-Object { $_.id -eq $script:ProjectId }).Count -ne 1) { $script:ProjectId = [string]$script:Settings.projects[0].id }
}

function New-DefaultSettings([string]$ProjectId,[string]$ProjectPath,[string]$Branch,[string]$Roadmap,[string]$Progress,[string]$OpenCode,[string]$TaskIdPattern = '') {
    $root = Get-ConfigRoot
    return [ordered]@{
        schemaVersion=3; openCodeCommand=$OpenCode; agent='build'; model=''
        projects=@([ordered]@{ id=$ProjectId; path=$ProjectPath; branch=$Branch; roadmap=$Roadmap; progress=$Progress; prompt='terra-prompt.md'; taskIdPattern=$TaskIdPattern })
        budget=[ordered]@{ mode='daily'; dailyUsd=5.0; reserveUsd=0.5; emergencyStopUsd=4.95; allowUnlimited=$false; requireGlobalOpenCodeStats=$true; stopOnZeroCostWithTokens=$true; balance=[ordered]@{ source='snapshot'; id='default-account'; minimumUsd=5.0; iterationReserveUsd=0.5; maxAgeMinutes=5; command=''; arguments=@() } }
        execution=[ordered]@{ pollSeconds=20; maxIterationMinutes=45; maxIterationsPerRun=500; maxConsecutiveNoProgress=3; maxConsecutiveDocumentationOnly=12; maxToolErrorsPerIteration=15; maxTransientRetries=3; transientRetryDelaySeconds=30; maxPushRetries=3; pushRetryDelaySeconds=30; pauseBetweenIterationsSeconds=3; maxRawLogMiB=80 }
        logs=[ordered]@{ root=(Join-Path $root 'projects'); retainDays=21; maxIterationsPerProject=150; maxTotalMiBPerProject=300; reportRetainDays=60 }
    }
}
function Start-SetupWizard {
    Clear-Host
    Write-Line "Terra Runner $($script:Version) setup" 'Cyan'
    Write-Rule
    Write-Line 'This wizard saves configuration only. It never starts development or sends paid requests.' 'Gray'
    $pwshOk = $PSVersionTable.PSVersion.Major -ge 7
    $gitOk = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    Write-Line "PowerShell 7+: $(if ($pwshOk) { 'available' } else { 'missing' })" $(if ($pwshOk) { 'Green' } else { 'Red' })
    Write-Line "Git: $(if ($gitOk) { 'available' } else { 'missing' })" $(if ($gitOk) { 'Green' } else { 'Yellow' })
    $openCode = Read-Text 'OpenCode command' 'opencode' $true
    $openCodeOk = $null -ne (Get-Command $openCode -ErrorAction SilentlyContinue)
    Write-Line "OpenCode: $(if ($openCodeOk) { 'available' } else { 'not found; validation will explain how to fix it' })" $(if ($openCodeOk) { 'Green' } else { 'Yellow' })
    $path = Read-Text 'Project folder' '' $true
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Project folder does not exist.' }
    $path = (Resolve-Path -LiteralPath $path).ProviderPath
    $suggestedId = ((Split-Path $path -Leaf) -replace '[^A-Za-z0-9_.-]','-').Trim('-').ToLowerInvariant()
    if (-not $suggestedId) { $suggestedId = 'project-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
    $id = Read-Text 'Project ID' $suggestedId $true
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw 'Project ID may contain letters, numbers, dots, underscores, and hyphens.' }
    $branch = Read-Text 'Git branch' 'main' $true
    $roadmap = Read-Text 'Roadmap file' 'ROADMAP.md' $true
    $progress = Read-Text 'Progress file' 'PROGRESS.md' $true
    $taskIdPattern = Read-Text 'Optional task ID pattern (blank tracks all checklist items)'
    Write-Line 'Budget modes: 1 Daily limit, 2 Balance floor, 3 Hybrid, 4 Unlimited.' 'Gray'
    $mode = switch (Read-Choice 'Budget mode [1]') { '2' { 'balance' } '3' { 'hybrid' } '4' { 'unlimited' } default { 'daily' } }
    if ($mode -eq 'unlimited' -and -not (Confirm 'Unlimited mode removes Terra Runner monetary limits. Continue?')) { $mode = 'daily' }
    $script:Settings = New-DefaultSettings $id $path $branch $roadmap $progress $openCode $taskIdPattern
    $script:Settings.budget.mode = $mode
    $script:Settings.budget.allowUnlimited = ($mode -eq 'unlimited')
    $script:ProjectId = $id
    Write-Rule
    Write-Line "Project: $id" 'White'; Write-Line "Path: $path" 'Gray'; Write-Line "Budget mode: $mode" 'Gray'
    if (-not (Confirm 'Save these settings?')) { Write-Line 'Setup cancelled. No settings were saved.' 'Yellow'; return $false }
    Save-Settings
    return $true
}
function Initialize-Configuration {
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) { return $true }
    $legacy = Join-Path $script:Root 'terra-config.json'
    if (-not $Portable -and (Test-Path -LiteralPath $legacy -PathType Leaf) -and (Confirm 'Copy the legacy configuration to Local AppData?')) {
        [void][IO.Directory]::CreateDirectory((Get-ConfigRoot))
        Copy-Item -LiteralPath $legacy -Destination ($script:ConfigFile + '.legacy-backup') -Force
        Copy-Item -LiteralPath $legacy -Destination $script:ConfigFile -Force
        $script:Settings = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
        if (-not [IO.Path]::IsPathRooted([string]$script:Settings.logs.root)) { $script:Settings.logs.root = Join-Path (Get-ConfigRoot) 'projects' }
        foreach ($project in @($script:Settings.projects)) {
            if ($null -eq (Read-SettingMember $project 'taskIdPattern') -and [string]$project.roadmap -match '^NTD-') { $project.taskIdPattern = 'NTD-\d{4,}' }
        }
        Save-Settings
        Write-Line "Legacy settings copied to $script:ConfigFile" 'Green'
        return $true
    }
    return (Start-SetupWizard)
}

function Show-Header {
    Clear-Host
    $project = Get-SelectedProject
    Write-Line "TERRA RUNNER  $($script:Version)" 'Cyan'
    Write-Line 'Local OpenCode development orchestrator' 'DarkCyan'
    Write-Rule
    Write-Line "Project: $($project.id) | Branch: $($project.branch)" 'White'
    Write-Line "Path:    $($project.path)" 'Gray'
    $openCode = [string]$script:Settings.openCodeCommand
    $openCodeAvailable = $null -ne (Get-Command $openCode -ErrorAction SilentlyContinue)
    Write-Line "OpenCode: $(if ($openCodeAvailable) { 'available' } else { 'not found' }) | Model: $($script:Settings.model)" $(if ($openCodeAvailable) { 'Green' } else { 'Yellow' })
    $budget = $script:Settings.budget
    $last = Get-LatestSummary
    Write-Line (Get-HeaderBudgetText $budget $last) $(if ($budget.mode -eq 'unlimited') { 'Yellow' } else { 'Green' })
    $counts = Get-RoadmapCounts $project
    if ($counts) { Write-Line "Roadmap: $($counts.Done) complete, $($counts.Pending) pending" 'DarkCyan' }
    if ($last) {
        $task = Get-LatestCompletedTask
        Write-Line "Last run: $($last.id) | Last completed: $(if ($task) { $task } else { 'none recorded' })" 'DarkGray'
    }
    Write-Rule
}
function Test-DevelopmentRestartRequired($Summary, [bool]$RunnerFailed) {
    if ($RunnerFailed -or $null -eq $Summary) { return $true }
    if ([bool](Read-SettingMember $Summary 'noActionableTasksReported')) { return $true }
    $exitCode = Read-SettingMember $Summary 'exitCode'
    if ($null -ne $exitCode -and [int]$exitCode -ne 0) { return $true }
    $reason = [string](Read-SettingMember $Summary 'stoppedReason')
    if ([string]::IsNullOrWhiteSpace($reason)) { return $false }
    return $reason -notin @('roadmap-complete','stop-requested','abort-requested')
}
function Get-DevelopmentStopText($Summary, [bool]$RunnerFailed) {
    if ($RunnerFailed) { return 'runner error' }
    $reason = [string](Read-SettingMember $Summary 'stoppedReason')
    if ($reason) { return $reason }
    $blocker = [string](Read-SettingMember $Summary 'noActionableTasksMessage')
    if ($blocker) { return (($blocker -replace '\s+',' ').Trim() | Select-Object -First 1) }
    return 'unknown development error'
}
function Invoke-RunnerCommand([hashtable]$Command) {
    $isDevelopmentRun = (($Command.ContainsKey('Once') -and [bool]$Command['Once']) -or ($Command.ContainsKey('Continuous') -and [bool]$Command['Continuous']))
    while ($true) {
        $parameters = @{ Project=$script:ProjectId; Config=$script:ConfigFile }
        foreach ($key in $Command.Keys) { $parameters[$key] = $Command[$key] }
        $runnerFailed = $false
        try { & $script:Runner @parameters }
        catch { $runnerFailed = $true; Write-Line "Error: $($_.Exception.Message)" 'Red' }
        if (-not $isDevelopmentRun) { Pause-Menu; return }
        $summary = Get-LatestSummary
        if (-not (Test-DevelopmentRestartRequired $summary $runnerFailed)) { Pause-Menu; return }
        Write-Line "Development stopped: $(Get-DevelopmentStopText $summary $runnerFailed)" 'Yellow'
        if (-not (Confirm 'Reload configuration and restart this development run?')) { Pause-Menu; return }
        try {
            Load-Settings
            [void](Get-SelectedProject)
            Write-Line 'Configuration reloaded. Restarting development.' 'Cyan'
        } catch {
            Write-Line "Configuration reload failed: $($_.Exception.Message)" 'Red'
            Pause-Menu
            return
        }
    }
}
function Format-ProjectMenuEntry([int]$Number, $Project, [string]$SelectedProjectId) {
    $marker = if ([string]$Project.id -eq $SelectedProjectId) { '* ' } else { '  ' }
    return ("  {0}  {1}{2}" -f $Number,$marker,$Project.id)
}
function Show-DevelopmentMenu {
    while ($true) {
        Show-Header
        Write-Line 'Development' 'White'
        Write-Line '  1  Run one iteration' 'Green'
        Write-Line '  2  Run continuously' 'Green'
        Write-Line '  3  Validate project (dry run)' 'Cyan'
        Write-Line '  4  View development status' 'Cyan'
        Write-Line '  0  Back'
        switch (Read-Choice 'Choose an option') {
            '0' { return }
            '1' { Invoke-RunnerCommand @{ Once=$true; ShowProgress=$true } }
            '2' { if (Confirm 'Start continuous development?') { Invoke-RunnerCommand @{ Continuous=$true; ShowProgress=$true } } }
            '3' { Invoke-RunnerCommand @{ DryRun=$true } }
            '4' { Invoke-RunnerCommand @{ Status=$true } }
            default { Write-Line 'Unknown option.' 'Yellow'; Pause-Menu }
        }
    }
}
function Show-BudgetMenu {
    while ($true) {
        Show-Header; $budget = $script:Settings.budget
        Write-Line 'Budget' 'White'
        Write-Line "  1  Select mode (current: $($budget.mode))"
        Write-Line '  2  Configure daily limit and reserve'
        Write-Line '  3  Configure balance floor and reserve'
        Write-Line '  4  Set or reconcile current balance'
        Write-Line '  5  View current budget'
        Write-Line '  0  Back'
        switch (Read-Choice 'Choose an option') {
            '0' { return }
            '1' { $mode = switch (Read-Choice '1 Daily, 2 Balance, 3 Hybrid, 4 Unlimited') { '2' {'balance'} '3' {'hybrid'} '4' {'unlimited'} default {'daily'} }; if ($mode -ne 'unlimited' -or (Confirm 'Enable unlimited spending?')) { $budget.mode=$mode; $budget.allowUnlimited=($mode -eq 'unlimited'); Save-Settings } }
            '2' { $budget.dailyUsd=Read-Money 'Daily limit' ([decimal]$budget.dailyUsd) 0.01; $budget.reserveUsd=Read-Money 'Safety reserve' ([decimal]$budget.reserveUsd); if ($budget.reserveUsd -ge $budget.dailyUsd) { Write-Line 'Reserve must be below the daily limit.' 'Yellow' } else { $budget.emergencyStopUsd=$budget.dailyUsd; Save-Settings } }
            '3' { $budget.balance.minimumUsd=Read-Money 'Minimum balance' ([decimal]$budget.balance.minimumUsd); $budget.balance.iterationReserveUsd=Read-Money 'Next-iteration reserve' ([decimal]$budget.balance.iterationReserveUsd); Save-Settings }
            '4' { if ($budget.mode -notin @('balance','hybrid')) { Write-Line 'Select Balance or Hybrid mode first.' 'Yellow'; Pause-Menu; break }; $amount=Read-Money 'Actual provider balance' 0; if (Confirm "Record $(Format-TerraMoney $amount)?") { $cmd=@{ SetBalanceUsd=$amount.ToString($script:Invariant) }; if (Test-Path -LiteralPath (Join-Path (Join-Path (Get-StorageRoot) 'budgets') ($budget.balance.id + '.json'))) { $cmd.ReconcileBalance=$true }; Invoke-RunnerCommand $cmd } }
            '5' { Invoke-RunnerCommand @{ Status=$true } }
            default { Write-Line 'Unknown option.' 'Yellow'; Pause-Menu }
        }
    }
}
function Show-ProjectsMenu {
    while ($true) {
        Show-Header; $projects=@($script:Settings.projects)
        Write-Line 'Projects' 'White'
        for ($i=0; $i -lt $projects.Count; $i++) { Write-Line (Format-ProjectMenuEntry ($i + 1) $projects[$i] $script:ProjectId) }
        Write-Line '  A  Add project'; Write-Line '  E  Edit selected project'; Write-Line '  R  Remove selected project'; Write-Line '  0  Back'
        $choice=Read-Choice 'Choose an option'
        if ($choice -eq '0') { return }
        if ($choice -eq 'a') { $path=Read-Text 'Project folder' '' $true; if (-not (Test-Path -LiteralPath $path -PathType Container)) { Write-Line 'Folder does not exist.' 'Yellow'; Pause-Menu; continue }; $path=(Resolve-Path -LiteralPath $path).ProviderPath; $id=Read-Text 'Project ID' ((Split-Path $path -Leaf) -replace '[^A-Za-z0-9_.-]','-') $true; if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or @($projects | Where-Object id -eq $id).Count) { Write-Line 'Project ID is invalid or already in use.' 'Yellow'; Pause-Menu; continue }; $script:Settings.projects += [ordered]@{ id=$id; path=$path; branch=(Read-Text 'Git branch' 'main' $true); roadmap=(Read-Text 'Roadmap file' 'ROADMAP.md' $true); progress=(Read-Text 'Progress file' 'PROGRESS.md' $true); prompt='terra-prompt.md'; taskIdPattern=(Read-Text 'Optional task ID pattern') }; $script:ProjectId=$id; Save-Settings; continue }
        if ($choice -eq 'e') { $p=Get-SelectedProject; $p.path=Read-Text 'Project folder' $p.path $true; $p.branch=Read-Text 'Git branch' $p.branch $true; $p.roadmap=Read-Text 'Roadmap file' $p.roadmap $true; $p.progress=Read-Text 'Progress file' $p.progress $true; $p.taskIdPattern=Read-Text 'Optional task ID pattern' ([string](Read-SettingMember $p 'taskIdPattern')); Save-Settings; continue }
        if ($choice -eq 'r') { if ($projects.Count -eq 1) { Write-Line 'At least one project must remain configured.' 'Yellow'; Pause-Menu; continue }; if (Confirm "Remove configuration for $($script:ProjectId)? Project files will not be deleted.") { $script:Settings.projects=@($projects | Where-Object id -ne $script:ProjectId); $script:ProjectId=[string]$script:Settings.projects[0].id; Save-Settings }; continue }
        $index=0; if ([int]::TryParse($choice,[ref]$index) -and $index -ge 1 -and $index -le $projects.Count) { $script:ProjectId=[string]$projects[$index-1].id }
    }
}
function Show-SettingsMenu {
    while ($true) {
        Show-Header; $e=$script:Settings.execution; $l=$script:Settings.logs
        Write-Line 'Settings' 'White'; Write-Line '  1  OpenCode command and model'; Write-Line '  2  Iteration limits and timeout'; Write-Line '  3  Logging and retention'; Write-Line '  4  Run setup wizard again'; Write-Line '  0  Back'
        switch (Read-Choice 'Choose an option') {
            '0' { return }
            '1' { $script:Settings.openCodeCommand=Read-Text 'OpenCode command' $script:Settings.openCodeCommand $true; $script:Settings.model=Read-Text 'Model (optional)' $script:Settings.model; $script:Settings.agent=Read-Text 'Agent' $script:Settings.agent $true; Save-Settings }
            '2' { $e.maxIterationsPerRun=Read-Integer 'Maximum iterations per run' $e.maxIterationsPerRun 1 1000; $e.maxIterationMinutes=Read-Integer 'Iteration timeout in minutes' $e.maxIterationMinutes 1 1440; $e.pollSeconds=Read-Integer 'Poll interval in seconds' $e.pollSeconds 1 300; Save-Settings }
            '3' { $l.retainDays=Read-Integer 'Log retention in days' $l.retainDays 1; $l.maxIterationsPerProject=Read-Integer 'Maximum saved iterations' $l.maxIterationsPerProject 1; $l.maxTotalMiBPerProject=Read-Integer 'Maximum project log size in MiB' $l.maxTotalMiBPerProject 1; Save-Settings }
            '4' { if (Confirm 'Replace current settings through setup?') { if (Start-SetupWizard) { Load-Settings } } }
            default { Write-Line 'Unknown option.' 'Yellow'; Pause-Menu }
        }
    }
}
function Show-ReportsMenu {
    while ($true) {
        Show-Header; Write-Line 'Reports' 'White'; Write-Line "  1  Today's report"; Write-Line '  2  Report for a date'; Write-Line '  3  Open project logs folder'; Write-Line '  0  Back'
        switch (Read-Choice 'Choose an option') {
            '0' { return }
            '1' { Invoke-RunnerCommand @{ Report=$true } }
            '2' { $date=Read-Text 'Date (YYYY-MM-DD)' '' $true; Invoke-RunnerCommand @{ Report=$true; ReportDate=$date } }
            '3' { $logs=Join-Path (Get-ProjectDataRoot) 'logs'; [void][IO.Directory]::CreateDirectory($logs); if ($IsWindows) { Invoke-Item -LiteralPath $logs } else { Write-Line $logs 'Cyan'; Pause-Menu } }
            default { Write-Line 'Unknown option.' 'Yellow'; Pause-Menu }
        }
    }
}
function Invoke-UiSelfTest {
    foreach ($file in @($script:Runner,(Join-Path $script:Root 'terra-ui.ps1'),(Join-Path $script:Root 'terra-core.psm1'))) {
        $tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Parser errors in ${file}: $($errors -join '; ')" }
    }
    $money = ConvertTo-TerraMoney -Text '96,11'
    if ((Format-TerraMoney -Amount $money) -ne '$96.11') { throw 'Money parser or formatter failed.' }
    $selected = [pscustomobject]@{ id='selected-project' }
    $other = [pscustomobject]@{ id='other-project' }
    if ((Format-ProjectMenuEntry 1 $selected 'selected-project') -ne '  1  * selected-project') { throw 'Selected project menu rendering failed.' }
    if ((Format-ProjectMenuEntry 2 $other 'selected-project') -ne '  2    other-project') { throw 'Unselected project menu rendering failed.' }
    Write-Line 'PASS: UI, runner, and core scripts parse successfully.' 'Green'
    Write-Line 'PASS: English UI text, money, and project list formatting are valid.' 'Green'
}

if (-not (Test-Path -LiteralPath $script:Runner -PathType Leaf)) { throw "Runner is missing: $script:Runner" }
if ($SelfTest) { Invoke-UiSelfTest; return }
if (-not (Initialize-Configuration)) { Write-Line 'Setup cancelled.'; return }
Load-Settings
while ($true) {
    Show-Header
    Write-Line 'Main menu' 'White'
    Write-Line '  1  Development' 'Green'; Write-Line '  2  Projects'; Write-Line '  3  Budget'; Write-Line '  4  Settings'; Write-Line '  5  Reports'; Write-Line '  6  System diagnostics'; Write-Line '  S  Stop after the current iteration' 'Yellow'; Write-Line '  A  Emergency stop' 'Red'; Write-Line '  0  Exit'
    switch (Read-Choice 'Choose an option') {
        '0' { return }
        '1' { Show-DevelopmentMenu }
        '2' { Show-ProjectsMenu }
        '3' { Show-BudgetMenu }
        '4' { Show-SettingsMenu }
        '5' { Show-ReportsMenu }
        '6' { Invoke-UiSelfTest; Pause-Menu }
        's' { Invoke-RunnerCommand @{ Stop=$true } }
        'a' { if (Confirm 'Emergency stop the active iteration?') { Invoke-RunnerCommand @{ Abort=$true } } }
        default { Write-Line 'Unknown option.' 'Yellow'; Pause-Menu }
    }
}
