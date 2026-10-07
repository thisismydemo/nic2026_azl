function Get-NIC26AutomationRoot {
    <#
    .SYNOPSIS
        Returns the automation\ folder that contains this module (override with $env:NIC26_AUTOMATION_ROOT).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:NIC26_AUTOMATION_ROOT)) {
        return (Resolve-Path -LiteralPath $env:NIC26_AUTOMATION_ROOT).Path
    }
    # <automation>\shared\powershell\NIC26.Automation -> three levels up
    return (Resolve-Path -LiteralPath (Join-Path $script:ModuleRoot '..' '..' '..')).Path
}
