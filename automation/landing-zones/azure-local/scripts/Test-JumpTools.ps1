#Requires -Version 7.0
<#
.SYNOPSIS
    Checks selected pinned jump-tool inventory without installing or configuring tools.
.DESCRIPTION
    Exits 1 for missing/mismatched inventory, unresolved pins or inventory errors. Default checks all tools.
    -Only and -SkipOffice narrow the check. Passing inventory does not verify console launch, Office activation,
    fresh-user registration, WSL availability to other users or overall jump-server readiness.
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [switch] $SkipOffice,
    [string] $VersionsPath = (Join-Path $PSScriptRoot 'jump-tools.versions.psd1'),
    [string] $AdditionalVersionsPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$verifyArguments = @{ Only = $Only; SkipOffice = $SkipOffice; VersionsPath = $VersionsPath; AdditionalVersionsPath = $AdditionalVersionsPath }
. (Join-Path $PSScriptRoot 'Install-JumpTools.ps1')
try {
    $rows = @(Invoke-JumpTools -VerifyOnly -PassThru @verifyArguments)
    $rows
    if ($rows.Count -eq 0 -or @($rows | Where-Object { $_.Result -ne 'Passed' }).Count -gt 0) { exit 1 }
}
catch {
    Write-Warning 'Jump-tool inventory could not be verified. Check the selected pins and inventory prerequisites.'
    exit 1
}
exit 0
