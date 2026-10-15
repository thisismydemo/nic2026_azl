#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
# Pester 5 — pre-Deploy gate (ClusterDeploy.Common.ps1 + Test-ClusterDeployArcNameGate.ps1): refuses the Deploy pass when
# the Arc machines are named by device ID (simplified machine provisioning) and the MocArb package's DeployVmoArcExtension
# resolves the Arc machine from $env:COMPUTERNAME. Package texts are synthetic; no node is contacted.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a synthetic test credential is converted.')]
param()

BeforeAll {
    $script:solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $script:solutionRoot 'scripts\ClusterDeploy.Common.ps1')
    $script:gateScript = Join-Path $script:solutionRoot 'scripts\Test-ClusterDeployArcNameGate.ps1'
    # The CI runner has no Posh-SSH: Pester can only mock commands that exist, so the absent ones get inert stubs.
    foreach ($cmd in 'New-SSHSession', 'Remove-SSHSession', 'Invoke-SSHCommand', 'Add-SSHTrustedHost', 'New-SSHMemoryTrustedHostStore') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Set-Item -Path "Function:\global:$cmd" -Value { throw "$cmd stub: Posh-SSH is not installed here" } }
    }

    $script:buggy = @'
function Get-Helper { $env:COMPUTERNAME }
function DeployVmoArcExtension {
    param($Context)
    $machine = $env:COMPUTERNAME
    $id = "/subscriptions/$($Context.Sub)/resourceGroups/$($Context.Rg)/providers/Microsoft.HybridCompute/machines/$machine"
    return $id
}
'@
    $script:fixed = @'
function DeployVmoArcExtension {
    param($Context)
    $machine = $Context.ArcMachineName
    return $machine
}
'@
    $script:other = @'
function Install-Something { $env:COMPUTERNAME }
'@
    $script:classMethod = @'
class VmoDeployer {
    [string] DeployVmoArcExtension() { return $env:computername }
}
'@
    $script:newInputs = {
        param([hashtable]$ArcNames = @{})
        [pscustomobject]@{
            nodes             = @([pscustomobject]@{ name = 'node-01'; management_ip = '192.0.2.11' }, [pscustomobject]@{ name = 'node-02'; management_ip = '192.0.2.12' })
            arc_machine_names = [pscustomobject]$ArcNames
        }
    }
    $script:deviceIds = @{ 'node-01' = '00000000-0000-0000-0000-000000000000-1'; 'node-02' = '00000000-0000-0000-0000-000000000000-2' }
}

Describe 'MocArb package analysis (Test-ClusterDeployMocArbArcNameBug)' {
    It 'finds $env:COMPUTERNAME inside DeployVmoArcExtension and reports its line' {
        $r = Test-ClusterDeployMocArbArcNameBug -Content $script:buggy -Path 'MocArb.psm1'
        $r.FunctionFound | Should -BeTrue
        $r.UsesComputerName | Should -BeTrue
        $r.Lines | Should -Be @(4)
    }
    It 'reports a DeployVmoArcExtension that does not read $env:COMPUTERNAME' {
        $r = Test-ClusterDeployMocArbArcNameBug -Content $script:fixed
        $r.FunctionFound | Should -BeTrue
        $r.UsesComputerName | Should -BeFalse
    }
    It 'ignores $env:COMPUTERNAME in other functions' {
        $r = Test-ClusterDeployMocArbArcNameBug -Content $script:other
        $r.FunctionFound | Should -BeFalse
        $r.UsesComputerName | Should -BeFalse
    }
    It 'also reads a class method of that name, case-insensitively' {
        $r = Test-ClusterDeployMocArbArcNameBug -Content $script:classMethod
        $r.FunctionFound | Should -BeTrue
        $r.UsesComputerName | Should -BeTrue
    }
}

