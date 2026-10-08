#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
    $script:layout = @{ Directory = (Join-Path $TestDrive 'Machine/Bicep'); Binary = (Join-Path $TestDrive 'Machine/Bicep/bicep.exe') }
    $script:spec = @{ Version = '1.2.3'; Binary = @{ DownloadUrl = 'https://example.invalid/bicep.exe'; Sha256 = ('A' * 64); Publisher = 'CN=Example' } }
}
Describe 'Bicep machine scope inventory' {
    BeforeEach {
        Mock Get-JumpBicepLayout { [pscustomobject]$script:layout }
        Mock Test-Path { $false }
        Mock Get-JumpMachineEnvironment { if ($Name -eq 'Path') { $script:layout.Directory } else { 'true' } }
        Mock Get-JumpBicepBinaryVersion { '1.2.3' }
    }
    It 'requires the exact explicit machine binary' {
        Get-InstalledAzBicepVersion $script:spec | Should -Be '1.2.3'
        Should -Invoke Get-JumpBicepBinaryVersion -Times 1 -ParameterFilter { $Path -eq $script:layout.Binary }
    }
    It 'does not count a version when the machine PATH is incomplete' {
        Mock Get-JumpMachineEnvironment { if ($Name -eq 'Path') { 'C:\Example' } else { 'true' } }
        Get-InstalledAzBicepVersion $script:spec | Should -BeNullOrEmpty
        Should -Invoke Get-JumpBicepBinaryVersion -Times 0
    }
    It 'does not count a version without machine CLI selection' {
        Mock Get-JumpMachineEnvironment { if ($Name -eq 'Path') { $script:layout.Directory } else { 'false' } }
        Get-InstalledAzBicepVersion $script:spec | Should -BeNullOrEmpty
    }
    It 'rejects a target reparse point before reading a binary' {
        Mock Test-Path { $true }
        Mock Get-Item { @{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        Get-InstalledAzBicepVersion $script:spec | Should -BeNullOrEmpty
        Should -Invoke Get-JumpBicepBinaryVersion -Times 0
    }
    It 'does not treat a user-profile CLI-managed version as machine inventory' {
        Mock Get-JumpBicepBinaryVersion { $null }
        Get-InstalledAzBicepVersion $script:spec | Should -BeNullOrEmpty
        Should -Invoke Get-JumpBicepBinaryVersion -Times 1 -ParameterFilter { $Path -eq $script:layout.Binary }
    }
}
Describe 'Bicep preflight' {
    BeforeEach {
        Mock Get-JumpBicepLayout { [pscustomobject]$script:layout }
        Mock Test-Path { $false }
        Mock Invoke-WebRequest {}
        Mock Get-JumpBicepBinaryVersion { '1.2.3' }
        Mock New-Item {}
        Mock Set-Acl {}
        Mock Copy-Item {}
        Mock Set-JumpBicepEnvironment {}
    }
    It 'rejects an invalid pin before downloading or changing machine state' {
        $bad = @{ Version = '1.2.3'; Binary = @{ DownloadUrl = 'http://example.invalid/bicep.exe'; Sha256 = 'bad' } }
        { Invoke-JumpBicepSetup $bad } | Should -Throw '*HTTPS*'
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Set-JumpBicepEnvironment -Times 0
    }
    It 'does not create a target or change settings when artifact validation fails' {
        Mock Get-JumpBicepBinaryVersion { $null }
        { Invoke-JumpBicepSetup $script:spec } | Should -Throw '*pinned*'
        Should -Invoke New-Item -Times 0
        Should -Invoke Copy-Item -Times 0
        Should -Invoke Set-JumpBicepEnvironment -Times 0
    }
    It 'does not update CLI selection when the copied machine binary fails verification' {
        Mock Get-JumpBicepBinaryVersion { $null } -ParameterFilter { $Path -eq $script:layout.Binary }
        { Invoke-JumpBicepSetup $script:spec } | Should -Throw '*Machine Bicep*'
        Should -Invoke Set-JumpBicepEnvironment -Times 0
    }
    It 'configures machine selection only after both artifact and target checks pass' {
        Invoke-JumpBicepSetup $script:spec
        Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Destination -eq $script:layout.Binary }
        Should -Invoke Set-JumpBicepEnvironment -Times 1 -ParameterFilter { $Directory -eq $script:layout.Directory }
        Should -Invoke Set-Acl -Times 2
        Should -Invoke Set-Acl -Times 1 -ParameterFilter {
            $LiteralPath -eq $script:layout.Binary -and $AclObject.AreAccessRulesProtected -and
            @($AclObject.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object {
                    $_.IdentityReference.Value -eq 'S-1-5-32-545' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)
                }).Count -eq 0
        }
    }
}

Describe 'Bicep plan boundaries' {
    BeforeEach {
        Mock Get-JumpConfiguration { @{ Tools = @{ bicep = $script:spec } } }
        Mock Get-InstalledAzBicepVersion { $null }
        Mock Test-JumpElevated { $true }
        Mock Invoke-JumpBicepSetup { throw 'No mutation expected' }
        Mock Invoke-WebRequest { throw 'No download expected' }
    }
    It '<Case> does not download or call the machine installer' -ForEach @(
        @{ Case = 'Default plan'; Execute = $false }, @{ Case = 'Execute with WhatIf'; Execute = $true }
    ) {
        $result = @(Invoke-JumpTools -Only bicep -Execute:$Execute -WhatIf:$Execute -PassThru)
        $result[0].Result | Should -Be 'Planned'
        Should -Invoke Invoke-JumpBicepSetup -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }
}
