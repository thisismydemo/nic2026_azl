#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Native command exit-code mock sets the automatic global exit code consumed by the wrapper.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
}
Describe 'WinGet machine inventory' {
    It 'queries exact id/source in machine scope and parses the returned version' {
        Mock winget { $global:LASTEXITCODE = 0; 'Example  Test.Package  1.2.3  winget' }
        Get-InstalledWingetVersion -Id 'Test.Package' -Source 'winget' | Should -Be '1.2.3'
        Should -Invoke winget -Times 1 -ParameterFilter {
            $args[0] -eq 'list' -and $args -contains '--exact' -and $args -contains '--disable-interactivity' -and
            $args[([array]::IndexOf($args, '--scope') + 1)] -eq 'machine' -and
            $args[([array]::IndexOf($args, '--id') + 1)] -eq 'Test.Package' -and
            $args[([array]::IndexOf($args, '--source') + 1)] -eq 'winget'
        }
    }
    It 'does not accept a user-only package when machine inventory is empty' {
        Mock winget {
            $global:LASTEXITCODE = 0
            if ($args -notcontains '--scope' -or $args[([array]::IndexOf($args, '--scope') + 1)] -ne 'machine') { 'Example  Test.Package  1.2.3  winget' }
        }
        Get-InstalledWingetVersion -Id 'Test.Package' -Source 'winget' | Should -BeNullOrEmpty
    }
    It 'does not accept output from an unsuccessful inventory command' {
        Mock winget { $global:LASTEXITCODE = 1; 'Example  Test.Package  1.2.3  winget' }
        Get-InstalledWingetVersion -Id 'Test.Package' -Source 'winget' | Should -BeNullOrEmpty
    }
}
