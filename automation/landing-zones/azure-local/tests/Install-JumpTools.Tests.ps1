#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for scripts/Install-JumpTools.ps1 and scripts/jump-tools.versions.psd1.
# Nothing here installs anything, needs administrator rights or reaches the network: every external command is mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mock bodies run outside the test file scope; the fake machine state has to live in global variables.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that only register mocks.')]
param()

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts'
    . (Join-Path $script:ScriptsDir 'Install-JumpTools.ps1')
    $script:RealVersions = Join-Path $script:ScriptsDir 'jump-tools.versions.psd1'

    # A small versions file with fake versions, so these tests do not depend on the real pins.
    $script:TestVersions = Join-Path $TestDrive 'test.versions.psd1'
    Set-Content -LiteralPath $script:TestVersions -Value @'
@{
    Tools = @{
        git = @{ Version = '1.0.0'; Packages = @(@{ Id = 'Test.Git'; Version = '1.0.0'; Source = 'winget' }) }
        terraform = @{ Version = '2.0.0'; Packages = @(@{ Id = 'Test.Terraform'; Version = '2.0.0'; Source = 'winget' }) }
        vscode = @{
            Version = '3.0.0'
            Packages = @(@{ Id = 'Test.Code'; Version = '3.0.0'; Source = 'winget'; Override = '/VERYSILENT /MERGETASKS=!runcode' })
            Extensions = @{ 'pub.one' = '9.9.9' }
        }
        'az-powershell' = @{ Version = '4.0.0'; Modules = @{ Az = '4.0.0'; 'Az.KeyVault' = '4.1.0' } }
        'azure-cli' = @{ Version = '5.0.0'; Packages = @(@{ Id = 'Test.AzCli'; Version = '5.0.0'; Source = 'winget' }); Extensions = @{ ssh = '1.1.1' } }
        bicep = @{ Version = '1.2.3'; Binary = @{ DownloadUrl = 'https://example.invalid/bicep.exe'; Sha256 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; Publisher = 'CN=Example' } }
        'ansible-wsl' = @{ Version = '24.04'; Distribution = 'Ubuntu-Test'; AnsibleCoreVersion = '7.0.0' }
        rsat = @{ Version = 'N/A'; Features = @('RSAT-Test-A', 'RSAT-Test-B') }
        'windows-app' = @{ Version = '1.0.0'; Packages = @(@{ Id = 'STOREID'; Version = '1.0.0'; Source = 'msstore' }) }
        office = @{ Version = '16.0.20001.20002'; DownloadUrl = 'https://example.invalid/odt.exe'; DownloadSha256 = 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789' }
        unpinned = @{ Version = 'TODO-PIN'; Packages = @(@{ Id = 'Test.Unpinned'; Version = 'TODO-PIN'; Source = 'winget' }) }
    }
    AnsibleCollections = @{ 'ns.one' = '1.2.3' }
}
'@
    # One fake machine: the read mocks report what the change mocks have "installed", so the install-then-verify step is exercised.
    function Set-NothingInstalled {
        $global:JumpState = @{}
        $global:JumpCalls = 0
        Mock Get-InstalledWingetVersion { $global:JumpState["winget:$Id"] }
        Mock Get-InstalledPSResourceVersion { $global:JumpState["ps:$Name"] }
        Mock Get-InstalledAzExtensionVersion { $global:JumpState["azext:$Name"] }
        Mock Get-InstalledAzBicepVersion { $global:JumpState['bicep'] }
        Mock Get-VSCodeExtensionVersion { $global:JumpState["code:$Id"] }
        Mock Get-WindowsFeatureState { $v = $global:JumpState["feature:$Name"]; if ($v) { $v } else { 'Available' } }
        Mock Get-WslState { [bool]$global:JumpState["wsl:$Distribution"] }
        Mock Get-AnsibleState { $global:JumpState["ansible:$Component"] }
        Mock Get-OfficeBuild { $global:JumpState['office'] }
    }
    function Set-MutatorsMocked {
        Mock Invoke-Winget {
            $global:JumpCalls++
            $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
            $i = [array]::IndexOf($Arguments, '--version')
            $global:JumpState["winget:$id"] = if ($i -ge 0) { $Arguments[$i + 1] } else { 'present' }
        }
        Mock Install-PSResourcePinned { $global:JumpCalls++; $global:JumpState["ps:$Name"] = $Version }
        Mock Invoke-AzCli {
            if ($Arguments[0] -eq 'extension') { $global:JumpState["azext:$($Arguments[3])"] = $Arguments[5] }
            elseif ($Arguments[0] -eq 'bicep') { $global:JumpState['bicep'] = $Arguments[3] }
        }
        Mock Install-WindowsFeaturePinned { $global:JumpState["feature:$Name"] = 'Installed'; [pscustomobject]@{ Success = $true; RestartNeeded = 'No' } }
        Mock Invoke-Code { $global:JumpState["code:$Id"] = $Version }
        Mock Invoke-Wsl {
            if ($Arguments -contains '--install') { $global:JumpState["wsl:$($Arguments[([array]::IndexOf($Arguments, '-d') + 1)])"] = $true }
            elseif ($Arguments -contains 'pipx') { $global:JumpState['ansible:ansible-core'] = (($Arguments | Where-Object { $_ -like 'ansible-core==*' }) -replace '^ansible-core==', '') }
            elseif ($Arguments -contains 'ansible-galaxy') { $name, $ver = $Arguments[-1] -split ':'; $global:JumpState["ansible:$name"] = $ver }
        }
        Mock Set-MachineExtensionsDirectory {}
        Mock Invoke-OfficeSetup { $global:JumpState['office'] = $Build }
        Mock Set-WingetAutoUpdate {}
        Mock Invoke-JumpBicepSetup { $global:JumpState['bicep'] = $Spec.Version }
    }
}

