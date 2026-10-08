#Requires -Version 7.0
<#
.SYNOPSIS
    Plans or installs the machine-wide tools of the jump server, from one versions file.
.DESCRIPTION
    Reads every pinned version from jump-tools.versions.psd1. Without -Execute it changes nothing and prints the plan (what is
    installed, what is wanted, what it would do). With -Execute (elevated session) it installs what is missing or at the wrong
    version and skips what is already correct, so a re-run is safe.

    Machine-wide scope is the requirement: winget --scope machine, Install-PSResource -Scope AllUsers, system Azure CLI extensions, Windows features, the Office
    Deployment Tool and MSIX provisioning. WSL distributions remain a scope acceptance gap; do not treat a successful run as proof that all tools meet that requirement. Office updates are disabled; Store update policy remains a live acceptance check. -Execute is refused while a version in the file is still 'TODO-PIN' for a selected tool.
    Not installed by design: Azure VPN Client, Windows Admin Center, RVTools.

    Dot-sourcing the file defines the functions without running anything (the tests do this).
.PARAMETER Execute
    Perform the changes. Without it the script only prints the plan.
.PARAMETER Only
    Limit the run to these tool keys (see the Tools section of the versions file).
.PARAMETER SkipOffice
    Leave out Microsoft 365 Apps.
.PARAMETER PassThru
    Return the per-tool result objects on the pipeline.
.PARAMETER VersionsPath
    Path to the versions file. Default: jump-tools.versions.psd1 next to this script.
.PARAMETER AdditionalVersionsPath
    Optional second versions file merged over the first: its Tools entries are added or replace the same keys, and its
    AnsibleCollections are added to the list. A site layer uses it for tools that are specific to one environment, so the
    shared file stays generic.
.EXAMPLE
    ./Install-JumpTools.ps1
.EXAMPLE
    ./Install-JumpTools.ps1 -Execute -Only git, terraform -PassThru
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Execute,
    [string[]] $Only,
    [switch] $SkipOffice,
    [switch] $PassThru,
    [string] $VersionsPath = (Join-Path $PSScriptRoot 'jump-tools.versions.psd1'),
    [string] $AdditionalVersionsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)
    Write-Information ('[{0}] {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message) -InformationAction Continue
}

function Test-JumpElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JumpConfiguration {
    param([string] $Path)
    return Import-PowerShellDataFile -Path $Path
}

# Returns the locations (path inside the data) of every 'TODO-PIN' value.
function Get-PendingPins {
    param([System.Collections.IDictionary] $Configuration)
    $pending = [System.Collections.Generic.List[string]]::new()
    function Find-Pin {
        param($Value, [string] $Location)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) { Find-Pin -Value $Value[$key] -Location "$Location.$key" }
        }
        elseif ($Value -is [array]) {
            for ($i = 0; $i -lt $Value.Count; $i++) {
                $label = if ($Value[$i] -is [System.Collections.IDictionary] -and $Value[$i].Contains('Id')) { $Value[$i].Id } else { $i }
                Find-Pin -Value $Value[$i] -Location "$Location.$label"
            }
        }
        elseif ($Value -is [string] -and $Value -ceq 'TODO-PIN') { $pending.Add($Location) }
    }
    Find-Pin -Value $Configuration -Location 'Configuration'
    return $pending.ToArray()
}

