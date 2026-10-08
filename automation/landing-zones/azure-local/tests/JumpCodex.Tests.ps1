#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester setup variables are used in test blocks.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
}
Describe 'full-layout Codex CLI verification' {
    BeforeEach {
        $script:tree = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:tree 'bin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tree 'codex-resources') | Out-Null
        Set-Content (Join-Path $script:tree 'bin/codex.exe') 'synthetic binary'
        Set-Content (Join-Path $script:tree 'codex-resources/resource.dat') 'synthetic resource'
        $script:spec = @{ Version = '1.2.3'; Archive = @{ Publisher = 'CN=Example'; Files = @{
                    'bin/codex.exe' = (Get-FileHash (Join-Path $script:tree 'bin/codex.exe')).Hash
                    'codex-resources/resource.dat' = (Get-FileHash (Join-Path $script:tree 'codex-resources/resource.dat')).Hash
                } 
            } 
        }
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Example' } } }
        Mock Get-JumpCodexReportedVersion { 'codex-cli 1.2.3' }
        Mock Get-JumpCodexLayout { @{ Directory = $script:tree; Bin = (Join-Path $script:tree 'bin') } }
        Mock Get-JumpMachineEnvironment { Join-Path $script:tree 'bin' }
        Mock Set-JumpCodexEnvironment {}
        Mock Invoke-WebRequest {}
    }
    It 'accepts only a complete hash-matched signed package and machine PATH' {
        Get-InstalledJumpCodexVersion -Spec $script:spec | Should -Be '1.2.3'
    }
    It 'rejects a changed ancillary resource before running the executable' {
        Set-Content (Join-Path $script:tree 'codex-resources/resource.dat') 'changed'
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*hash mismatch*'
        Should -Invoke Get-JumpCodexReportedVersion -Times 0
    }
    It 'rejects missing package files' {
        Remove-Item -LiteralPath (Join-Path $script:tree 'codex-resources/resource.dat')
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*file set mismatch*'
    }
    It 'rejects unexpected files' {
        Set-Content (Join-Path $script:tree 'unexpected.txt') 'extra'
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*file set mismatch*'
    }
    It 'rejects an otherwise valid different publisher' {
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Other' } } }
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*signature mismatch*'
    }
    It 'rejects an unexpected reported version' {
        Mock Get-JumpCodexReportedVersion { 'codex-cli 9.9.9' }
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*version mismatch*'
    }
    It 'rejects a redirected installation ancestor before reading package contents' {
        Mock Get-Item { @{ Attributes = [IO.FileAttributes]::ReparsePoint } } -ParameterFilter { $LiteralPath -eq $script:tree }
        { Assert-JumpCodexTree -Directory $script:tree -Spec $script:spec } | Should -Throw '*reparse point*'
        Should -Invoke Get-JumpCodexReportedVersion -Times 0
    }
    It 'reads a real hidden Windows ancestor and retains package/signature validation' -Skip:(-not $IsWindows) {
        $hidden = Join-Path $TestDrive 'hidden-parent'
        $null = New-Item -ItemType Directory -Path $hidden
        $package = Join-Path $hidden 'package'
        Copy-Item -LiteralPath $script:tree -Destination $package -Recurse
        $original = [IO.File]::GetAttributes($hidden)
        try {
            [IO.File]::SetAttributes($hidden, ($original -bor [IO.FileAttributes]::Hidden))
            { Get-Item -LiteralPath $hidden -ErrorAction Stop } | Should -Throw
            { Assert-JumpCodexTree -Directory $package -Spec $script:spec } | Should -Not -Throw
        }
        finally { [IO.File]::SetAttributes($hidden, $original) }
    }
    It 'does not install or update PATH after an archive checksum mismatch' {
        Mock Get-JumpCodexLayout { @{ Directory = (Join-Path $TestDrive 'absent-version'); Bin = (Join-Path $TestDrive 'absent-version/bin') } }
        $script:spec.Archive.DownloadUrl = 'https://example.invalid/package.tar.gz'
        $script:spec.Archive.Sha256 = ('A' * 64)
        Mock Get-FileHash { @{ Hash = ('B' * 64) } }
        Mock Copy-Item {}
        Mock Set-Acl {}
        { Invoke-JumpCodexSetup -Spec $script:spec } | Should -Throw '*archive SHA-256 mismatch*'
        Should -Invoke Copy-Item -Times 0
        Should -Invoke Set-Acl -Times 0
        Should -Invoke Set-JumpCodexEnvironment -Times 0
    }
    It 'does not accept current-process or per-user PATH instead of machine PATH' {
        Mock Get-JumpMachineEnvironment { 'C:\Example\UserTools' }
        Get-InstalledJumpCodexVersion -Spec $script:spec | Should -BeNullOrEmpty
    }
    It 'repairs machine PATH only after an existing complete package is verified' {
        Invoke-JumpCodexSetup -Spec $script:spec
        Should -Invoke Set-JumpCodexEnvironment -Times 1
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'refuses to overwrite a mismatched existing package' {
        Set-Content (Join-Path $script:tree 'codex-resources/resource.dat') 'changed'
        { Invoke-JumpCodexSetup -Spec $script:spec } | Should -Throw '*hash mismatch*'
        Should -Invoke Set-JumpCodexEnvironment -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'keeps plan and VerifyOnly free of setup operations' {
        Mock Get-JumpConfiguration { @{ Tools = @{ 'codex-cli' = $script:spec } } }
        Mock Invoke-JumpCodexSetup {}
        $plan = Invoke-JumpTools -Only codex-cli -PassThru
        $plan.Tool | Should -Be 'codex-cli'
        $verified = Invoke-JumpTools -Only codex-cli -VerifyOnly -PassThru
        $verified.Result | Should -Be 'Passed'
        Should -Invoke Invoke-JumpCodexSetup -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }
}