Describe 'the real versions file' {
    It 'is valid data and gives every tool a Version' {
        $c = Import-PowerShellDataFile $script:RealVersions
        $c.Tools.Keys.Count | Should -BeGreaterThan 10
        foreach ($key in $c.Tools.Keys) {
            $c.Tools[$key].Contains('Version') | Should -BeTrue -Because "tool '$key' needs a Version"
            [string]$c.Tools[$key].Version | Should -Not -BeNullOrEmpty
        }
    }

    It 'has no unresolved TODO-PIN: every version is pinned' {
        $c = Import-PowerShellDataFile $script:RealVersions
        @(Get-PendingPins -Configuration $c) | Should -BeNullOrEmpty
    }

    It 'covers the tools the design lists (management-plane 1.8)' {
        $c = Import-PowerShellDataFile $script:RealVersions
        foreach ($key in 'powershell7', 'az-powershell', 'envchecker', 'graph', 'azure-cli', 'bicep', 'terraform', 'packer', 'ansible-wsl', 'git', 'vscode', 'office', 'rsat', 'local-identity', 'windows-app', 'drawio', 'azcopy', 'storage-explorer') {
            $c.Tools.Keys | Should -Contain $key
        }
        $c.Tools.vscode.Extensions.Keys.Count | Should -Be 9
        $c.Tools.office.DownloadSha256 | Should -Match '^[0-9A-Fa-f]{64}$'
        $c.Tools.office.DownloadUrl | Should -Match '^https://'
    }

    It 'does not define the tools that are excluded by design' {
        $text = (Get-Content -LiteralPath $script:RealVersions -Raw)
        foreach ($name in 'VPN', 'Admin Center', 'WindowsAdminCenter', 'RVTools') { $text | Should -Not -Match ([regex]::Escape($name)) }
    }

    It 'installs only machine-wide: no per-user package settings anywhere' {
        $text = (Get-Content -LiteralPath $script:RealVersions -Raw) + (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'Install-JumpTools.ps1') -Raw)
        $text | Should -Not -Match '--scope user'
        $text | Should -Not -Match '-Scope CurrentUser'
        (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'Install-JumpTools.ps1') -Raw) | Should -Match "'--scope', 'machine'"
        (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'Install-JumpTools.ps1') -Raw) | Should -Match '-Scope AllUsers'
    }
}

