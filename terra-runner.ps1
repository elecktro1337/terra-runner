<#
.SYNOPSIS
    Terra Runner: one OpenCode Build iteration at a time with a project-scoped log store.
.DESCRIPTION
    Requires PowerShell 7 and OpenCode v2 with JSON usage statistics.
    Budget modes: daily, balance (manual snapshot or external command), hybrid, unlimited.
    Balance snapshots use global *local OpenCode* lifetime costs; they are NOT live provider billing.
    This is not a provider-side billing hard limit.
.EXAMPLE
    ./terra-runner.ps1 -Project ntd-terra -Once
.EXAMPLE
    ./terra-runner.ps1 -Project ntd-terra
.EXAMPLE
    ./terra-runner.ps1 -Project ntd-terra -Status
.EXAMPLE
    ./terra-runner.ps1 -Project ntd-terra -Stop
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Project = 'ntd-terra',
    [string]$Config = '',
    [switch]$Portable,
    [switch]$Once,
    [switch]$Continuous,
    [switch]$DryRun,
    [switch]$Status,
    [switch]$Stop,
    [switch]$Abort,
    [switch]$ClearStop,
    [switch]$Report,
    [string]$ReportDate = '',
    [string]$SetBalanceUsd = '',
    [switch]$ReconcileBalance,
    [switch]$ShowProgress,
    [ValidateRange(0, 1000)][int]$MaxIterations = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ is required. Run with pwsh.' }
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir 'terra-core.psm1') -Force -ErrorAction Stop
$Config = Resolve-TerraConfigPath -Config $Config -Portable:$Portable -InstallRoot $ScriptDir
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw "Configuration not found: $Config. Start Terra Runner without CLI arguments to run Setup Wizard."
}
$hasSetBalance = -not [string]::IsNullOrWhiteSpace($SetBalanceUsd)
$setBalanceAmount = $null
if ($hasSetBalance) { $setBalanceAmount = ConvertTo-TerraMoney -Text $SetBalanceUsd }
if ($Once -and $Continuous) { throw 'Use either -Once or -Continuous, not both.' }
if ($ReconcileBalance -and -not $hasSetBalance) { throw '-ReconcileBalance requires -SetBalanceUsd.' }

