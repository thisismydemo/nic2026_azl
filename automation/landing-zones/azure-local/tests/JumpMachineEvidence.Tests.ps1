#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
}
Describe 'exact non-ProductCode machine package evidence' {
    BeforeEach {
        $script:package = [pscustomobject]@{ Id='Example.Tool'; Source='winget'; InstalledVersion='1.2.3' }
        $script:evidence = @{ PackageId='Example.Tool'; Kind='portable'; CatalogVersion='1.2.3'; UninstallKey='Example.Tool_Official.Source'; Publisher='Example Publisher'; Directory='Example Tool'; Binary='tool.exe'; SourceIdentifier='Official.Source'; BinarySha256=('A' * 64) }
        $script:registration = [pscustomobject]@{
            PSChildName='Example.Tool_Official.Source'; DisplayVersion='1.2.3'; Publisher='Example Publisher'; InstallLocation=(Join-Path $env:ProgramFiles 'Example Tool')
            WinGetPackageIdentifier='Example.Tool'; WinGetSourceIdentifier='Official.Source'; WinGetInstallerType='portable'
        }
        Mock Get-JumpMachineUninstallEntry { $script:registration }
        Mock Test-Path { $true }
        Mock Get-Item { [pscustomobject]@{ Attributes=[IO.FileAttributes]::Normal; VersionInfo=[pscustomobject]@{ProductVersion='1.2.3.windows.4' } } }
        Mock Get-FileHash { [pscustomobject]@{Hash=('A' * 64) } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid'; SignerCertificate=[pscustomobject]@{Subject='CN=Example Signer' } } }
    }
    It 'proves an exact portable identity with independent executable bytes' {
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -Be '1.2.3'
    }
    It 'rejects wrong catalog <Field>' -ForEach @(@{Field='Id' }, @{Field='Source' }, @{Field='InstalledVersion' }) {
        $script:package.$Field = 'other'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects wrong registration <Field>' -ForEach @(
        @{Field='PSChildName' }, @{Field='DisplayVersion' }, @{Field='Publisher' }, @{Field='WinGetPackageIdentifier' }, @{Field='WinGetSourceIdentifier' }, @{Field='WinGetInstallerType' }
    ) {
        $script:registration.$Field = 'other'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects duplicate machine registration instead of guessing' {
        Mock Get-JumpMachineUninstallEntry { @($script:registration, $script:registration) }
        { Get-JumpEvidenceInstalledVersion $script:package $script:evidence } | Should -Throw '*ambiguous*'
    }
    It 'rejects an altered executable hash' {
        Mock Get-FileHash { [pscustomobject]@{Hash=('B' * 64) } }
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects a user install location despite catalog presence' {
        $script:registration.InstallLocation = Join-Path $TestDrive 'user-tool'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects traversal in configured <Field>' -ForEach @(@{Field='Directory' }, @{Field='Binary' }) {
        $script:evidence[$Field] = '../escaped.exe'
        { Get-JumpEvidenceInstalledVersion $script:package $script:evidence } | Should -Throw '*bounded relative*'
    }
    It 'rejects any reparse escape along the binary path' {
        Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint } }
        { Get-JumpEvidenceInstalledVersion $script:package $script:evidence } | Should -Throw '*reparse*'
    }
    It 'requires readable independent executable evidence' {
        Mock Get-FileHash { throw 'Access denied' }
        { Get-JumpEvidenceInstalledVersion $script:package $script:evidence } | Should -Throw '*Access denied*'
    }
    It 'accepts signed Inno evidence only with the explicitly pinned PE version' {
        $script:evidence.Kind='signed-inno'; $script:evidence.Signer='CN=Example Signer'; $script:evidence.ProductVersion='1.2.3.windows.4'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -Be '1.2.3'
        $script:evidence.ProductVersion='1.2.3.4'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects a valid signature with the wrong signer' {
        $script:evidence.Kind='signed-inno'; $script:evidence.Signer='CN=Other'; $script:evidence.ProductVersion='1.2.3.windows.4'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects an untrusted signature despite the expected signer' {
        $script:evidence.Kind='signed-inno'; $script:evidence.Signer='CN=Example Signer'; $script:evidence.ProductVersion='1.2.3.windows.4'
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotTrusted'; SignerCertificate=[pscustomobject]@{Subject='CN=Example Signer' } } }
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'requires the pinned product commit and system application identity' {
        $script:evidence.Kind='signed-inno'; $script:evidence.Signer='CN=Example Signer'; $script:evidence.ProductVersion='1.2.3.windows.4'
        $script:evidence.ProductJson='resources/product.json'; $script:evidence.Commit='expected-commit'; $script:evidence.SystemAppId='expected-system-id'
        Mock Get-Content { '{"commit":"expected-commit","win32x64AppId":"expected-system-id"}' }
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -Be '1.2.3'
        Mock Get-Content { '{"commit":"other","win32x64AppId":"expected-system-id"}' }
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'passes configured proof through the public pinned client without requiring ProductCodes' {
        Mock Import-JumpPackageClient {}
        Mock Get-WinGetPackage { $script:package }
        Get-JumpClientInstalledVersion -Id 'Example.Tool' -Source 'winget' -ClientVersion '1.29.380' -MachineEvidence $script:evidence | Should -Be '1.2.3'
    }
    It 'cannot bypass configured machine proof through a successful CLI query' {
        Mock Get-JumpClientInstalledVersion { throw 'Exact proof failed' }
        { Get-InstalledWingetVersion -Id 'Example.Tool' -Source 'winget' -ClientVersion '1.29.380' -MachineEvidence $script:evidence } | Should -Throw '*proof failed*'
    }
    It 'accepts only an explicit MSI catalog-to-file version mapping with matching ProductCode and bytes' {
        $script:package.InstalledVersion='1.2.3.0'
        $script:package | Add-Member -NotePropertyName AvailableVersions -NotePropertyValue @('1.2.3')
        $script:package | Add-Member -MemberType ScriptMethod -Name GetPackageVersionInfo -Value { param($version); @{ProductCodes=@('{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}') } }
        $script:evidence.Kind='msi-file-hash'; $script:evidence.CatalogVersion='1.2.3.0'; $script:evidence.PackageVersion='1.2.3'; $script:evidence.UninstallKey='{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        $script:registration.PSChildName='{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'; $script:registration.DisplayVersion='1.2.3.0'; $script:registration.InstallLocation=''
        Mock Get-Item { [pscustomobject]@{Attributes=[IO.FileAttributes]::Normal; VersionInfo=[pscustomobject]@{ProductVersion='1.2.3' } } }
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -Be '1.2.3'
        $script:package.InstalledVersion='1.2.3.0.0'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
    It 'rejects MSI mapping when catalog metadata does not contain the exact machine ProductCode' {
        $script:package | Add-Member -NotePropertyName AvailableVersions -NotePropertyValue @('1.2.3')
        $script:package | Add-Member -MemberType ScriptMethod -Name GetPackageVersionInfo -Value { param($version); @{ProductCodes=@('Other.MSI') } }
        $script:evidence.Kind='msi-file-hash'; $script:evidence.PackageVersion='1.2.3'; $script:evidence.UninstallKey='{00000000-0000-0000-0000-000000000000}'
        $script:registration.PSChildName='{00000000-0000-0000-0000-000000000000}'
        Get-JumpEvidenceInstalledVersion $script:package $script:evidence | Should -BeNullOrEmpty
    }
}
