#Requires -Version 7.0
<#
.SYNOPSIS
    NIC 2026 lab automation - shared PowerShell module (config loader, naming, converters, Key Vault resolver, logging).
.DESCRIPTION
    Root module. Dot-sources every function under Private\ and Public\ (one function per file) and exports the
    public ones. See automation\shared\README.md and automation\CONTRACT.md.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:NIC26NameRegistry = $null
$script:NIC26NamingDefaults = $null

$privateFunctions = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object -Property Name)
$publicFunctions = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object -Property Name)

foreach ($file in ($privateFunctions + $publicFunctions)) {
    . $file.FullName
}

Export-ModuleMember -Function $publicFunctions.BaseName
