Set-StrictMode -Version Latest

$script:TerraInvariant = [System.Globalization.CultureInfo]::InvariantCulture

function ConvertTo-TerraMoney {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [decimal]$Minimum = 0,
        [decimal]$Maximum = 1000000000
    )

    $value = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Enter an amount.' }
    if ($value -match '[\s\u00A0]' -or $value -match '[eE]' -or $value -notmatch '^\d+(?:[\.,]\d+)?$') {
        throw 'Enter a plain decimal amount using either a dot or a comma.'
    }
    if ($value.Contains('.') -and $value.Contains(',')) {
        throw 'Use either a dot or a comma as the decimal separator, not both.'
    }
    $normalized = $value.Replace(',','.')
    $result = [decimal]0
    if (-not [decimal]::TryParse($normalized,[Globalization.NumberStyles]::AllowDecimalPoint,$script:TerraInvariant,[ref]$result)) {
        throw 'The amount is not valid.'
    }
    if ($result -lt $Minimum -or $result -gt $Maximum) {
        throw "Enter an amount from $Minimum to $Maximum."
    }
    return $result
}

function Format-TerraMoney {
    [CmdletBinding()]
    param([Parameter(Mandatory)][decimal]$Amount)
    return ('$' + $Amount.ToString('F2',$script:TerraInvariant))
}

function Get-TerraAppDataRoot {
    [CmdletBinding()]
    param([switch]$Portable,[string]$InstallRoot = $PSScriptRoot)
    if ($Portable) { return (Join-Path $InstallRoot 'data') }
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'Local application data directory is unavailable.' }
    return (Join-Path $base 'TerraRunner')
}

function Resolve-TerraConfigPath {
    [CmdletBinding()]
    param([string]$Config,[switch]$Portable,[string]$InstallRoot = $PSScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($Config)) { return $Config }
    $modern = Join-Path (Get-TerraAppDataRoot -Portable:$Portable -InstallRoot $InstallRoot) 'terra-config.json'
    if (Test-Path -LiteralPath $modern -PathType Leaf) { return $modern }
    $legacy = Join-Path $InstallRoot 'terra-config.json'
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { return $legacy }
    return $modern
}

Export-ModuleMember -Function ConvertTo-TerraMoney,Format-TerraMoney,Get-TerraAppDataRoot,Resolve-TerraConfigPath
