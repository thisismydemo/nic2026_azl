#Requires -Version 7.0
<#
.SYNOPSIS
    Tests pinned Python source trust, all-users inventory and read-only planning guards.
.NOTES
    Author: Kristopher Turner
    Contact: kris@hybridsolutions.cloud
    Version: 1.0.0
    TaskReference: T-3.1.3b
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '../scripts'
    . (Join-Path $script:scripts 'Install-JumpTools.ps1')
    . (Join-Path $script:scripts 'JumpPython.Common.ps1')
    $script:spec = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:scripts 'jump-tools.versions.psd1')).Tools.python
}
Describe 'machine Python and renderer acceptance' {
    It 'pins complete renderer dependency closure and matching lock hashes' {
        $script:spec.Version | Should -Be '3.14.8'
        @($script:spec.Python.Packages.Name) | Should -Be @('Jinja2', 'PyYAML', 'MarkupSafe')
        $lock = (Get-Content -LiteralPath (Join-Path $script:scripts 'jump-python.requirements.lock.txt') -Raw).Trim().Replace("`r`n", "`n")
        $expected = @($script:spec.Python.Packages | ForEach-Object { '{0}=={1} --hash=sha256:{2}' -f $_.Name, $_.Version, $_.Sha256 }) -join "`n"
        $lock | Should -BeExactly $expected
    }
    It 'uses Program Files and rejects directory traversal before execution' {
        $layout = Get-JumpPythonLayout -Spec $script:spec
        $layout.Python | Should -Be (Join-Path $env:ProgramFiles 'Python314/python.exe')
        $bad = @{ Version='3.14.8'; Python=@{ InstallDirectory='../outside'; RendererDirectory='Example' } }
        { Get-JumpPythonLayout -Spec $bad } | Should -Throw '*relative to machine Program Files*'
    }
    It 'does not accept a missing runtime or Store alias as machine installation' {
        Mock Test-Path { $false }
        Mock Get-JumpPythonProbe { throw 'Unexpected interpreter execution' }
        Get-InstalledJumpPythonVersion -Spec $script:spec | Should -BeNullOrEmpty
        Should -Invoke Get-JumpPythonProbe -Times 0
    }
    It 'rejects installer checksum mismatch before signature or wheel acceptance' {
        Mock Get-FileHash { @{ Hash=('0' * 64) } }
        Mock Get-AuthenticodeSignature { throw 'Should not verify a hash-mismatched installer' }
        { Assert-JumpPythonArtifact -Installer 'example.exe' -WheelDirectory $TestDrive -Spec $script:spec } | Should -Throw '*installer hash mismatch*'
        Should -Invoke Get-AuthenticodeSignature -Times 0
    }
    It 'rejects a validly signed installer with a different publisher' {
        Mock Get-FileHash { @{ Hash=$script:spec.Python.Sha256 } }
        Mock Get-AuthenticodeSignature { @{ Status='Valid'; SignerCertificate=@{ Subject='CN=Different Publisher' } } }
        { Assert-JumpPythonArtifact -Installer 'example.exe' -WheelDirectory $TestDrive -Spec $script:spec } | Should -Throw '*signature mismatch*'
    }
    It 'rejects a tampered dependency wheel after verifying the installer' {
        Mock Get-FileHash { if ($LiteralPath -eq 'example.exe') { @{ Hash=$script:spec.Python.Sha256 } } else { @{ Hash=('0' * 64) } } }
        Mock Get-AuthenticodeSignature { @{ Status='Valid'; SignerCertificate=@{ Subject=$script:spec.Python.Publisher } } }
        { Assert-JumpPythonArtifact -Installer 'example.exe' -WheelDirectory $TestDrive -Spec $script:spec } | Should -Throw '*wheel hash mismatch*'
    }
    It 'keeps direct setup WhatIf free of download, staging, installer and native calls' {
        Mock Invoke-WebRequest { throw 'Unexpected download' }
        Mock New-JumpMsixStagingDirectory { throw 'Unexpected staging' }
        Mock Start-Process { throw 'Unexpected installer' }
        Invoke-JumpPythonSetup -Spec $script:spec -WhatIf
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke New-JumpMsixStagingDirectory -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects unapproved installer origin before staging' {
        $bad = @{ Version=$script:spec.Version; Python=@{} }
        foreach ($key in $script:spec.Python.Keys) { $bad.Python[$key]=$script:spec.Python[$key] }
        $bad.Python.DownloadUrl='https://example.invalid/python.exe'
        Mock New-JumpMsixStagingDirectory { throw 'Unexpected staging' }
        { Invoke-JumpPythonSetup -Spec $bad -Confirm:$false } | Should -Throw '*official x64 source*'
        Should -Invoke New-JumpMsixStagingDirectory -Times 0
    }
    It 'dispatches canonical Python verification without any installation' {
        Mock Get-InstalledJumpPythonVersion { '3.14.8' }
        Mock Invoke-JumpPythonSetup { throw 'Unexpected installation' }
        $result = Invoke-JumpTools -Only python -VerifyOnly -PassThru
        $result.Tool | Should -Be 'python'
        $result.Result | Should -Be 'Passed'
        Should -Invoke Invoke-JumpPythonSetup -Times 0
    }
    It 'skips an already-correct Python tool in execution mode' {
        Mock Test-JumpElevated { $true }
        Mock Get-InstalledJumpPythonVersion { '3.14.8' }
        Mock Invoke-JumpPythonSetup { throw 'Unexpected reinstall' }
        $result = Invoke-JumpTools -Only python -Execute -PassThru
        $result.Result | Should -Be 'AlreadyCorrect'
        Should -Invoke Invoke-JumpPythonSetup -Times 0
    }
    It 'fails the component when post-install verification remains incomplete' {
        Mock Test-JumpElevated { $true }
        Mock Get-InstalledJumpPythonVersion { $null }
        Mock Invoke-JumpPythonSetup {}
        $result = Invoke-JumpTools -Only python -Execute -PassThru
        $result.Result | Should -Be 'Failed'
        Should -Invoke Invoke-JumpPythonSetup -Times 1
    }
}
