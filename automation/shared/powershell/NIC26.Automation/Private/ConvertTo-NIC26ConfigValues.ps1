function ConvertTo-NIC26ConfigValues {
    <#
    .SYNOPSIS
        Accepts the object returned by Get-NIC26Config (uses its 'values'), or any flat dictionary / PSCustomObject, and
        returns an ordered dictionary of canonical values.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config
    )

    if ($null -eq $Config) {
        throw '-Config is required: pass the object returned by Get-NIC26Config (or a dictionary of canonical values).'
    }
    $dictionary = Copy-NIC26Value -Value $Config
    if ($dictionary -isnot [System.Collections.IDictionary]) {
        throw "-Config must be a dictionary or PSCustomObject, found $($Config.GetType().Name)."
    }
    if ($dictionary.Contains('values') -and ($dictionary['values'] -is [System.Collections.IDictionary]) -and $dictionary.Contains('scope')) {
        return $dictionary['values']
    }
    return $dictionary
}
