function Get-NIC26RepoRoot {
    <#
    .SYNOPSIS
        Returns the repository root (the parent of the automation\ folder). Override with $env:NIC26_REPO_ROOT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:NIC26_REPO_ROOT)) {
        return (Resolve-Path -LiteralPath $env:NIC26_REPO_ROOT).Path
    }
    return (Split-Path -Path (Get-NIC26AutomationRoot) -Parent)
}
