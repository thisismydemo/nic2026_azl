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
        Mock Invoke-JumpAzCommand { throw 'Native call should not occur' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh') } | Should -Throw '*--system*'
        Should -Invoke Invoke-JumpAzCommand -Times 0
    }
    It 'refuses an unresolved machine directory before calling az' {
        Mock Get-JumpAzSystemExtensionDirectory { $null }
        Mock Invoke-JumpAzCommand { throw 'Native call should not occur' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh', '--system') } | Should -Throw '*trusted*'
        Should -Invoke Invoke-JumpAzCommand -Times 0
    }
    It 'restores the process system-directory override after a native failure' {
        $original = [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', 'Process')
        $authDirectory = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR', 'Process')
        Mock Get-JumpAzSystemExtensionDirectory { $script:SystemRoot }
        Mock Invoke-JumpAzCommand { throw 'Synthetic native failure' }
        { Invoke-AzCli @('extension', 'add', '--name', 'ssh', '--system') } | Should -Throw '*Synthetic*'
        [Environment]::GetEnvironmentVariable('AZURE_EXTENSION_SYS_DIR', 'Process') | Should -Be $original
        [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR', 'Process') | Should -Be $authDirectory
    }
    It 'does not invoke the CLI before its prerequisite exists' {
        Mock Get-JumpAzSystemExtensionDirectory { $null }
        Mock Invoke-JumpAzCommand { throw 'Should not be invoked' }
        Get-InstalledAzExtensionVersion -Name ssh | Should -BeNullOrEmpty
        Should -Invoke Invoke-JumpAzCommand -Times 0
    }
    It 'does not treat a failed CLI inventory as a missing extension' {
        Mock Get-JumpAzSystemExtensionDirectory { $script:SystemRoot }
        Mock Invoke-JumpAzCommand { throw 'Inventory denied' }
        { Get-InstalledAzExtensionVersion -Name ssh } | Should -Throw '*Inventory denied*'
    }
    It 'rejects malformed inventory JSON' {
        Mock Get-JumpAzSystemExtensionDirectory { $script:SystemRoot }
        Mock Invoke-JumpAzCommand { 'invalid JSON' }
        { Get-InstalledAzExtensionVersion -Name ssh } | Should -Throw
    }
    It 'accepts only the machine path in a successful inventory' {
        Mock Get-JumpAzSystemExtensionDirectory { $script:SystemRoot }
        Mock Invoke-JumpAzCommand { @(@{name='ssh';version='1.2.3';path=(Join-Path $script:SystemRoot 'ssh')}) | ConvertTo-Json -Compress }
        Get-InstalledAzExtensionVersion -Name ssh | Should -Be '1.2.3'
    }
    It 'finds a newly installed machine CLI when the process PATH is stale' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        Mock Test-Path { $LiteralPath -eq (Join-Path $env:ProgramFiles 'Microsoft SDKs/Azure/CLI2/wbin/az.cmd') }
        Get-JumpAzSystemCommand | Should -Be (Join-Path $env:ProgramFiles 'Microsoft SDKs/Azure/CLI2/wbin/az.cmd')
    }
}
