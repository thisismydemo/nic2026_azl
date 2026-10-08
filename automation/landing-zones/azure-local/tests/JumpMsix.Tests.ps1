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
        Mock Invoke-WebRequest {}
        Mock Get-ChildItem { @([pscustomobject]@{ FullName = 'synthetic-dependency.appx' }) }
        Mock Get-FileHash { @{ Hash = ('A' * 64) } }
        Mock Add-AppxProvisionedPackage {}
        $script:spec = @{ Msix = @{ Name = 'Example.App'; DownloadUrl = 'https://example.invalid/app.msix'; StoreId = 'EXAMPLE'; Architecture = 'x64'; Dependencies = @(@{ Name = 'Example.Framework'; Version = '1.0.30000.0'; Publisher = 'CN=Example'; Sha256 = ('A' * 64) }) } }
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
}