Describe 'the Office configuration' {
    It 'is pinned to the build, 64-bit, Current Channel, shared licensing, no updates, no UI' {
        $xml = New-OfficeConfigurationXml -Build '16.0.20430.20146'
        $xml.Configuration.Add.Version | Should -Be '16.0.20430.20146'
        $xml.Configuration.Add.OfficeClientEdition | Should -Be '64'
        $xml.Configuration.Add.Channel | Should -Be 'Current'
        $xml.Configuration.Add.Product.ID | Should -Be 'O365ProPlusRetail'
        $xml.Configuration.Property.Name | Should -Be 'SharedComputerLicensing'
        $xml.Configuration.Property.Value | Should -Be '1'
        $xml.Configuration.Updates.Enabled | Should -Be 'FALSE'
        $xml.Configuration.Display.Level | Should -Be 'None'
        $xml.Configuration.Display.AcceptEULA | Should -Be 'TRUE'
    }

    It 'keeps Word, Excel, PowerPoint, Outlook and OneNote and excludes the rest' {
        $excluded = @((New-OfficeConfigurationXml -Build '16.0.20001.20002').Configuration.Add.Product.ExcludeApp | ForEach-Object { $_.ID })
        foreach ($app in 'Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote') { $excluded | Should -Not -Contain $app }
        foreach ($app in 'Access', 'Publisher', 'Teams') { $excluded | Should -Contain $app }
    }

    It 'rejects a build that is not four-part' {
        { New-OfficeConfigurationXml -Build '2609' } | Should -Throw '*four-part*'
    }

    It 'refuses a non-https download URL and a missing or wrong SHA-256, before any download' {
        { Invoke-OfficeSetup -Build '16.0.20001.20002' -DownloadUrl 'http://example.invalid/odt.exe' -Sha256 ('A' * 64) } | Should -Throw '*https*'
        { Invoke-OfficeSetup -Build '16.0.20001.20002' -DownloadUrl 'https://example.invalid/odt.exe' -Sha256 'nothex' } | Should -Throw '*SHA-256*'
    }
}