# ---- read wrappers (no changes) ------------------------------------------------------------------------------------------
function Get-JumpMsixManifest {
    param([string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry) { throw 'Package has no AppxManifest.xml.' }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = $entry.Open()
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try { $document = [xml]::new(); $document.Load($reader); return $document }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Assert-JumpMsixPackage {
    param([string] $Path, [System.Collections.IDictionary] $Pin)
    if ($Pin.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Pin.Sha256) {
        throw "Package SHA-256 mismatch: $($Pin.Name)."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Pin.Publisher) {
        throw "Package signature mismatch: $($Pin.Name)."
    }
    $manifest = Get-JumpMsixManifest -Path $Path
    $identity = $manifest.Package.Identity
    foreach ($field in @('Name', 'Version', 'Publisher')) {
        if ([string]$identity.GetAttribute($field) -cne [string]$Pin[$field]) { throw "Package identity $field mismatch: $($Pin.Name)." }
    }
    if ($identity.GetAttribute('ProcessorArchitecture') -cne $Pin.Architecture) { throw "Package architecture mismatch: $($Pin.Name)." }
    return $manifest
}

function Get-ProvisionedJumpMsixVersion {
    param([System.Collections.IDictionary] $Pin)
    $expected = '{0}_{1}_{2}__{3}' -f $Pin.Name, $Pin.Version, $Pin.Architecture, $Pin.PublisherId
    $packages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    if (@($packages | Where-Object { $_.PackageName -ceq $expected }).Count -ne 1) { return $null }
    # DISM's provisioned main package alone does not establish framework availability.
    # AllUsers is an inventory of staged/registered frameworks, not proof of every user's registration or launch.
    $frameworks = @(Get-AppxPackage -AllUsers -PackageTypeFilter Framework -ErrorAction Stop)
    foreach ($dependency in $Pin.Dependencies) {
        $packageMatches = @($frameworks | Where-Object {
                $_.Name -ceq $dependency.Name -and [string]$_.Version -ceq $dependency.Version -and
                $_.Publisher -ceq $dependency.Publisher -and ([string]$_.Architecture).ToLowerInvariant() -ceq $dependency.Architecture -and
                [string]$_.Status -eq 'Ok' -and $_.InstallLocation
            })
        if ($packageMatches.Count -ne 1) { return $null }
    }
    return $Pin.Version
}

function Invoke-JumpMsixProvisioning {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only within Invoke-JumpTools Execute and ShouldProcess gate.')]
    param([System.Collections.IDictionary] $Spec)
    $pin = $Spec.Msix
    if ($pin.DownloadUrl -notmatch '^https://') { throw 'MSIX download requires HTTPS.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('nic26-msix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    # Store download only acquires files. Every artifact is independently checked before provisioning.
    if ($pin.Dependencies.Count -gt 0) {
        & winget download --id $pin.StoreId --source msstore --exact --architecture $pin.Architecture --download-directory $directory --skip-license --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "MSIX dependency download failed (exit $LASTEXITCODE)." }
    }
    $main = Join-Path $directory 'pinned-main.msix'
    Invoke-WebRequest -Uri $pin.DownloadUrl -OutFile $main
    $manifest = Assert-JumpMsixPackage -Path $main -Pin $pin
    $dependencyPaths = [Collections.Generic.List[string]]::new()
    $files = if ($pin.Dependencies.Count -gt 0) { @(Get-ChildItem -LiteralPath (Join-Path $directory 'Dependencies') -File) } else { @() }
    $required = @($manifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Dependencies']/*[local-name()='PackageDependency']"))
    if ($required.Count -ne $pin.Dependencies.Count) { throw 'Required dependency set does not match the pins.' }
    foreach ($dependency in $required) {
        $packageMatches = @($pin.Dependencies | Where-Object { $_.Name -ceq $dependency.Name -and $_.Publisher -ceq $dependency.Publisher })
        if ($packageMatches.Count -ne 1 -or [version]$packageMatches[0].Version -lt [version]$dependency.MinVersion) { throw "Missing or insufficient dependency pin: $($dependency.Name)." }
        $dependencyPin = $packageMatches[0]
        $candidates = @($files | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ceq $dependencyPin.Sha256 })
        if ($candidates.Count -ne 1) { throw "Pinned dependency unavailable: $($dependency.Name)." }
        $dependencyManifest = Assert-JumpMsixPackage -Path $candidates[0].FullName -Pin $dependencyPin
        if (@($dependencyManifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Dependencies']/*[local-name()='PackageDependency']")).Count -gt 0) {
            throw "Unresolved transitive package dependencies: $($dependency.Name)."
        }
        $dependencyPaths.Add($candidates[0].FullName)
    }
    # No package state is changed until every main/dependency check above has passed.
    $provisionArguments = @{ Online = $true; PackagePath = $main; ErrorAction = 'Stop' }
    if ($dependencyPaths.Count -gt 0) { $provisionArguments.DependencyPackagePath = $dependencyPaths.ToArray() }
    if ($pin.Contains('License')) {
        if ($pin.License.DownloadUrl -notmatch '^https://' -or $pin.License.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid offline MSIX license pin.' }
        $licensePath = Join-Path $directory 'pinned-license.xml'
        Invoke-WebRequest -Uri $pin.License.DownloadUrl -OutFile $licensePath
        if ((Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash -cne $pin.License.Sha256) { throw 'Offline MSIX license SHA-256 mismatch.' }
        $provisionArguments.LicensePath = $licensePath
        $provisionArguments.Regions = 'all'
    }
    else { $provisionArguments.SkipLicense = $true }
    Add-AppxProvisionedPackage @provisionArguments | Out-Null
    # Provisioning makes the package available to new profiles. Existing-profile registration and launch are separate live checks.
}

function Get-JumpCodexLayout {
    param([System.Collections.IDictionary] $Spec)
    if ($Spec.Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid Codex version path.' }
    $directory = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('JumpTools/Codex/' + $Spec.Version)
    return [pscustomobject]@{ Directory = $directory; Bin = (Join-Path $directory 'bin') }
}

function Get-JumpCodexReportedVersion {
    param([string] $Binary)
    $text = & $Binary --version 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Codex version command failed.' }
    return ($text -join ' ').Trim()
}

function Assert-JumpCodexTree {
    param([string] $Directory, [System.Collections.IDictionary] $Spec)
    # Walk ancestors as well as package contents; never follow an installation junction.
    $ancestor = [IO.Path]::GetFullPath($Directory)
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Codex path contains a reparse point.' }
        $ancestor = Split-Path $ancestor -Parent
    }
    $items = @(Get-ChildItem -LiteralPath $Directory -Recurse -Force -ErrorAction Stop)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw 'Codex package contains a reparse point.' }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $pins = $Spec.Archive.Files
    if ($pins.Count -eq 0 -or $files.Count -ne $pins.Count) { throw 'Codex package file set mismatch.' }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/')
        if (-not $pins.Contains($relative) -or $pins[$relative] -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne $pins[$relative]) { throw 'Codex package file hash mismatch.' }
    }
    $binary = Join-Path $Directory 'bin/codex.exe'
    $signature = Get-AuthenticodeSignature -LiteralPath $binary
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Spec.Archive.Publisher) { throw 'Codex executable signature mismatch.' }
    if ((Get-JumpCodexReportedVersion -Binary $binary) -cne ('codex-cli ' + $Spec.Version)) { throw 'Codex executable version mismatch.' }
}

function Get-InstalledJumpCodexVersion {
    param([System.Collections.IDictionary] $Spec)
    $layout = Get-JumpCodexLayout -Spec $Spec
    if (-not (Test-Path -LiteralPath $layout.Directory -PathType Container)) { return $null }
    $entries = @(([string](Get-JumpMachineEnvironment 'Path')) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\', '/') })
    if ($entries -inotcontains $layout.Bin.TrimEnd('\', '/')) { return $null }
    Assert-JumpCodexTree -Directory $layout.Directory -Spec $Spec
    return $Spec.Version
}

function Set-JumpCodexEnvironment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by guarded installer after package validation.')]
    param([string] $Bin)
    $entries = @(([string](Get-JumpMachineEnvironment 'Path')) -split ';' | Where-Object { $_ -and $_.TrimEnd('\', '/') -ine $Bin.TrimEnd('\', '/') })
    [Environment]::SetEnvironmentVariable('Path', ((@($Bin) + $entries) -join ';'), 'Machine')
    $env:Path = $Bin + ';' + $env:Path
}

function Invoke-JumpCodexSetup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only within Invoke-JumpTools Execute and ShouldProcess gate.')]
    param([System.Collections.IDictionary] $Spec)
    $layout = Get-JumpCodexLayout -Spec $Spec
    if (Test-Path -LiteralPath $layout.Directory) {
        Assert-JumpCodexTree -Directory $layout.Directory -Spec $Spec
        Set-JumpCodexEnvironment -Bin $layout.Bin
        return
    }
    $pin = $Spec.Archive
    if ($pin.DownloadUrl -notmatch '^https://' -or $pin.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid Codex archive pin.' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('nic26-codex-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $archive = Join-Path $stage 'package.tar.gz'
    Invoke-WebRequest -Uri $pin.DownloadUrl -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $pin.Sha256) { throw 'Codex archive SHA-256 mismatch.' }
    $tar = Join-Path ([Environment]::SystemDirectory) 'tar.exe'
    $members = @(& $tar -tzf $archive)
    if ($LASTEXITCODE -ne 0 -or $members.Count -eq 0 -or @($members | Where-Object { $_ -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)' }).Count -gt 0) { throw 'Unsafe Codex archive path.' }
    $expanded = Join-Path $stage 'expanded'
    New-Item -ItemType Directory -Path $expanded | Out-Null
    & $tar -xzf $archive -C $expanded
    if ($LASTEXITCODE -ne 0) { throw 'Codex archive extraction failed.' }
    Assert-JumpCodexTree -Directory $expanded -Spec $Spec
    # No package writes before validation. Refuse changed existing version contents, retaining them for review.
    $parent = Split-Path $layout.Directory -Parent
    $ancestor = $parent
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Codex destination contains a reparse point.' }
        $ancestor = Split-Path $ancestor -Parent
    }
    New-Item -ItemType Directory -Path $layout.Directory -ErrorAction Stop | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $identity = [Security.Principal.SecurityIdentifier]::new($rule[0])
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, $rule[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $layout.Directory -AclObject $acl
    Get-ChildItem -LiteralPath $expanded -Force | Copy-Item -Destination $layout.Directory -Recurse
    Assert-JumpCodexTree -Directory $layout.Directory -Spec $Spec
    Set-JumpCodexEnvironment -Bin $layout.Bin
    # Retain uniquely named temporary artifacts for diagnosis; never copy authentication or home directories.
}

function Get-InstalledWingetVersion {
    param([string] $Id, [string] $Source)
    $arguments = @('list', '--id', $Id, '--exact', '--scope', 'machine', '--disable-interactivity')
    if ($Source) { $arguments += @('--source', $Source) }
    $output = & winget @arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $output) {
        if ($line -match ('\s{2,}' + [regex]::Escape($Id) + '\s{2,}(?<Version>\S+)')) { return $Matches.Version }
    }
    return $null
}

function Get-InstalledPSResourceVersion {
    param([string] $Name)
    $resource = Get-InstalledPSResource -Name $Name -Scope AllUsers -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $resource) { return $null }
    return [string] $resource.Version
}

function Get-JumpAzSystemExtensionDirectory {
    $command = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    $source = [IO.Path]::GetFullPath($command.Source)
    $trusted = @($env:ProgramFiles, ${env:ProgramFiles(x86)} | Where-Object { $_ })
    if (-not @($trusted | Where-Object { $source.StartsWith(([IO.Path]::GetFullPath($_).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) }).Count) { return $null }
    # Windows MSI CLI layout: wbin/az.cmd, with Python's purelib at Lib/site-packages.
    if ([IO.Path]::GetFileName($source) -ine 'az.cmd' -or (Split-Path (Split-Path $source -Parent) -Leaf) -ine 'wbin') { return $null }
    return Join-Path (Split-Path (Split-Path $source -Parent) -Parent) 'Lib/site-packages/azure-cli-extensions'
}

function Test-JumpAzExtensionPath {
    param([string] $Path, [string] $Name, [string] $SystemDirectory)
    if (-not $Path -or -not $SystemDirectory -or $Name -notmatch '^[a-z0-9][a-z0-9-]*$') { return $false }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') -ieq [IO.Path]::GetFullPath((Join-Path $SystemDirectory $Name)).TrimEnd('\', '/')
}

function Get-InstalledAzExtensionVersion {
    param([string] $Name)
    $json = & az extension list --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $extension = @($json | ConvertFrom-Json) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $extension) { return $null }
    if (-not (Test-JumpAzExtensionPath -Path $extension.path -Name $Name -SystemDirectory (Get-JumpAzSystemExtensionDirectory))) { return $null }
    return [string] $extension.version
}

function Get-JumpBicepLayout {
    $directory = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'JumpTools/Bicep'
    return [pscustomobject]@{ Directory = $directory; Binary = (Join-Path $directory 'bicep.exe') }
}

function Get-JumpMachineEnvironment {
    param([string] $Name)
    return [Environment]::GetEnvironmentVariable($Name, 'Machine')
}

function Get-JumpBicepBinaryVersion {
    param([string] $Path, [System.Collections.IDictionary] $Pin)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Pin.Sha256) { return $null }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Pin.Publisher) { return $null }
    $text = & $Path --version 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (($text -join ' ') -match '\b(?<Version>\d+\.\d+\.\d+)\b') { return $Matches.Version }
    return $null
}

function Get-InstalledAzBicepVersion {
    param([System.Collections.IDictionary] $Spec)
    $layout = Get-JumpBicepLayout
    foreach ($path in @((Split-Path $layout.Directory -Parent), $layout.Directory, $layout.Binary)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    }
    $entries = @(([string](Get-JumpMachineEnvironment 'Path')) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\', '/') })
    if ($entries -inotcontains $layout.Directory.TrimEnd('\', '/') -or (Get-JumpMachineEnvironment 'AZURE_BICEP_USE_BINARY_FROM_PATH') -ine 'true') { return $null }
    return Get-JumpBicepBinaryVersion -Path $layout.Binary -Pin $Spec.Binary
}

function Set-JumpBicepEnvironment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by the guarded Bicep installer after pinned binary verification.')]
    param([string] $Directory)
    $currentPath = [string](Get-JumpMachineEnvironment 'Path')
    $entries = @($currentPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\', '/') -ine $Directory.TrimEnd('\', '/') })
    [Environment]::SetEnvironmentVariable('Path', ((@($Directory) + $entries) -join ';'), 'Machine')
    [Environment]::SetEnvironmentVariable('AZURE_BICEP_USE_BINARY_FROM_PATH', 'true', 'Machine')
    $env:Path = $Directory + ';' + $env:Path
    $env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'true'
}

function Invoke-JumpBicepSetup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only within Invoke-JumpTools Execute/ShouldProcess boundary.')]
    param([System.Collections.IDictionary] $Spec)
    $pin = $Spec.Binary
    if ($pin.DownloadUrl -notmatch '^https://' -or $pin.Sha256 -notmatch '^[A-F0-9]{64}$') { throw 'Bicep requires an HTTPS URL and pinned SHA-256.' }
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'The Bicep source pin requires an x64 machine.' }
    $layout = Get-JumpBicepLayout
    foreach ($path in @((Split-Path $layout.Directory -Parent), $layout.Directory, $layout.Binary)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Bicep target must not be a reparse point.' }
    }
    $download = Join-Path ([IO.Path]::GetTempPath()) ('nic26-bicep-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        Invoke-WebRequest -Uri $pin.DownloadUrl -OutFile $download
        if ((Get-JumpBicepBinaryVersion -Path $download -Pin $pin) -cne $Spec.Version) { throw 'Downloaded Bicep does not match the pinned bytes, publisher and version.' }
        $null = New-Item -ItemType Directory -Path $layout.Directory -Force
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            $identity = [Security.Principal.SecurityIdentifier]::new($rule[0])
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, $rule[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $layout.Directory -AclObject $acl
        Copy-Item -LiteralPath $download -Destination $layout.Binary -Force
        $fileAcl = [Security.AccessControl.FileSecurity]::new()
        $fileAcl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            $identity = [Security.Principal.SecurityIdentifier]::new($rule[0])
            $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, $rule[1], 'Allow'))
        }
        Set-Acl -LiteralPath $layout.Binary -AclObject $fileAcl
        if ((Get-JumpBicepBinaryVersion -Path $layout.Binary -Pin $pin) -cne $Spec.Version) { throw 'Machine Bicep binary verification failed.' }
        Set-JumpBicepEnvironment -Directory $layout.Directory
    }
    finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force } }
}

function Get-WslState {
    param([string] $Distribution)
    $names = & wsl --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return (@($names | ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() }) -contains $Distribution)
}