Describe 'Gate decision (Get-ClusterDeployArcNameGateResult / Assert-ClusterDeployArcNameGate)' {
    BeforeAll {
        $script:bugFinding = Test-ClusterDeployMocArbArcNameBug -Content $script:buggy -Path 'C:\NugetStore\Example.MocArb\MocArb.psm1'
        $script:fixedFinding = Test-ClusterDeployMocArbArcNameBug -Content $script:fixed -Path 'C:\NugetStore\Example.MocArb\MocArb.psm1'
    }
    It 'passes when every Arc machine carries its host name, even with the lookup present' {
        $g = Get-ClusterDeployArcNameGateResult -Inputs (& $script:newInputs) -Finding $script:bugFinding
        $g.Result | Should -Be 'Pass'
        $g.Reason | Should -Be 'HostNames'
    }
    It 'refuses device-ID Arc names with the lookup present and names the nodes and the file' {
        $inputs = & $script:newInputs $script:deviceIds
        $g = Get-ClusterDeployArcNameGateResult -Inputs $inputs -Finding $script:bugFinding -SeedNode 'node-01'
        $g.Result | Should -Be 'Refuse'
        $g.Reason | Should -Be 'BugPresent'
        $g.Message | Should -Match 'Deploy refused'
        $g.Message | Should -Match 'node-01 -> 00000000-0000-0000-0000-000000000000-1'
        $g.Message | Should -Match 'MocArb\.psm1 line 4'
        { Assert-ClusterDeployArcNameGate -Inputs $inputs -Finding $script:bugFinding } | Should -Throw '*Deploy refused*COMPUTERNAME*'
    }
    It 'passes device-ID Arc names when the function does not read $env:COMPUTERNAME' {
        $g = Get-ClusterDeployArcNameGateResult -Inputs (& $script:newInputs $script:deviceIds) -Finding $script:fixedFinding
        $g.Result | Should -Be 'Pass'
        $g.Reason | Should -Be 'LookupAbsent'
    }
    It 'refuses device-ID Arc names when the package cannot be found, unless -AcceptUnverified' {
        $inputs = & $script:newInputs $script:deviceIds
        $g = Get-ClusterDeployArcNameGateResult -Inputs $inputs -Finding @() -SearchedRoot 'C:\NugetStore'
        $g.Result | Should -Be 'Refuse'
        $g.Reason | Should -Be 'Unverified'
        $g.Message | Should -Match 'C:\\NugetStore'
        (Get-ClusterDeployArcNameGateResult -Inputs $inputs -Finding @() -AcceptUnverified).Reason | Should -Be 'AcceptedUnverified'
    }
    It 'never lets -AcceptUnverified pass a package with the lookup' {
        { Assert-ClusterDeployArcNameGate -Inputs (& $script:newInputs $script:deviceIds) -Finding $script:bugFinding -AcceptUnverified } | Should -Throw '*Deploy refused*'
    }
    It 'treats an Arc name equal to the host name (any case) as a host name' {
        @(Get-ClusterDeployDeviceIdArcName -Inputs (& $script:newInputs @{ 'node-01' = 'NODE-01' })).Count | Should -Be 0
        @(Get-ClusterDeployDeviceIdArcName -Inputs (& $script:newInputs @{ 'node-02' = '00000000-0000-0000-0000-000000000000-2' })).Node | Should -Be 'node-02'
    }
}

