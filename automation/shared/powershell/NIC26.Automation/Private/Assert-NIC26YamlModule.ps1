function Assert-NIC26YamlModule {
    <#
    .SYNOPSIS
        Ensures ConvertFrom-Yaml / ConvertTo-Yaml (powershell-yaml) are available; throws with install guidance otherwise.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'ConvertFrom-Yaml' -ErrorAction SilentlyContinue) {
        return
    }
    $null = Import-Module -Name 'powershell-yaml' -ErrorAction SilentlyContinue -PassThru
    if (Get-Command -Name 'ConvertFrom-Yaml' -ErrorAction SilentlyContinue) {
        return
    }
    throw "The 'powershell-yaml' module is required but not installed. Install it with: Install-PSResource powershell-yaml -Scope CurrentUser  (or: Install-Module powershell-yaml -Scope CurrentUser). Third-party code is not vendored into this repository."
}