function Get-AnsibleState {
    param([string] $Distribution, [string] $Component)
    $command = if ($Component -eq 'ansible-core') { 'ansible --version' } else { 'ansible-galaxy collection list --format json' }
    $output = & wsl -d $Distribution -u root -- sh -lc $command 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($Component -eq 'ansible-core') {
        if (($output -join ' ') -match 'ansible \[core (?<Version>[^\]\s]+)') { return $Matches.Version }
        return $null
    }
    try {
        $paths = ($output -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($path in $paths.Keys) {
            if ($paths[$path].Contains($Component)) { return [string] $paths[$path][$Component].version }
        }
    }
    catch { return $null }
    return $null
}

function Get-WindowsFeatureState {
    param([string] $Name)
    return [string] (Get-WindowsFeature -Name $Name).InstallState
}

function Get-VSCodeExtensionVersion {
    param([string] $Id, [string] $Directory)
    # An explicit CLI directory alone does not prove the default for new operators.
    $machineDirectory = Get-JumpMachineEnvironment -Name 'VSCODE_EXTENSIONS'
    if ([string]::IsNullOrWhiteSpace($machineDirectory)) { return $null }
    try {
        $expected = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
        $configured = [IO.Path]::GetFullPath($machineDirectory).TrimEnd('\', '/')
    }
    catch { return $null }
    if (-not [string]::Equals($configured, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $lines = & code --list-extensions --show-versions --extensions-dir $Directory 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $lines) {
        if ($line -match ('^' + [regex]::Escape($Id) + '@(?<Version>\S+)$')) { return $Matches.Version }
    }
    return $null
}

function Get-OfficeBuild {
    $entries = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($null -eq $entries) { return $null }
    $reported = [string] $entries.VersionToReport
    # VersionToReport is 16.0.<build>.<revision>, the same shape as the pin.
    return $reported
}

# ---- mutating wrappers (every change goes through one of these) ------------------------------------------------------
function Invoke-Winget {
    param([string[]] $Arguments)
    & winget @Arguments
    if ($LASTEXITCODE -ne 0) { throw "winget failed (exit $LASTEXITCODE)." }
}

function Install-PSResourcePinned {
    param([string] $Name, [string] $Version)
    $repository = Get-PSResourceRepository -Name PSGallery
    if (-not $repository.Trusted) { Set-PSResourceRepository -Name PSGallery -Trusted }
    Install-PSResource -Name $Name -Version $Version -Repository PSGallery -Scope AllUsers -TrustRepository -AcceptLicense -ErrorAction Stop
}

function Invoke-AzCli {
    param([string[]] $Arguments)
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'extension' -and $Arguments[1] -eq 'add') {
        if ($Arguments -notcontains '--system') { throw 'Jump extensions require --system.' }
        $systemDirectory = Get-JumpAzSystemExtensionDirectory
        if (-not $systemDirectory) { throw 'Cannot resolve a trusted machine Azure CLI installation.' }
        # Override per-user sys_dir configuration for this child invocation, without relocating authentication caches.
        $previousDirectory = [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', $systemDirectory, 'Process')
            & az @Arguments
            if ($LASTEXITCODE -ne 0) { throw "az failed (exit $LASTEXITCODE)." }
        }
        finally {
            $restoreDirectory = if ($null -eq $previousDirectory) { [NullString]::Value } else { $previousDirectory }
            [Environment]::SetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', $restoreDirectory, 'Process')
        }
    }
    else {
        & az @Arguments
        if ($LASTEXITCODE -ne 0) { throw "az failed (exit $LASTEXITCODE)." }
    }
}

function Invoke-Wsl {
    param([string[]] $Arguments)
    & wsl @Arguments
    if ($LASTEXITCODE -ne 0) { throw "wsl failed (exit $LASTEXITCODE)." }
}

function Install-WindowsFeaturePinned {
    param([string] $Name)
    $result = Install-WindowsFeature -Name $Name -IncludeAllSubFeature
    if (-not $result.Success) { throw "Windows feature $Name failed to install." }
    return $result
}

function Set-MachineExtensionsDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param([string] $Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    # A machine-scoped VSCODE_EXTENSIONS makes this the extensions directory of every VS Code process started after the next
    # sign-in (verify on the first build: sign out and in, then run `code --list-extensions`).
    [Environment]::SetEnvironmentVariable('VSCODE_EXTENSIONS', $Directory, 'Machine')
}

function Invoke-Code {
    param([string] $Id, [string] $Version, [string] $Directory)
    & code --install-extension "$Id@$Version" --extensions-dir $Directory --force
    if ($LASTEXITCODE -ne 0) { throw "VS Code extension $Id failed." }
}

function Set-WingetAutoUpdate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param()
    # winget has no package auto-upgrade by itself; if this installation's settings file carries an auto-update flag, turn it off.
    $settings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path $settings)) { return }
    $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -AsHashtable
    $changed = $false
    if ($json.Contains('autoUpdate')) { $json.autoUpdate = $false; $changed = $true }
    if ($json.Contains('source') -and $json.source -is [System.Collections.IDictionary] -and $json.source.Contains('autoUpdateIntervalInMinutes')) {
        $json.source.autoUpdateIntervalInMinutes = 0; $changed = $true
    }
    if ($changed) { $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settings -Encoding utf8 }
}

