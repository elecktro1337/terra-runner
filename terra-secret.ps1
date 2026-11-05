[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Protect','Unprotect')][string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'terra-core.psm1') -Force -ErrorAction Stop
$value = [Console]::In.ReadToEnd()
if ($Action -eq 'Protect') { [Console]::Out.Write((Protect-TerraSecret $value)); exit 0 }
[Console]::Out.Write((Unprotect-TerraSecret $value)); exit 0
