function Get-NIC26ConfigValue {
    <#
    .SYNOPSIS
        Looks up one canonical input in the config values: by dot path when given, otherwise by top-level key.
    .OUTPUTS
        Hashtable { Found = [bool]; Value = object }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Path = ''
    )

    $lookupPath = if ($Path) { $Path } else { $Name }
    $current = $Values
    foreach ($segment in $lookupPath.Split('.')) {
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) {
                return @{ Found = $false; Value = $null }
            }
            $current = $current[$segment]
        }
        elseif ($current -is [System.Management.Automation.PSCustomObject]) {
            $property = $current.PSObject.Properties[$segment]
            if (-not $property) {
                return @{ Found = $false; Value = $null }
            }
            $current = $property.Value
        }
        else {
            return @{ Found = $false; Value = $null }
        }
    }
    return @{ Found = $true; Value = $current }
}