Describe 'the additional versions file' {
    BeforeEach { Set-NothingInstalled; Set-MutatorsMocked }

    It 'adds tools and Ansible collections and replaces a tool of the same key' {
        $extra = Join-Path $TestDrive 'extra.versions.psd1'
        Set-Content -LiteralPath $extra -Value "@{ Tools = @{ git = @{ Version = '9.0.0'; Packages = @(@{ Id = 'Test.Git'; Version = '9.0.0'; Source = 'winget' }) }; extra = @{ Version = '1.0.0'; Packages = @(@{ Id = 'Test.Extra'; Version = '1.0.0'; Source = 'winget' }) } }; AnsibleCollections = @{ 'ns.two' = '2.0.0' } }"
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -AdditionalVersionsPath $extra -Only git, extra, ansible-wsl -PassThru -WarningAction SilentlyContinue)
        @($r.Tool) | Should -Contain 'extra'
        ($r | Where-Object Tool -eq 'git').Wanted | Should -Be '9.0.0'
    }

    It 'installs the added collections too' {
        Mock Test-JumpElevated { $true }
        Mock Get-WslState { $true }
        $extra = Join-Path $TestDrive 'extra2.versions.psd1'
        Set-Content -LiteralPath $extra -Value "@{ AnsibleCollections = @{ 'ns.two' = '2.0.0' } }"
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -AdditionalVersionsPath $extra -Only ansible-wsl -Execute -PassThru
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { $Arguments -contains 'ns.two:2.0.0' }
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { $Arguments -contains 'ns.one:1.2.3' }
    }
}
Describe 'planning without -Execute' {
    BeforeEach { Set-NothingInstalled; Set-MutatorsMocked }

    It 'makes no mutating call' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -PassThru -WarningAction SilentlyContinue
        foreach ($name in 'Invoke-Winget', 'Invoke-AzCli', 'Invoke-Wsl', 'Install-PSResourcePinned', 'Install-WindowsFeaturePinned', 'Invoke-Code', 'Set-MachineExtensionsDirectory', 'Invoke-OfficeSetup', 'Set-WingetAutoUpdate') {
            Should -Invoke $name -Times 0 -Because "$name changes the machine"
        }
    }

    It 'reports every tool with Wanted, Found, Action and Result' {
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -PassThru -WarningAction SilentlyContinue)
        $r.Count | Should -Be 1
        $r[0].Tool | Should -Be 'git'
        $r[0].Wanted | Should -Be '1.0.0'
        $r[0].Found | Should -Be 'Not found'
        $r[0].Action | Should -Be 'Install'
        $r[0].Result | Should -Be 'Planned'
    }

    It '-Only limits the plan and an unknown key is an error' {
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git, terraform -PassThru -WarningAction SilentlyContinue)
        @($r.Tool) | Should -Be @('git', 'terraform')
        { Invoke-JumpTools -VersionsPath $script:TestVersions -Only nope } | Should -Throw '*Unknown tool key*'
    }

    It '-SkipOffice leaves Office out' {
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git, office -SkipOffice -PassThru -WarningAction SilentlyContinue)
        @($r.Tool) | Should -Be @('git')
    }

    It 'warns about an unresolved pin only for a selected tool' {
        $w = @()
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -PassThru -WarningVariable w -WarningAction SilentlyContinue
        $w.Count | Should -Be 0
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only unpinned -PassThru -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'TODO-PIN|Unresolved pins'
    }
}

Describe 'execution preflight' {
    BeforeEach { Set-NothingInstalled; Set-MutatorsMocked }

    It 'refuses -Execute without elevation' {
        Mock Test-JumpElevated { $false }
        { Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -Execute } | Should -Throw '*elevated*'
        Should -Invoke Invoke-Winget -Times 0
    }

    It 'refuses -Execute for a selected tool that still has TODO-PIN, and names it' {
        Mock Test-JumpElevated { $true }
        { Invoke-JumpTools -VersionsPath $script:TestVersions -Only unpinned -Execute } | Should -Throw '*TODO-PIN*Test.Unpinned*'
        Should -Invoke Invoke-Winget -Times 0
    }

    It 'allows -Execute for tools without an unresolved pin even when another tool has one' {
        Mock Test-JumpElevated { $true }
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -Execute -PassThru)
        $r[0].Result | Should -Be 'Installed'
    }
}

