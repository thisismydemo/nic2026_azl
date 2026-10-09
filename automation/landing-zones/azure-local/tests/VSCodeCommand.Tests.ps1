#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
}
Describe 'VS Code system command resolution and native output' {
    It 'resolves only the existing machine command' {
        Mock Test-Path { $true } -ParameterFilter { $PathType -eq 'Leaf' }
        Get-JumpCodeSystemCommand | Should -Be (Join-Path $env:ProgramFiles 'Microsoft VS Code/bin/code.cmd')
        Should -Invoke Test-Path -Times 1 -ParameterFilter { $LiteralPath -eq (Join-Path $env:ProgramFiles 'Microsoft VS Code/bin/code.cmd') -and $PathType -eq 'Leaf' }
    }
    It 'fails closed when the machine command is absent' {
        Mock Test-Path { $false }
        { Get-JumpCodeSystemCommand } | Should -Throw '*system command is unavailable*'
    }
    It 'captures real native output without returning installer strings' {
        $script:fakeCode = Join-Path $TestDrive 'native-code.cmd'
        Set-Content $script:fakeCode '@echo off', 'echo Extension installed successfully', 'exit /b 0'
        Mock Get-JumpCodeSystemCommand { $script:fakeCode }
        @(Invoke-JumpCodeCommand -Arguments @('--list-extensions')) | Should -Contain 'Extension installed successfully'
        @(Invoke-Code -Id 'example.extension' -Version '1.2.3' -Directory $TestDrive).Count | Should -Be 0
    }
    It 'throws on a real failing native exit even with plausible output' {
        $script:fakeCode = Join-Path $TestDrive 'failed-code.cmd'
        Set-Content $script:fakeCode '@echo off', 'echo example.extension@1.2.3', 'exit /b 7'
        Mock Get-JumpCodeSystemCommand { $script:fakeCode }
        { Invoke-Code -Id 'example.extension' -Version '1.2.3' -Directory $TestDrive } | Should -Throw '*exit code 7*'
    }
}
