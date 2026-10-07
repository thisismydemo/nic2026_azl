#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Describe 'Repo scripts only use parameters the installed cmdlets have' {
    It 'finds no unknown named parameter' {
        $checker = Join-Path $PSScriptRoot '../../Test-CmdletParameters.ps1'
        $root = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
        $found = @(& $checker -Root $root)
        $found | Should -BeNullOrEmpty -Because ($found -join '; ')
    }
}
