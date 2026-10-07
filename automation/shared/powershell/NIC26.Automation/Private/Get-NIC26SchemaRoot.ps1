function Get-NIC26SchemaRoot {
    <#
    .SYNOPSIS
        Returns the folder holding the JSON Schemas (automation\shared\schemas), resolved relative to this module
        so it works even when $env:NIC26_AUTOMATION_ROOT points elsewhere. Override with $env:NIC26_SCHEMA_ROOT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:NIC26_SCHEMA_ROOT)) {
        return (Resolve-Path -LiteralPath $env:NIC26_SCHEMA_ROOT).Path
    }
    # <automation>\shared\powershell\NIC26.Automation -> <automation>\shared\schemas
    return (Resolve-Path -LiteralPath (Join-Path $script:ModuleRoot '..' '..' 'schemas')).Path
}
