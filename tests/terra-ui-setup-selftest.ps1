# Exercises the first-run Setup Wizard with an isolated configuration file.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$mock = Join-Path $PSScriptRoot 'mock-opencode.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('terra-ui-setup-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'project'
$config = Join-Path $tempRoot 'settings/terra-config.json'
$answers = [System.Collections.Generic.Queue[string]]::new()

function global:Clear-Host { }
function global:Read-Host([string]$Prompt) {
    if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $answers.Dequeue()
}

try {
    [void][IO.Directory]::CreateDirectory($repo)
    # Decline legacy-config copying, then complete and save a new setup.
    foreach ($answer in @('n',$mock,$repo,'wizard-project','codex/terra','ROADMAP.md','PROGRESS.md','','1','y','0')) { $answers.Enqueue($answer) }
    & (Join-Path $root 'terra-ui.ps1') -Config $config
    if ($answers.Count -ne 0) { throw 'The setup wizard did not consume the expected inputs.' }
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$saved.schemaVersion -ne 5 -or $saved.projects[0].id -ne 'wizard-project' -or $saved.projects[0].path -ne $repo) {
        throw 'The setup wizard did not write the expected isolated configuration.'
    }
    Write-Host 'PASS: first-run Setup Wizard saves an isolated configuration.' -ForegroundColor Green
}
finally {
    Remove-Item Function:global:Clear-Host -ErrorAction SilentlyContinue
    Remove-Item Function:global:Read-Host -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
