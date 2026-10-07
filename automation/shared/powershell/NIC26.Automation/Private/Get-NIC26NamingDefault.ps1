function Get-NIC26NamingDefault {
    <#
    .SYNOPSIS
        Returns the default organisation, lab token or region short code used when a caller does not pass one.
    .DESCRIPTION
        Order: environment variable (NIC26_ORG, NIC26_TOKEN, NIC26_REGION; read on every call), then NamingDefaults.psd1
        next to the module (read once per session; reload the module to pick up an edit). The environment file values
        (org, token, location_short) are applied by the callers before this is consulted. PowerShell does not apply a
        parameter's validation attributes to a default value, so the same patterns are enforced here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Org', 'Token', 'Region')]
        [string]$Name
    )

    $patterns = @{ Org = '^[a-z0-9]{2,8}$'; Token = '^[a-z0-9]{3,8}$'; Region = '^[a-z0-9]{2,8}$' }
    $envName = @{ Org = 'NIC26_ORG'; Token = 'NIC26_TOKEN'; Region = 'NIC26_REGION' }[$Name]

    $value = [Environment]::GetEnvironmentVariable($envName)
    $source = "environment variable $envName"
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($null -eq $script:NIC26NamingDefaults) {
            $path = Join-Path $script:ModuleRoot 'NamingDefaults.psd1'
            if (-not (Test-Path -LiteralPath $path)) { throw "NamingDefaults.psd1 not found next to the module ($path); set $envName or restore the file." }
            $script:NIC26NamingDefaults = Import-PowerShellDataFile -LiteralPath $path
        }
        $value = [string]$script:NIC26NamingDefaults[$Name]
        $source = 'NamingDefaults.psd1'
    }
    if ([string]::IsNullOrWhiteSpace($value)) { throw "No default for '$Name': set $envName or a value in NamingDefaults.psd1." }

    $value = $value.Trim().ToLowerInvariant()
    if ($value -notmatch $patterns[$Name]) { throw "The default $Name '$value' (from $source) must match $($patterns[$Name])." }
    return $value
}
