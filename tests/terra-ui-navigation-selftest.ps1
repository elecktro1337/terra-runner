# Executes the actual UI navigation loop with deterministic console input.
# It never invokes runner commands and therefore never starts OpenCode.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$answers = [System.Collections.Generic.Queue[string]]::new()
# Open and return from every menu that has no state-changing command selected,
# run UI diagnostics, then exit the application.
foreach ($answer in @('1','0','2','0','3','0','4','0','5','0','6','','0')) { $answers.Enqueue($answer) }

function global:Clear-Host { }
function global:Read-Host([string]$Prompt) {
    if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $answers.Dequeue()
}

try {
    & (Join-Path $root 'terra-ui.ps1') -Config (Join-Path $root 'terra-config.json')
    if ($answers.Count -ne 0) { throw 'The UI did not consume the expected navigation inputs.' }
    Write-Host 'PASS: actual UI navigation opens every safe menu and returns to the main menu.' -ForegroundColor Green
}
finally {
    Remove-Item Function:global:Clear-Host -ErrorAction SilentlyContinue
    Remove-Item Function:global:Read-Host -ErrorAction SilentlyContinue
}
