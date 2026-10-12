#Requires -Version 7.0
<#
.SYNOPSIS
    Tests machine Node provenance, canonical dispatch and immutable CI module pins.
.NOTES
    Author: Kristopher Turner
    TaskReference: T-3.1.3b
#>
BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '../scripts'
    . (Join-Path $script:scripts 'Install-JumpTools.ps1')
    $script:configuration = Import-PowerShellDataFile -LiteralPath (Join-Path $script:scripts 'jump-tools.versions.psd1')
    $script:spec = $script:configuration.Tools.node
}
Describe 'machine Node source trust and canonical acceptance' {
    It 'pins testing dependencies to the actual CI requirements' {
        $ci = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../../.github/workflows/ci.yml') -Raw
        foreach ($name in $script:configuration.Tools.testing.Modules.Keys) {
            $version = $script:configuration.Tools.testing.Modules[$name]
            $ci | Should -Match ('Install-Module ' + [regex]::Escape($name) + ' -RequiredVersion ' + [regex]::Escape($version))
        }
    }
    It 'rejects a checksum mismatch before asking for signer trust' {
        Mock Get-FileHash { @{Hash=('0' * 64) } }
        Mock Get-AuthenticodeSignature { throw 'Unexpected signature lookup' }
        { Assert-JumpNodeArtifact -Path 'sample.msi' -Spec $script:spec } | Should -Throw '*checksum mismatch*'
        Should -Invoke Get-AuthenticodeSignature -Times 0
    }
    It 'rejects a valid signature from a different publisher' {
        Mock Get-FileHash { @{Hash=$script:spec.Node.Sha256 } }
        Mock Get-AuthenticodeSignature { @{Status='Valid'; SignerCertificate=@{Subject='CN=Different publisher' } } }
        { Assert-JumpNodeArtifact -Path 'sample.msi' -Spec $script:spec } | Should -Throw '*publisher verification failed*'
    }
    It 'performs no downloads or staging under WhatIf' {
        Mock Invoke-WebRequest { throw 'Unexpected download' }
        Mock New-JumpMsixStagingDirectory { throw 'Unexpected staging' }
        Mock Start-Process { throw 'Unexpected install' }
        Invoke-JumpNodeSetup -Spec $script:spec -WhatIf
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke New-JumpMsixStagingDirectory -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects an unapproved origin before staging' {
        $bad = @{Version=$script:spec.Version; Node=@{DownloadUrl='https://example.invalid/node.msi' } }
        Mock New-JumpMsixStagingDirectory { throw 'Unexpected staging' }
        { Invoke-JumpNodeSetup -Spec $bad } | Should -Throw '*exact official pinned release*'
        Should -Invoke New-JumpMsixStagingDirectory -Times 0
    }
    It 'does not accept a missing runtime or operator PATH as machine proof' {
        Mock Test-Path { $false }
        Get-InstalledJumpNodeVersion -Spec $script:spec | Should -BeNullOrEmpty
    }
    It 'rejects missing HKLM installer proof even if binaries exist' {
        Mock Test-Path { $true }
        Mock Get-Item { @{Attributes=[IO.FileAttributes]::Normal } }
        Mock Get-JumpMachineUninstallEntry { @() }
        Get-InstalledJumpNodeVersion -Spec $script:spec | Should -BeNullOrEmpty
    }
    It 'rejects an npm version mismatch before executing runtime probes' {
        Mock Test-Path { $true }
        Mock Get-Item { @{Attributes=[IO.FileAttributes]::Normal; VersionInfo=@{ProductVersion=$script:spec.Version } } }
        Mock Get-JumpMachineUninstallEntry { @{PSChildName=$script:spec.Node.ProductCode; DisplayVersion=$script:spec.Version; Publisher=$script:spec.Node.RegistrationPublisher; WindowsInstaller=1 } }
        Mock Get-FileHash { @{Hash=$script:spec.Node.BinarySha256 } }
        Mock Get-Content { '{"version":"0.0.0"}' }
        Get-InstalledJumpNodeVersion -Spec $script:spec | Should -BeNullOrEmpty
    }
    It 'uses canonical read-only verification without installation' {
        Mock Get-InstalledJumpNodeVersion { $script:spec.Version }
        Mock Invoke-JumpNodeSetup { throw 'Unexpected installation' }
        $result = Invoke-JumpTools -Only node -VerifyOnly -PassThru
        $result.Result | Should -Be 'Passed'
        Should -Invoke Invoke-JumpNodeSetup -Times 0
    }
    It 'skips a complete correct installation in Execute mode' {
        Mock Test-JumpElevated { $true }
        Mock Get-InstalledJumpNodeVersion { $script:spec.Version }
        Mock Invoke-JumpNodeSetup { throw 'Unexpected installation' }
        $result = Invoke-JumpTools -Only node -Execute -PassThru
        $result.Result | Should -Be 'AlreadyCorrect'
        Should -Invoke Invoke-JumpNodeSetup -Times 0
    }
    It 'fails incomplete post-install acceptance' {
        Mock Test-JumpElevated { $true }
        Mock Get-InstalledJumpNodeVersion { $null }
        Mock Invoke-JumpNodeSetup {}
        $result = Invoke-JumpTools -Only node -Execute -PassThru
        $result.Result | Should -Be 'Failed'
    }
}
