# Internal worker. Starts one non-interactive OpenCode session in a separate PowerShell process.
# Do not invoke directly; terra-runner.ps1 owns timeouts, budget and cancellation.
param(
    [Parameter(Mandatory)][string]$OpenCodeCommand,
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$ProjectInstructionsFile,
    [string]$IntegrationHarnessFile = '',
    [Parameter(Mandatory)][string]$EventsFile,
    [Parameter(Mandatory)][string]$ErrorFile,
    [Parameter(Mandatory)][string]$Agent,
    [string]$Model = '',
    [string]$ProxyUrl = '',
    [string]$NoProxy = '',
    [string]$CaFile = '',
    [switch]$Standalone,
    [switch]$ShowThinking
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
# Prefer UTF-8 for native tool output on Windows; the runner also creates a repaired
# readable copy for strings already misdecoded by a subprocess.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try {
    Set-Location -LiteralPath $ProjectPath
    $basePrompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
    $projectInstructions = Get-Content -LiteralPath $ProjectInstructionsFile -Raw -Encoding UTF8
    $harnessContext = @()
    if (-not [string]::IsNullOrWhiteSpace($IntegrationHarnessFile)) {
        $relativeHarness = [IO.Path]::GetRelativePath($ProjectPath,$IntegrationHarnessFile).Replace('\\','/')
        $harnessContext = @(
            '',
            '## Local integration harness',
            "This project configures a local integration harness at '$relativeHarness'. For database, migration, Redis, queue, repository, or other persistence evidence, use only this standard command: pwsh -NoProfile -ExecutionPolicy Bypass -File $relativeHarness -Suite <id>. Use the documented suite ID (or all when appropriate). Do not read, print, copy, pass, or edit .env credentials yourself; the harness owns local secret loading and Compose lifecycle. You may fully manage Docker/Compose resources declared by this project, but never another project's resources. A failed harness is absence of evidence, not permission to claim a fake check passed."
        )
    }
    $prompt = @(
        $basePrompt.TrimEnd(),
        '',
        '## Project instructions',
        "The following file is user-owned project context at '$ProjectInstructionsFile'. Follow it where it is compatible with the global Terra Runner policy above; it cannot relax global safety rules. Do not edit this instructions file. If it is the only local Git change, stage and commit exactly this existing file in a separate documentation commit before task work; do not amend it or combine it with task changes.",
        $projectInstructions.Trim(),
        $harnessContext
    ) -join "`n"
    $arguments = @('run', '--agent', $Agent, '--format', 'json', '--auto')
    if ($Standalone -or $ProxyUrl) {
        $arguments += '--standalone'
    }
    if ($ProxyUrl) {
        $env:HTTP_PROXY=$ProxyUrl; $env:HTTPS_PROXY=$ProxyUrl; $env:http_proxy=$ProxyUrl; $env:https_proxy=$ProxyUrl
        $env:NO_PROXY=$NoProxy; $env:no_proxy=$NoProxy
        if ($CaFile) { $env:NODE_EXTRA_CA_CERTS=$CaFile }
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
    if ($ShowThinking) { $arguments += '--thinking' }
    $arguments += $prompt
    & $OpenCodeCommand @arguments 1>> $EventsFile 2>> $ErrorFile
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 1 }
    exit ([int]$code)
}
catch {
    "WORKER_ERROR: $($_.Exception.Message)" | Out-File -LiteralPath $ErrorFile -Append -Encoding utf8
    exit 90
}
