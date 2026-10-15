#Requires -Version 7.0
<#
.SYNOPSIS
    Installs and verifies the pinned machine Node runtime and bundled npm.
.DESCRIPTION
    Function library dot-sourced by Install-JumpTools.ps1 (not run on its own). It proves the machine Node install from
    the pinned manifest (MSI ProductCode, publisher, binary hash, npm version, machine PATH) and installs the verified
    official MSI only through Invoke-JumpNodeSetup, whose ShouldProcess gate is driven by the entry script's -Execute switch.
.NOTES
    Author: Kristopher Turner
    TaskReference: T-3.1.3b
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JumpNodeDirectory {
    $root = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
    $directory = Join-Path $root 'nodejs'
    foreach ($path in @($root, $directory, (Join-Path $directory 'node_modules'), (Join-Path $directory 'node_modules/npm'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Machine Node path contains a reparse point.' }
    }
    return $directory
}

function Get-InstalledJumpNodeVersion {
    param([System.Collections.IDictionary]$Spec)
    $directory = Get-JumpNodeDirectory
    $binary = Join-Path $directory 'node.exe'
    $npm = Join-Path $directory 'npm.cmd'
    $package = Join-Path $directory 'node_modules/npm/package.json'
    foreach ($path in @($binary, $npm, $package)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Machine Node file contains a reparse point.' }
    }
    $entries = @(Get-JumpMachineUninstallEntry | Where-Object { $_.PSChildName -ceq $Spec.Node.ProductCode })
    if ($entries.Count -ne 1) { return $null }
    $entry = $entries[0]
    if ($entry.DisplayVersion -cne $Spec.Version -or $entry.Publisher -cne $Spec.Node.RegistrationPublisher -or $entry.WindowsInstaller -ne 1) { return $null }
    if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ine $Spec.Node.BinarySha256 -or
        (Get-Item -LiteralPath $binary).VersionInfo.ProductVersion -cne $Spec.Version) { return $null }
    if ((Get-Content -LiteralPath $package -Raw | ConvertFrom-Json).version -cne $Spec.Node.NpmVersion) { return $null }
    $machinePath = @([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';' | ForEach-Object { $_.TrimEnd('\') })
    if ($machinePath -inotcontains $directory) { return $null }
    $originalPath = $env:PATH
    try {
        $env:PATH = $directory + [IO.Path]::PathSeparator + $originalPath
        $actual = & $binary --version
        if ($LASTEXITCODE -ne 0 -or $actual -cne ('v' + $Spec.Version)) { return $null }
        $npmVersion = & $npm --version
        if ($LASTEXITCODE -ne 0 -or $npmVersion -cne $Spec.Node.NpmVersion) { return $null }
    }
    finally { $env:PATH = $originalPath }
    return $Spec.Version
}

function Assert-JumpNodeArtifact {
    param([string]$Path, [System.Collections.IDictionary]$Spec)
    if ($Spec.Node.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Spec.Node.Sha256) { throw 'Pinned Node MSI checksum mismatch.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Spec.Node.Publisher) { throw 'Pinned Node MSI publisher verification failed.' }
}

function Invoke-JumpNodeSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param([System.Collections.IDictionary]$Spec)
    $directory = Get-JumpNodeDirectory
    $expectedUrl = 'https://nodejs.org/dist/v' + $Spec.Version + '/node-v' + $Spec.Version + '-x64.msi'
    if ($Spec.Node.DownloadUrl -cne $expectedUrl) { throw 'Node MSI origin must match the exact official pinned release.' }
    if (-not $PSCmdlet.ShouldProcess('Machine Node and bundled npm', 'Install verified pinned MSI')) { return }
    if (-not (Test-JumpElevated)) { throw 'Node machine installation requires elevation.' }
    $binary = Join-Path $directory 'node.exe'
    if ((Test-Path -LiteralPath $binary) -and (Get-Item -LiteralPath $binary).VersionInfo.ProductVersion -cne $Spec.Version) { throw 'Existing Node version differs; reviewed upgrade required.' }
    $staging = New-JumpMsixStagingDirectory
    try {
        $installer = Join-Path $staging 'node-x64.msi'
        Invoke-WebRequest -Uri $expectedUrl -OutFile $installer -ErrorAction Stop
        Assert-JumpNodeArtifact -Path $installer -Spec $Spec
        $arguments = @('/i', ('"' + $installer + '"'), '/qn', '/norestart', 'ALLUSERS=1')
        $result = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/msiexec.exe') -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
        if ($result.ExitCode -notin @(0, 3010)) { throw "Pinned Node MSI failed with exit $($result.ExitCode)." }
        if ((Get-InstalledJumpNodeVersion -Spec $Spec) -cne $Spec.Version) { throw 'Node machine registration or runtime acceptance failed.' }
        if ($result.ExitCode -eq 3010) { Write-Warning 'Node MSI requires a restart; no restart was initiated.' }
    }
    finally {
        $verified = [IO.Path]::GetFullPath($staging)
        $stagingRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'JumpTools/MSIXStaging')).TrimEnd('\') + '\'
        if (-not $verified.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected Node cleanup path; retained.' }
        Remove-Item -LiteralPath $verified -Recurse -Force -ErrorAction Stop
    }
}