function Ensure-Directory([string]$Path) {
    [void][System.IO.Directory]::CreateDirectory($Path)
}
function Require-PositiveNumber($Value, [string]$Name) {
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -le 0) {
        throw "Invalid positive setting: $Name"
    }
    return $d
}
function Read-Member($Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $p = $Value.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}
function Read-Cost($Stats) {
    $direct = Read-Member $Stats 'totalCost'
    if ($null -eq $direct) { $direct = Read-Member $Stats 'total_cost' }
    if ($null -eq $direct) { $direct = Read-Member $Stats 'totalUSD' }
    if ($null -eq $direct) {
        $totals = Read-Member $Stats 'totals'
        $direct = Read-Member $totals 'cost'
    }
    if ($null -eq $direct) {
        # OpenCode v2.2.5: { "cost": 1.4040467, "tokens": { ... } }.
        # Older/alternative formats may expose cost as { total: ... }.
        $costNode = Read-Member $Stats 'cost'
        if ($costNode -is [System.Collections.IDictionary]) {
            $direct = Read-Member $costNode 'total'
        } elseif ($null -ne $costNode) {
            $direct = $costNode
        }
    }
    if ($null -eq $direct -or $direct -is [bool]) { throw 'Stats JSON does not expose a recognized total cost field; refusing to guess.' }
    try { $cost = [double]::Parse([string]$direct, $Invariant) }
    catch { throw 'OpenCode stats cost is not a valid number.' }
    if ([double]::IsNaN($cost) -or [double]::IsInfinity($cost) -or $cost -lt 0) {
        throw 'OpenCode stats contains an invalid cost value.'
    }
    return $cost
}
function Read-Tokens($Stats) {
    $tokenNode = Read-Member $Stats 'totalTokens'
    if ($null -eq $tokenNode) { $tokenNode = Read-Member $Stats 'total_tokens' }
    if ($null -eq $tokenNode) { $tokenNode = Read-Member $Stats 'tokens' }
    if ($null -eq $tokenNode) { throw 'OpenCode stats lacks token totals; refusing to assume usage is zero.' }
    if ($tokenNode -is [ValueType]) { return [double]$tokenNode }
    $sum = 0.0
    $found = $false
    foreach ($name in @('input','output','reasoning','total')) {
        $value = Read-Member $tokenNode $name
        if ($null -ne $value) {
            if ($name -eq 'total') { return [double]$value }
            $sum += [double]$value
            $found = $true
        }
    }
    $cache = Read-Member $tokenNode 'cache'
    foreach ($name in @('read','write')) {
        $value = Read-Member $cache $name
        if ($null -ne $value) { $sum += [double]$value; $found = $true }
    }
    if (-not $found) { throw 'Unrecognized token summary in OpenCode stats.' }
    if ([double]::IsNaN($sum) -or [double]::IsInfinity($sum) -or $sum -lt 0) {
        throw 'Invalid token summary.'
    }
    return $sum
}
function Invoke-Cli([string]$Executable, [string[]]$Arguments, [string]$Directory) {
    Push-Location -LiteralPath $Directory
    try {
        $lines = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($exitCode -ne 0) { throw "Command '$Executable $($Arguments -join ' ')' failed (exit $exitCode): $($lines -join ' ')" }
    return [string]::Join("`n", [string[]]@($lines))
}
function Get-Usage([string]$Executable, [string]$Directory, $Settings, [string]$Scope = 'day') {
    $usageArgs = if ($Scope -eq 'all') { @('stats','--all','--json') }
            elseif ($Scope -eq 'day') { @('stats','--days','0','--json') }
            else { throw "Unsupported usage scope: $Scope" }
    # No --project: a shared locally-recorded OpenCode budget must cover all projects.
    $json = Invoke-Cli $Executable $usageArgs $Directory
    try { $stats = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 60 }
    catch { throw "OpenCode $Scope usage statistics did not return valid JSON." }
    $cost = Read-Cost $stats
    $tokens = Read-Tokens $stats
    if ([bool]$Settings.stopOnZeroCostWithTokens -and $tokens -gt 0 -and $cost -eq 0) {
        throw "OpenCode $Scope statistics contain tokens with zero cost. Cannot safely enforce a paid budget."
    }
    return [pscustomobject]@{
        Scope = $Scope; Day = (Get-Date).ToString('yyyy-MM-dd')
        CostUSD = $cost; Tokens = $tokens; CheckedAt = (Get-Date).ToString('o')
    }
}
function Get-Head([string]$Directory) {
    return (Invoke-Cli 'git' @('-C', $Directory, 'rev-parse', 'HEAD') $Directory).Trim()
}
function Confirm-RemotePush([string]$Directory, [string]$Branch) {
    $head = Get-Head $Directory
    $line = Invoke-Cli 'git' @('-C',$Directory,'ls-remote','--heads','origin',"refs/heads/$Branch") $Directory
    $first = @($line -split "`n" | Where-Object { $_ -match '^[0-9a-f]{40,64}\s+' }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$first)) { return $false }
    $remoteHead = ($first -split '\s+')[0]
    return $remoteHead -ceq $head
}
function Get-EventErrors([string]$EventsFile) {
    $streamErrors = 0
    $toolErrorIds = [System.Collections.Generic.HashSet[string]]::new()
    $verificationIds = [System.Collections.Generic.HashSet[string]]::new()
    $verificationErrors = 0
    $verificationExamples = [System.Collections.Generic.List[string]]::new()
    $noTasks = $false
    $toolExamples = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($EventsFile, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 60 }
        catch { throw 'Malformed OpenCode JSON event detected. Review raw event log.' }
        $eventType = [string](Read-Member $event 'type')
        if ($eventType -eq 'error') { $streamErrors++ }
        $part = Read-Member $event 'part'
        if ($eventType -eq 'tool_use') {
            $state = Read-Member $part 'state'
            $toolStatus = [string](Read-Member $state 'status')
            $input = Read-Member $state 'input'
            $commandLine = [string](Read-Member $input 'command')
            if ($commandLine -match '(?i)(phpunit|phpstan|phpcs|composer\s+validate|php\s+-l\b|npm\s+(test|run\s+test)|pytest|git\s+diff\s+--check)') {
                $checkId = [string](Read-Member $part 'id')
                if ([string]::IsNullOrWhiteSpace($checkId)) { $checkId = [string](Read-Member $part 'partID') }
                if ($verificationIds.Add($checkId)) {
                    if ($toolStatus -eq 'error') { $verificationErrors++ }
                    if ($verificationExamples.Count -lt 5) { $verificationExamples.Add($commandLine.Substring(0,[Math]::Min(150,$commandLine.Length))) }
                }
            }
            if ($toolStatus -eq 'error') {
                $id = [string](Read-Member $part 'id')
                if ([string]::IsNullOrWhiteSpace($id)) { $id = [string](Read-Member $part 'partID') }
                if ([string]::IsNullOrWhiteSpace($id)) { $id = 'unknown-' + $toolErrorIds.Count }
                if ($toolErrorIds.Add($id) -and $toolExamples.Count -lt 5) {
                    $toolExamples.Add([string](Read-Member $part 'tool'))
                }
            }
        }
        if ($eventType -eq 'text') {
            $body = [string](Read-Member $part 'text')
            if ($body -match '\bNO_ACTIONABLE_TASKS\b') { $noTasks = $true }
        }
    }
    return [pscustomobject]@{
        Errors = $streamErrors; ToolErrors = $toolErrorIds.Count
        ToolErrorExamples = @($toolExamples.ToArray()); NoTasks = $noTasks
        VerificationCommands = $verificationIds.Count; VerificationCommandErrors = $verificationErrors
        VerificationExamples = @($verificationExamples.ToArray())
    }
}
function Test-RoadmapTask([string]$Line, [bool]$Completed, [string]$TaskIdPattern = '') {
    $checkbox = if ($Completed) { '^\s*-\s*\[[xX]\]' } else { '^\s*-\s*\[ \]' }
    if ($Line -notmatch $checkbox) { return $false }
    if ([string]::IsNullOrWhiteSpace($TaskIdPattern)) { return $true }
    try { return $Line -match $TaskIdPattern }
    catch { throw "Invalid project taskIdPattern: $TaskIdPattern" }
}
function Count-Completed([string]$RoadmapFile, [string]$TaskIdPattern = '') {
    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($RoadmapFile)) {
        if (Test-RoadmapTask $line $true $TaskIdPattern) { $count++ }
    }
    return $count
}
function Count-Pending([string]$RoadmapFile, [string]$TaskIdPattern = '') {
    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($RoadmapFile)) {
        if (Test-RoadmapTask $line $false $TaskIdPattern) { $count++ }
    }
    return $count
}
function Rotate-ProjectLogs([string]$LogsDirectory, $Settings) {
    if (-not (Test-Path -LiteralPath $LogsDirectory)) { return }
    $files = @(Get-ChildItem -LiteralPath $LogsDirectory -Recurse -File | Where-Object {
        $_.Name -match '\.(events\.jsonl|events\.readable\.jsonl|stderr\.log|summary\.json)$'
    })
    if ($files.Count -eq 0) { return }
    $bundles = @($files | Group-Object {
        $_.DirectoryName + [System.IO.Path]::DirectorySeparatorChar + ($_.Name -replace '\.(events\.jsonl|events\.readable\.jsonl|stderr\.log|summary\.json)$','')
    } | ForEach-Object {
        $members = @($_.Group)
        [pscustomobject]@{
            Files = $members
            LastWrite = ($members | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
            Bytes = ($members | Measure-Object Length -Sum).Sum
        }
    } | Sort-Object LastWrite -Descending)
    $expiry = [datetime]::UtcNow.AddDays(-[double]$Settings.retainDays)
    $maxBundles = [int]$Settings.maxIterationsPerProject
    $maxBytes = [double]$Settings.maxTotalMiBPerProject * 1MB
    $runningBytes = 0.0
    $kept = 0
    foreach ($bundle in $bundles) {
        $shouldRemove = $bundle.LastWrite -lt $expiry -or $kept -ge $maxBundles -or ($runningBytes + $bundle.Bytes) -gt $maxBytes
        if ($shouldRemove) {
            foreach ($item in $bundle.Files) { Remove-Item -LiteralPath $item.FullName -Force }
        } else {
            $kept++
            $runningBytes += [double]$bundle.Bytes
        }
    }
    Get-ChildItem -LiteralPath $LogsDirectory -Recurse -Directory |
        Sort-Object FullName -Descending | ForEach-Object {
            if (-not @(Get-ChildItem -LiteralPath $_.FullName -Force).Count) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
}
function Save-Json([string]$Filename, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 25
    [System.IO.File]::WriteAllText($Filename, ($json + "`n"), [System.Text.UTF8Encoding]::new($false))
}
function Stop-Child([System.Diagnostics.Process]$Child) {
    try {
        if (-not $Child.HasExited) { $Child.Kill($true); [void]$Child.WaitForExit(10000) }
    } catch { Write-Warning "Unable to terminate child process tree: $($_.Exception.Message)" }
}
function Require-NonNegativeNumber($Value, [string]$Name) {
    if ($null -eq $Value) { throw "Missing setting: $Name" }
    try { $d = [double]$Value } catch { throw "Invalid number: $Name" }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -lt 0) { throw "Invalid non-negative setting: $Name" }
    return $d
}
function Get-BudgetMode($Settings) {
    $m = [string](Read-Member $Settings 'mode')
    if ([string]::IsNullOrWhiteSpace($m)) { $m = 'daily' } # schema v1 compatibility
    if ($m -cnotin @('daily','balance','hybrid','unlimited')) { throw "Unsupported budget mode '$m'." }
    if ($m -eq 'unlimited' -and -not [bool](Read-Member $Settings 'allowUnlimited')) {
        throw 'Unrestricted spending requires explicit budget.allowUnlimited=true.'
    }
    return $m
}
function Get-BalanceStatePath([string]$Root, $Settings) {
    $id = [string](Read-Member $Settings 'id')
    if ($id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Unsafe or missing balance.id' }
    return Join-Path (Join-Path $Root 'budgets') ($id + '.json')
}
function Get-LiveBalance($Settings) {
    $command = [string](Read-Member $Settings 'command')
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'balance.command is required for balance.source=command.' }
    $commandArgs = @()
    foreach ($argument in @((Read-Member $Settings 'arguments'))) {
        if ($null -ne $argument) { $commandArgs += [string]$argument }
    }
    $raw = Invoke-Cli $command ([string[]]$commandArgs) $ScriptDir
    try { $value = ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 20 }
    catch { throw 'Balance command must output one valid JSON object.' }
    $amount = Read-Member $value 'balanceUsd'
    [void](Require-NonNegativeNumber $amount 'balance command balanceUsd')
    $observed = [string](Read-Member $value 'observedAt')
    try { $at = [DateTimeOffset]::Parse($observed, $Invariant) }
    catch { throw 'Balance command must return observedAt in ISO 8601 with timezone.' }
    $lag = ([DateTimeOffset]::UtcNow - $at.ToUniversalTime()).TotalMinutes
    $maxLag = Require-PositiveNumber (Read-Member $Settings 'maxAgeMinutes') 'balance.maxAgeMinutes'
    if ($lag -lt -2 -or $lag -gt $maxLag) { throw "Balance provider observation is not recent (age $([Math]::Round($lag,1)) minutes)." }
    return [pscustomobject]@{ AmountUSD=[double]$amount; Source='external-command'; ObservedAt=$observed }
}
function Set-BalanceSnapshot([string]$File, [double]$Amount, $Usage, [bool]$Overwrite) {
    [void](Require-NonNegativeNumber $Amount 'SetBalanceUsd')
    if ((Test-Path -LiteralPath $File) -and -not $Overwrite) {
        throw "Balance snapshot already exists ($File). Use -ReconcileBalance to intentionally reset it after checking the REAL provider balance."
    }
    Ensure-Directory (Split-Path -Parent $File)
    if ($Overwrite -and (Test-Path -LiteralPath $File)) {
        $history = $File -replace '\.json$', '.history.jsonl'
        $existing = Get-Content -LiteralPath $File -Raw -Encoding UTF8
        [System.IO.File]::AppendAllText($history, ($existing.Trim() -replace "`r?`n",'') + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    Save-Json $File ([ordered]@{
        formatVersion=1; observedBalanceUsd=$Amount; baselineAllTimeCostUsd=[double]$Usage.CostUSD
        observedAt=(Get-Date).ToString('o'); accounting='estimated-from-local-opencode-all-time'
    })
}
function Get-BudgetSnapshot([string]$Executable, [string]$Directory, $Budget, [string]$Root) {
    $mode = Get-BudgetMode $Budget
    $day = Get-Usage $Executable $Directory $Budget 'day'
    $all = Get-Usage $Executable $Directory $Budget 'all'
    $balance = $null; $source = ''; $observedAt = ''
    if ($mode -in @('balance','hybrid')) {
        $settings = Read-Member $Budget 'balance'
        if ($null -eq $settings) { throw 'budget.balance settings are required.' }
        $balanceSource = [string](Read-Member $settings 'source')
        if ($balanceSource -eq 'snapshot') {
            $file = Get-BalanceStatePath $Root $settings
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                throw "No balance snapshot at '$file'. Run -SetBalanceUsd 100 (with your actual balance) once, BEFORE starting the agent."
            }
            $state = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $baseline = Require-NonNegativeNumber (Read-Member $state 'baselineAllTimeCostUsd') 'balance baseline'
            $starting = Require-NonNegativeNumber (Read-Member $state 'observedBalanceUsd') 'observed balance'
            if ($all.CostUSD + 0.000001 -lt $baseline) {
                throw 'OpenCode all-time usage decreased since the balance snapshot. Cannot safely estimate the remaining balance.'
            }
            $balance = [Math]::Max(0.0, ($starting - ($all.CostUSD - $baseline)))
            $source = 'local-estimate'; $observedAt = [string](Read-Member $state 'observedAt')
        } elseif ($balanceSource -eq 'command') {
            $live = Get-LiveBalance $settings
            $balance = $live.AmountUSD; $source = $live.Source; $observedAt = $live.ObservedAt
        } else { throw "Unsupported balance.source '$balanceSource'. Use snapshot or command." }
    }
    return [pscustomobject]@{
        Mode=$mode; Daily=$day; AllTime=$all; BalanceUSD=$balance
        BalanceSource=$source; BalanceObservedAt=$observedAt
    }
}
function Get-BudgetStopReason($Snapshot, $Budget, [bool]$Emergency) {
    $mode = $Snapshot.Mode
    if ($mode -in @('daily','hybrid')) {
        $cap = [double]$Budget.dailyUsd
        $reserve = [double]$Budget.reserveUsd
        $cutoff = if ($Emergency) { [double]$Budget.emergencyStopUsd } else { $cap - $reserve }
        if ($Snapshot.Daily.CostUSD -ge $cutoff) {
            return "daily budget threshold reached (spent $($Snapshot.Daily.CostUSD), threshold $cutoff)"
        }
    }
    if ($mode -in @('balance','hybrid')) {
        $floor = [double]$Budget.balance.minimumUsd
        $iterationReserve = [double]$Budget.balance.iterationReserveUsd
        $cutoff = if ($Emergency) { $floor } else { $floor + $iterationReserve }
        if ($Snapshot.BalanceUSD -le $cutoff) {
            return "balance threshold reached (estimated $($Snapshot.BalanceUSD), threshold $cutoff)"
        }
    }
    return ''
}
function Show-Usage($Snapshot, $Budget) {
    $usage = $Snapshot.Daily
    $message = ('Day {0}: OpenCode cost ${1:N4}; tokens {2:N0}' -f $usage.Day,$usage.CostUSD,$usage.Tokens)
    if ($Snapshot.Mode -in @('daily','hybrid')) {
        $remaining = [Math]::Max(0.0, [double]$Budget.dailyUsd - [double]$usage.CostUSD)
        $message += ('; daily remaining ${0:N4}' -f $remaining)
    }
    if ($Snapshot.Mode -in @('balance','hybrid')) {
        $spendable = [Math]::Max(0.0, [double]$Snapshot.BalanceUSD - [double]$Budget.balance.minimumUsd)
        $message += ('; {0} balance ${1:N4}, above floor ${2:N4}' -f $Snapshot.BalanceSource,$Snapshot.BalanceUSD,$spendable)
    }
    if ($Snapshot.Mode -eq 'unlimited') { $message += '; NO MONETARY LIMIT ENABLED' }
    Write-Host $message
    Show-ProgressMeters $Snapshot $Budget
}
function Show-ProgressMeters($Snapshot, $Budget) {
    if (-not $ShowProgress) { return }
    if ($Snapshot.Mode -in @('daily','hybrid')) {
        $cap = [double]$Budget.dailyUsd
        $spent = [double]$Snapshot.Daily.CostUSD
        if ($cap -gt 0) {
            $ratio = [Math]::Min(1.0,[Math]::Max(0.0,$spent/$cap))
            $filled = [Math]::Min(26,[Math]::Max(0,[int][Math]::Round($ratio*26)))
            Write-Host ('  DAILY   [{0}{1}] {2:N1}% (${3:N2} / ${4:N2})' -f ('█'*$filled),('░'*(26-$filled)),($ratio*100),$spent,$cap) -ForegroundColor $(if ($ratio -ge 0.9) { 'Yellow' } else { 'Cyan' })
        }
    }
    if ($Snapshot.Mode -in @('balance','hybrid') -and $null -ne $Snapshot.BalanceUSD) {
        $remaining = [double]$Snapshot.BalanceUSD
        $floor = [double]$Budget.balance.minimumUsd
        $reserve = [double]$Budget.balance.iterationReserveUsd
        Write-Host ('  BALANCE ${0:N2} | protected ${1:N2} | next-run reserve ${2:N2}' -f $remaining,$floor,$reserve) -ForegroundColor 'Cyan'
    }
    if ($Snapshot.Mode -eq 'unlimited') {
        Write-Host '  WARNING: unlimited spending is enabled.' -ForegroundColor Yellow
    }
}
function Show-IterationProgress([int]$Current, [int]$Total, [timespan]$Elapsed, [double]$MaximumMinutes, [int]$Pending) {
    if (-not $ShowProgress) { return }
    $overallPercent = [Math]::Min(100,[int][Math]::Floor((($Current-1)/[double]$Total)*100))
    $timePercent = [Math]::Min(99,[Math]::Max(0,[int][Math]::Floor(($Elapsed.TotalMinutes/$MaximumMinutes)*100)))
    Write-Progress -Id 1 -Activity 'Terra Runner | development cycle' -Status ("Iteration $Current of $Total | $Pending tasks pending") -PercentComplete $overallPercent
    Write-Progress -Id 2 -ParentId 1 -Activity 'OpenCode | current iteration' -Status ('Elapsed {0:mm\:ss} | timeout {1:N0} min' -f $Elapsed,$MaximumMinutes) -PercentComplete $timePercent
}
function Fix-MojibakeText([string]$Value) {
    if ($Value -notmatch '[╨╤]') { return $Value }
    try {
        $enc = [System.Text.Encoding]::GetEncoding(866)
        $strict = [System.Text.UTF8Encoding]::new($false,$true)
        $fixed = $strict.GetString($enc.GetBytes($Value))
        if ($fixed -match '[А-Яа-яЁё]' -and $fixed -notmatch '[╨╤]') { return $fixed }
    } catch { }
    return $Value
}
function Fix-MojibakeNode($Node) {
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return (Fix-MojibakeText $Node) }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { $Node[$k] = Fix-MojibakeNode $Node[$k] }
        return $Node
    }
    if ($Node -is [array]) {
        for ($n=0; $n -lt $Node.Count; $n++) { $Node[$n] = Fix-MojibakeNode $Node[$n] }
        return $Node
    }
    return $Node
}
function Write-ReadableEvents([string]$RawFile, [string]$ReadableFile) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.IO.StreamWriter]::new($ReadableFile,$false,$utf8)
    try {
        foreach ($line in [System.IO.File]::ReadLines($RawFile, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 60
                $fixed = Fix-MojibakeNode $event
                $writer.WriteLine((ConvertTo-Json -InputObject $fixed -Compress -Depth 60))
            } catch {
                # Raw data remains untouched, skip unparseable event in the readable derivative.
                $writer.WriteLine($line)
            }
        }
    } finally { $writer.Dispose() }
}
function Get-ChangedFiles([string]$Directory, [string]$From, [string]$To) {
    if ($From -eq $To) { return [pscustomobject]@{ Code=0; Docs=0; Tests=0; Other=0; Paths=@() } }
    $output = Invoke-Cli 'git' @('-C',$Directory,'diff','--name-only',$From,$To) $Directory
    $paths = @($output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $code = 0; $docs = 0; $tests = 0; $other = 0
    foreach ($path in $paths) {
        $normalized = $path -replace '\\','/'
        if ($normalized -match '(^|/)(tests?|specs?)/' -or $normalized -match '(Test|Spec)\.(php|js|ts|ps1)$') { $tests++ }
        elseif ($normalized -match '(?i)\.(php|js|mjs|cjs|ts|tsx|jsx|css|scss|sql|py|ps1|sh|html|twig)$') { $code++ }
        elseif ($normalized -match '(?i)\.(md|rst|adoc|txt|pdf)$' -or $normalized -match '(^|/)docs/') { $docs++ }
        else { $other++ }
    }
    return [pscustomobject]@{ Code=$code; Docs=$docs; Tests=$tests; Other=$other; Paths=$paths }
}
function Get-CompletionIds([string]$Directory, [string]$RoadmapFile, [string]$BeforeHead, [string]$TaskIdPattern = '') {
    if ([string]::IsNullOrWhiteSpace($TaskIdPattern)) { return @() }
    $relative = [IO.Path]::GetRelativePath($Directory, $RoadmapFile).Replace('\','/')
    $old = Invoke-Cli 'git' @('-C',$Directory,'show',("${BeforeHead}:$relative")) $Directory
    $new = Get-Content -LiteralPath $RoadmapFile -Raw -Encoding UTF8
    try { $regex = [regex]::new('(?m)^\s*-\s*\[[xX]\].*?(' + $TaskIdPattern + ')') }
    catch { throw "Invalid project taskIdPattern: $TaskIdPattern" }
    $already = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in $regex.Matches($old)) { [void]$already.Add($match.Groups[1].Value) }
    $justDone = [System.Collections.Generic.List[string]]::new()
    foreach ($match in $regex.Matches($new)) {
        $id = $match.Groups[1].Value
        if (-not $already.Contains($id) -and -not $justDone.Contains($id)) { $justDone.Add($id) }
    }
    return @($justDone.ToArray())
}
function Get-CommitsInIteration([string]$Directory, [string]$From, [string]$To) {
    if ($From -eq $To) { return @() }
    $text = Invoke-Cli 'git' @('-C',$Directory,'log','--format=%h%x09%s',"$From..$To") $Directory
    $commits = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($text -split "`n")) {
        $parts = $line -split "`t",2
        if ($parts.Count -eq 2) { $commits.Add([pscustomobject]@{ hash=$parts[0]; subject=$parts[1] }) }
    }
    return @($commits.ToArray())
}
function Write-DailyReport([string]$DataDirectory, [string]$Date) {
    if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'ReportDate must be YYYY-MM-DD.' }
    $dir = Join-Path (Join-Path $DataDirectory 'logs') $Date
    $summaries = @()
    if (Test-Path -LiteralPath $dir) {
        $summaries = @(Get-ChildItem -LiteralPath $dir -Filter '*.summary.json' -File | Sort-Object Name |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable })
    }
    $reportsDir = Join-Path $DataDirectory 'reports'
    Ensure-Directory $reportsDir
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add('# Terra Runner — ' + $Date)
    $rows.Add('')
    $rows.Add('Проект: **' + (Split-Path $DataDirectory -Leaf) + '**')
    $rows.Add('')
    $costTotal = 0.0; $tasks = 0; $pushes = 0; $code = 0; $docs = 0; $tests = 0; $toolErrors = 0; $verifications = 0
    $allTaskIds = [System.Collections.Generic.HashSet[string]]::new()
    $allCommitNames = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $summaries) {
        $delta = Read-Member $s 'costDeltaUSD'
        if ($null -ne $delta) { $costTotal += [double]$delta }
        $tasks += [Math]::Max(0, [int](Read-Member $s 'doneAfter') - [int](Read-Member $s 'doneBefore'))
        if ([bool](Read-Member $s 'pushVerified')) { $pushes++ }
        $code += [int](Read-Member $s 'codeFilesChanged')
        $docs += [int](Read-Member $s 'documentationFilesChanged')
        $tests += [int](Read-Member $s 'testFilesChanged')
        $toolErrors += [int](Read-Member $s 'toolErrors')
        $verifications += [int](Read-Member $s 'verificationCommandsObserved')
        foreach ($id in @((Read-Member $s 'completedTaskIds'))) { if ($id) { [void]$allTaskIds.Add([string]$id) } }
        foreach ($commit in @((Read-Member $s 'commits'))) {
            if ($null -ne $commit) { $allCommitNames.Add(([string](Read-Member $commit 'hash') + ' ' + [string](Read-Member $commit 'subject'))) }
        }
    }
    $rows.Add(('- Итераций: **{0}**; закрыто TODO: **{1}**; подтверждённых push: **{2}**' -f $summaries.Count,$tasks,$pushes))
    $rows.Add(('- Локальная стоимость за итерации: **${0:N4}** (не включает ручные сессии и внешние расходы)' -f $costTotal))
    $rows.Add(('- Изменения: код **{0}**, тесты **{1}**, документация **{2}** файлов; ошибок инструментов **{3}**; обнаружено команд проверки **{4}**' -f $code,$tests,$docs,$toolErrors,$verifications))
    if ($allTaskIds.Count -gt 0) { $rows.Add('- Закрытые ID задач: ' + (@($allTaskIds | Sort-Object) -join ', ')) }
    if ($allCommitNames.Count -gt 0) {
        $rows.Add('')
        $rows.Add('## Коммиты')
        foreach ($commitName in $allCommitNames) { $rows.Add('- ' + $commitName) }
    }
    $rows.Add('')
    $rows.Add('| Время | Итерация | TODO | Код | Тесты | Документы | Ошибки инструментов | Стоимость | Git push | Проблема |')
    $rows.Add('|---|---|---:|---:|---:|---:|---:|---:|---|---|')
    foreach ($s in $summaries) {
        $timestamp = [string](Read-Member $s 'started')
        $timePart = if ($timestamp.Length -ge 19) { $timestamp.Substring(11,8) } else { '--:--:--' }
        $completed = [Math]::Max(0,[int](Read-Member $s 'doneAfter')-[int](Read-Member $s 'doneBefore'))
        $cost = Read-Member $s 'costDeltaUSD'
        $costDisplay = if ($null -eq $cost) { '?' } else { '$' + ([double]$cost).ToString('F4',$Invariant) }
        $reason = [string](Read-Member $s 'stoppedReason')
        if ($reason -eq '') { $reason = '-' }
        $reason = $reason.Replace('|','/')
        $rows.Add(('| {0} | `{1}` | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f
            $timePart,[string](Read-Member $s 'id'),$completed,[int](Read-Member $s 'codeFilesChanged'),
            [int](Read-Member $s 'testFilesChanged'),[int](Read-Member $s 'documentationFilesChanged'),
            [int](Read-Member $s 'toolErrors'),$costDisplay,([bool](Read-Member $s 'pushVerified')),$reason))
    }
    $rows.Add('')
    $rows.Add('Стоимость взята из глобальной локальной статистики OpenCode до и после итерации; сторонняя активность может искажать дельту.')
    $rows.Add('Обнаруженные команды проверок — не доказательство их успешности; фактические результаты нужно читать в progress и логах OpenCode.')
    [System.IO.File]::WriteAllText((Join-Path $reportsDir "$Date.md"), (($rows -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Save-Json (Join-Path $reportsDir "$Date.json") ([ordered]@{
        project=(Split-Path $DataDirectory -Leaf); date=$Date; iterations=$summaries.Count
        tasksCompleted=$tasks; pushesVerified=$pushes; costDeltaUsd=[Math]::Round($costTotal,6)
        codeFilesChanged=$code; testFilesChanged=$tests; documentationFilesChanged=$docs
        toolErrors=$toolErrors; verificationCommandsObserved=$verifications
        completedTaskIds=@($allTaskIds | Sort-Object)
        commits=@($allCommitNames.ToArray())
        generatedAt=(Get-Date).ToString('o')
    })
    return (Join-Path $reportsDir "$Date.md")
}
function Write-EnglishDailyReport([string]$DataDirectory, [string]$Date) {
    if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'ReportDate must be YYYY-MM-DD.' }
    $logDirectory = Join-Path (Join-Path $DataDirectory 'logs') $Date
    $summaries = @()
    if (Test-Path -LiteralPath $logDirectory) {
        $summaries = @(Get-ChildItem -LiteralPath $logDirectory -Filter '*.summary.json' -File | Sort-Object Name |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable })
    }
    $reportDirectory = Join-Path $DataDirectory 'reports'
    Ensure-Directory $reportDirectory
    $cost = 0.0; $tasks = 0; $pushes = 0; $code = 0; $tests = 0; $docs = 0; $errors = 0
    $ids = [System.Collections.Generic.HashSet[string]]::new(); $commits = [System.Collections.Generic.List[string]]::new()
    foreach ($summary in $summaries) {
        $delta = Read-Member $summary 'costDeltaUSD'; if ($null -ne $delta) { $cost += [double]$delta }
        $tasks += [Math]::Max(0,[int](Read-Member $summary 'doneAfter')-[int](Read-Member $summary 'doneBefore'))
        if ([bool](Read-Member $summary 'pushVerified')) { $pushes++ }
        $code += [int](Read-Member $summary 'codeFilesChanged'); $tests += [int](Read-Member $summary 'testFilesChanged'); $docs += [int](Read-Member $summary 'documentationFilesChanged'); $errors += [int](Read-Member $summary 'toolErrors')
        foreach ($id in @(Read-Member $summary 'completedTaskIds')) { if ($id) { [void]$ids.Add([string]$id) } }
        foreach ($commit in @(Read-Member $summary 'commits')) { if ($commit) { $commits.Add(([string](Read-Member $commit 'hash') + ' ' + [string](Read-Member $commit 'subject'))) } }
    }
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add("# Terra Runner daily report — $Date"); $rows.Add(''); $rows.Add("Project: **$(Split-Path $DataDirectory -Leaf)**"); $rows.Add('')
    $rows.Add("- Iterations: **$($summaries.Count)**; completed roadmap tasks: **$tasks**; verified pushes: **$pushes**")
    $rows.Add(('- Estimated local OpenCode usage during iterations: **${0:N4}**' -f $cost))
    $rows.Add("- Changed files: code **$code**, tests **$tests**, documentation **$docs**; tool errors **$errors**")
    if ($ids.Count) { $rows.Add('- Completed task IDs: ' + (@($ids | Sort-Object) -join ', ')) }
    if ($commits.Count) { $rows.Add(''); $rows.Add('## Commits'); foreach ($commit in $commits) { $rows.Add('- ' + $commit) } }
    $rows.Add(''); $rows.Add('| Time | Iteration | Tasks | Code | Tests | Docs | Cost | Push | Stop reason |'); $rows.Add('|---|---|---:|---:|---:|---:|---:|---|---|')
    foreach ($summary in $summaries) {
        $started = [string](Read-Member $summary 'started'); $time = if ($started.Length -ge 19) { $started.Substring(11,8) } else { '--:--:--' }
        $completed = [Math]::Max(0,[int](Read-Member $summary 'doneAfter')-[int](Read-Member $summary 'doneBefore'))
        $delta = Read-Member $summary 'costDeltaUSD'; $displayCost = if ($null -eq $delta) { '?' } else { ('$' + ([double]$delta).ToString('F4',$Invariant)) }
        $reason = [string](Read-Member $summary 'stoppedReason'); if (-not $reason) { $reason = '-' }
        $rows.Add(('| {0} | `{1}` | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $time,[string](Read-Member $summary 'id'),$completed,[int](Read-Member $summary 'codeFilesChanged'),[int](Read-Member $summary 'testFilesChanged'),[int](Read-Member $summary 'documentationFilesChanged'),$displayCost,([bool](Read-Member $summary 'pushVerified')),$reason.Replace('|','/')))
    }
    $rows.Add(''); $rows.Add('Usage is derived from local OpenCode statistics. It is an estimate, not a provider-reported account balance. Verification commands observed in agent logs do not by themselves prove successful tests.')
    $markdown = Join-Path $reportDirectory "$Date.md"
    [IO.File]::WriteAllText($markdown,(($rows -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
    Save-Json (Join-Path $reportDirectory "$Date.json") ([ordered]@{ project=(Split-Path $DataDirectory -Leaf); date=$Date; iterations=$summaries.Count; tasksCompleted=$tasks; pushesVerified=$pushes; costDeltaUsd=[Math]::Round($cost,6); codeFilesChanged=$code; testFilesChanged=$tests; documentationFilesChanged=$docs; toolErrors=$errors; completedTaskIds=@($ids | Sort-Object); commits=@($commits.ToArray()); generatedAt=(Get-Date).ToString('o') })
    return $markdown
}
function Rotate-Reports([string]$DataDirectory, $Settings) {
    $dir = Join-Path $DataDirectory 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $days = if ($null -ne (Read-Member $Settings 'reportRetainDays')) { [double]$Settings.reportRetainDays } else { 60.0 }
    $expiry = [datetime]::UtcNow.AddDays(-$days)
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.LastWriteTimeUtc -lt $expiry -and $_.Extension -in @('.json','.md') } |
        Remove-Item -Force
}

$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 40
if ([int]$cfg.schemaVersion -notin @(1,2,3)) { throw 'Unsupported terra-config.json schemaVersion.' }
$projectConfig = @($cfg.projects | Where-Object { $_.id -eq $Project })
if ($projectConfig.Count -ne 1) { throw "Expected exactly one project with id '$Project'." }
$projectConfig = $projectConfig[0]
if ($Project -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Unsafe project ID.' }
$repo = [string]$projectConfig.path
if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw "Project directory not found: $repo" }
$repo = (Resolve-Path -LiteralPath $repo).ProviderPath
$openCode = [string]$cfg.openCodeCommand
if ([string]::IsNullOrWhiteSpace($openCode)) { throw 'openCodeCommand is required.' }
$logRoot = [string]$cfg.logs.root
if (-not [System.IO.Path]::IsPathRooted($logRoot)) { $logRoot = Join-Path (Split-Path -Parent $Config) $logRoot }
$projectData = Join-Path $logRoot $Project
$logsPath = Join-Path $projectData 'logs'
$stopPath = Join-Path $projectData 'STOP'
$abortPath = Join-Path $projectData 'ABORT'
Ensure-Directory $projectData
Ensure-Directory $logsPath

if ($Stop) {
    [System.IO.File]::WriteAllText($stopPath,"stop requested at $(Get-Date -Format o)")
    Write-Host "Stop requested: current iteration will finish, then $Project stops."
    return
}
if ($Abort) {
    [System.IO.File]::WriteAllText($abortPath,"abort requested at $(Get-Date -Format o)")
    Write-Host "Abort requested: current iteration will be terminated on next poll."
    return
}
if ($ClearStop) {
    foreach ($p in @($stopPath,$abortPath)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
    Write-Host 'Stop/abort flags cleared.'
    return
}

$budgetMode = Get-BudgetMode $cfg.budget
if (-not [bool]$cfg.budget.requireGlobalOpenCodeStats) {
    throw 'The global OpenCode usage scope is required for reliable local accounting.'
}
if ($budgetMode -in @('daily','hybrid')) {
    Require-PositiveNumber $cfg.budget.dailyUsd 'budget.dailyUsd' | Out-Null
    [void](Require-NonNegativeNumber $cfg.budget.reserveUsd 'budget.reserveUsd')
    Require-PositiveNumber $cfg.budget.emergencyStopUsd 'budget.emergencyStopUsd' | Out-Null
    if ([double]$cfg.budget.emergencyStopUsd -gt [double]$cfg.budget.dailyUsd) {
        throw 'emergencyStopUsd must not exceed dailyUsd.'
    }
    if ([double]$cfg.budget.reserveUsd -ge [double]$cfg.budget.dailyUsd) {
        throw 'reserveUsd must be below dailyUsd.'
    }
}
if ($budgetMode -in @('balance','hybrid')) {
    if ($null -eq (Read-Member $cfg.budget 'balance')) { throw 'budget.balance is required.' }
    [void](Require-NonNegativeNumber $cfg.budget.balance.minimumUsd 'budget.balance.minimumUsd')
    [void](Require-NonNegativeNumber $cfg.budget.balance.iterationReserveUsd 'budget.balance.iterationReserveUsd')
    if ($cfg.budget.balance.source -eq 'snapshot') { [void](Get-BalanceStatePath $logRoot $cfg.budget.balance) }
    elseif ($cfg.budget.balance.source -ne 'command') { throw 'budget.balance.source must be snapshot or command.' }
}
if ($hasSetBalance -and $budgetMode -notin @('balance','hybrid')) {
    throw '-SetBalanceUsd is only available in balance/hybrid modes.'
}
if ($hasSetBalance -and $cfg.budget.balance.source -ne 'snapshot') {
    throw '-SetBalanceUsd is only available for balance.source=snapshot.'
}
Require-PositiveNumber $cfg.execution.pollSeconds 'execution.pollSeconds' | Out-Null
Require-PositiveNumber $cfg.execution.maxIterationMinutes 'execution.maxIterationMinutes' | Out-Null
Require-PositiveNumber $cfg.execution.maxRawLogMiB 'execution.maxRawLogMiB' | Out-Null
Require-PositiveNumber $cfg.logs.retainDays 'logs.retainDays' | Out-Null
Require-PositiveNumber $cfg.logs.maxIterationsPerProject 'logs.maxIterationsPerProject' | Out-Null
Require-PositiveNumber $cfg.logs.maxTotalMiBPerProject 'logs.maxTotalMiBPerProject' | Out-Null
if ($null -ne (Read-Member $cfg.logs 'reportRetainDays')) { Require-PositiveNumber $cfg.logs.reportRetainDays 'logs.reportRetainDays' | Out-Null }
if ([int]$cfg.execution.maxConsecutiveNoProgress -lt 1) { throw 'maxConsecutiveNoProgress must be >= 1.' }
if ($null -ne (Read-Member $cfg.execution 'maxConsecutiveDocumentationOnly') -and [int]$cfg.execution.maxConsecutiveDocumentationOnly -lt 1) { throw 'maxConsecutiveDocumentationOnly must be >= 1.' }
$maxCycles = if ($MaxIterations -gt 0) { $MaxIterations } else { [int]$cfg.execution.maxIterationsPerRun }
if ($Once) { $maxCycles = 1 }
if ($maxCycles -lt 1) { throw 'No iterations configured.' }

if ($Report) {
    $date = if ($ReportDate) { $ReportDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $reportFile = Write-EnglishDailyReport $projectData $date
    Rotate-Reports $projectData $cfg.logs
    Write-Host "Project daily report: $reportFile"
    return
}
if ($Status) {
    $snapshot = Get-BudgetSnapshot $openCode $repo $cfg.budget $logRoot
    Show-Usage $snapshot $cfg.budget
    $reason = Get-BudgetStopReason $snapshot $cfg.budget $false
    if ($reason) { Write-Host "No new iteration allowed: $reason" }
    Write-Host "Project logs: $logsPath"
    Write-Host "STOP: $(Test-Path -LiteralPath $stopPath); ABORT: $(Test-Path -LiteralPath $abortPath)"
    return
}

if (-not ($Once -or $Continuous -or $DryRun -or $hasSetBalance)) {
    Write-Host 'No development command was selected. Use -Once or -Continuous to start OpenCode.'
    Write-Host 'Informational commands such as -Status and -Report never start an agent.'
    return
}

# FileShare.None prevents two runner instances (including runners for other projects)
# from simultaneously consuming the same local daily budget.
$globalLockPath = Join-Path $logRoot 'global-runner.lock'
Ensure-Directory (Split-Path -Parent $globalLockPath)
$lock = $null
$activeChild = $null
try {
    try {
        $lock = [System.IO.File]::Open($globalLockPath,[System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    } catch { throw 'Another Terra Runner already holds the global budget lock. Concurrent runners are blocked.' }

    $branch = (Invoke-Cli 'git' @('-C',$repo,'branch','--show-current') $repo).Trim()
    if ($branch -cne [string]$projectConfig.branch) { throw "Wrong Git branch '$branch'; expected '$($projectConfig.branch)'" }
    [void](Invoke-Cli 'git' @('-C',$repo,'remote','get-url','origin') $repo)
    $initialGitStatus = Invoke-Cli 'git' @('-C',$repo,'status','--porcelain') $repo
    if ($initialGitStatus.Trim() -ne '') {
        throw 'Git working tree has uncommitted/untracked changes. Review and resolve them before automated execution.'
    }
    $roadmap = Join-Path $repo ([string]$projectConfig.roadmap)
    $progress = Join-Path $repo ([string]$projectConfig.progress)
    $taskIdPattern = [string](Read-Member $projectConfig 'taskIdPattern')
    if ([string]::IsNullOrWhiteSpace($taskIdPattern) -and [int]$cfg.schemaVersion -lt 3) { $taskIdPattern = 'NTD-\d{4,}' }
    foreach ($f in @($roadmap,$progress)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Required project file is missing: $f" }
    }
    $promptFile = Join-Path $ScriptDir 'terra-prompt.md'
    $workerFile = Join-Path $ScriptDir 'terra-worker.ps1'
    foreach ($f in @($promptFile,$workerFile)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Runner file is missing: $f" }
    }
    if (-not (Get-Command -Name $openCode -ErrorAction SilentlyContinue)) {
        throw "OpenCode command '$openCode' not found. Install OpenCode and make it available in PATH."
    }
    # Fail closed on CLI variants without the requisite noninteractive/structured interface.
    $help = Invoke-Cli $openCode @('run','--help') $repo
    foreach ($flag in @('--agent','--format','--auto')) {
        if ($help -notmatch [regex]::Escape($flag)) { throw "Installed OpenCode does not support $flag; update OpenCode first." }
    }
    $statsHelp = Invoke-Cli $openCode @('stats','--help') $repo
    if ($statsHelp -notmatch '\-\-json') { throw 'Installed OpenCode lacks stats --json; update to compatible OpenCode v2.' }
    if ($hasSetBalance) {
        $all = Get-Usage $openCode $repo $cfg.budget 'all'
        $stateFile = Get-BalanceStatePath $logRoot $cfg.budget.balance
        Set-BalanceSnapshot $stateFile ([double]$setBalanceAmount) $all ([bool]$ReconcileBalance)
        Write-Host ('Balance snapshot saved: {0}; OpenCode lifetime baseline ${1:N4}; file: {2}' -f (Format-TerraMoney $setBalanceAmount),$all.CostUSD,$stateFile)
        return
    }
    $initialUsage = Get-BudgetSnapshot $openCode $repo $cfg.budget $logRoot
    Show-Usage $initialUsage $cfg.budget
    Rotate-ProjectLogs $logsPath $cfg.logs
    Rotate-Reports $projectData $cfg.logs
    if ($DryRun) {
        Write-Host "DRY RUN OK: project=$Project branch=$branch iterations=$maxCycles; would launch agent '$($cfg.agent)'."
        return
    }
    if (Test-Path -LiteralPath $stopPath) { throw "STOP flag exists: $stopPath. Use -ClearStop after review." }
    if (Test-Path -LiteralPath $abortPath) { throw "ABORT flag exists: $abortPath. Use -ClearStop after review." }

    $noProgress = 0
    $activeChild = $null
    for ($i = 1; $i -le $maxCycles; $i++) {
        if (Test-Path -LiteralPath $stopPath) { Write-Host 'STOP detected; exiting after previous iteration.'; break }
        if (Test-Path -LiteralPath $abortPath) { Write-Host 'ABORT detected; exiting.'; break }
        $usageBefore = Get-BudgetSnapshot $openCode $repo $cfg.budget $logRoot
        Show-Usage $usageBefore $cfg.budget
        $budgetBlock = Get-BudgetStopReason $usageBefore $cfg.budget $false
        if ($budgetBlock) { Write-Host "Cannot start next iteration: $budgetBlock"; break }
        $pending = Count-Pending $roadmap $taskIdPattern
        if ($pending -eq 0) { Write-Host 'No pending roadmap checkbox tasks found. Stopping.'; break }
        $headBefore = Get-Head $repo
        $doneBefore = Count-Completed $roadmap $taskIdPattern
        $runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
        $runDirectory = Join-Path $logsPath (Get-Date -Format 'yyyy-MM-dd')
        Ensure-Directory $runDirectory
        $prefix = Join-Path $runDirectory $runId
        $eventsPath = $prefix + '.events.jsonl'
        $stderrPath = $prefix + '.stderr.log'
        $summaryPath = $prefix + '.summary.json'
        [System.IO.File]::WriteAllText($eventsPath,'')
        [System.IO.File]::WriteAllText($stderrPath,'')
        Write-Host "Iteration $i/$maxCycles [$runId], pending tasks: $pending"
        $begin = Get-Date
        Show-IterationProgress $i $maxCycles ([timespan]::Zero) ([double]$cfg.execution.maxIterationMinutes) $pending
        $termination = ''
        $exitCode = -1
        $child = $null
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $pwshExe = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            $psi.FileName = $pwshExe
            $psi.WorkingDirectory = $repo
            $psi.UseShellExecute = $false
            $argsList = @('-NoProfile','-NonInteractive','-File',$workerFile,
                '-OpenCodeCommand',$openCode,'-ProjectPath',$repo,'-PromptFile',$promptFile,
                '-EventsFile',$eventsPath,'-ErrorFile',$stderrPath,'-Agent',([string]$cfg.agent),'-Model',([string]$cfg.model))
            foreach ($item in $argsList) { [void]$psi.ArgumentList.Add([string]$item) }
            $child = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $child) { throw 'Failed to start OpenCode worker.' }
            $activeChild = $child
            while (-not $child.WaitForExit([int]([double]$cfg.execution.pollSeconds * 1000))) {
                if (Test-Path -LiteralPath $abortPath) { $termination = 'manual-abort'; break }
                $elapsed = (Get-Date) - $begin
                Show-IterationProgress $i $maxCycles $elapsed ([double]$cfg.execution.maxIterationMinutes) $pending
                if ($elapsed.TotalMinutes -gt [double]$cfg.execution.maxIterationMinutes) { $termination = 'iteration-timeout'; break }
                $size = (Get-Item -LiteralPath $eventsPath).Length
                if ($size -gt ([double]$cfg.execution.maxRawLogMiB * 1MB)) { $termination = 'raw-log-size-limit'; break }
                try {
                    $liveUsage = Get-BudgetSnapshot $openCode $repo $cfg.budget $logRoot
                    $liveBlock = Get-BudgetStopReason $liveUsage $cfg.budget $true
                    if ($liveBlock) { $termination = "budget-emergency-stop: $liveBlock"; break }
                } catch {
                    $termination = "budget-unverifiable: $($_.Exception.Message)"
                    break
                }
            }
            if ($termination) { Stop-Child $child }
            if ($child.HasExited) { $exitCode = $child.ExitCode }
        }
        catch {
            $termination = "runner-error: $($_.Exception.Message)"
            if ($null -ne $child) { Stop-Child $child }
        }
        finally {
            if ($null -ne $child) {
                if (-not $child.HasExited) { Stop-Child $child }
                $child.Dispose()
            }
            $activeChild = $null
        }
        $ended = Get-Date
        if ($ShowProgress) {
            Write-Progress -Id 2 -ParentId 1 -Activity 'OpenCode | current iteration' -Completed
            Write-Progress -Id 1 -Activity 'Terra Runner | development cycle' -Completed
        }
        $usageAfter = $null
        $usageError = ''
        try { $usageAfter = Get-BudgetSnapshot $openCode $repo $cfg.budget $logRoot }
        catch { $usageError = $_.Exception.Message }
        $headAfter = Get-Head $repo
        $doneAfter = Count-Completed $roadmap $taskIdPattern
        $eventErrors = 0
        $toolErrors = 0
        $toolErrorExamples = @()
        $verificationCommandsObserved = 0
        $verificationCommandErrors = 0
        $verificationExamples = @()
        $noTasksReported = $false
        try {
            $eventsReview = Get-EventErrors $eventsPath
            $eventErrors = $eventsReview.Errors
            $toolErrors = $eventsReview.ToolErrors
            $toolErrorExamples = @($eventsReview.ToolErrorExamples)
            $verificationCommandsObserved = $eventsReview.VerificationCommands
            $verificationCommandErrors = $eventsReview.VerificationCommandErrors
            $verificationExamples = @($eventsReview.VerificationExamples)
            $noTasksReported = $eventsReview.NoTasks
        } catch {
            if (-not $termination) { $termination = "invalid-event-output: $($_.Exception.Message)" }
        }
        if ($eventErrors -gt 0 -and -not $termination) { $termination = "opencode-reported-$eventErrors-errors" }
        $maxToolErrors = if ($null -ne (Read-Member $cfg.execution 'maxToolErrorsPerIteration')) { [int]$cfg.execution.maxToolErrorsPerIteration } else { 15 }
        if ($toolErrors -gt $maxToolErrors -and -not $termination) { $termination = "too-many-tool-errors-$toolErrors" }
        $readablePath = $prefix + '.events.readable.jsonl'
        try { Write-ReadableEvents $eventsPath $readablePath }
        catch { if (-not $termination) { $termination = "readable-log-error: $($_.Exception.Message)" } }
        if ((Get-Item -LiteralPath $eventsPath).Length -eq 0 -and -not $termination) {
            $termination = 'empty-opencode-event-stream'
        }
        if ($null -ne $usageAfter -and
            $usageAfter.AllTime.Tokens -gt $usageBefore.AllTime.Tokens -and
            $usageAfter.AllTime.CostUSD -le $usageBefore.AllTime.CostUSD -and
            [bool]$cfg.budget.stopOnZeroCostWithTokens -and -not $termination) {
            $termination = 'new-token-usage-without-recorded-cost'
        }
        $gitStatus = ''
        try { $gitStatus = Invoke-Cli 'git' @('-C',$repo,'status','--porcelain') $repo }
        catch { if (-not $termination) { $termination = "git-status-error: $($_.Exception.Message)" } }
        if ($gitStatus.Trim() -ne '' -and -not $termination) { $termination = 'uncommitted-changes-left-by-agent' }
        $pushVerified = $false
        try { $pushVerified = Confirm-RemotePush $repo ([string]$projectConfig.branch) }
        catch { if (-not $termination) { $termination = "git-remote-verification-error: $($_.Exception.Message)" } }
        if (-not $pushVerified -and -not $termination) { $termination = 'local-and-remote-branch-heads-differ' }
        $changedFiles = $null
        $completedIds = @(); $iterationCommits = @()
        try {
            $completedIds = @(Get-CompletionIds $repo $roadmap $headBefore $taskIdPattern)
            $iterationCommits = @(Get-CommitsInIteration $repo $headBefore $headAfter)
        } catch { if (-not $termination) { $termination = "git-commit-audit-error: $($_.Exception.Message)" } }
        try { $changedFiles = Get-ChangedFiles $repo $headBefore $headAfter }
        catch { if (-not $termination) { $termination = "git-diff-review-error: $($_.Exception.Message)" } }
        if ($null -eq $changedFiles) { $changedFiles = [pscustomobject]@{ Code=0; Docs=0; Tests=0; Other=0; Paths=@() } }
        $stateFile = Join-Path $projectData 'control-state.json'
        $state = @{ noProgress=0; documentationOnly=0 }
        if (Test-Path -LiteralPath $stateFile) {
            $state = Get-Content -LiteralPath $stateFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        }
        $noProgressNow = ($doneAfter -le $doneBefore)
        $noProgress = if ($noProgressNow) { [int]$state.noProgress + 1 } else { 0 }
        $docsOnlyNow = ($changedFiles.Docs -gt 0 -and $changedFiles.Code -eq 0 -and $changedFiles.Tests -eq 0)
        $docsOnly = if ($docsOnlyNow) { [int]$state.documentationOnly + 1 } else { 0 }
        Save-Json $stateFile ([ordered]@{ noProgress=$noProgress; documentationOnly=$docsOnly; lastRunId=$runId; updatedAt=(Get-Date).ToString('o') })
        $summary = [ordered]@{
            project = $Project; id = $runId; started = $begin.ToString('o'); ended = $ended.ToString('o')
            elapsedSeconds = [Math]::Round(($ended-$begin).TotalSeconds,1)
            branch = $branch; exitCode = $exitCode; stoppedReason = $termination
            headBefore = $headBefore; headAfter = $headAfter
            pushVerified = $pushVerified; eventErrors = $eventErrors
            toolErrors = $toolErrors; toolErrorExamples = $toolErrorExamples
            verificationCommandsObserved = $verificationCommandsObserved
            verificationCommandErrors = $verificationCommandErrors
            verificationExamples = $verificationExamples
            completedTaskIds = @($completedIds)
            commits = @($iterationCommits)
            noActionableTasksReported = $noTasksReported
            workingTreeClean = ($gitStatus.Trim() -eq '')
            doneBefore = $doneBefore; doneAfter = $doneAfter
            pendingAfter = (Count-Pending $roadmap $taskIdPattern)
            costBeforeUSD = $usageBefore.Daily.CostUSD
            costAfterUSD = $(if ($null -ne $usageAfter) { $usageAfter.Daily.CostUSD } else { $null })
            costDeltaUSD = $(if ($null -ne $usageAfter) {
                [Math]::Round([Math]::Max(0.0,[double]$usageAfter.AllTime.CostUSD-[double]$usageBefore.AllTime.CostUSD),6)
            } else { $null })
            dayBefore = $usageBefore.Daily.Day
            dayAfter = $(if ($null -ne $usageAfter) { $usageAfter.Daily.Day } else { $null })
            totalTokensBefore = $usageBefore.AllTime.Tokens
            totalTokensAfter = $(if ($null -ne $usageAfter) { $usageAfter.AllTime.Tokens } else { $null })
            budgetMode = $budgetMode
            balanceBeforeUSD = $usageBefore.BalanceUSD
            balanceAfterUSD = $(if ($null -ne $usageAfter) { $usageAfter.BalanceUSD } else { $null })
            balanceSource = $usageBefore.BalanceSource
            codeFilesChanged = $changedFiles.Code
            documentationFilesChanged = $changedFiles.Docs
            testFilesChanged = $changedFiles.Tests
            otherFilesChanged = $changedFiles.Other
            changedFiles = @($changedFiles.Paths)
            documentationOnly = $docsOnlyNow
            consecutiveDocumentationOnly = $docsOnly
            consecutiveNoProgress = $noProgress
            usageError = $usageError
            eventsFile = [IO.Path]::GetFileName($eventsPath)
            readableEventsFile = [IO.Path]::GetFileName($readablePath)
            errorFile = [IO.Path]::GetFileName($stderrPath)
        }
        Save-Json $summaryPath $summary
        $reportPath = Write-EnglishDailyReport $projectData $begin.ToString('yyyy-MM-dd')
        Write-Host "Iteration finished: exit=$exitCode new completed tasks=$($doneAfter-$doneBefore) changedHEAD=$($headAfter -ne $headBefore) code=$($changedFiles.Code) tests=$($changedFiles.Tests) docs=$($changedFiles.Docs) toolErrors=$toolErrors"
        if ($null -ne $usageAfter) { Show-Usage $usageAfter $cfg.budget }
        Write-Host "Daily project report: $reportPath"
        Rotate-ProjectLogs $logsPath $cfg.logs
        Rotate-Reports $projectData $cfg.logs
        if ($termination -or $exitCode -ne 0 -or $usageError) {
            Write-Warning "Stopped on error or safety condition. Reason=$termination exit=$exitCode usage=$usageError; see $summaryPath"
            break
        }
        if ($noTasksReported) {
            Write-Host 'Agent reported NO_ACTIONABLE_TASKS; stopping.'
            break
        }
        if ($noProgress -ge [int]$cfg.execution.maxConsecutiveNoProgress) {
            Write-Warning "$noProgress consecutive iterations without completed TODO. Stopping to avoid a spend loop."
            break
        }
        $docsLimit = if ($null -ne (Read-Member $cfg.execution 'maxConsecutiveDocumentationOnly')) { [int]$cfg.execution.maxConsecutiveDocumentationOnly } else { 12 }
        if ($docsOnly -ge $docsLimit) {
            Write-Warning "$docsOnly consecutive documentation-only iterations. Stopping for a code-progress review."
            break
        }
        if ($i -lt $maxCycles) { Start-Sleep -Seconds ([int]$cfg.execution.pauseBetweenIterationsSeconds) }
    }
    Write-Host "Terra Runner finished. Project logs: $logsPath"
}
finally {
    if ($null -ne $activeChild) { Stop-Child $activeChild; $activeChild.Dispose() }
    if ($null -ne $lock) { $lock.Dispose() }
}
