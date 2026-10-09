#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Native command mock sets the automatic exit code consumed by the wrapper.')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
}
Describe 'VS Code default machine extension inventory' {
    BeforeEach {
        Mock Invoke-JumpCodeCommand { 'example.extension@1.2.3' }
    }
    It 'rejects shared files when the machine default is absent' {
        Mock Get-JumpMachineEnvironment { $null }
        Get-VSCodeExtensionVersion -Id 'example.extension' -Directory $TestDrive | Should -BeNullOrEmpty
        Should -Invoke Invoke-JumpCodeCommand -Times 0
    }
    It 'rejects a different machine default' {
        Mock Get-JumpMachineEnvironment { Join-Path $TestDrive 'other' }
        Get-VSCodeExtensionVersion -Id 'example.extension' -Directory $TestDrive | Should -BeNullOrEmpty
        Should -Invoke Invoke-JumpCodeCommand -Times 0
    }
    It 'accepts matching machine default and exact version inventory' {
        Mock Get-JumpMachineEnvironment { $TestDrive + '\' }
        Get-VSCodeExtensionVersion -Id 'example.extension' -Directory $TestDrive | Should -Be '1.2.3'
        Should -Invoke Get-JumpMachineEnvironment -Times 1 -ParameterFilter { $Name -eq 'VSCODE_EXTENSIONS' }
        Should -Invoke Invoke-JumpCodeCommand -Times 1 -ParameterFilter { $Arguments -contains '--extensions-dir' -and $Arguments -contains $TestDrive }
    }
    It 'rejects output from a failed extension listing' {
        Mock Get-JumpMachineEnvironment { $TestDrive }
        Mock Invoke-JumpCodeCommand { throw 'Listing failed.' }
        Get-VSCodeExtensionVersion -Id 'example.extension' -Directory $TestDrive | Should -BeNullOrEmpty
    }
}
