# No paid OpenCode calls. Tests the interactive UI's config serialization and rendering.
# Run with PowerShell 7 from the Terra Runner folder.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'terra-ui.ps1') -SelfTest
Write-Host 'ALL TERRA UI SELF-TESTS PASSED' -ForegroundColor Green
