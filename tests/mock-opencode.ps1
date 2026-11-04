# Offline fake OpenCode for terra-selftest.ps1. NEVER use with real projects.
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
if ($Rest.Count -eq 0) { exit 2 }
$cmd = $Rest[0]
if ($env:TERRA_MOCK_CALL_LOG) {
    [System.IO.File]::AppendAllText($env:TERRA_MOCK_CALL_LOG,($Rest -join ' ') + "`n",[System.Text.UTF8Encoding]::new($false))
}
if ($cmd -eq 'stats') {
    if ($Rest -contains '--help') { 'Stats options: --days --json'; exit 0 }
    if ($env:TERRA_MOCK_BROKEN_STATS -eq '1') { 'unavailable'; exit 0 }
    $cost = if (($Rest -contains '--all') -and $env:TERRA_MOCK_ALL_COST) { $env:TERRA_MOCK_ALL_COST }
            elseif ($env:TERRA_MOCK_COST) { $env:TERRA_MOCK_COST } else { '0.15' }
    # Mirror the OpenCode v2.2.x stats --days 0 --json response shape.
    ('{"range":{"from":1793653200000,"to":1793725397066},"sessions":1,"tokens":{"input":900,"output":300,"reasoning":0,"cache":{"read":0,"write":0}},"cost":' + $cost + '}')
    exit 0
}
if ($cmd -eq 'run') {
    if ($Rest -contains '--help') { 'Run options: --agent --format --auto --model'; exit 0 }
    if ($env:TERRA_MOCK_TLS_ONCE -eq '1') {
        if ([string]::IsNullOrWhiteSpace($env:TERRA_MOCK_STATE_DIR)) { throw 'TERRA_MOCK_STATE_DIR is required for TLS simulation.' }
        [void][IO.Directory]::CreateDirectory($env:TERRA_MOCK_STATE_DIR)
        $marker = Join-Path $env:TERRA_MOCK_STATE_DIR 'tls-once.marker'
        if (-not (Test-Path -LiteralPath $marker)) {
            [IO.File]::WriteAllText($marker,'failed once')
            '{"type":"error","error":{"message":"TLS handshake connection reset"}}'
            exit 1
        }
    }
    if ($env:TERRA_MOCK_BLOCKED -eq '1') {
        '{"type":"text","part":{"text":"NO_ACTIONABLE_TASKS`n`nNTD-0101 is blocked: local Docker daemon is unavailable. Roadmap dependencies prohibit the next stage."}}'
        exit 0
    }
    if ($env:TERRA_MOCK_NO_ACTIONABLE -eq '1') {
        '{"type":"text","part":{"text":"NO_ACTIONABLE_TASKS"}}'
        exit 0
    }
    $repo = (Get-Location).Path
    $roadmap = Join-Path $repo 'NTD-ROADMAP.md'
    $text = Get-Content -LiteralPath $roadmap -Raw
    $text = $text.Replace('[ ]','[x]')
    [IO.File]::WriteAllText($roadmap,$text)
    Add-Content -LiteralPath (Join-Path $repo 'NTD-PROGRESS.md') -Value 'Mock iteration complete.'
    & git -C $repo add NTD-ROADMAP.md NTD-PROGRESS.md | Out-Null
    & git -C $repo commit -m 'test(mock): NTD-0001 mock completion' | Out-Null
    if ($env:TERRA_MOCK_SKIP_PUSH -ne '1') {
        & git -C $repo push origin codex/terra 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { exit 3 }
    }
    '{"type":"step_finish","part":{"id":"prt_mock","cost":0.01,"tokens":{"input":20,"output":40}}}'
    '{"type":"tool_use","part":{"id":"call_recovered","tool":"read","state":{"status":"error"}}}'
    '{"type":"text","part":{"text":"╨Т╤Б╨╡"}}'
    '{"type":"text","part":{"text":"Mock iteration completed"}}'
    if ($env:TERRA_MOCK_TLS_TEXT -eq '1') { '{"type":"text","part":{"text":"TLS/HSTS is documented as a project security requirement."}}' }
    exit 0
}
exit 2