function New-OfficeConfigurationXml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param([string] $Build)
    if ($Build -notmatch '^\d+(?:\.\d+){3}$') { throw 'The Office version must be a four-part build number such as 16.0.20430.20146.' }
    [xml] $xml = '<Configuration/>'
    $add = $xml.CreateElement('Add')
    $add.SetAttribute('OfficeClientEdition', '64')
    $add.SetAttribute('Channel', 'Current')
    $add.SetAttribute('Version', $Build)
    [void] $xml.DocumentElement.AppendChild($add)
    $product = $xml.CreateElement('Product')
    $product.SetAttribute('ID', 'O365ProPlusRetail')
    [void] $add.AppendChild($product)
    $language = $xml.CreateElement('Language')
    $language.SetAttribute('ID', 'MatchOS')
    [void] $product.AppendChild($language)
    # Word, Excel, PowerPoint, Outlook and OneNote stay; the rest of the suite is excluded.
    foreach ($app in @('Access', 'Publisher', 'Groove', 'Lync', 'Teams', 'OneDrive', 'Bing')) {
        $exclude = $xml.CreateElement('ExcludeApp')
        $exclude.SetAttribute('ID', $app)
        [void] $product.AppendChild($exclude)
    }
    $property = $xml.CreateElement('Property')
    $property.SetAttribute('Name', 'SharedComputerLicensing')
    $property.SetAttribute('Value', '1')
    [void] $xml.DocumentElement.AppendChild($property)
    $updates = $xml.CreateElement('Updates')
    $updates.SetAttribute('Enabled', 'FALSE')
    [void] $xml.DocumentElement.AppendChild($updates)
    $display = $xml.CreateElement('Display')
    $display.SetAttribute('Level', 'None')
    $display.SetAttribute('AcceptEULA', 'TRUE')
    [void] $xml.DocumentElement.AppendChild($display)
    return $xml
}

