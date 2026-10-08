#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
    $script:SystemRoot = Join-Path $env:ProgramFiles 'ExampleCLI/Lib/site-packages/azure-cli-extensions'
}
Describe 'Azure CLI extension scope' {
    It 'accepts an exact extension inside the system directory' {
        Test-JumpAzExtensionPath (Join-Path $script:SystemRoot 'ssh') 'ssh' $script:SystemRoot | Should -BeTrue
    }
    It 'rejects an equally versioned user-profile extension' {
        Test-JumpAzExtensionPath (Join-Path $env:USERPROFILE '.azure/cliextensions/ssh') 'ssh' $script:SystemRoot | Should -BeFalse
    }
    It 'rejects a similarly prefixed sibling directory' {
        Test-JumpAzExtensionPath ($script:SystemRoot + '-user/ssh') 'ssh' $script:SystemRoot | Should -BeFalse
    }
    It 'rejects path traversal in the extension name' {
        Test-JumpAzExtensionPath (Join-Path $script:SystemRoot '../ssh') '../ssh' $script:SystemRoot | Should -BeFalse
    }
    It 'requires a trusted machine CLI root' {
        Mock Get-Command { [pscustomobject]@{ Source = (Join-Path $env:USERPROFILE 'ExampleCLI/wbin/az.cmd') } } -ParameterFilter { $Name -eq 'az' }
        Get-JumpAzSystemExtensionDirectory | Should -BeNullOrEmpty
    }
    It 'derives the system directory from the trusted Windows CLI layout' {
        Mock Get-Command { [pscustomobject]@{ Source = (Join-Path $env:ProgramFiles 'ExampleCLI/wbin/az.cmd') } } -ParameterFilter { $Name -eq 'az' }
        Get-JumpAzSystemExtensionDirectory | Should -Be $script:SystemRoot
    }
    It 'refuses an extension mutation that omits system scope before calling az' {
        Mock az { throw 'Native call should not occur' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh') } | Should -Throw '*--system*'
        Should -Invoke az -Times 0
    }
    It 'refuses an unresolved machine directory before calling az' {
        Mock Get-JumpAzSystemExtensionDirectory { $null }
        Mock az { throw 'Native call should not occur' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh', '--system') } | Should -Throw '*trusted*'
        Should -Invoke az -Times 0
    }
    It 'restores the process system-directory override after a native failure' {
        $original = [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', 'Process')
        $authDirectory = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR', 'Process')
        Mock Get-JumpAzSystemExtensionDirectory { $script:SystemRoot }
        Mock az { throw 'Synthetic native failure' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh', '--system') } | Should -Throw '*Synthetic*'
        [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', 'Process') | Should -Be $original
        [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR', 'Process') | Should -Be $authDirectory
    }
}
