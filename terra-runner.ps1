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
    [switch]$ClearControlFlags,
    [switch]$Report,
    [switch]$ProxyStatus,
    [switch]$ProxyTest,
    [string]$ReportDate = '',
    [string]$SetBalanceUsd = '',
    [switch]$ReconcileBalance,
    [switch]$ShowProgress,
    [switch]$UiEvents,
    [string]$InstanceId = '',
    [string]$ProfileId = '',
    [string]$AuthStoreId = '',
    [switch]$UnlimitedIterations,
    [switch]$SkipProviderSnapshotGuard,
    [ValidateRange(0, 1000)][int]$MaxIterations = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ is required. Run with pwsh.' }
# UI events are read as UTF-8 JSON by the Node processes. The Windows console
# code page is not a transport encoding: force UTF-8 for redirected stdout so
# Cyrillic roadmap titles survive the PowerShell -> Node boundary.
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
try { [Console]::InputEncoding = $Utf8NoBom } catch { }
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
function Resolve-ProjectInstructionsFile([string]$Repository, $ProjectConfig) {
    $relative = [string](Read-Member $ProjectConfig 'instructions')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'PROJECT-INSTRUCTIONS.md' }
    if ([IO.Path]::IsPathRooted($relative)) { throw 'Project instructions must be a relative path inside the project.' }
    $segments = @($relative -split '[\\/]')
    if ($segments | Where-Object { $_ -eq '..' }) { throw 'Project instructions path must not leave the project directory.' }
    $base = [IO.Path]::GetFullPath($Repository).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $filename = [IO.Path]::GetFullPath((Join-Path $base $relative))
    $prefix = $base + [IO.Path]::DirectorySeparatorChar
    if (-not $filename.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Project instructions path must stay inside the project directory.' }
    return [pscustomobject]@{ Path=$filename; Relative=([IO.Path]::GetRelativePath($base,$filename).Replace('\\','/')) }
}
function Assert-ProjectInstructionsFile([string]$Repository, $Instructions) {
    if ($null -eq $Instructions -or -not (Test-Path -LiteralPath $Instructions.Path -PathType Leaf)) {
        $relative = if ($null -eq $Instructions) { 'PROJECT-INSTRUCTIONS.md' } else { [string]$Instructions.Relative }
        throw "Project instructions file is required: $relative. Create it from Projects before Development."
    }
}
function Test-OnlyProjectInstructionsChanges([string]$Repository, $Instructions) {
    # Compare Git's own porcelain output instead of parsing filenames ourselves:
    # this remains correct for spaces and non-ASCII paths. The instructions
    # file may be new, staged, or modified, but it must be the *only* change.
    $allChanges = Invoke-Cli 'git' @('-C',$Repository,'status','--porcelain') $Repository
    if ([string]::IsNullOrWhiteSpace($allChanges)) { return $false }
    $instructionChanges = Invoke-Cli 'git' @('-C',$Repository,'status','--porcelain','--',$Instructions.Relative) $Repository
    return $allChanges.Trim() -ceq $instructionChanges.Trim()
}
function Get-ActiveProxyRoute($Config) {
    $proxy = Read-Member $Config 'proxy'
    if ($null -eq $proxy -or [string](Read-Member $proxy 'activeRouteId') -in @('','direct')) { return $null }
    $id = [string](Read-Member $proxy 'activeRouteId')
    $route = @((Read-Member $proxy 'routes') | Where-Object { [string](Read-Member $_ 'id') -eq $id }) | Select-Object -First 1
    if ($null -eq $route) { throw "Configured proxy route '$id' was not found." }
    # $Host is a built-in read-only PowerShell automatic variable. Variable names
    # are case-insensitive, so never use $host for an upstream endpoint here.
    $protocol = [string](Read-Member $route 'protocol'); $upstreamHost = [string](Read-Member $route 'host'); $port = [int](Read-Member $route 'port')
    if ($protocol -notin @('http','https','socks4','socks4a','socks5','socks5h') -or [string]::IsNullOrWhiteSpace($upstreamHost) -or $upstreamHost -match '[\s/@]' -or $port -lt 1 -or $port -gt 65535) { throw 'Configured proxy route is invalid.' }
    return $route
}
function Get-ProxyNoProxy($Route) { return (@('localhost','127.0.0.1','::1') + @((Read-Member $Route 'noProxy')) | Where-Object { $_ } | Select-Object -Unique) -join ',' }
function Start-TerraProxyBridge($Route) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue; if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue }; if ($null -eq $node) { throw 'Node.js 20+ is required for a configured proxy route.' }
    $bridge = Join-Path $ScriptDir 'node-ui/proxy-bridge.mjs'; if (-not (Test-Path -LiteralPath $bridge)) { throw 'Proxy bridge file is missing.' }
    $cipher = [string](Read-Member $Route 'passwordProtected'); $password = if ($cipher) { Unprotect-TerraSecret $cipher } else { '' }
    $payload = [ordered]@{ protocol=[string](Read-Member $Route 'protocol'); host=[string](Read-Member $Route 'host'); port=[int](Read-Member $Route 'port'); username=[string](Read-Member $Route 'username'); password=$password } | ConvertTo-Json -Compress
    $psi = [Diagnostics.ProcessStartInfo]::new(); $psi.FileName = $node.Source; $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $ca = [string](Read-Member $Route 'caFile'); if ($ca) { if (-not (Test-Path -LiteralPath $ca -PathType Leaf)) { throw 'Configured proxy CA file was not found.' }; $psi.Environment['NODE_EXTRA_CA_CERTS'] = $ca }
    [void]$psi.ArgumentList.Add($bridge); $process = [Diagnostics.Process]::Start($psi); $process.StandardInput.Write($payload); $process.StandardInput.Close(); $line = $process.StandardOutput.ReadLine()
    try { $port = [int](($line | ConvertFrom-Json -AsHashtable).port) } catch { $detail = $process.StandardError.ReadToEnd(); $process.Dispose(); throw "Proxy bridge failed to start: $detail" }
    if ($port -lt 1 -or $port -gt 65535) { $process.Kill($true); $process.Dispose(); throw 'Proxy bridge returned an invalid port.' }
    return [pscustomobject]@{ Process=$process; Url="http://127.0.0.1:$port"; NoProxy=(Get-ProxyNoProxy $Route); CaFile=$ca; Display="$([string](Read-Member $Route 'protocol'))://$([string](Read-Member $Route 'host')):$([int](Read-Member $Route 'port'))" }
}
function Stop-TerraProxyBridge($Bridge) { if ($null -eq $Bridge) { return }; try { if (-not $Bridge.Process.HasExited) { $Bridge.Process.Kill($true); $Bridge.Process.WaitForExit(5000) | Out-Null } } finally { $Bridge.Process.Dispose() } }
function Write-UiEvent([string]$Type, [hashtable]$Data = @{}) {
    if (-not $UiEvents) { return }
    $payload = [ordered]@{ type=$Type; at=(Get-Date).ToUniversalTime().ToString('o') }
    foreach ($key in $Data.Keys) { $payload[$key] = $Data[$key] }
    [Console]::Out.WriteLine('__TERRA_UI__' + ($payload | ConvertTo-Json -Compress -Depth 8))
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
function Get-HourlyUsage([string]$Root) {
    $sum = 0.0; $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
    $logs = Join-Path (Join-Path $Root $Project) 'logs'
    if (Test-Path -LiteralPath $logs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $logs -Recurse -File -Filter '*.summary.json' -ErrorAction SilentlyContinue)) {
            try { $summary = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 30; $ended = [DateTimeOffset]::Parse([string]$summary.ended).ToUniversalTime()
                if ($ended -ge $cutoff -and $null -ne $summary.costDeltaUSD) { $sum += [double]$summary.costDeltaUSD } } catch { }
        }
    }
    return [pscustomobject]@{ CostUSD=$sum; Tokens=0.0 }
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
function Test-TransientGitPushFailure([string]$Output) {
    return $Output -match '(?i)(internal server error|\b5\d\d\b|temporar(?:y|ily)|timed? out|connection (?:reset|refused)|network|tls|ssl|schannel|handshake|service unavailable|rate limit)'
}
function Invoke-GitPushWithRetry([string]$Directory, [string]$Branch, [int]$Attempts, [int]$DelaySeconds) {
    $lastOutput = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Push-Location -LiteralPath $Directory
        try {
            $lines = & git push origin $Branch 2>&1
            $exitCode = $LASTEXITCODE
        } finally { Pop-Location }
        $lastOutput = [string]::Join("`n",[string[]]@($lines))
        $confirmed = $false
        if ($exitCode -eq 0) {
            try { $confirmed = Confirm-RemotePush $Directory $Branch }
            catch { $lastOutput = ($lastOutput + "`n" + $_.Exception.Message).Trim() }
        }
        if ($confirmed) {
            return [pscustomobject]@{ Success=$true; Attempts=$attempt; Output=$lastOutput }
        }
        if (-not (Test-TransientGitPushFailure $lastOutput)) {
            return [pscustomobject]@{ Success=$false; Attempts=$attempt; Output=$lastOutput }
        }
        if ($attempt -lt $Attempts) {
            Write-Warning "Transient Git push failure. Waiting $DelaySeconds seconds before retry ($attempt/$Attempts)."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return [pscustomobject]@{ Success=$false; Attempts=$Attempts; Output=$lastOutput }
}
function Wait-ForGitRemotePublish([string]$Directory, [string]$Branch, [int]$PushAttempts, [int]$DelaySeconds, [string]$StopPath, [string]$AbortPath) {
    # A completed worker may already have a durable local commit.  A temporary
    # transport outage must not turn that into a failed development run: keep
    # the worktree lock and wait until origin can confirm or accept the commit.
    $waitAttempt = 0
    while ($true) {
        if (Test-Path -LiteralPath $abortPath) { return [pscustomobject]@{ Success=$false; Interrupted=$true; Reason='manual-abort'; Error='' } }
        if (Test-Path -LiteralPath $stopPath) { return [pscustomobject]@{ Success=$false; Interrupted=$true; Reason='manual-stop'; Error='' } }
        $lastError = ''
        try {
            if (Confirm-RemotePush $Directory $Branch) { return [pscustomobject]@{ Success=$true; Interrupted=$false; Reason=''; Error='' } }
            Write-Warning 'Local branch is not yet confirmed on origin. Retrying the non-force push.'
            $push = Invoke-GitPushWithRetry $Directory $Branch $PushAttempts $DelaySeconds
            if ($push.Success) { return [pscustomobject]@{ Success=$true; Interrupted=$false; Reason=''; Error='' } }
            $lastError = [string]$push.Output
        } catch { $lastError = $_.Exception.Message }
        if (-not (Test-TransientGitPushFailure $lastError)) {
            return [pscustomobject]@{ Success=$false; Interrupted=$false; Reason=''; Error=$lastError }
        }
        $waitAttempt++
        Write-Warning "Git remote is temporarily unavailable. Waiting $DelaySeconds seconds before connection check ($waitAttempt)."
        Write-UiEvent 'network-waiting' @{ source='Git remote'; attempt=$waitAttempt; delaySeconds=$DelaySeconds }
        Start-Sleep -Seconds $DelaySeconds
    }
}
function Get-TerraRecoveryMarkerPath([string]$ProjectData) {
    return Join-Path $ProjectData 'recovery/inflight.json'
}
function Write-TerraRecoveryMarker([string]$ProjectData, [string]$RunId, [string]$Branch, [string]$BaseHead) {
    $markerPath = Get-TerraRecoveryMarkerPath $ProjectData
    Save-Json $markerPath ([ordered]@{
        project = $Project; runId = $RunId; branch = $Branch; baseHead = $BaseHead
        startedAt = (Get-Date).ToString('o')
    })
    return $markerPath
}
function Clear-TerraRecoveryMarker([string]$ProjectData) {
    $markerPath = Get-TerraRecoveryMarkerPath $ProjectData
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
}
function Test-GitAncestor([string]$Directory, [string]$Ancestor, [string]$Descendant) {
    Push-Location -LiteralPath $Directory
    try { & git merge-base --is-ancestor $Ancestor $Descendant; $exitCode = $LASTEXITCODE }
    finally { Pop-Location }
    return $exitCode -eq 0
}
function Recover-TerraInterruptedWork([string]$Directory, [string]$Branch, [string]$ProjectData, [int]$Attempts, [int]$DelaySeconds, [string]$StopPath, [string]$AbortPath) {
    $markerPath = Get-TerraRecoveryMarkerPath $ProjectData
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 10 }
    catch { throw 'Interrupted Terra recovery marker is unreadable; resolve the working tree manually before development.' }
    $runId = [string](Read-Member $marker 'runId')
    $markerProject = [string](Read-Member $marker 'project')
    $markerBranch = [string](Read-Member $marker 'branch')
    $baseHead = [string](Read-Member $marker 'baseHead')
    if ($markerProject -ne $Project -or $markerBranch -cne $Branch -or $runId -notmatch '^[A-Za-z0-9-]{8,96}$' -or $baseHead -notmatch '^[a-f0-9]{40,64}$') {
        throw 'Interrupted Terra recovery marker does not match this project and branch; resolve the working tree manually before development.'
    }
    $status = Invoke-Cli 'git' @('-C',$Directory,'status','--porcelain') $Directory
    if ([string]::IsNullOrWhiteSpace($status)) {
        Clear-TerraRecoveryMarker $ProjectData
        Write-Host 'Cleared a stale interrupted-run marker; the Git working tree is already clean.'
        return $null
    }
    $currentHead = Get-Head $Directory
    if (-not (Test-GitAncestor $Directory $baseHead $currentHead)) {
        throw 'Interrupted Terra recovery cannot verify the Git base commit; resolve the working tree manually before development.'
    }
    Invoke-Cli 'git' @('-C',$Directory,'add','--all') $Directory | Out-Null
    Push-Location -LiteralPath $Directory
    try { & git diff --cached --quiet; $stagedExit = $LASTEXITCODE }
    finally { Pop-Location }
    if ($stagedExit -eq 0) { throw 'Interrupted Terra recovery found no staged work after a dirty Git status; resolve the working tree manually.' }
    if ($stagedExit -ne 1) { throw 'Interrupted Terra recovery could not inspect the staged checkpoint.' }
    Invoke-Cli 'git' @('-C',$Directory,'diff','--cached','--check') $Directory | Out-Null
    Invoke-Cli 'git' @('-C',$Directory,'commit','-m',"chore(terra): recover interrupted run $runId") $Directory | Out-Null
    $push = Wait-ForGitRemotePublish $Directory $Branch $Attempts $DelaySeconds $StopPath $AbortPath
    if (-not $push.Success) {
        if ($push.Interrupted) {
            Write-Host "Interrupted-work checkpoint is local; Git remote wait interrupted by $($push.Reason)."
            return [pscustomobject]@{ Interrupted=$true; Commit='' }
        }
        throw "Interrupted Terra recovery created a local checkpoint but could not push it: $($push.Error)"
    }
    $commit = Get-Head $Directory
    $recoveryDirectory = Split-Path -Parent $markerPath
    Save-Json (Join-Path $recoveryDirectory 'last-recovery.json') ([ordered]@{ project=$Project; interruptedRunId=$runId; recoveryCommit=$commit; recoveredAt=(Get-Date).ToString('o') })
    Clear-TerraRecoveryMarker $ProjectData
    Write-Host "Recovered interrupted Terra work in commit $commit and pushed it to origin/$Branch."
    Write-UiEvent 'recovery-finished' @{ interruptedRunId=$runId; recoveryCommit=$commit }
    return [pscustomobject]@{ Interrupted=$false; Commit=$commit }
}
function Get-EventErrors([string]$EventsFile) {
    $streamErrors = 0
    $toolErrorIds = [System.Collections.Generic.HashSet[string]]::new()
    $verificationIds = [System.Collections.Generic.HashSet[string]]::new()
    $verificationErrors = 0
    $verificationExamples = [System.Collections.Generic.List[string]]::new()
    $noTasks = $false
    $noTaskMessage = ''
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
            if ($body -match '\bNO_ACTIONABLE_TASKS\b') {
                $noTasks = $true
                if ([string]::IsNullOrWhiteSpace($noTaskMessage)) { $noTaskMessage = $body.Substring(0,[Math]::Min(1200,$body.Length)) }
            }
        }
    }
    return [pscustomobject]@{
        Errors = $streamErrors; ToolErrors = $toolErrorIds.Count
        ToolErrorExamples = @($toolExamples.ToArray()); NoTasks = $noTasks; NoTaskMessage = $noTaskMessage
        VerificationCommands = $verificationIds.Count; VerificationCommandErrors = $verificationErrors
        VerificationExamples = @($verificationExamples.ToArray())
    }
}
function Test-TransientNetworkFailure([string]$EventsFile, [string]$ErrorFile) {
    $signature = '(?is)(?:\b(?:tls|ssl)\b.{0,120}\b(?:handshake|connection|socket|network|reset|timeout|certificate)\b|\b(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|SSL_ERROR|CERT_|UNABLE_TO_VERIFY)\b)'
    if (Test-Path -LiteralPath $ErrorFile -PathType Leaf) {
        try {
            if ([IO.File]::ReadAllText($ErrorFile,[Text.UTF8Encoding]::new($false)) -match $signature) { return $true }
        } catch { }
    }
    if (-not (Test-Path -LiteralPath $EventsFile -PathType Leaf)) { return $false }
    try {
        foreach ($line in [IO.File]::ReadLines($EventsFile,[Text.UTF8Encoding]::new($false))) {
            # A task, source file, or agent explanation may legitimately mention TLS/SSL.
            # Treat it as a connection failure only when OpenCode marks the event as an error.
            if ($line -match $signature -and $line -match '(?i)"(?:type|status)"\s*:\s*"[^"\r\n]*error[^"\r\n]*"') { return $true }
        }
    } catch { }
    return $false
}
function Wait-ForOpenCodeRecovery([string]$Executable, [string]$Directory, $Budget, [string]$LogRoot, [bool]$LimitsEnabled, [int]$DelaySeconds, [string]$StopPath, [string]$AbortPath) {
    $attempt = 0
    while ($true) {
        if ((Test-Path -LiteralPath $abortPath) -or (Test-Path -LiteralPath $stopPath)) { return $false }
        $attempt++
        Write-Warning "Transient TLS/SSL or network failure. Waiting $DelaySeconds seconds before connection check ($attempt)."
        Write-UiEvent 'network-waiting' @{ source='OpenCode'; attempt=$attempt; delaySeconds=$DelaySeconds }
        Start-Sleep -Seconds $DelaySeconds
        if ((Test-Path -LiteralPath $abortPath) -or (Test-Path -LiteralPath $stopPath)) { return $false }
        # Dispatcher instances intentionally do not have Terra usage polling.
        # Their next worker attempt is the connection check after the delay.
        if (-not $LimitsEnabled) {
            Write-Host 'Retrying the interrupted iteration after the network wait.'
            return $true
        }
        try {
            [void](Get-BudgetSnapshot $Executable $Directory $Budget $LogRoot)
            Write-Host 'OpenCode connection check succeeded. Retrying the interrupted iteration.'
            return $true
        } catch {
            Write-Warning "OpenCode connection check failed: $($_.Exception.Message)"
        }
    }
    return $false
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
    foreach ($line in [System.IO.File]::ReadAllLines($RoadmapFile)) {
        if (Test-RoadmapTask $line $false $TaskIdPattern) { $count++ }
    }
    return $count
}
function Get-NextPendingRoadmapTask([string]$RoadmapFile, [string]$TaskIdPattern = '') {
    $idPattern = if ([string]::IsNullOrWhiteSpace($TaskIdPattern)) { '[A-Za-z][A-Za-z0-9_]{1,31}-\d{2,}' } else { $TaskIdPattern }
    # ReadAllLines closes the stream before an early return. ReadLines keeps a
    # lazy enumerator open on Windows and could prevent the worker from editing
    # the selected roadmap file.
    foreach ($line in [System.IO.File]::ReadAllLines($RoadmapFile)) {
        if (-not (Test-RoadmapTask $line $false $TaskIdPattern)) { continue }
        $id = ''; try { $match = [regex]::Match($line,$idPattern); if ($match.Success) { $id = $match.Value } } catch { }
        $title = ($line -replace '^\s*-\s*\[ \]\s*','' -replace '\s+',' ').Trim()
        if ($title.Length -gt 140) { $title = $title.Substring(0,140) + '...' }
        return [pscustomobject]@{ Id=$id; Title=$title }
    }
    return [pscustomobject]@{ Id=''; Title='' }
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
    Ensure-Directory (Split-Path -Parent $Filename)
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
function ConvertTo-UtcTimestamp($Value, [string]$ErrorMessage) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw $ErrorMessage }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    try {
        return [DateTimeOffset]::Parse([string]$Value, $Invariant, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
    } catch {
        throw $ErrorMessage
    }
}
function Get-BudgetMode($Settings) {
    $m = [string](Read-Member $Settings 'mode')
    if ([string]::IsNullOrWhiteSpace($m)) { $m = 'daily' } # schema v1 compatibility
    if ($m -cnotin @('daily','hourly','balance','hybrid','unlimited')) { throw "Unsupported budget mode '$m'." }
    if ($m -eq 'unlimited' -and -not [bool](Read-Member $Settings 'allowUnlimited')) {
        throw 'Unrestricted spending requires explicit budget.allowUnlimited=true.'
    }
    return $m
}
function Get-ActiveOpenCodeAccount($Config) {
    $settings = Read-Member $Config 'openCode'
    if ($null -eq $settings) { return [ordered]@{ id='legacy'; usageKind='balance'; provider=''; credentialId=''; label='Legacy API configuration'; authMethod='key' } }
    $activeId = [string](Read-Member $settings 'activeAccountId')
    $accounts = @((Read-Member $settings 'accounts'))
    if ($accounts.Count -eq 0) { return [ordered]@{ id='legacy'; usageKind='balance'; provider=''; credentialId=''; label='Legacy API configuration'; authMethod='key' } }
    foreach ($account in $accounts) {
        if ([string](Read-Member $account 'id') -eq $activeId) { return $account }
    }
    throw 'No active OpenCode account is configured. Select one in Settings > OpenCode accounts, model and reasoning.'
}
function Get-OpenCodeUsageKind($Config) {
    $kind = [string](Read-Member (Get-ActiveOpenCodeAccount $Config) 'usageKind')
    if ($kind -notin @('balance','quota','oauth','local','unlimited')) { throw "Unsupported or unclassified OpenCode account usage kind '$kind'. Select a profile again." }
    return $kind
}
function New-ZeroUsage([string]$Scope) {
    return [pscustomobject]@{ Scope=$Scope; Day=(Get-Date).ToString('yyyy-MM-dd'); CostUSD=0.0; Tokens=0.0; CheckedAt=(Get-Date).ToString('o') }
}
function Get-QuotaSnapshot($Account, [string]$Executable = '', [string]$Directory = '', $Budget = $null) {
    $quota = Read-Member $Account 'quota'
    if ($null -eq $quota -or -not [bool](Read-Member $quota 'configured')) {
        throw 'Provider snapshot is not configured. Set a current balance or quota snapshot in Profiles before development.'
    }
    $remaining = Require-NonNegativeNumber (Read-Member $quota 'remaining') 'quota.remaining'
    $reserve = Require-NonNegativeNumber (Read-Member $quota 'reserve') 'quota.reserve'
    $observed = ConvertTo-UtcTimestamp (Read-Member $quota 'observedAt') 'Provider snapshot has no valid observation time. Refresh it in Profiles.'
    $observedAt = $observed.ToString('o')
    $maxAge = Require-PositiveNumber (Read-Member $quota 'maxAgeMinutes') 'quota.maxAgeMinutes'
    $age = ([DateTimeOffset]::UtcNow - $observed.ToUniversalTime()).TotalMinutes
    if ($age -lt -2 -or $age -gt $maxAge) { throw "Provider snapshot is stale ($([Math]::Round($age,1)) minutes). Refresh it in Profiles before development." }
    $allTime = New-ZeroUsage 'all'; $reportedRemaining = $remaining; $estimatedSpend = $null
    if ([bool](Read-Member $quota 'trackOpenCodeCosts')) {
        $baseline = Require-NonNegativeNumber (Read-Member $quota 'costBaselineAllTimeUsd') 'quota.costBaselineAllTimeUsd'
        if ([string]::IsNullOrWhiteSpace($Executable) -or [string]::IsNullOrWhiteSpace($Directory) -or $null -eq $Budget) { throw 'OpenCode cost tracking requires runner context.' }
        $allTime = Get-Usage $Executable $Directory $Budget 'all'
        $estimatedSpend = [Math]::Max(0.0, [double]$allTime.CostUSD - $baseline)
        $remaining = [Math]::Max(0.0, $remaining - $estimatedSpend)
    }
    return [pscustomobject]@{ Kind='quota'; Mode='quota'; Daily=(New-ZeroUsage 'day'); AllTime=$allTime; BalanceUSD=$null; BalanceSource=''; BalanceObservedAt=''; QuotaRemaining=$remaining; QuotaReportedRemaining=$reportedRemaining; QuotaEstimatedSpendUSD=$estimatedSpend; QuotaReserve=$reserve; QuotaUnit=[string](Read-Member $quota 'unit'); QuotaObservedAt=$observedAt }
}
function New-LocalSnapshot {
    return [pscustomobject]@{ Kind='local'; Mode='local'; Daily=(New-ZeroUsage 'day'); AllTime=(New-ZeroUsage 'all'); BalanceUSD=$null; BalanceSource=''; BalanceObservedAt=''; QuotaRemaining=$null; QuotaReportedRemaining=$null; QuotaEstimatedSpendUSD=$null; QuotaReserve=$null; QuotaUnit=''; QuotaObservedAt='' }
}
function New-OAuthSnapshot {
    # OAuth plan usage and reset windows belong to the provider. Never invent a
    # local number or block a paid-free OAuth account on a manually typed quota.
    return [pscustomobject]@{ Kind='oauth'; Mode='oauth'; Daily=(New-ZeroUsage 'day'); AllTime=(New-ZeroUsage 'all'); BalanceUSD=$null; BalanceSource='provider-managed'; BalanceObservedAt=''; QuotaRemaining=$null; QuotaReportedRemaining=$null; QuotaEstimatedSpendUSD=$null; QuotaReserve=$null; QuotaUnit=''; QuotaObservedAt='' }
}
function New-UnlimitedSnapshot {
    return [pscustomobject]@{ Kind='unlimited'; Mode='unlimited'; Daily=(New-ZeroUsage 'day'); AllTime=(New-ZeroUsage 'all'); BalanceUSD=$null; BalanceSource=''; BalanceObservedAt=''; QuotaRemaining=$null; QuotaReportedRemaining=$null; QuotaEstimatedSpendUSD=$null; QuotaReserve=$null; QuotaUnit=''; QuotaObservedAt='' }
}
function New-UntrackedSnapshot {
    return [pscustomobject]@{ Kind='untracked'; Mode='disabled'; Daily=(New-ZeroUsage 'day'); AllTime=(New-ZeroUsage 'all'); BalanceUSD=$null; BalanceSource=''; BalanceObservedAt=''; QuotaRemaining=$null; QuotaReportedRemaining=$null; QuotaEstimatedSpendUSD=$null; QuotaReserve=$null; QuotaUnit=''; QuotaObservedAt='' }
}
function Switch-OpenCodeAccount([string]$Executable, $Account, [string]$Directory) {
    if ([string](Read-Member $Account 'usageKind') -eq 'local') { return }
    $provider = [string](Read-Member $Account 'provider'); $credential = [string](Read-Member $Account 'credentialId')
    if (-not $provider -or -not $credential) { throw 'The selected OpenCode account has no provider or credential ID.' }
    [void](Invoke-Cli $Executable @('auth','switch',$provider,$credential) $Directory)
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
    $at = ConvertTo-UtcTimestamp (Read-Member $value 'observedAt') 'Balance command must return observedAt in ISO 8601 with timezone.'
    $lag = ([DateTimeOffset]::UtcNow - $at.ToUniversalTime()).TotalMinutes
    $maxLag = Require-PositiveNumber (Read-Member $Settings 'maxAgeMinutes') 'balance.maxAgeMinutes'
    if ($lag -lt -2 -or $lag -gt $maxLag) { throw "Balance provider observation is not recent (age $([Math]::Round($lag,1)) minutes)." }
    return [pscustomobject]@{ AmountUSD=[double]$amount; Source='external-command'; ObservedAt=$at.ToString('o') }
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
    $account = Get-ActiveOpenCodeAccount $cfg
    $kind = Get-OpenCodeUsageKind $cfg
    if ($kind -eq 'quota' -and $SkipProviderSnapshotGuard) { return (New-UnlimitedSnapshot) }
    if ($kind -eq 'quota') { return (Get-QuotaSnapshot $account $Executable $Directory $Budget) }
    if ($kind -eq 'oauth') { return (New-OAuthSnapshot) }
    if ($kind -eq 'unlimited') { return (New-UnlimitedSnapshot) }
    if ($kind -eq 'local') { return (New-LocalSnapshot) }
    $mode = Get-BudgetMode $Budget
    $day = Get-Usage $Executable $Directory $Budget 'day'
    $all = Get-Usage $Executable $Directory $Budget 'all'
    $hour = Get-HourlyUsage $Root
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
        Kind='balance'; Mode=$mode; Daily=$day; Hourly=$hour; AllTime=$all; BalanceUSD=$balance
        BalanceSource=$source; BalanceObservedAt=$observedAt; QuotaRemaining=$null; QuotaReportedRemaining=$null; QuotaEstimatedSpendUSD=$null; QuotaReserve=$null; QuotaUnit=''; QuotaObservedAt=''
    }
}
function Get-BudgetStopReason($Snapshot, $Budget, [bool]$Emergency) {
    if ($Snapshot.Kind -in @('local','oauth','unlimited')) { return '' }
    if ($Snapshot.Kind -eq 'quota') {
        $cutoff = [double]$Snapshot.QuotaReserve
        if ([double]$Snapshot.QuotaRemaining -le $cutoff) {
            return "provider snapshot threshold reached (reported $($Snapshot.QuotaRemaining) $($Snapshot.QuotaUnit), threshold $cutoff $($Snapshot.QuotaUnit))"
        }
        return ''
    }
    $mode = $Snapshot.Mode
    if ($mode -eq 'hourly') {
        $cap = [double]$Budget.hourlyUsd
        if ($Snapshot.Hourly.CostUSD -ge $cap) { return "hourly budget threshold reached (spent $($Snapshot.Hourly.CostUSD), threshold $cap)" }
    }
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
    if ($Snapshot.Kind -eq 'local') { Write-Host 'Local model: no provider balance or quota limits are configured.'; return }
    if ($Snapshot.Kind -eq 'oauth') { Write-Host 'OpenCode OAuth: usage and reset windows are managed by the provider; no local quota is estimated.'; return }
    if ($Snapshot.Kind -eq 'unlimited') { Write-Host 'WARNING: provider limits are disabled for this profile.' -ForegroundColor Yellow; return }
    if ($Snapshot.Kind -eq 'quota') {
        if ($null -ne $Snapshot.QuotaEstimatedSpendUSD) {
            Write-Host ('Provider snapshot: {0:N2} {1}; local OpenCode spend since snapshot ${2:N4}; estimated remaining {3:N2} {1}; launch threshold {4:N2} {1}' -f [double]$Snapshot.QuotaReportedRemaining,$Snapshot.QuotaUnit,[double]$Snapshot.QuotaEstimatedSpendUSD,[double]$Snapshot.QuotaRemaining,[double]$Snapshot.QuotaReserve)
        } else {
            Write-Host ('Provider snapshot: {0:N2} {1} remaining; launch threshold {2:N2} {1}' -f [double]$Snapshot.QuotaRemaining,$Snapshot.QuotaUnit,[double]$Snapshot.QuotaReserve)
        }
        Show-ProgressMeters $Snapshot $Budget
        return
    }
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
    if ($Snapshot.Kind -in @('local','oauth')) { return }
    if ($Snapshot.Kind -eq 'quota') {
        if ($Snapshot.QuotaUnit -eq 'percent') {
            $ratio = [Math]::Min(1.0,[Math]::Max(0.0,[double]$Snapshot.QuotaRemaining / 100.0))
            $filled = [Math]::Min(26,[Math]::Max(0,[int][Math]::Round($ratio*26)))
            Write-Host ('  QUOTA   [{0}{1}] {2:N1}% remaining' -f ('█'*$filled),('░'*(26-$filled)),($ratio*100)) -ForegroundColor $(if ($ratio -le 0.1) { 'Yellow' } else { 'Cyan' })
        }
        return
    }
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
    $relative = [IO.Path]::GetRelativePath($Directory, $RoadmapFile).Replace('\','/')
    $old = Invoke-Cli 'git' @('-C',$Directory,'show',("${BeforeHead}:$relative")) $Directory
    $new = Get-Content -LiteralPath $RoadmapFile -Raw -Encoding UTF8
    # A schema v3 project may intentionally omit taskIdPattern. Keep its task IDs
    # visible by recognising the conventional PREFIX-123 form instead of silently
    # reporting a completed roadmap item without an ID.
    $effectivePattern = if ([string]::IsNullOrWhiteSpace($TaskIdPattern)) { '[A-Za-z][A-Za-z0-9_]{1,31}-\d{2,}' } else { $TaskIdPattern }
    try { $regex = [regex]::new('(?m)^\s*-\s*\[[xX]\].*?(' + $effectivePattern + ')') }
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
    $usageKinds = [System.Collections.Generic.HashSet[string]]::new(); $latestQuota = $null
    $ids = [System.Collections.Generic.HashSet[string]]::new(); $commits = [System.Collections.Generic.List[string]]::new()
    foreach ($summary in $summaries) {
        $kind = [string](Read-Member $summary 'accountUsageKind'); if (-not $kind) { $kind = 'balance' }; [void]$usageKinds.Add($kind)
        $delta = Read-Member $summary 'costDeltaUSD'; if ($kind -eq 'balance' -and $null -ne $delta) { $cost += [double]$delta }
        if ($kind -eq 'quota') { $latestQuota = $summary }
        $tasks += [Math]::Max(0,[int](Read-Member $summary 'doneAfter')-[int](Read-Member $summary 'doneBefore'))
        if ([bool](Read-Member $summary 'pushVerified')) { $pushes++ }
        $code += [int](Read-Member $summary 'codeFilesChanged'); $tests += [int](Read-Member $summary 'testFilesChanged'); $docs += [int](Read-Member $summary 'documentationFilesChanged'); $errors += [int](Read-Member $summary 'toolErrors')
        foreach ($id in @(Read-Member $summary 'completedTaskIds')) { if ($id) { [void]$ids.Add([string]$id) } }
        foreach ($commit in @(Read-Member $summary 'commits')) { if ($commit) { $commits.Add(([string](Read-Member $commit 'hash') + ' ' + [string](Read-Member $commit 'subject'))) } }
    }
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add("# Terra Runner daily report — $Date"); $rows.Add(''); $rows.Add("Project: **$(Split-Path $DataDirectory -Leaf)**"); $rows.Add('')
    $rows.Add("- Iterations: **$($summaries.Count)**; completed roadmap tasks: **$tasks**; verified pushes: **$pushes**")
    if ($usageKinds.Count -eq 1 -and $usageKinds.Contains('balance')) { $rows.Add(('- Estimated local OpenCode usage during iterations: **${0:N4}**' -f $cost)) }
    elseif ($usageKinds.Count -eq 1 -and $usageKinds.Contains('quota') -and $null -ne $latestQuota) { $rows.Add(('- Latest provider-reported quota snapshot: **{0} {1}**; reserve **{2} {1}**' -f (Read-Member $latestQuota 'quotaRemaining'),(Read-Member $latestQuota 'quotaUnit'),(Read-Member $latestQuota 'quotaReserve'))) }
    elseif ($usageKinds.Count -eq 1 -and $usageKinds.Contains('local')) { $rows.Add('- Local model profile: **no provider balance or quota tracking**.') }
    elseif ($usageKinds.Count -eq 1 -and $usageKinds.Contains('untracked')) { $rows.Add('- Dispatcher instance: **Terra budget and quota tracking disabled**.') }
    else { $rows.Add('- Mixed account usage: see each iteration policy below.') }
    $rows.Add("- Changed files: code **$code**, tests **$tests**, documentation **$docs**; tool errors **$errors**")
    if ($ids.Count) { $rows.Add('- Completed task IDs: ' + (@($ids | Sort-Object) -join ', ')) }
    if ($commits.Count) { $rows.Add(''); $rows.Add('## Commits'); foreach ($commit in $commits) { $rows.Add('- ' + $commit) } }
    $rows.Add(''); $rows.Add('| Time | Iteration | Policy | Tasks | Code | Tests | Docs | Usage | Push | Stop reason |'); $rows.Add('|---|---|---|---:|---:|---:|---:|---|---|---|')
    foreach ($summary in $summaries) {
        $started = [string](Read-Member $summary 'started'); $time = if ($started.Length -ge 19) { $started.Substring(11,8) } else { '--:--:--' }
        $completed = [Math]::Max(0,[int](Read-Member $summary 'doneAfter')-[int](Read-Member $summary 'doneBefore'))
        $kind = [string](Read-Member $summary 'accountUsageKind'); if (-not $kind) { $kind='balance' }
        $delta = Read-Member $summary 'costDeltaUSD'; $displayCost = if ($kind -eq 'quota') { ('{0} {1}' -f (Read-Member $summary 'quotaRemaining'),(Read-Member $summary 'quotaUnit')) } elseif ($kind -in @('local','untracked')) { 'not tracked' } elseif ($null -eq $delta) { '?' } else { ('$' + ([double]$delta).ToString('F4',$Invariant)) }
        $reason = [string](Read-Member $summary 'stoppedReason'); if (-not $reason) { $reason = '-' }
        $rows.Add(('| {0} | `{1}` | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f $time,[string](Read-Member $summary 'id'),$kind,$completed,[int](Read-Member $summary 'codeFilesChanged'),[int](Read-Member $summary 'testFilesChanged'),[int](Read-Member $summary 'documentationFilesChanged'),$displayCost,([bool](Read-Member $summary 'pushVerified')),$reason.Replace('|','/')))
    }
    $rows.Add(''); $rows.Add('Balance is derived from local OpenCode statistics and is an estimate, not provider billing. OAuth plan usage and reset windows are managed by the provider and are not locally estimated. Local profiles and dispatcher instances have no Terra provider-limit tracking. Verification commands observed in agent logs do not by themselves prove successful tests.')
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
if ([int]$cfg.schemaVersion -notin @(1,2,3,4,5,6,7,8,9,10,11)) { throw 'Unsupported terra-config.json schemaVersion.' }
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
$runtimeRoot = Join-Path (Split-Path -Parent $Config) 'runtime'
$requiresProjectInstructions = [bool]($Once -or $Continuous -or $DryRun)
$projectInstructions = $null
$instance = $null
$limitsEnabled = -not [bool]$InstanceId
$requiresExplicitProfile = -not $InstanceId -and ($Once -or $Continuous -or $DryRun -or $Status -or $hasSetBalance)
if ([int]$cfg.schemaVersion -ge 9 -and $requiresExplicitProfile -and [string]::IsNullOrWhiteSpace($ProfileId)) {
    throw "schema v9+ requires -ProfileId for this command. Select a profile in Terra Runner or pass -ProfileId <profile-id>."
}
if ($InstanceId -and -not [string]::IsNullOrWhiteSpace($AuthStoreId)) {
    throw '-AuthStoreId is only accepted for a main-window profile launch. Dispatcher instances use their immutable authentication-store snapshot.'
}
if ($InstanceId -or $ProfileId) {
    if ($InstanceId -and $InstanceId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Unsafe instance ID.' }
    if ($InstanceId) {
        $instancePath = Join-Path (Join-Path $runtimeRoot 'instances') "$InstanceId.json"
        if (-not (Test-Path -LiteralPath $instancePath -PathType Leaf)) { throw "Instance '$InstanceId' was not found." }
        $instance = Get-Content -LiteralPath $instancePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 30
        if ([string](Read-Member $instance 'projectId') -ne $Project) { throw 'Instance project does not match -Project.' }
        $profile = Read-Member $instance 'profile'
        if ($null -eq $profile) { throw 'Instance profile snapshot is missing.' }
    } else {
        $profiles = @((Read-Member (Read-Member $cfg 'openCode') 'profiles') | Where-Object { [string](Read-Member $_ 'id') -eq $ProfileId })
        if ($profiles.Count -ne 1) { throw "Expected exactly one profile with id '$ProfileId'." }
        $profile = $profiles[0]
    }
    $cfg.model = [string](Read-Member $profile 'model')
    $variant = [string](Read-Member $profile 'reasoningVariant'); if ($variant) { $cfg.model += "#$variant" }
    $cfg.openCode = [ordered]@{ activeAccountId='instance'; reasoning=[ordered]@{ variant=$variant; showThinking=[bool](Read-Member $profile 'showThinking') }; accounts=@() }
    $policy = [string](Read-Member $profile 'policy')
    $usageKind = if ($policy -eq 'local') { 'local' } elseif ([string](Read-Member (Read-Member $profile 'limitPolicy') 'mode') -eq 'unlimited') { 'unlimited' } elseif ($policy -eq 'oauth-managed') { 'quota' } else { 'balance' }
    $instanceAuthMethod = if ($policy -eq 'oauth-managed') { 'oauth' } elseif ($policy -eq 'local') { 'local' } else { 'key' }
    $quota = if ($policy -eq 'local') { $null } else { $usage = Read-Member $profile 'usageSource'; [ordered]@{ configured=($null -ne (Read-Member $usage 'remaining')); unit=[string](Read-Member $usage 'unit'); remaining=(Read-Member $usage 'remaining'); reserve=(Read-Member $usage 'reserve'); maxAgeMinutes=(Read-Member $usage 'maxAgeMinutes'); observedAt=[string](Read-Member $usage 'observedAt'); trackOpenCodeCosts=[bool](Read-Member (Read-Member $usage 'costTracking') 'enabled'); costBaselineAllTimeUsd=(Read-Member (Read-Member $usage 'costTracking') 'baselineAllTimeCostUsd'); costBaselineObservedAt=[string](Read-Member (Read-Member $usage 'costTracking') 'baselineObservedAt') } }
    $cfg.openCode.accounts = @([ordered]@{ id='instance'; provider=[string](Read-Member $profile 'provider'); credentialId=[string](Read-Member $profile 'credentialId'); label=[string](Read-Member $profile 'credentialLabel'); authMethod=$instanceAuthMethod; usageKind=$usageKind; quota=$quota })
    if ($policy -eq 'api' -and $null -ne (Read-Member $profile 'limits')) { $cfg.budget = Read-Member $profile 'limits' }
    $route = Read-Member $instance 'proxyRoute'
    if ($null -ne $route) { $cfg.proxy = [ordered]@{ activeRouteId=[string](Read-Member $route 'id'); routes=@($route) } }
    $storeId = if ($InstanceId -or [string]::IsNullOrWhiteSpace($AuthStoreId)) { [string](Read-Member $profile 'authStoreId') } else { $AuthStoreId }
    if ($storeId -and $storeId -ne 'legacy-shared') {
        if ($storeId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw 'Unsafe OpenCode auth store ID.' }
        $storeDb = Join-Path (Join-Path (Join-Path (Split-Path -Parent $Config) 'opencode-stores') $storeId) 'opencode.db'
        if (-not ($Stop -or $Abort -or $ClearStop -or $ClearControlFlags)) {
            if (-not (Test-Path -LiteralPath $storeDb -PathType Leaf)) { throw "OpenCode auth store '$storeId' is not initialized. Reconnect the selected profile in Terra Runner and try again." }
            $env:OPENCODE_DB = $storeDb
        }
    }
}
$stopPath = if ($InstanceId) { Join-Path (Join-Path (Join-Path $runtimeRoot 'controls') $InstanceId) 'STOP' } else { Join-Path $projectData 'STOP' }
$abortPath = if ($InstanceId) { Join-Path (Join-Path (Join-Path $runtimeRoot 'controls') $InstanceId) 'ABORT' } else { Join-Path $projectData 'ABORT' }
Ensure-Directory $projectData
Ensure-Directory $logsPath
if ($InstanceId) { Ensure-Directory (Split-Path -Parent $stopPath) }
$activeProxyRoute = Get-ActiveProxyRoute $cfg
if ($ProxyStatus) { if ($null -eq $activeProxyRoute) { Write-Host 'Proxy route: Direct (disabled).' } else { Write-Host "Proxy route: $([string](Read-Member $activeProxyRoute 'name')) ($([string](Read-Member $activeProxyRoute 'protocol'))://$([string](Read-Member $activeProxyRoute 'host')):$([int](Read-Member $activeProxyRoute 'port')))" }; return }
if ($ProxyTest) {
    if ($null -eq $activeProxyRoute) { Write-Host 'Proxy test: Direct route is selected; no proxy is configured.'; return }
    $testBridge = $null
    try { $testBridge = Start-TerraProxyBridge $activeProxyRoute; $null = & curl.exe --proxy $testBridge.Url --connect-timeout 8 --max-time 20 --silent --show-error --head https://example.com/ 2>&1; if ($LASTEXITCODE -ne 0) { throw 'HTTPS CONNECT test failed.' }; Write-Host "Proxy test succeeded through $($testBridge.Display)." } finally { Stop-TerraProxyBridge $testBridge }
    return
}

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
if ($ClearStop -or $ClearControlFlags) {
    foreach ($p in @($stopPath,$abortPath)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
    if ($ClearStop) {
        Write-Host 'Stop/abort flags cleared.'
        return
    }
}

if ($Report) {
    $date = if ($ReportDate) { $ReportDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $reportFile = Write-EnglishDailyReport $projectData $date
    Rotate-Reports $projectData $cfg.logs
    Write-Host "Project daily report: $reportFile"
    return
}

$usageKind = Get-OpenCodeUsageKind $cfg
$activeOpenCodeAccount = Get-ActiveOpenCodeAccount $cfg
$profileBudget = Read-Member $cfg 'budget'
if ($limitsEnabled -and $usageKind -eq 'balance' -and $null -eq $profileBudget) {
    throw "The selected profile is missing its API limit policy. Edit the profile before development."
}
$budgetMode = if ($limitsEnabled -and $usageKind -eq 'balance') { Get-BudgetMode $profileBudget } elseif ($limitsEnabled) { $usageKind } else { 'disabled' }
if ($limitsEnabled -and $usageKind -eq 'balance' -and -not [bool]$profileBudget.requireGlobalOpenCodeStats) {
    throw 'The global OpenCode usage scope is required for reliable local accounting.'
}
if ($limitsEnabled -and $usageKind -eq 'balance' -and $budgetMode -in @('daily','hybrid')) {
    Require-PositiveNumber $profileBudget.dailyUsd 'budget.dailyUsd' | Out-Null
    [void](Require-NonNegativeNumber $profileBudget.reserveUsd 'budget.reserveUsd')
    Require-PositiveNumber $profileBudget.emergencyStopUsd 'budget.emergencyStopUsd' | Out-Null
    if ([double]$profileBudget.emergencyStopUsd -gt [double]$profileBudget.dailyUsd) {
        throw 'emergencyStopUsd must not exceed dailyUsd.'
    }
    if ([double]$profileBudget.reserveUsd -ge [double]$profileBudget.dailyUsd) {
        throw 'reserveUsd must be below dailyUsd.'
    }
}
if ($limitsEnabled -and $usageKind -eq 'balance' -and $budgetMode -eq 'hourly') {
    Require-PositiveNumber $profileBudget.hourlyUsd 'budget.hourlyUsd' | Out-Null
}
if ($limitsEnabled -and $usageKind -eq 'balance' -and $budgetMode -in @('balance','hybrid')) {
    if ($null -eq (Read-Member $profileBudget 'balance')) { throw 'budget.balance is required.' }
    [void](Require-NonNegativeNumber $profileBudget.balance.minimumUsd 'budget.balance.minimumUsd')
    [void](Require-NonNegativeNumber $profileBudget.balance.iterationReserveUsd 'budget.balance.iterationReserveUsd')
    if ($profileBudget.balance.source -eq 'snapshot') { [void](Get-BalanceStatePath $logRoot $profileBudget.balance) }
    elseif ($profileBudget.balance.source -ne 'command') { throw 'budget.balance.source must be snapshot or command.' }
}
if ($hasSetBalance -and (-not $limitsEnabled -or $usageKind -ne 'balance' -or $budgetMode -notin @('balance','hybrid'))) {
    throw '-SetBalanceUsd is only available in balance/hybrid modes.'
}
if ($hasSetBalance -and $profileBudget.balance.source -ne 'snapshot') {
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
$transientRetryDelaySeconds = if ($null -ne (Read-Member $cfg.execution 'transientRetryDelaySeconds')) { [int]$cfg.execution.transientRetryDelaySeconds } else { 30 }
$maxPushRetries = if ($null -ne (Read-Member $cfg.execution 'maxPushRetries')) { [int]$cfg.execution.maxPushRetries } else { 3 }
$pushRetryDelaySeconds = if ($null -ne (Read-Member $cfg.execution 'pushRetryDelaySeconds')) { [int]$cfg.execution.pushRetryDelaySeconds } else { 30 }
if ($transientRetryDelaySeconds -lt 1) { throw 'transientRetryDelaySeconds must be >= 1.' }
if ($maxPushRetries -lt 1) { throw 'maxPushRetries must be >= 1.' }
if ($pushRetryDelaySeconds -lt 1) { throw 'pushRetryDelaySeconds must be >= 1.' }
$maxCycles = if ($UnlimitedIterations) { [int]::MaxValue } elseif ($MaxIterations -gt 0) { $MaxIterations } else { [int]$cfg.execution.maxIterationsPerRun }
if ($Once) { $maxCycles = 1 }
if ($maxCycles -lt 1) { throw 'No iterations configured.' }

if ($Status) {
    if ($limitsEnabled) {
        $snapshot = Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot
        Show-Usage $snapshot $profileBudget
        $reason = Get-BudgetStopReason $snapshot $profileBudget $false
        if ($reason) { Write-Host "No new iteration allowed: $reason" }
    } else { Write-Host 'Terra limits and provider snapshots are disabled for this dispatcher instance.' }
    Write-Host "Project logs: $logsPath"
    Write-Host "STOP: $(Test-Path -LiteralPath $stopPath); ABORT: $(Test-Path -LiteralPath $abortPath)"
    return
}

if (-not ($Once -or $Continuous -or $DryRun -or $hasSetBalance)) {
    Write-Host 'No development command was selected. Use -Once or -Continuous to start OpenCode.'
    Write-Host 'Informational commands such as -Status and -Report never start an agent.'
    return
}

# One Git worktree can have only one active runner; different projects remain
# independent and may run concurrently.
$projectLockPath = Join-Path $projectData 'project-runner.lock'
Ensure-Directory (Split-Path -Parent $projectLockPath)
$lock = $null
$activeChild = $null
$proxyBridge = $null
try {
    try {
        $lock = [System.IO.File]::Open($projectLockPath,[System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    } catch { throw "Another Terra Runner already owns project '$Project'. A Git worktree cannot run two agents at once." }

    $branch = (Invoke-Cli 'git' @('-C',$repo,'branch','--show-current') $repo).Trim()
    if ($branch -cne [string]$projectConfig.branch) { throw "Wrong Git branch '$branch'; expected '$($projectConfig.branch)'" }
    [void](Invoke-Cli 'git' @('-C',$repo,'remote','get-url','origin') $repo)
    $pendingPush = Wait-ForGitRemotePublish $repo ([string]$projectConfig.branch) $maxPushRetries $pushRetryDelaySeconds $stopPath $abortPath
    if (-not $pendingPush.Success) {
        if ($pendingPush.Interrupted) {
            Write-Host "Git remote wait interrupted by $($pendingPush.Reason)."
            return
        }
        throw "Local and remote branch heads differ or could not be verified: $($pendingPush.Error)"
    }
    if ($requiresProjectInstructions) {
        $projectInstructions = Resolve-ProjectInstructionsFile $repo $projectConfig
        Assert-ProjectInstructionsFile $repo $projectInstructions
    }
    $initialGitStatus = Invoke-Cli 'git' @('-C',$repo,'status','--porcelain') $repo
    $instructionsAreOnlyChange = $requiresProjectInstructions -and (Test-OnlyProjectInstructionsChanges $repo $projectInstructions)
    if ($initialGitStatus.Trim() -ne '' -and -not $instructionsAreOnlyChange -and ($Once -or $Continuous)) {
        $recovery = Recover-TerraInterruptedWork $repo ([string]$projectConfig.branch) $projectData $maxPushRetries $pushRetryDelaySeconds $stopPath $abortPath
        if ($null -ne $recovery -and $recovery.Interrupted) { return }
        $initialGitStatus = Invoke-Cli 'git' @('-C',$repo,'status','--porcelain') $repo
        $instructionsAreOnlyChange = $requiresProjectInstructions -and (Test-OnlyProjectInstructionsChanges $repo $projectInstructions)
    }
    if ($initialGitStatus.Trim() -ne '' -and -not $instructionsAreOnlyChange) {
        throw 'Git working tree has uncommitted/untracked changes. Review and resolve them before automated execution.'
    }
    if ($instructionsAreOnlyChange) {
        Write-Host "Project instructions are the only local Git change. The worker must commit '$($projectInstructions.Relative)' unchanged before task work."
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
    if ($limitsEnabled -and ($usageKind -eq 'balance' -or ($usageKind -eq 'quota' -and [bool](Read-Member (Read-Member $activeOpenCodeAccount 'quota') 'trackOpenCodeCosts')))) {
        $statsHelp = Invoke-Cli $openCode @('stats','--help') $repo
        if ($statsHelp -notmatch '\-\-json') { throw 'Installed OpenCode lacks stats --json; update to compatible OpenCode v2.' }
    }
    if (($Once -or $Continuous -or $hasSetBalance) -and [string](Read-Member $activeOpenCodeAccount 'id') -ne 'legacy') {
        Switch-OpenCodeAccount $openCode $activeOpenCodeAccount $repo
        Write-Host "OpenCode account selected: $([string](Read-Member $activeOpenCodeAccount 'label')) ($usageKind)"
    }
    if ($hasSetBalance) {
        $all = Get-Usage $openCode $repo $profileBudget 'all'
        $stateFile = Get-BalanceStatePath $logRoot $profileBudget.balance
        Set-BalanceSnapshot $stateFile ([double]$setBalanceAmount) $all ([bool]$ReconcileBalance)
        Write-Host ('Balance snapshot saved: {0}; OpenCode lifetime baseline ${1:N4}; file: {2}' -f (Format-TerraMoney $setBalanceAmount),$all.CostUSD,$stateFile)
        return
    }
    if ($DryRun) {
        # A dry run must not write logs or budgets, but it still verifies that
        # the selected account's usage data is internally consistent.
        if ($limitsEnabled) { [void](Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot) }
        Write-Host "DRY RUN OK: project=$Project branch=$branch iterations=$maxCycles; would launch agent '$($cfg.agent)'."
        return
    }
    if ($null -ne $activeProxyRoute) { $proxyBridge = Start-TerraProxyBridge $activeProxyRoute; Write-Host "Proxy route enabled for this Terra run: $($proxyBridge.Display)" }
    $initialUsage = if ($limitsEnabled) { Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot } else { New-UntrackedSnapshot }
    if ($limitsEnabled) { Show-Usage $initialUsage $profileBudget } else { Write-Host 'Terra budget, quota, and snapshot controls are disabled for this dispatcher instance.' }
    Rotate-ProjectLogs $logsPath $cfg.logs
    Rotate-Reports $projectData $cfg.logs
    if (Test-Path -LiteralPath $stopPath) { throw "STOP flag exists: $stopPath. Use -ClearStop after review." }
    if (Test-Path -LiteralPath $abortPath) { throw "ABORT flag exists: $abortPath. Use -ClearStop after review." }

    # These safety counters deliberately apply to one explicit development
    # launch. A prior, completed launch must not make a newly requested
    # Continuous run stop after its first iteration.
    $noProgress = 0
    $docsOnly = 0
    $activeChild = $null
    for ($i = 1; $i -le $maxCycles; $i++) {
        if (Test-Path -LiteralPath $stopPath) { Write-Host 'STOP detected; exiting after previous iteration.'; break }
        if (Test-Path -LiteralPath $abortPath) { Write-Host 'ABORT detected; exiting.'; break }
        $usageBefore = if ($limitsEnabled) { Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot } else { New-UntrackedSnapshot }
        if ($limitsEnabled) {
            Show-Usage $usageBefore $profileBudget
            $budgetBlock = Get-BudgetStopReason $usageBefore $profileBudget $false
            if ($budgetBlock) { Write-Host "Cannot start next iteration: $budgetBlock"; break }
        }
        $pending = Count-Pending $roadmap $taskIdPattern
        if ($pending -eq 0) { Write-Host 'No pending roadmap checkbox tasks found. Stopping.'; break }
        # The file is user-owned and versioned. Re-check it before every worker
        # so a newly committed project rule applies to the next iteration.
        Assert-ProjectInstructionsFile $repo $projectInstructions
        $plannedTask = Get-NextPendingRoadmapTask $roadmap $taskIdPattern
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
        [void](Write-TerraRecoveryMarker $projectData $runId $branch $headBefore)
        Write-Host "Iteration $i/$maxCycles [$runId], pending tasks: $pending"
        Write-UiEvent 'iteration-started' @{ iteration=$i; total=$(if ($UnlimitedIterations) { $null } else { $maxCycles }); runId=$runId; pending=$pending; taskId=$plannedTask.Id; taskTitle=$plannedTask.Title; eventsFile=$eventsPath }
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
            $argsList = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$workerFile,
                '-OpenCodeCommand',$openCode,'-ProjectPath',$repo,'-PromptFile',$promptFile,
                '-ProjectInstructionsFile',$projectInstructions.Path,
                '-EventsFile',$eventsPath,'-ErrorFile',$stderrPath,'-Agent',([string]$cfg.agent),'-Model',([string]$cfg.model))
            if ($InstanceId -or $ProfileId) { $argsList += '-Standalone' }
            if ($null -ne $proxyBridge) { $argsList += @('-ProxyUrl',$proxyBridge.Url,'-NoProxy',$proxyBridge.NoProxy,'-CaFile',$proxyBridge.CaFile) }
            $reasoning = Read-Member (Read-Member $cfg 'openCode') 'reasoning'
            if ($null -ne $reasoning -and [bool](Read-Member $reasoning 'showThinking')) { $argsList += '-ShowThinking' }
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
                Write-UiEvent 'iteration-heartbeat' @{ iteration=$i; elapsedSeconds=[Math]::Round($elapsed.TotalSeconds,0); eventBytes=$size }
                if ($size -gt ([double]$cfg.execution.maxRawLogMiB * 1MB)) { $termination = 'raw-log-size-limit'; break }
                if ($limitsEnabled) { try {
                    $liveUsage = Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot
                    $liveBlock = Get-BudgetStopReason $liveUsage $profileBudget $true
                    if ($liveBlock) { $termination = "budget-emergency-stop: $liveBlock"; break }
                } catch {
                    $termination = "budget-unverifiable: $($_.Exception.Message)"
                    break
                } }
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
        if ($limitsEnabled) { try { $usageAfter = Get-BudgetSnapshot $openCode $repo $profileBudget $logRoot } catch { $usageError = $_.Exception.Message } } else { $usageAfter = New-UntrackedSnapshot }
        $headAfter = Get-Head $repo
        $doneAfter = Count-Completed $roadmap $taskIdPattern
        $eventErrors = 0
        $toolErrors = 0
        $toolErrorExamples = @()
        $verificationCommandsObserved = 0
        $verificationCommandErrors = 0
        $verificationExamples = @()
        $noTasksReported = $false
        $noTaskMessage = ''
        try {
            $eventsReview = Get-EventErrors $eventsPath
            $eventErrors = $eventsReview.Errors
            $toolErrors = $eventsReview.ToolErrors
            $toolErrorExamples = @($eventsReview.ToolErrorExamples)
            $verificationCommandsObserved = $eventsReview.VerificationCommands
            $verificationCommandErrors = $eventsReview.VerificationCommandErrors
            $verificationExamples = @($eventsReview.VerificationExamples)
            $noTasksReported = $eventsReview.NoTasks
            $noTaskMessage = [string]$eventsReview.NoTaskMessage
        } catch {
            if (-not $termination) { $termination = "invalid-event-output: $($_.Exception.Message)" }
        }
        $transientNetworkFailure = Test-TransientNetworkFailure $eventsPath $stderrPath
        if ($transientNetworkFailure) { $termination = 'transient-tls-or-ssl-failure' }
        if ($eventErrors -gt 0 -and -not $termination) { $termination = "opencode-reported-$eventErrors-errors" }
        $maxToolErrors = if ($null -ne (Read-Member $cfg.execution 'maxToolErrorsPerIteration')) { [int]$cfg.execution.maxToolErrorsPerIteration } else { 15 }
        if ($toolErrors -gt $maxToolErrors -and -not $termination) { $termination = "too-many-tool-errors-$toolErrors" }
        $readablePath = $prefix + '.events.readable.jsonl'
        try { Write-ReadableEvents $eventsPath $readablePath }
        catch { if (-not $termination) { $termination = "readable-log-error: $($_.Exception.Message)" } }
        if ((Get-Item -LiteralPath $eventsPath).Length -eq 0 -and -not $termination) {
            $termination = 'empty-opencode-event-stream'
        }
        if ($limitsEnabled -and $null -ne $usageAfter -and
            $usageAfter.AllTime.Tokens -gt $usageBefore.AllTime.Tokens -and
            $usageAfter.AllTime.CostUSD -le $usageBefore.AllTime.CostUSD -and
            $usageKind -eq 'balance' -and [bool]$profileBudget.stopOnZeroCostWithTokens -and -not $termination) {
            $termination = 'new-token-usage-without-recorded-cost'
        }
        $gitStatus = ''
        try { $gitStatus = Invoke-Cli 'git' @('-C',$repo,'status','--porcelain') $repo }
        catch { if (-not $termination) { $termination = "git-status-error: $($_.Exception.Message)" } }
        if ($gitStatus.Trim() -ne '' -and -not $termination) { $termination = 'uncommitted-changes-left-by-agent' }
        $pushVerified = $false
        $remotePublish = Wait-ForGitRemotePublish $repo ([string]$projectConfig.branch) $maxPushRetries $pushRetryDelaySeconds $stopPath $abortPath
        $pushVerified = [bool]$remotePublish.Success
        if ($remotePublish.Interrupted -and -not $termination) { $termination = [string]$remotePublish.Reason }
        elseif (-not $pushVerified -and -not $termination) { $termination = "git-remote-verification-error: $($remotePublish.Error)" }
        if (-not $pushVerified -and -not $termination) { $termination = 'local-and-remote-branch-heads-differ' }
        if ($gitStatus.Trim() -eq '' -and $pushVerified) { Clear-TerraRecoveryMarker $projectData }
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
        # A roadmap checkbox is the strongest completion signal, but it is not
        # the only useful output of an iteration. A verified, pushed code or
        # test change is real implementation progress even when the agent has
        # not yet completed the larger roadmap item. Do not stop an unattended
        # run merely because that item spans several commits.
        $implementationProgressNow = ($doneAfter -gt $doneBefore) -or ($changedFiles.Code -gt 0) -or ($changedFiles.Tests -gt 0)
        $noProgressNow = (-not $implementationProgressNow) -and -not $transientNetworkFailure
        $noProgress = if ($transientNetworkFailure) { $noProgress } elseif ($noProgressNow) { $noProgress + 1 } else { 0 }
        $docsOnlyNow = ($changedFiles.Docs -gt 0 -and $changedFiles.Code -eq 0 -and $changedFiles.Tests -eq 0)
        $docsOnly = if ($docsOnlyNow) { $docsOnly + 1 } else { 0 }
        Save-Json $stateFile ([ordered]@{ noProgress=$noProgress; documentationOnly=$docsOnly; lastRunId=$runId; updatedAt=(Get-Date).ToString('o') })
        $docsLimit = if ($null -ne (Read-Member $cfg.execution 'maxConsecutiveDocumentationOnly')) { [int]$cfg.execution.maxConsecutiveDocumentationOnly } else { 12 }
        if (-not $termination -and $noTasksReported) {
            $pendingAfter = Count-Pending $roadmap $taskIdPattern
            $termination = if ($pendingAfter -eq 0) { 'roadmap-complete' } else { 'no-actionable-roadmap-task' }
        }
        elseif (-not $termination -and $noProgress -ge [int]$cfg.execution.maxConsecutiveNoProgress) {
            $termination = "no-verified-implementation-progress: $noProgress consecutive iteration(s) made no roadmap, code, or test progress"
        }
        elseif (-not $termination -and $docsOnly -ge $docsLimit) {
            $termination = "documentation-only-progress: $docsOnly consecutive iteration(s) changed no code or tests"
        }
        $summary = [ordered]@{
            project = $Project; id = $runId; started = $begin.ToString('o'); ended = $ended.ToString('o')
            elapsedSeconds = [Math]::Round(($ended-$begin).TotalSeconds,1)
            branch = $branch; exitCode = $exitCode; stoppedReason = $termination
            plannedTaskId = $plannedTask.Id; plannedTaskTitle = $plannedTask.Title
            headBefore = $headBefore; headAfter = $headAfter
            pushVerified = $pushVerified; eventErrors = $eventErrors
            toolErrors = $toolErrors; toolErrorExamples = $toolErrorExamples
            verificationCommandsObserved = $verificationCommandsObserved
            verificationCommandErrors = $verificationCommandErrors
            verificationExamples = $verificationExamples
            completedTaskIds = @($completedIds)
            commits = @($iterationCommits)
            noActionableTasksReported = $noTasksReported
            noActionableTasksMessage = $noTaskMessage
            workingTreeClean = ($gitStatus.Trim() -eq '')
            doneBefore = $doneBefore; doneAfter = $doneAfter
            pendingAfter = (Count-Pending $roadmap $taskIdPattern)
            costBeforeUSD = $(if ($limitsEnabled) { $usageBefore.Daily.CostUSD } else { $null })
            costAfterUSD = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.Daily.CostUSD } else { $null })
            costDeltaUSD = $(if ($limitsEnabled -and $null -ne $usageAfter -and ($usageKind -eq 'balance' -or ($usageKind -eq 'quota' -and $null -ne $usageAfter.QuotaEstimatedSpendUSD))) {
                [Math]::Round([Math]::Max(0.0,[double]$usageAfter.AllTime.CostUSD-[double]$usageBefore.AllTime.CostUSD),6)
            } else { $null })
            dayBefore = $(if ($limitsEnabled) { $usageBefore.Daily.Day } else { $null })
            dayAfter = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.Daily.Day } else { $null })
            totalTokensBefore = $(if ($limitsEnabled) { $usageBefore.AllTime.Tokens } else { $null })
            totalTokensAfter = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.AllTime.Tokens } else { $null })
            budgetMode = $budgetMode
            accountUsageKind = $(if ($limitsEnabled) { $usageKind } else { 'untracked' })
            openCodeAccountId = [string](Read-Member $activeOpenCodeAccount 'id')
            openCodeAccountLabel = [string](Read-Member $activeOpenCodeAccount 'label')
            quotaRemaining = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.QuotaRemaining } else { $null })
            quotaReportedRemaining = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.QuotaReportedRemaining } else { $null })
            quotaEstimatedSpendUSD = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.QuotaEstimatedSpendUSD } else { $null })
            quotaReserve = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.QuotaReserve } else { $null })
            quotaUnit = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.QuotaUnit } else { '' })
            balanceBeforeUSD = $(if ($limitsEnabled) { $usageBefore.BalanceUSD } else { $null })
            balanceAfterUSD = $(if ($limitsEnabled -and $null -ne $usageAfter) { $usageAfter.BalanceUSD } else { $null })
            balanceSource = $(if ($limitsEnabled) { $usageBefore.BalanceSource } else { 'disabled' })
            codeFilesChanged = $changedFiles.Code
            documentationFilesChanged = $changedFiles.Docs
            testFilesChanged = $changedFiles.Tests
            otherFilesChanged = $changedFiles.Other
            changedFiles = @($changedFiles.Paths)
            implementationProgress = $implementationProgressNow
            documentationOnly = $docsOnlyNow
            consecutiveDocumentationOnly = $docsOnly
            consecutiveNoProgress = $noProgress
            transientNetworkFailure = $transientNetworkFailure
            usageError = $usageError
            eventsFile = [IO.Path]::GetFileName($eventsPath)
            readableEventsFile = [IO.Path]::GetFileName($readablePath)
            errorFile = [IO.Path]::GetFileName($stderrPath)
        }
        Save-Json $summaryPath $summary
        Write-UiEvent 'iteration-finished' @{ iteration=$i; runId=$runId; summaryFile=$summaryPath; taskId=$plannedTask.Id; taskTitle=$plannedTask.Title; completedTaskIds=@($completedIds); completedCount=($doneAfter-$doneBefore); doneAfter=$doneAfter; totalRoadmap=($doneAfter + $summary.pendingAfter); pending=$summary.pendingAfter; elapsedSeconds=$summary.elapsedSeconds; costDeltaUSD=$summary.costDeltaUSD; commits=@($iterationCommits); toolErrors=$toolErrors; exitCode=$exitCode; stoppedReason=$termination }
        $reportPath = Write-EnglishDailyReport $projectData $begin.ToString('yyyy-MM-dd')
        Write-Host "Iteration finished: exit=$exitCode new completed tasks=$($doneAfter-$doneBefore) changedHEAD=$($headAfter -ne $headBefore) code=$($changedFiles.Code) tests=$($changedFiles.Tests) docs=$($changedFiles.Docs) toolErrors=$toolErrors"
        if ($limitsEnabled -and $null -ne $usageAfter) { Show-Usage $usageAfter $profileBudget }
        Write-Host "Daily project report: $reportPath"
        Rotate-ProjectLogs $logsPath $cfg.logs
        Rotate-Reports $projectData $cfg.logs
        if ($transientNetworkFailure) {
            if (-not (Wait-ForOpenCodeRecovery $openCode $repo $profileBudget $logRoot $limitsEnabled $transientRetryDelaySeconds $stopPath $abortPath)) {
                Write-Host 'Network wait interrupted by Stop or Abort.'
                break
            }
            $i--
            continue
        }
        if ($termination -or $exitCode -ne 0 -or $usageError) {
            Write-Warning "Stopped on error or safety condition. Reason=$termination exit=$exitCode usage=$usageError; see $summaryPath"
            break
        }
        if ($i -lt $maxCycles) { Start-Sleep -Seconds ([int]$cfg.execution.pauseBetweenIterationsSeconds) }
    }
    Write-Host "Terra Runner finished. Project logs: $logsPath"
}
finally {
    if ($null -ne $activeChild) { Stop-Child $activeChild; $activeChild.Dispose() }
    Stop-TerraProxyBridge $proxyBridge
    if ($null -ne $lock) { $lock.Dispose() }
}
