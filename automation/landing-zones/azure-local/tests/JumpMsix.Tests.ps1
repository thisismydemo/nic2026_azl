#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
    $script:pin = @{ Name = 'Example.App'; Version = '2.0.30000.0'; Architecture = 'x64'; Publisher = 'CN=Example'; PublisherId = 'example'; Sha256 = ('A' * 64); Dependencies = @() }
    $script:file = Join-Path $TestDrive 'package.msix'
    Set-Content $script:file 'synthetic package'
    function winget { $global:LASTEXITCODE = 0 }
}
Describe 'signed MSIX pin validation' {
    BeforeEach {
        Mock Get-FileHash { @{ Hash = ('A' * 64) } }
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Example' } } }
        Mock Get-JumpMsixManifest { [xml]'<Package><Identity Name="Example.App" Version="2.0.30000.0" ProcessorArchitecture="x64" Publisher="CN=Example" /></Package>' }
    }
    It 'accepts the exact signed identity and bytes' { Assert-JumpMsixPackage $script:file $script:pin | Should -Not -BeNullOrEmpty }
    It 'accepts lowercase hexadecimal pins without changing version matching' {
        $pin = $script:pin.Clone(); $pin.Sha256 = $pin.Sha256.ToLowerInvariant()
        Assert-JumpMsixPackage $script:file $pin | Should -Not -BeNullOrEmpty
    }
    It 'rejects changed bytes before reading the manifest' {
        Mock Get-FileHash { @{ Hash = ('B' * 64) } }
        { Assert-JumpMsixPackage $script:file $script:pin } | Should -Throw '*SHA-256*'
        Should -Invoke Get-JumpMsixManifest -Times 0
    }
    It 'rejects an untrusted signature' {
        Mock Get-AuthenticodeSignature { @{ Status = 'NotTrusted'; SignerCertificate = @{ Subject = 'CN=Example' } } }
        { Assert-JumpMsixPackage $script:file $script:pin } | Should -Throw '*signature*'
    }
    It 'rejects a different signer even if its signature is valid' {
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Other' } } }
        { Assert-JumpMsixPackage $script:file $script:pin } | Should -Throw '*signature*'
    }
    It 'rejects a wrong <Field> identity' -ForEach @(
        @{ Field = 'Name'; Value = 'Other.App' }, @{ Field = 'Version'; Value = '9.0.30000.0' },
        @{ Field = 'Publisher'; Value = 'CN=Other' }, @{ Field = 'ProcessorArchitecture'; Value = 'arm64' }
    ) {
        $wrongPin = $script:pin.Clone()
        if ($Field -eq 'ProcessorArchitecture') { $wrongPin.Architecture = $Value } else { $wrongPin[$Field] = $Value }
        { Assert-JumpMsixPackage $script:file $wrongPin } | Should -Throw '*mismatch*'
    }
}
Describe 'direct official dependency archive acquisition' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:archive = Join-Path $TestDrive 'source.zip'
        $zip = [IO.Compression.ZipFile]::Open($script:archive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry('x64/Example.Framework.appx')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('synthetic framework bytes') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose() }
        $script:sourceHash = (Get-FileHash -LiteralPath $script:archive).Hash
        $script:sourcePin = @{ Name='Example.Framework'; DownloadUrl='https://example.invalid/deps.zip'; ArchiveSha256=$script:sourceHash; ArchiveEntry='x64/Example.Framework.appx' }
    }
    BeforeEach {
        $script:target = Join-Path $TestDrive ([IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:target
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:archive -Destination $OutFile }
    }
    It 'extracts only the exact pinned entry into a locally selected filename' {
        $file = Get-JumpMsixDependencyArtifact -Pin $script:sourcePin -Directory $script:target
        Get-Content -LiteralPath $file -Raw | Should -Be 'synthetic framework bytes'
        Split-Path -Leaf $file | Should -Be 'Example.Framework.appx'
    }
    It 'accepts lowercase archive hash pins' {
        $pin = $script:sourcePin.Clone(); $pin.ArchiveSha256 = $pin.ArchiveSha256.ToLowerInvariant()
        Get-JumpMsixDependencyArtifact -Pin $pin -Directory $script:target | Should -Exist
    }
    It 'rejects altered archive bytes before extraction' {
        $bad = $script:sourcePin.Clone(); $bad.ArchiveSha256 = ('B' * 64)
        { Get-JumpMsixDependencyArtifact -Pin $bad -Directory $script:target } | Should -Throw '*archive SHA-256*'
        Test-Path (Join-Path $script:target 'Example.Framework.appx') | Should -BeFalse
    }
    It 'rejects a missing exact entry' {
        $bad = $script:sourcePin.Clone(); $bad.ArchiveEntry = 'x64/Missing.appx'
        { Get-JumpMsixDependencyArtifact -Pin $bad -Directory $script:target } | Should -Throw '*missing or ambiguous*'
    }
    It 'extracts a root package or license entry without expanding archive paths' -ForEach @(@{Entry='Main.msix' }, @{Entry='License.xml' }) {
        $script:fixtureRootArchive = Join-Path $script:target 'root-source.zip'
        $zip = [IO.Compression.ZipFile]::Open($script:fixtureRootArchive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($Entry).Open())
            try { $writer.Write('exact root artifact') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose() }
        $pin = $script:sourcePin.Clone(); $pin.ArchiveEntry = $Entry; $pin.ArchiveSha256 = (Get-FileHash $script:fixtureRootArchive).Hash
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:fixtureRootArchive -Destination $OutFile }
        $file = Get-JumpMsixDependencyArtifact -Pin $pin -Directory $script:target
        Get-Content -LiteralPath $file -Raw | Should -Be 'exact root artifact'
        Split-Path -Leaf $file | Should -Be ('Example.Framework' + [IO.Path]::GetExtension($Entry))
    }
    It 'rejects unsafe entry <Entry> before download' -ForEach @(
        @{ Entry='../Example.appx' }, @{ Entry='x64/../Example.appx' }, @{ Entry='/x64/Example.appx' }, @{ Entry='x64\Example.appx' }
    ) {
        $bad = $script:sourcePin.Clone(); $bad.ArchiveEntry = $Entry
        { Get-JumpMsixDependencyArtifact -Pin $bad -Directory $script:target } | Should -Throw '*source pin*'
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'rejects duplicate exact entries in a pinned archive' {
        $duplicate = Join-Path $script:target 'duplicate.zip'
        $zip = [IO.Compression.ZipFile]::Open($duplicate, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $null = $zip.CreateEntry('x64/Example.Framework.appx')
            $null = $zip.CreateEntry('x64/Example.Framework.appx')
        }
        finally { $zip.Dispose() }
        $bad = $script:sourcePin.Clone(); $bad.ArchiveSha256 = (Get-FileHash $duplicate).Hash
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $duplicate -Destination $OutFile }
        { Get-JumpMsixDependencyArtifact -Pin $bad -Directory $script:target } | Should -Throw '*missing or ambiguous*'
    }
}
Describe 'protected machine provisioning staging' {
    BeforeEach {
        $script:originalProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ([IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $env:ProgramData
        Mock Set-Acl {}
    }
    AfterEach { $env:ProgramData = $script:originalProgramData }
    It 'stages only in a unique private machine child with administrator and SYSTEM permissions' {
        $directory = New-JumpMsixStagingDirectory
        $directory | Should -BeLike (Join-Path $env:ProgramData 'JumpTools/MSIXStaging/nic26-msix-*')
        Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
            $AclObject.AreAccessRulesProtected -and $AclObject.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and
            @($AclObject.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])).Count -eq 2 -and
            @($AclObject.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') }).Count -eq 0
        }
    }
    It 'rejects a reparse parent before setting any staging permissions' {
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        { New-JumpMsixStagingDirectory } | Should -Throw '*reparse point*'
        Should -Invoke Set-Acl -Times 0
    }
    It 'inspects a real hidden machine-data ancestor before creating private staging' {
        $parent = Get-Item -LiteralPath $env:ProgramData -Force
        $originalAttributes = $parent.Attributes
        try {
            $parent.Attributes = $originalAttributes -bor [IO.FileAttributes]::Hidden
            $directory = New-JumpMsixStagingDirectory
            Test-Path -LiteralPath $directory -PathType Container | Should -BeTrue
            (Get-Item -LiteralPath $env:ProgramData -Force).Attributes.HasFlag([IO.FileAttributes]::Hidden) | Should -BeTrue
            Should -Invoke Set-Acl -Times 1 -Exactly
        }
        finally { $parent.Attributes = $originalAttributes }
    }
}
Describe 'machine provisioning evidence' {
    BeforeEach {
        Mock Get-AppxProvisionedPackage { @([pscustomobject]@{ PackageName = 'Example.App_2.0.30000.0_x64__example' }) }
        Mock Get-AppxPackage { @() }
    }
    It 'requires an exact machine-provisioned main identity' { Get-ProvisionedJumpMsixVersion $script:pin | Should -Be '2.0.30000.0' }
    It 'does not accept current-user presence when provisioning is absent' {
        Mock Get-AppxProvisionedPackage { @() }
        Get-ProvisionedJumpMsixVersion $script:pin | Should -BeNullOrEmpty
        Should -Invoke Get-AppxPackage -Times 0
    }
    It 'does not accept a different provisioned version' {
        Mock Get-AppxProvisionedPackage { @([pscustomobject]@{ PackageName = 'Example.App_9.0.30000.0_x64__example' }) }
        Get-ProvisionedJumpMsixVersion $script:pin | Should -BeNullOrEmpty
    }
    It 'requires the pinned framework inventory as well as the main provisioning' {
        $p = $script:pin.Clone(); $p.Dependencies = @(@{ Name = 'Example.Framework'; Version = '1.0.30000.0'; Publisher = 'CN=Example'; Architecture = 'x64' })
        Get-ProvisionedJumpMsixVersion $p | Should -BeNullOrEmpty
        Mock Get-AppxPackage { @([pscustomobject]@{ Name = 'Example.Framework'; Version = '1.0.30000.0'; Publisher = 'CN=Example'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = 'C:\Example' }) }
        Get-ProvisionedJumpMsixVersion $p | Should -Be '2.0.30000.0'
    }
    It 'never accepts an N/A package pin' { Test-JumpComponentCorrect @{ Kind = 'winget'; Version = 'N/A' } '7.7.7' | Should -BeFalse }
}
Describe 'provisioning preflight' {
    BeforeEach {
        Mock New-Item {}
        Mock New-JumpMsixStagingDirectory { Join-Path $TestDrive 'private-staging' }
        Mock Invoke-WebRequest {}
        Mock Get-ChildItem { throw 'No Store dependency directory should be searched' }
        Mock Get-JumpMsixDependencyArtifact { 'synthetic-dependency.appx' }
        Mock Get-FileHash { @{ Hash = ('A' * 64) } }
        Mock Add-AppxProvisionedPackage {}
        $script:spec = @{ Msix = @{ Name = 'Example.App'; DownloadUrl = 'https://example.invalid/app.msix'; Architecture = 'x64'; Dependencies = @(@{ Name = 'Example.Framework'; Version = '1.0.30000.0'; Publisher = 'CN=Example'; Architecture = 'x64'; Sha256 = ('A' * 64) }) } }
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies><PackageDependency Name="Example.Framework" Publisher="CN=Example" MinVersion="1.0.30000.0" /></Dependencies></Package>' }
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies /></Package>' } -ParameterFilter { $Path -eq 'synthetic-dependency.appx' }
    }
    It 'does not mutate package state if a dependency fails validation' {
        Mock Assert-JumpMsixPackage { throw 'Dependency signature mismatch' } -ParameterFilter { $Path -eq 'synthetic-dependency.appx' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*signature*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'does not provision if a dependency pin is below the manifest minimum' {
        $script:spec.Msix.Dependencies[0].Version = '0.9.30000.0'
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*insufficient*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'passes all verified dependency paths in the single online provisioning operation' {
        Invoke-JumpMsixProvisioning $script:spec
        Should -Invoke Add-AppxProvisionedPackage -Times 1 -ParameterFilter { $Online -and $SkipLicense -and $DependencyPackagePath -contains 'synthetic-dependency.appx' }
        Should -Invoke Get-ChildItem -Times 0
    }
    It 'does not provision when a direct dependency download fails' {
        Mock Get-JumpMsixDependencyArtifact { throw 'Dependency archive SHA-256 mismatch.' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*archive SHA-256*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'rejects a newly required unpinned main dependency' {
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies><PackageDependency Name="Example.Framework" Publisher="CN=Example" MinVersion="1.0.30000.0" /><PackageDependency Name="Other.Framework" Publisher="CN=Example" MinVersion="1.0.0.0" /></Dependencies></Package>' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*dependency set*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'rejects unresolved required transitive framework dependencies' {
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies><PackageDependency Name="Other.Framework" Publisher="CN=Example" MinVersion="1.0.0.0" /></Dependencies></Package>' } -ParameterFilter { $Path -eq 'synthetic-dependency.appx' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*transitive*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'rejects a dependency with the wrong architecture' {
        $script:spec.Msix.Dependencies[0].Architecture = 'arm64'
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*architecture mismatch*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'provisions a dependency-free package with the pinned offline license' {
        $script:spec.Msix.Dependencies = @()
        $script:spec.Msix.License = @{ DownloadUrl = 'https://example.invalid/license.xml'; Sha256 = ('A' * 64) }
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies><TargetDeviceFamily Name="Windows.Desktop" /></Dependencies></Package>' }
        Invoke-JumpMsixProvisioning $script:spec
        Should -Invoke Add-AppxProvisionedPackage -Times 1 -ParameterFilter { $Online -and $LicensePath -like '*pinned-license.xml' -and $Regions -eq 'all' -and -not $SkipLicense -and -not $DependencyPackagePath }
        Should -Invoke Get-ChildItem -Times 0
    }
    It 'does not provision when offline license bytes change' {
        $script:spec.Msix.Dependencies = @()
        $script:spec.Msix.License = @{ DownloadUrl = 'https://example.invalid/license.xml'; Sha256 = ('B' * 64) }
        Mock Assert-JumpMsixPackage { [xml]'<Package><Dependencies /></Package>' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*license SHA-256*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'provisions a verified archive-backed main and matching offline kit license' {
        $script:spec.Msix.ArchiveSha256 = ('A' * 64); $script:spec.Msix.ArchiveEntry = 'Main.msix'
        $script:spec.Msix.License = @{Name='Example.License'; DownloadUrl='https://example.invalid/kit.zip'; ArchiveSha256=('A' * 64); ArchiveEntry='License.xml'; Sha256=('A' * 64) }
        Mock Get-JumpMsixDependencyArtifact { 'synthetic-main.msix' } -ParameterFilter { $Pin.Name -eq 'Example.App' }
        Mock Get-JumpMsixDependencyArtifact { 'synthetic-license.xml' } -ParameterFilter { $Pin.Name -eq 'Example.License' }
        Invoke-JumpMsixProvisioning $script:spec
        Should -Invoke Add-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $PackagePath -eq 'synthetic-main.msix' -and $LicensePath -eq 'synthetic-license.xml' -and $Regions -eq 'all' -and -not $SkipLicense }
    }
    It 'rejects changed extracted main bytes before any provision operation' {
        $script:spec.Msix.ArchiveSha256 = ('A' * 64); $script:spec.Msix.ArchiveEntry = 'Main.msix'
        Mock Get-JumpMsixDependencyArtifact { 'synthetic-main.msix' } -ParameterFilter { $Pin.Name -eq 'Example.App' }
        Mock Assert-JumpMsixPackage { throw 'Package SHA-256 mismatch' } -ParameterFilter { $Path -eq 'synthetic-main.msix' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*SHA-256*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'rejects changed extracted kit license bytes before provisioning' {
        $script:spec.Msix.License = @{Name='Example.License'; DownloadUrl='https://example.invalid/kit.zip'; ArchiveSha256=('A' * 64); ArchiveEntry='License.xml'; Sha256=('B' * 64) }
        Mock Get-JumpMsixDependencyArtifact { 'synthetic-license.xml' } -ParameterFilter { $Pin.Name -eq 'Example.License' }
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*license SHA-256*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
    It 'never skips a required offline license when its pin is missing' {
        $script:spec.Msix.RequireLicense = $true
        { Invoke-JumpMsixProvisioning $script:spec } | Should -Throw '*Required offline MSIX license*'
        Should -Invoke Add-AppxProvisionedPackage -Times 0
    }
}