Describe 'execution' {
    BeforeEach { Set-NothingInstalled; Set-MutatorsMocked; Mock Test-JumpElevated { $true } }

    It 'installs winget packages machine-wide, exact, silent, pinned, with the override when one is set' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only vscode -Execute -PassThru
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter {
            $Arguments[0] -eq 'install' -and $Arguments -contains '--exact' -and $Arguments -contains '--silent' -and
            $Arguments[([array]::IndexOf($Arguments, '--scope') + 1)] -eq 'machine' -and
            $Arguments[([array]::IndexOf($Arguments, '--version') + 1)] -eq '3.0.0' -and
            $Arguments[([array]::IndexOf($Arguments, '--override') + 1)] -like '/VERYSILENT*'
        }
        Should -Invoke Invoke-Code -Times 1 -ParameterFilter { $Id -eq 'pub.one' -and $Version -eq '9.9.9' }
        Should -Invoke Set-MachineExtensionsDirectory -Times 1
    }

    It 'passes the exact version even for a Store package' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only windows-app -Execute -PassThru
        Should -Invoke Invoke-Winget -Times 1 -ParameterFilter { $Arguments -contains '--version' -and $Arguments[([array]::IndexOf($Arguments, '--source') + 1)] -eq 'msstore' -and $Arguments -contains '--scope' }
    }

    It 'installs PowerShell modules for all users at the pinned versions, and az extensions at the pinned version' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only az-powershell, azure-cli -Execute -PassThru
        Should -Invoke Install-PSResourcePinned -Times 1 -ParameterFilter { $Name -eq 'Az' -and $Version -eq '4.0.0' }
        Should -Invoke Install-PSResourcePinned -Times 1 -ParameterFilter { $Name -eq 'Az.KeyVault' -and $Version -eq '4.1.0' }
        Should -Invoke Invoke-AzCli -Times 1 -ParameterFilter { $Arguments -contains 'extension' -and $Arguments -contains 'ssh' -and $Arguments -contains '1.1.1' -and $Arguments -contains '--system' }
    }

    It 'installs each missing Windows feature once' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only rsat -Execute -PassThru
        Should -Invoke Install-WindowsFeaturePinned -Times 1 -ParameterFilter { $Name -eq 'RSAT-Test-A' }
        Should -Invoke Install-WindowsFeaturePinned -Times 1 -ParameterFilter { $Name -eq 'RSAT-Test-B' }
    }

    It 'installs the pinned Bicep binary through the machine installer, then skips a correct rerun' {
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only bicep -Execute -PassThru)
        $r[0].Result | Should -Be 'Installed'
        Should -Invoke Invoke-JumpBicepSetup -Times 1 -ParameterFilter { $Spec.Version -eq '1.2.3' }
        Should -Invoke Invoke-AzCli -Times 0
        Should -Invoke Invoke-Winget -Times 0
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only bicep -Execute -PassThru)
        $r[0].Result | Should -Be 'AlreadyCorrect'
        Should -Invoke Invoke-JumpBicepSetup -Times 1
    }

    It 'reports RebootRequired after installing WSL and does not run the Ansible steps in the same pass' {
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only ansible-wsl -Execute -PassThru)
        $r[0].Result | Should -Be 'RebootRequired'
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { $Arguments -contains '--install' -and $Arguments -contains 'Ubuntu-Test' }
        Should -Invoke Invoke-Wsl -Times 0 -ParameterFilter { $Arguments -contains 'pipx' }
    }

    It 'installs the pinned Ansible core and collections once WSL is present (pipx is installed first)' {
        Mock Get-WslState { $true }
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only ansible-wsl -Execute -PassThru
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { ($Arguments -join ' ') -match 'apt-get install -y pipx' }
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { $Arguments -contains 'pipx' -and $Arguments -contains 'ansible-core==7.0.0' }
        Should -Invoke Invoke-Wsl -Times 1 -ParameterFilter { $Arguments -contains 'ns.one:1.2.3' }
    }

    It 'calls the Office installer with the pinned build, URL and hash' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only office -Execute -PassThru
        Should -Invoke Invoke-OfficeSetup -Times 1 -ParameterFilter { $Build -eq '16.0.20001.20002' -and $DownloadUrl -like 'https://*' -and $Sha256 -match '^[0-9A-F]{64}$' }
    }

    It 'marks a failing tool Failed and carries on with the next one' {
        Mock Invoke-Winget {
            if ($Arguments -contains 'Test.Git') { throw 'boom' }
            $global:JumpState["winget:$($Arguments[[array]::IndexOf($Arguments, '--id') + 1])"] = $Arguments[[array]::IndexOf($Arguments, '--version') + 1]
        }
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git, terraform -Execute -PassThru)
        ($r | Where-Object Tool -eq 'git').Result | Should -Be 'Failed'
        ($r | Where-Object Tool -eq 'terraform').Result | Should -Be 'Installed'
    }

    It 'verifies after installing: a different version landing is a failure, not a success' {
        Mock Invoke-Winget { $global:JumpState['winget:Test.Git'] = '0.0.1' }
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -Execute -PassThru)
        $r[0].Result | Should -Be 'Failed'
    }

    It 'keeps the reboot need visible when another component of the tool fails' {
        Mock Install-WindowsFeaturePinned {
            if ($Name -eq 'RSAT-Test-B') { throw 'feature failed' }
            $global:JumpState["feature:$Name"] = 'InstallPending'
            [pscustomobject]@{ Success = $true; RestartNeeded = 'Yes' }
        }
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only rsat -Execute -PassThru)
        $r[0].Result | Should -Be 'Failed'
        $r[0].Reboot | Should -BeTrue
    }

    It 'a feature waiting for a restart counts as installed and is not installed again' {
        $global:JumpState['feature:RSAT-Test-A'] = 'InstallPending'
        $global:JumpState['feature:RSAT-Test-B'] = 'InstallPending'
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only rsat -Execute -PassThru)
        $r[0].Result | Should -Be 'AlreadyCorrect'
        Should -Invoke Install-WindowsFeaturePinned -Times 0
    }
}