Describe 'Test-ClusterDeployArcNameGate.ps1' {
    BeforeAll {
        $script:writeInputs = {
            param([hashtable]$ArcNames)
            $file = Join-Path $TestDrive "inputs-$([guid]::NewGuid().ToString('N')).json"
            [ordered]@{
                subscription_id = '00000000-0000-0000-0000-000000000000'; cluster_name = 'clus-example'; kv_azl_name = 'kv-example'
                witness = @{ type = 'cloud' }; names = @{ rg_azl = 'rg-example' }
                identity = @{ local_admin_username_secret = 'keyvault://kv-example/admin-user'; local_admin_password_secret = 'keyvault://kv-example/admin-password' }
                nodes = @(@{ name = 'node-01'; management_ip = '192.0.2.11' }, @{ name = 'node-02'; management_ip = '192.0.2.12' })
                arc_machine_names = $ArcNames
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
            $file
        }
        $script:pkg = Join-Path $TestDrive 'MocArb.psm1'
        Set-Content -LiteralPath $script:pkg -Value $script:buggy
        $script:pkgFixed = Join-Path $TestDrive 'MocArbFixed.psm1'
        Set-Content -LiteralPath $script:pkgFixed -Value $script:fixed
    }
    BeforeEach {
        Mock New-SSHSession { throw 'no node may be contacted in this test' }
        Mock New-PSSession { throw 'no node may be contacted in this test' }
        Mock Invoke-Command { throw 'no node may be contacted in this test' }
        Mock Add-SSHTrustedHost { throw 'the persistent trusted-host store must never be used' } -ParameterFilter { $null -eq $TrustedHostStore }
        $script:mockSshProbe = {
            Mock Import-Module {} -ParameterFilter { $Name -eq 'Posh-SSH' }
            Mock New-SSHSession { [pscustomobject]@{ SessionId = 7 } }
            Mock Remove-SSHSession {}
            Mock Invoke-SSHCommand {
                $content = "function DeployVmoArcExtension {`n    `$machine = `$env:COMPUTERNAME`n    `$machine`n}"
                $json = ConvertTo-Json -InputObject @([pscustomobject]@{ Path = 'C:\NugetStore\Example.MocArb\MocArb.psm1'; Content = $content }) -Depth 3 -Compress
                [pscustomobject]@{ ExitStatus = 0; Output = @([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))); Error = @() }
            }
        }
    }

    It 'throws the refusal for copied package files with the lookup and device-ID names' {
        $file = & $script:writeInputs $script:deviceIds
        { & $script:gateScript -InputFile $file -PackageFile $script:pkg -InformationAction SilentlyContinue } | Should -Throw '*Deploy refused*'
    }
    It 'returns the refusal with -PassThru' {
        $g = & $script:gateScript -InputFile (& $script:writeInputs $script:deviceIds) -PackageFile $script:pkg -PassThru -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $g.Result | Should -Be 'Refuse'
        $g.SeedNode | Should -Be 'node-01'
    }
    It 'passes a fixed package' {
        $g = & $script:gateScript -InputFile (& $script:writeInputs $script:deviceIds) -PackageFile $script:pkgFixed -InformationAction SilentlyContinue
        $g.Reason | Should -Be 'LookupAbsent'
    }
    It 'does not contact the node when every Arc machine carries its host name' {
        $g = & $script:gateScript -InputFile (& $script:writeInputs @{}) -InformationAction SilentlyContinue
        $g.Result | Should -Be 'Pass'
        Should -Invoke New-SSHSession -Times 0 -Exactly
        Should -Invoke New-PSSession -Times 0 -Exactly
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }
    It 'reads the seed node over SSH read-only and decides from the returned files' {
        . $script:mockSshProbe
        # Throwaway fixture key (ssh-keygen -lf: SHA256:9wFyHWkJdS3L+7pM+1PjRdiI7rK2zZy260XQTCqNs10).
        Mock Invoke-Command { 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMMYi6yVbGDhRYTnB1mc1130i0jGAQVL6Qwjs7w5EiH7 fixture' } -ParameterFilter { $ComputerName -eq '192.0.2.11' -and $Authentication -eq 'Negotiate' }
        $cred = [pscredential]::new('admin-example', (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force))
        $g = & $script:gateScript -InputFile (& $script:writeInputs $script:deviceIds) -Credential $cred -PassThru -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $g.Reason | Should -Be 'BugPresent'
        # The seed's host key, read over WinRM, is pinned in memory: -TrustedHostStore -ErrorOnUntrusted, never -AcceptKey.
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $ComputerName -eq '192.0.2.11' -and $Credential.UserName -eq 'admin-example' }
        Should -Invoke New-SSHSession -Times 1 -Exactly -ParameterFilter {
            $ComputerName -eq '192.0.2.11' -and $ErrorOnUntrusted -and -not $AcceptKey -and
            @(Get-SSHTrustedHost -HostName '192.0.2.11' -TrustedHostStore $TrustedHostStore).Fingerprint -contains '9wFyHWkJdS3L+7pM+1PjRdiI7rK2zZy260XQTCqNs10'
        }
        Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
            $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($Command -split ' ')[-1]))
            $decoded -match 'DeployVmoArcExtension' -and $decoded -match '\*MocArb\*' -and $decoded -notmatch 'Remove-Item|Set-Content|Invoke-Expression'
        }
        Should -Invoke Remove-SSHSession -Times 1 -Exactly
    }
    It 'falls back to -AcceptKey when WinRM cannot provide the seed host key' {
        . $script:mockSshProbe
        $cred = [pscredential]::new('admin-example', (ConvertTo-SecureString 'Example-Not-A-Secret-1' -AsPlainText -Force))
        $g = & $script:gateScript -InputFile (& $script:writeInputs $script:deviceIds) -Credential $cred -PassThru -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $g.Reason | Should -Be 'BugPresent'
        Should -Invoke New-SSHSession -Times 1 -Exactly -ParameterFilter { $ComputerName -eq '192.0.2.11' -and $AcceptKey -and $null -eq $TrustedHostStore }
    }
}
