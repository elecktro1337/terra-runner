# Executes the actual UI navigation loop with deterministic console input.
# It never invokes runner commands and therefore never starts OpenCode.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('terra-ui-navigation-' + [guid]::NewGuid().ToString('N'))
$config = Join-Path $tempRoot 'terra-config.json'
$null = [IO.Directory]::CreateDirectory($tempRoot)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/terra-config.json') -Destination $config
$settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
$settings.projects[0].path = $tempRoot
$settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config -Encoding UTF8
$answers = [System.Collections.Generic.Queue[string]]::new()
# Open every menu, edit a legacy project while keeping its values, run UI
# diagnostics, then exit. The temporary config is an isolated fixture.
foreach ($answer in @('1','0','2','e','','','','','','0','3','0','4','0','5','0','6','','0')) { $answers.Enqueue($answer) }

function global:Clear-Host { }
function global:Read-Host([string]$Prompt) {
    if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $answers.Dequeue()
}

try {
    & (Join-Path $root 'terra-ui.ps1') -Config $config
    if ($answers.Count -ne 0) { throw 'The UI did not consume the expected navigation inputs.' }
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    if (-not $saved.projects[0].Contains('taskIdPattern')) { throw 'Editing a legacy project did not persist taskIdPattern.' }
    Write-Host 'PASS: actual UI navigation opens every menu and safely edits a legacy project.' -ForegroundColor Green
}
finally {
    Remove-Item Function:global:Clear-Host -ErrorAction SilentlyContinue
    Remove-Item Function:global:Read-Host -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
