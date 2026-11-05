# Internal worker. Starts one non-interactive OpenCode session in a separate PowerShell process.
# Do not invoke directly; terra-runner.ps1 owns timeouts, budget and cancellation.
param(
    [Parameter(Mandatory)][string]$OpenCodeCommand,
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$EventsFile,
    [Parameter(Mandatory)][string]$ErrorFile,
    [Parameter(Mandatory)][string]$Agent,
    [string]$Model = '',
    [string]$ProxyUrl = '',
    [string]$NoProxy = '',
    [string]$CaFile = '',
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
    $prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
    $arguments = @('run', '--agent', $Agent, '--format', 'json', '--auto')
    if ($ProxyUrl) {
        $arguments += '--standalone'
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
