#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
    function Get-WinGetPackage { [CmdletBinding()] param($Id, $Source, $MatchOption) }
    function Install-WinGetPackage { [CmdletBinding(SupportsShouldProcess)] param($Id, $Source, $Version, $Scope, $Mode, $MatchOption, $Override) }
    function New-TestCatalogPackage {
        $package = [pscustomobject]@{ Id = 'Test.Package'; Source = 'winget'; InstalledVersion = '1.2.3'; Metadata = [pscustomobject]@{ ProductCodes = @('Test.Product'); PackageFamilyNames = @() } }
        $package | Add-Member -MemberType ScriptMethod -Name GetPackageVersionInfo -Value { param($Version) if ($Version -cne $this.InstalledVersion) { throw 'Wrong metadata version' }; return $this.Metadata }
        return $package
    }
}
Describe 'SYSTEM machine inventory uses supported client and separate registration evidence' {
    BeforeEach {
        $script:package = New-TestCatalogPackage
        Mock Test-JumpSystemContext { $true }
        Mock Import-JumpPackageClient {}
        Mock Get-WinGetPackage { $script:package }
        Mock Get-JumpMachineUninstallEntry { @() }
        Mock Get-AppxProvisionedPackage { @() }
    }
    It 'accepts exact catalog product code and version in HKLM' {
        Mock Get-JumpMachineUninstallEntry { [pscustomobject]@{ PSChildName = 'Test.Product'; DisplayVersion = '1.2.3' } }
        Get-InstalledWingetVersion -Id Test.Package -Source winget -ClientVersion '1.2.3' | Should -Be '1.2.3'
        Should -Invoke Get-WinGetPackage -Times 1 -ParameterFilter { $Id -ceq 'Test.Package' -and $Source -ceq 'winget' -and $MatchOption -ceq 'Equals' }
    }
    It 'does not accept a catalog version without machine registration' {
        Get-InstalledWingetVersion -Id Test.Package -Source winget | Should -BeNullOrEmpty
    }
    It 'does not accept a different registry version' {
        Mock Get-JumpMachineUninstallEntry { [pscustomobject]@{ PSChildName = 'Test.Product'; DisplayVersion = '1.2.4' } }
        Get-InstalledWingetVersion -Id Test.Package -Source winget | Should -BeNullOrEmpty
    }
    It 'does not turn failed catalog reads into package absence' {
        Mock Get-WinGetPackage { throw 'Catalog read denied' }
        { Get-InstalledWingetVersion -Id Test.Package -Source winget } | Should -Throw '*Catalog read denied*'
    }
    It 'rejects ambiguous identities' {
        Mock Get-WinGetPackage { $script:package; $script:package }
        { Get-InstalledWingetVersion -Id Test.Package -Source winget } | Should -Throw '*ambiguous*'
    }
    It 'rejects a different source' {
        $script:package.Source = 'other'
        { Get-InstalledWingetVersion -Id Test.Package -Source winget } | Should -Throw '*requested ID/source*'
    }
    It 'accepts exact machine MSIX provisioning but not user registration alone' {
        $script:package.Metadata.PackageFamilyNames = @('Test.App_publisher')
        Get-InstalledWingetVersion -Id Test.Package -Source winget | Should -BeNullOrEmpty
        Mock Get-AppxProvisionedPackage { [pscustomobject]@{ PackageName = 'Test.App_1.2.3_x64__publisher' } }
        Get-InstalledWingetVersion -Id Test.Package -Source winget | Should -Be '1.2.3'
    }
    It 'preserves registry inventory failures' {
        Mock Get-JumpMachineUninstallEntry { throw 'Registry read denied' }
        { Get-InstalledWingetVersion -Id Test.Package -Source winget } | Should -Throw '*Registry read denied*'
    }
}
Describe 'SYSTEM installation preserves pinned identity, machine scope and actual outcomes' {
    BeforeEach {
        Mock Test-JumpSystemContext { $true }
        Mock Import-JumpPackageClient {}
        Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'Ok'; RebootRequired = $false } }
        $script:arguments = @('install', '--id', 'Test.Package', '--source', 'winget', '--version', '1.2.3', '--scope', 'machine', '--exact', '--silent')
    }
    It 'passes exact ID/source/version and System scope to the supported API' {
        Invoke-Winget -Arguments $script:arguments -ClientVersion '1.2.3' | Out-Null
        Should -Invoke Install-WinGetPackage -Times 1 -ParameterFilter { $Id -ceq 'Test.Package' -and $Source -ceq 'winget' -and $Version -ceq '1.2.3' -and $Scope -ceq 'System' -and $Mode -ceq 'Silent' -and $MatchOption -ceq 'Equals' }
        Should -Invoke Import-JumpPackageClient -Times 1 -ParameterFilter { $ClientVersion -ceq '1.2.3' }
    }
    It 'rejects user scope before installing' {
        $script:arguments[8] = 'user'
        { Invoke-Winget -Arguments $script:arguments } | Should -Throw '*machine scope*'
        Should -Invoke Install-WinGetPackage -Times 0
    }
    It 'rejects hash overrides before installing' {
        { Invoke-Winget -Arguments ($script:arguments + '--ignore-security-hash') } | Should -Throw '*Unsupported*'
        Should -Invoke Install-WinGetPackage -Times 0
    }
    It 'rejects missing pins before installing' {
        { Invoke-Winget -Arguments @('install', '--id', 'Test.Package') } | Should -Throw '*Missing pinned*'
        Should -Invoke Install-WinGetPackage -Times 0
    }
    It 'does not report failed installer results as successful' {
        Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'InstallError'; RebootRequired = $false } }
        { Invoke-Winget -Arguments $script:arguments } | Should -Throw '*successful result*'
    }
    It 'retains a successful result requiring reboot' {
        Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'Ok'; RebootRequired = $true } }
        (Invoke-Winget -Arguments $script:arguments).RebootRequired | Should -BeTrue
    }
    It 'retains reboot evidence even when the tool installation fails' {
        Mock Get-JumpConfiguration { @{ Tools = @{ demo = @{ Version = '1.2.3'; Packages = @(@{ Id = 'Test.Package'; Version = '1.2.3'; Source = 'winget' }) } } } }
        Mock Test-JumpElevated { $true }
        Mock Get-WinGetPackage { @() }
        Mock Install-WinGetPackage { [pscustomobject]@{ Status = 'InstallError'; RebootRequired = $true } }
        $rows = @(Invoke-JumpTools -Only demo -Execute -PassThru -Confirm:$false)
        $rows.Count | Should -Be 1
        $rows[0].Result | Should -Be 'Failed'
        $rows[0].Reboot | Should -BeTrue
    }
}