Describe 'idempotency' {
    BeforeEach { Set-NothingInstalled; Set-MutatorsMocked; Mock Test-JumpElevated { $true } }

    It 'skips a package that is already at the wanted version' {
        $global:JumpState['winget:Test.Git'] = '1.0.0'
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -Execute -PassThru)
        $r[0].Result | Should -Be 'AlreadyCorrect'
        $r[0].Action | Should -Be 'Skip'
        Should -Invoke Invoke-Winget -Times 0
        Should -Invoke Set-WingetAutoUpdate -Times 0
    }

    It 'replaces a package that is installed at a different version' {
        $global:JumpState['winget:Test.Git'] = '0.9.0'
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git -Execute -PassThru)
        $r[0].Result | Should -Be 'Installed'
        Should -Invoke Invoke-Winget -Times 1
        $global:JumpState['winget:Test.Git'] | Should -Be '1.0.0'
    }

    It 'repairs an arbitrary installed package version rather than accepting presence' {
        $global:JumpState['winget:STOREID'] = '7.7.7'
        (@(Invoke-JumpTools -VersionsPath $script:TestVersions -Only windows-app -Execute -PassThru))[0].Result | Should -Be 'Installed'
        $global:JumpState.Remove('winget:STOREID')
        (@(Invoke-JumpTools -VersionsPath $script:TestVersions -Only windows-app -PassThru))[0].Result | Should -Be 'Planned'
    }

    It 'installs only the missing components of a multi-component tool' {
        $global:JumpState['ps:Az'] = '4.0.0'
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only az-powershell -Execute -PassThru
        Should -Invoke Install-PSResourcePinned -Times 0 -ParameterFilter { $Name -eq 'Az' }
        Should -Invoke Install-PSResourcePinned -Times 1 -ParameterFilter { $Name -eq 'Az.KeyVault' }
    }

    It 'skips a Windows feature that is already installed' {
        $global:JumpState['feature:RSAT-Test-A'] = 'Installed'
        $global:JumpState['feature:RSAT-Test-B'] = 'Installed'
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only rsat -Execute -PassThru)
        $r[0].Result | Should -Be 'AlreadyCorrect'
        Should -Invoke Install-WindowsFeaturePinned -Times 0
    }

    It 'a second run after a successful install changes nothing' {
        $null = Invoke-JumpTools -VersionsPath $script:TestVersions -Only git, az-powershell, rsat, vscode -Execute -PassThru
        $global:JumpCalls | Should -BeGreaterThan 0
        $global:JumpCalls = 0
        $r = @(Invoke-JumpTools -VersionsPath $script:TestVersions -Only git, az-powershell, rsat, vscode -Execute -PassThru)
        @($r.Result | Select-Object -Unique) | Should -Be @('AlreadyCorrect')
        $global:JumpCalls | Should -Be 0 -Because 'a second run must not call winget or Install-PSResource'
    }
}