function Invoke-OfficeSetup {
    param([string] $Build, [string] $DownloadUrl, [string] $Sha256)
    if (-not $DownloadUrl -or -not $DownloadUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Office.DownloadUrl must be an https URL of the Office Deployment Tool.'
    }
    if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Office.DownloadSha256 must be the SHA-256 of the Office Deployment Tool.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $bootstrap = Join-Path $directory 'odt.exe'
        $config = Join-Path $directory 'configuration.xml'
        $setup = Join-Path $directory 'setup.exe'
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $bootstrap
        if ((Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash -ne $Sha256.ToUpperInvariant()) { throw 'The downloaded Office Deployment Tool does not match the pinned SHA-256.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'The Office Deployment Tool is not signed by Microsoft.' }
        $extract = Start-Process -FilePath $bootstrap -ArgumentList @("/extract:$directory", '/quiet') -Wait -PassThru
        if ($extract.ExitCode -ne 0 -or -not (Test-Path $setup)) { throw 'Office Deployment Tool extraction failed.' }
        (New-OfficeConfigurationXml -Build $Build).Save($config)
        $install = Start-Process -FilePath $setup -ArgumentList @('/configure', "`"$config`"") -Wait -PassThru
        if ($install.ExitCode -ne 0) { throw "Office setup failed (exit $($install.ExitCode))." }
    }
    finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
}

# The installed version of one component, read through the (mockable) read wrappers. Used before an install (what is there) and after it (did it land).
function Get-JumpComponentVersion {
    param($Component, $Spec, [string] $ExtensionDirectory)
    switch ($Component.Kind) {
        'winget' { Get-InstalledWingetVersion -Id $Component.Name -Source $Component.Data.Source }
        'msix' { Get-ProvisionedJumpMsixVersion -Pin $Component.Data }
        'psresource' { Get-InstalledPSResourceVersion -Name $Component.Name }
        'az-extension' { Get-InstalledAzExtensionVersion -Name $Component.Name }
        'az-bicep' { Get-InstalledAzBicepVersion -Spec $Spec }
        'codex-cli' { Get-InstalledJumpCodexVersion -Spec $Spec }
        'code' { Get-VSCodeExtensionVersion -Id $Component.Name -Directory $ExtensionDirectory }
        'feature' { Get-WindowsFeatureState -Name $Component.Name }
        'wsl' { if (Get-WslState -Distribution $Component.Name) { $Component.Version } else { $null } }
        'ansible' { if (Get-WslState -Distribution $Spec.Distribution) { Get-AnsibleState -Distribution $Spec.Distribution -Component $Component.Name } else { $null } }
        'office' { Get-OfficeBuild }
    }
}

# A feature waiting for a restart counts as installed. Package versions must match exactly.
function Test-JumpComponentCorrect {
    param($Component, $Installed)
    if (-not $Installed) { return $false }
    if ($Component.Kind -eq 'feature') { return ([string]$Installed -in @('Installed', 'InstallPending')) }
    return ($Component.Version -cne 'N/A' -and [string]$Installed -ceq [string]$Component.Version)
}

function Invoke-JumpTools {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch] $Execute,
        [switch] $VerifyOnly,
        [string[]] $Only,
        [switch] $SkipOffice,
        [switch] $PassThru,
        [string] $VersionsPath = (Join-Path $PSScriptRoot 'jump-tools.versions.psd1'),
        [string] $AdditionalVersionsPath
    )

    $script:JumpToolsFailed = $false
    if ($VerifyOnly -and $Execute) { throw 'VerifyOnly cannot be combined with Execute.' }
    if (-not $Execute) { $WhatIfPreference = $true }
    $configuration = Get-JumpConfiguration -Path $VersionsPath
    if ($AdditionalVersionsPath) {
        $extra = Get-JumpConfiguration -Path $AdditionalVersionsPath
        if ($extra.Contains('Tools')) { foreach ($k in $extra.Tools.Keys) { $configuration.Tools[$k] = $extra.Tools[$k] } }
        if ($extra.Contains('AnsibleCollections')) {
            if (-not $configuration.Contains('AnsibleCollections')) { $configuration.AnsibleCollections = @{} }
            foreach ($k in $extra.AnsibleCollections.Keys) { $configuration.AnsibleCollections[$k] = $extra.AnsibleCollections[$k] }
        }
    }
    $tools = $configuration.Tools
    if ($null -eq $tools -or $tools -isnot [System.Collections.IDictionary]) { throw 'The versions file must contain a Tools dictionary.' }
    $requested = @($Only | Where-Object { $_ })
    foreach ($key in $requested) { if (-not $tools.Contains($key)) { throw "Unknown tool key: $key" } }

    $keys = @(if ($requested.Count -gt 0) { $requested } else { $tools.Keys })
    if ($SkipOffice) { $keys = @($keys | Where-Object { $_ -ne 'office' }) }
    if ($VerifyOnly -and $keys.Count -eq 0) { throw 'Verification requires at least one selected tool.' }

    # Pins are checked for the selected tools only, so one unresolved pin blocks its own tool and nothing else.
    $selected = @{ Tools = @{} }
    foreach ($key in $keys) { $selected.Tools[$key] = $tools[$key] }
    if ($keys -contains 'ansible-wsl') { $selected.AnsibleCollections = $configuration.AnsibleCollections }
    $pins = @(Get-PendingPins -Configuration $selected)
    if ($VerifyOnly -and $pins.Count -gt 0) { throw 'Verification requires resolved pins for every selected tool.' }
    if ($Execute) {
        if (-not (Test-JumpElevated)) { throw 'Execution requires an elevated session.' }
        if ($pins.Count -gt 0) { throw "Resolve TODO-PIN before execution: $($pins -join ', ')" }
    }
    elseif ($pins.Count -gt 0) { Write-Warning "Unresolved pins (execution is refused until they are set): $($pins -join ', ')" }

    $results = [System.Collections.Generic.List[object]]::new()
    $extensionDirectory = Join-Path $env:ProgramData 'JumpTools\VSCodeExtensions'

    foreach ($key in $keys) {
        $spec = $tools[$key]
        $wanted = [string] $spec.Version
        $found = [System.Collections.Generic.List[string]]::new()
        $missing = [System.Collections.Generic.List[object]]::new()
        $reboot = $false

        # A tool can have several components (a package plus extensions, several modules). Each is checked before it is
        # scheduled; a correct component is never installed again.
        $components = [System.Collections.Generic.List[object]]::new()
        if ($spec.Contains('Msix')) {
            $components.Add([pscustomobject]@{ Kind = 'msix'; Name = $spec.Msix.Name; Version = $spec.Msix.Version; Data = $spec.Msix })
        }
        if ($spec.Contains('Packages')) {
            foreach ($package in $spec.Packages) {
                $components.Add([pscustomobject]@{ Kind = 'winget'; Name = $package.Id; Version = $package.Version; Data = $package })
            }
        }
        if ($spec.Contains('Modules')) {
            foreach ($name in $spec.Modules.Keys) { $components.Add([pscustomobject]@{ Kind = 'psresource'; Name = $name; Version = $spec.Modules[$name]; Data = $null }) }
        }
        if ($spec.Contains('Features')) {
            foreach ($name in $spec.Features) { $components.Add([pscustomobject]@{ Kind = 'feature'; Name = $name; Version = 'Installed'; Data = $null }) }
        }
        if ($key -eq 'azure-cli') {
            foreach ($name in $spec.Extensions.Keys) { $components.Add([pscustomobject]@{ Kind = 'az-extension'; Name = $name; Version = $spec.Extensions[$name]; Data = $null }) }
        }
        if ($key -eq 'bicep') { $components.Add([pscustomobject]@{ Kind = 'az-bicep'; Name = 'az bicep'; Version = $spec.Version; Data = $null }) }
        if ($key -eq 'codex-cli') { $components.Add([pscustomobject]@{ Kind = 'codex-cli'; Name = 'Codex CLI'; Version = $spec.Version; Data = $null }) }
        if ($key -eq 'vscode') {
            foreach ($name in $spec.Extensions.Keys) { $components.Add([pscustomobject]@{ Kind = 'code'; Name = $name; Version = $spec.Extensions[$name]; Data = $null }) }
        }
        if ($key -eq 'ansible-wsl') {
            $components.Add([pscustomobject]@{ Kind = 'wsl'; Name = $spec.Distribution; Version = $spec.Version; Data = $null })
            $components.Add([pscustomobject]@{ Kind = 'ansible'; Name = 'ansible-core'; Version = $spec.AnsibleCoreVersion; Data = $null })
            foreach ($name in $configuration.AnsibleCollections.Keys) { $components.Add([pscustomobject]@{ Kind = 'ansible'; Name = $name; Version = $configuration.AnsibleCollections[$name]; Data = $null }) }
        }
        if ($key -eq 'office') { $components.Add([pscustomobject]@{ Kind = 'office'; Name = 'Microsoft 365 Apps'; Version = $spec.Version; Data = $null }) }
        if ($components.Count -eq 0) { throw "The versions file defines nothing to install for '$key'." }

        foreach ($component in $components) {
            try {
                $installed = Get-JumpComponentVersion -Component $component -Spec $spec -ExtensionDirectory $extensionDirectory
            }
            catch {
                if (-not $VerifyOnly) { throw }
                $installed = $null
            }
            if ($installed) { $found.Add("$($component.Name)=$installed") }
            if ($VerifyOnly -and $component.Kind -eq 'feature' -and $installed -eq 'InstallPending') {
                $missing.Add($component)
                $reboot = $true
            }
            elseif (-not (Test-JumpComponentCorrect -Component $component -Installed $installed)) { $missing.Add($component) }
        }

        $action = if ($missing.Count) { 'Install' } else { 'Skip' }
        $result = if ($missing.Count) { 'Planned' } else { 'AlreadyCorrect' }
        if ($VerifyOnly) {
            $action = 'Verify'
            $result = if ($missing.Count) { 'Failed' } else { 'Passed' }
        }

        if ($Execute -and $missing.Count -gt 0) {
            $result = 'Installed'
            foreach ($component in $missing) {
                Write-Log "$key`: installing $($component.Name) $($component.Version)"
                $verify = $true
                try {
                    if (-not $PSCmdlet.ShouldProcess($component.Name, "Install $($component.Version)")) { if ($result -ne 'Failed') { $result = 'Planned' }; continue }
                    switch ($component.Kind) {
                        'msix' { Invoke-JumpMsixProvisioning -Spec $spec }
                        'winget' {
                            $arguments = @('install', '--id', $component.Name, '--exact', '--scope', 'machine', '--silent',
                                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                            if ($component.Data.Source) { $arguments += @('--source', $component.Data.Source) }
                            if ($component.Version -cne 'N/A') { $arguments += @('--version', $component.Version) }
                            if ($component.Data.Contains('Override') -and $component.Data.Override) { $arguments += @('--override', $component.Data.Override) }
                            Invoke-Winget -Arguments $arguments
                            Set-WingetAutoUpdate
                        }
                        'psresource' { Install-PSResourcePinned -Name $component.Name -Version $component.Version }
                        'az-extension' { Invoke-AzCli -Arguments @('extension', 'add', '--name', $component.Name, '--version', $component.Version, '--system') }
                        'az-bicep' { Invoke-JumpBicepSetup -Spec $spec }
                        'codex-cli' { Invoke-JumpCodexSetup -Spec $spec }
                        'code' {
                            Set-MachineExtensionsDirectory -Directory $extensionDirectory
                            Invoke-Code -Id $component.Name -Version $component.Version -Directory $extensionDirectory
                        }
                        'feature' {
                            $featureResult = Install-WindowsFeaturePinned -Name $component.Name
                            if ($featureResult.RestartNeeded -eq 'Yes') { $reboot = $true }
                        }
                        'wsl' {
                            try { Invoke-Wsl -Arguments @('--install', '-d', $component.Name, '--no-launch') }
                            catch { if (-not (Get-WslState -Distribution $component.Name)) { throw } }
                            # A new WSL component or distribution is usable after the next boot; the Ansible steps run on the next pass.
                            $reboot = $true
                            $verify = $false
                        }
                        'ansible' {
                            if ($reboot) { $verify = $false; break }
                            if ($component.Name -eq 'ansible-core') {
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'sh', '-c', 'apt-get update && apt-get install -y pipx python3-venv')
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'pipx', 'install', '--global', "ansible-core==$($component.Version)")
                            }
                            else {
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'ansible-galaxy', 'collection', 'install', '-p', '/usr/share/ansible/collections', "$($component.Name):$($component.Version)")
                            }
                        }
                        'office' { Invoke-OfficeSetup -Build $component.Version -DownloadUrl $spec.DownloadUrl -Sha256 $spec.DownloadSha256 }
                    }
                    # Install-then-verify: an exit code of 0 does not prove the pinned version landed (winget can pick another one).
                    if ($verify) {
                        $after = Get-JumpComponentVersion -Component $component -Spec $spec -ExtensionDirectory $extensionDirectory
                        if (-not (Test-JumpComponentCorrect -Component $component -Installed $after)) {
                            throw "installed, but found '$after' where '$($component.Version)' is pinned"
                        }
                    }
                }
                catch {
                    $result = 'Failed'
                    Write-Log "$key`: $($component.Name) failed: $($_.Exception.Message)"
                }
            }
            if ($reboot -and $result -ne 'Failed') { $result = 'RebootRequired' }
        }

        Write-Log "$key`: $action, $result"
        $results.Add([pscustomobject]@{
                Tool   = $key
                Wanted = $wanted
                Found  = if ($found.Count) { $found -join '; ' } else { 'Not found' }
                Action = $action
                Result = $result
                Reboot = $reboot
            })
    }

    $results | Format-Table Tool, Wanted, Found, Action, Result, Reboot -AutoSize | Out-String | Write-Information -InformationAction Continue
    $script:JumpToolsFailed = @($results | Where-Object { $_.Result -eq 'Failed' }).Count -gt 0
    if ($PassThru) { return $results.ToArray() }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-JumpTools -Execute:$Execute -Only $Only -SkipOffice:$SkipOffice -PassThru:$PassThru -VersionsPath $VersionsPath -AdditionalVersionsPath $AdditionalVersionsPath
    if ($script:JumpToolsFailed) { exit 1 }
}
