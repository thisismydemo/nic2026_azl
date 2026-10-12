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
function ConvertFrom-JumpGitLfsVersion {
    param([string]$Text)
    if ($Text -cmatch '^git-lfs/(?<Version>\d+\.\d+\.\d+) \([^\r\n]+\)$') { return $Matches.Version }
    return $null
}
function Get-JumpGitLfsRuntimeVersion {
    param([string]$GitPath, [string]$ExpectedBinaryHash, [string]$RelativeLfsPath='mingw64/bin/git-lfs.exe')
    if (-not [string]::IsNullOrEmpty($env:GIT_EXEC_PATH)) { return $null }
    $gitRoot=Split-Path (Split-Path $GitPath)
    if ($RelativeLfsPath -cne 'mingw64/bin/git-lfs.exe') { return $null }
    $lfsBinary=Join-Path $gitRoot $RelativeLfsPath
    foreach ($path in @($GitPath, $lfsBinary)) {
        $item=Get-Item -LiteralPath $path -Force
        while ($null -ne $item) { if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }; $item=if ($item -is [IO.DirectoryInfo]) { $item.Parent }else { $item.Directory } }
    }
    if ($ExpectedBinaryHash -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $lfsBinary -Algorithm SHA256).Hash -ne $ExpectedBinaryHash) { return $null }
    $text=(& $lfsBinary version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $null }
    $direct=ConvertFrom-JumpGitLfsVersion $text
    $execPath=(& $GitPath --exec-path 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($execPath) -ne [IO.Path]::GetFullPath((Join-Path $gitRoot 'mingw64/libexec/git-core'))) { return $null }
    $normal=(& $GitPath lfs version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or (ConvertFrom-JumpGitLfsVersion $normal) -cne $direct) { return $null }
    return $direct
}
function Test-JumpGitLfsInventory {
    param([hashtable]$Spec, [bool]$TrustedGit)
    $wanted=if ($Spec.ContainsKey('LfsVersion')) { $Spec.LfsVersion }else { 'Unresolved' }
    $found=$null
    if ($TrustedGit -and $wanted -match '^\d+\.\d+\.\d+$') {
        $evidence=$Spec.Packages[0].MachineEvidence
        $binary=Join-Path (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $evidence.Directory) $evidence.Binary
        $found=Get-JumpGitLfsRuntimeVersion $binary $Spec.LfsBinarySha256 $Spec.LfsBinaryPath
    }
    [pscustomobject]@{Tool='git-lfs'; Wanted=$wanted; Found=$(if ($found) { $found }else { 'Not proven' }); Action='Verify'; Result=$(if ($found -and $found -ceq $wanted) { 'Passed' }else { 'Failed' }); Reboot=$false }
}
try {
    $rows = @(Invoke-JumpTools -VerifyOnly -PassThru @verifyArguments)
    $gitRow=@($rows | Where-Object Tool -EQ 'git')
    if ($gitRow.Count -gt 0) {
        $configuration=Get-JumpConfiguration -Path $VersionsPath
        $gitSpec=$configuration.Tools.git
        if ($AdditionalVersionsPath) { $extra=Get-JumpConfiguration -Path $AdditionalVersionsPath; if ($extra.Tools.ContainsKey('git')) { $gitSpec=$extra.Tools.git } }
        $rows+=Test-JumpGitLfsInventory -Spec $gitSpec -TrustedGit:($gitRow.Count -eq 1 -and $gitRow[0].Result -eq 'Passed')
    }
    $rows
    if ($rows.Count -eq 0 -or @($rows | Where-Object { $_.Result -ne 'Passed' }).Count -gt 0) { exit 1 }
}
catch {
    Write-Warning 'Jump-tool inventory could not be verified. Check the selected pins and inventory prerequisites.'
    exit 1
}
exit 0


