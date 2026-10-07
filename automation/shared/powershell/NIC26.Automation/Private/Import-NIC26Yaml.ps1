function Import-NIC26Yaml {
    <#
    .SYNOPSIS
        Reads one YAML file into an ordered dictionary using the powershell-yaml module.
    .DESCRIPTION
        Requires the third-party 'powershell-yaml' module (not vendored). Install it once per user:
            Install-PSResource powershell-yaml -Scope CurrentUser
        An empty file returns an empty ordered dictionary. A file whose root is not a mapping is rejected.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-NIC26YamlModule

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "YAML file not found: $Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [ordered]@{}
    }

    $data = ConvertFrom-Yaml -Yaml $text -Ordered
    if ($null -eq $data) {
        return [ordered]@{}
    }
    if ($data -isnot [System.Collections.IDictionary]) {
        throw "YAML root of '$Path' must be a mapping (key: value), found $($data.GetType().Name)."
    }
    return $data
}
