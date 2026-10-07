#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
<#
.SYNOPSIS
    Pester 5 tests for automation/demo/azure-local: fault preflight refusals, WhatIf defaults, -Execute paths with
    mocked remoting/Azure, Undo flows, readiness gate, Day-2 reset/restore, ASR start, dashboard hygiene.
.DESCRIPTION
    Run from the repo root:
        Import-Module Pester -RequiredVersion 5.9.1
        Invoke-Pester -Path automation\demo\azure-local\tests -Output Detailed
    Nothing here contacts Azure or a device: Get-DemoConfig, Get-DemoClusterHealth, Invoke-DemoRemote, the
    Az and ASR wrappers are all mocked. Addresses use documentation ranges only.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A throw-away test credential for the mocked wrappers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies invoked from another script file resolve $script: to that file (dynamic scoping); one global hashtable carries the mock state and is removed in AfterAll.')]
param()

BeforeAll {
    $global:NIC26Test = @{}
    $script:ScriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts')).Path
    $script:RegistryPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'day2-controls.yml')).Path
    Import-Module (Join-Path $script:ScriptsRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1') -Force
    $env:NIC26_DEMO_STATE_DIR = Join-Path $TestDrive 'state'
    $env:NIC26_ASSUME_PLATFORM = 'Windows'
    $env:NIC26_ASSUME_TRANSCRIPT = $null

    $global:NIC26Test.Config = @{
        org = 'iic'; token = 'nic26'; location_short = 'eus'; location = 'eastus'
        tenant_domain = 'contoso.com'; tenant_id = '00000000-0000-0000-0000-000000000000'
        subscriptions = @{ azure_local = '00000000-0000-0000-0000-000000000000' }
        owner_email = 'lab-owner@contoso.com'
        cluster_name = 'nic26-clus01'
        identity = @{ dns_zone = 'nic26.iic.local' }
        log_analytics_workspace_id = ''
        nodes = @(
            @{ name = 'nic26-01-n01'; management_ip = '192.0.2.11' },
            @{ name = 'nic26-01-n02'; management_ip = '192.0.2.12' }
        )
        intents = @(
            @{ name = 'Management'; adapters = @('NIC1', 'NIC2') },
            @{ name = 'Compute'; adapters = @('SLOT 3 Port 1', 'SLOT 6 Port 2') },
            @{ name = 'Storage'; adapters = @('SLOT 3 Port 2', 'SLOT 6 Port 1') }
        )
        secret_refs = @{}
    }
    $global:NIC26Test.TestCred = [pscredential]::new('ops-test', (ConvertTo-SecureString -String 'not-a-real-value' -AsPlainText -Force))

    function New-HealthyHealth {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object factory; changes no state.')]
        param()
        $disks = foreach ($n in @('nic26-01-n01', 'nic26-01-n02')) {
            for ($i = 1; $i -le 4; $i++) {
                [pscustomobject]@{ FriendlyName = "NVMe $n-$i"; SerialNumber = "S$($n.Substring(10))$i"; UniqueId = "U$i"; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; Usage = 'Auto-Select'; MediaType = 'SSD'; Node = $n }
            }
        }
        $intents = foreach ($n in @('nic26-01-n01', 'nic26-01-n02')) {
            foreach ($i in @('Management', 'Compute', 'Storage')) { [pscustomobject]@{ IntentName = $i; Host = $n; ConfigurationStatus = 'Success'; ProvisioningStatus = 'Completed' } }
        }
        return [pscustomobject]@{
            ClusterName   = 'nic26-clus01'
            Nodes         = @([pscustomobject]@{ Name = 'nic26-01-n01'; State = 'Up' }, [pscustomobject]@{ Name = 'nic26-01-n02'; State = 'Up' })
            Pool          = [pscustomobject]@{ FriendlyName = 'S2D on nic26-clus01'; HealthStatus = 'Healthy'; OperationalStatus = 'OK' }
            VirtualDisks  = @([pscustomobject]@{ FriendlyName = 'csv-nic26-m2-vmstore-01'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; ResiliencySettingName = 'Mirror' }, [pscustomobject]@{ FriendlyName = 'Infrastructure_1'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; ResiliencySettingName = 'Mirror' })
            PhysicalDisks = @($disks)
            StorageJobs   = @()
            Intents       = @($intents)
            Quorum        = [pscustomobject]@{ WitnessName = 'Cloud Witness'; WitnessState = 'Online' }
            RdmaAdapters  = @([pscustomobject]@{ Name = 'SLOT 3 Port 2'; Enabled = $true; Node = 'nic26-01-n01' }, [pscustomobject]@{ Name = 'SLOT 6 Port 1'; Enabled = $true; Node = 'nic26-01-n01' })
            Faults        = @()
            CollectedAt   = [DateTime]::UtcNow.ToString('o')
        }
    }
    function Clear-Locks { Get-ChildItem -LiteralPath (Get-DemoStateRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue | Remove-Item -Force }
    function Invoke-CaptureAll {
        param([scriptblock]$Script)
        $lines = & $Script *>&1 | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | Out-String } }
        return ($lines -join "`n")
    }
    function Initialize-DemoTestDefault {
        Clear-Locks
        $global:NIC26Test.Health = New-HealthyHealth
        Mock Get-DemoConfig { $global:NIC26Test.Config }
        Mock Get-DemoClusterHealth { $global:NIC26Test.Health }
        Mock Start-DemoSleep {}
    }
}

AfterAll {
    Remove-Variable -Name NIC26Test -Scope Global -ErrorAction SilentlyContinue
    $env:NIC26_DEMO_STATE_DIR = $null
    $env:NIC26_ASSUME_PLATFORM = $null
}

Describe 'Test-FaultPreflight.ps1' {
    BeforeEach { . Initialize-DemoTestDefault }
    BeforeAll { $script:Preflight = Join-Path $script:ScriptsRoot 'Test-FaultPreflight.ps1' }

    It 'passes every fault on a healthy, quiet cluster (<Fault>)' -ForEach @(@{ Fault = 'Drive' }, @{ Fault = 'IntentDrift' }, @{ Fault = 'NodePowerOff' }) {
        $r = & $script:Preflight -Fault $Fault -NodeName nic26-01-n01 -Quiet 6>$null
        $r.Passed | Should -BeTrue
        @($r.Checks | Where-Object { $_.Status -eq 'RED' }).Count | Should -Be 0
    }
    It 'refuses when a repair job is running' {
        $global:NIC26Test.Health.StorageJobs = @([pscustomobject]@{ Name = 'Repair'; JobState = 'Running'; PercentComplete = 40 })
        $r = & $script:Preflight -Fault Drive -NodeName nic26-01-n01 -Quiet 6>$null
        $r.Passed | Should -BeFalse
        @($r.Checks | Where-Object { $_.Check -like 'No storage/repair job*' }).Status | Should -Be 'RED'
    }
    It 'refuses when another fault is active, and allows the one being undone' {
        $null = New-DemoFaultLock -Fault Drive -Target nic26-01-n01 -Scope azure-local -Confirm:$false
        (& $script:Preflight -Fault IntentDrift -NodeName nic26-01-n02 -Quiet 6>$null).Passed | Should -BeFalse
        (& $script:Preflight -Fault Drive -NodeName nic26-01-n01 -AllowActiveFault Drive -Quiet 6>$null).Passed | Should -BeTrue
    }
    It 'refuses a node power-off when the other node is not Up or a disk is unhealthy' {
        $global:NIC26Test.Health.Nodes[1].State = 'Down'
        (& $script:Preflight -Fault NodePowerOff -NodeName nic26-01-n01 -Quiet 6>$null).Passed | Should -BeFalse
        $global:NIC26Test.Health = New-HealthyHealth
        $global:NIC26Test.Health.PhysicalDisks[5].HealthStatus = 'Warning'
        (& $script:Preflight -Fault NodePowerOff -NodeName nic26-01-n01 -Quiet 6>$null).Passed | Should -BeFalse
    }
    It 'refuses a drive fault when a volume is not Healthy, an intent is not Success, or the witness is offline' {
        $global:NIC26Test.Health.VirtualDisks[0].HealthStatus = 'Warning'
        (& $script:Preflight -Fault Drive -NodeName nic26-01-n01 -Quiet 6>$null).Passed | Should -BeFalse
        $global:NIC26Test.Health = New-HealthyHealth
        $global:NIC26Test.Health.Intents[1].ConfigurationStatus = 'Retrying'
        (& $script:Preflight -Fault Drive -NodeName nic26-01-n01 -Quiet 6>$null).Passed | Should -BeFalse
        $global:NIC26Test.Health = New-HealthyHealth
        $global:NIC26Test.Health.Quorum.WitnessState = 'Offline'
        (& $script:Preflight -Fault Drive -NodeName nic26-01-n01 -Quiet 6>$null).Passed | Should -BeFalse
    }
    It 'refuses an unknown node' {
        (& $script:Preflight -Fault Drive -NodeName nic26-01-n09 -Quiet 6>$null).Passed | Should -BeFalse
    }
}

Describe 'Invoke-DriveFault / Undo-DriveFault' {
    BeforeAll {
        $script:Drive = Join-Path $script:ScriptsRoot 'Invoke-DriveFault.ps1'
        $script:UndoDrive = Join-Path $script:ScriptsRoot 'Undo-DriveFault.ps1'
    }
    BeforeEach {
        . Initialize-DemoTestDefault
        Mock Invoke-DemoRemote { [pscustomobject]@{ Applied = $true; Reason = ''; PnpInstanceId = 'SCSI\DISK&TEST\1'; Serial = 'S011'; FriendlyName = 'NVMe nic26-01-n01-1' } }
    }
    It 'WhatIf is the default: prints the UNDO command first, touches nothing, records no lock' {
        $out = Invoke-CaptureAll { $script:Plan = & $script:Drive -NodeName nic26-01-n01 -PassThru }
        $out.IndexOf('UNDO') | Should -BeLessThan $out.IndexOf('PLAN')
        $out | Should -Match 'Undo-DriveFault.ps1 -NodeName nic26-01-n01 -Execute'
        Should -Invoke Invoke-DemoRemote -Times 0
        @(Get-DemoFaultLock).Count | Should -Be 0
        $script:Plan.Executed | Should -BeFalse
        $script:Plan.SerialNumber | Should -Be 'S011'
    }
    It '-Execute disables the drive over remoting on the node and records the lock; other faults then refuse' {
        $plan = & $script:Drive -NodeName nic26-01-n01 -Execute -PassThru 6>$null
        $plan.Executed | Should -BeTrue
        Should -Invoke Invoke-DemoRemote -Times 1 -ParameterFilter { $ComputerName -eq 'nic26-01-n01' }
        $lock = @(Get-DemoFaultLock -Scope azure-local)
        $lock.Count | Should -Be 1
        $lock[0].Fault | Should -Be 'Drive'
        $lock[0].Detail.PnpInstanceId | Should -Be 'SCSI\DISK&TEST\1'
        { & (Join-Path $script:ScriptsRoot 'Invoke-IntentDrift.ps1') -NodeName nic26-01-n02 -Execute 6>$null } | Should -Throw '*REFUSED*'
        (& $script:Preflight -Fault NodePowerOff -NodeName nic26-01-n02 -Quiet 6>$null).Passed | Should -BeFalse
    }
    It 'writes the fault lock BEFORE the drive is touched' {
        Mock Invoke-DemoRemote { $global:NIC26Test.LockCountAtCall = @(Get-DemoFaultLock).Count; [pscustomobject]@{ Applied = $true; Reason = ''; PnpInstanceId = 'P1'; Serial = 'S011'; FriendlyName = 'd' } }
        $null = & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null
        $global:NIC26Test.LockCountAtCall | Should -Be 1
        (Get-DemoFaultLock)[0].Detail.PnpInstanceId | Should -Be 'P1'
    }
    It 'releases the lock and changes nothing when the drive cannot be mapped to exactly one device' {
        Mock Invoke-DemoRemote { [pscustomobject]@{ Applied = $false; Reason = 'Could not map drive serial to exactly one PnP device (2 matches).'; PnpInstanceId = ''; Serial = 'S011'; FriendlyName = 'd' } }
        { & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null } | Should -Throw '*Nothing was changed*'
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
    It 'KEEPS the lock and names the Undo when the remote action throws (outcome unknown)' {
        Mock Invoke-DemoRemote { throw 'connection lost after the command was sent' }
        { & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null } | Should -Throw '*outcome is unknown*'
        @(Get-DemoFaultLock).Count | Should -Be 1
    }
    It 'refuses when the preflight fails' {
        $global:NIC26Test.Health.StorageJobs = @([pscustomobject]@{ Name = 'Repair'; JobState = 'Running'; PercentComplete = 10 })
        { & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null } | Should -Throw '*REFUSED*'
        Should -Invoke Invoke-DemoRemote -Times 0
    }
    It 'Undo: WhatIf default lists the plan; -Execute restores, waits for Healthy and clears the lock' {
        $null = & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null
        $r = & $script:UndoDrive -PassThru 6>$null
        $r.Undone | Should -BeFalse
        @(Get-DemoFaultLock).Count | Should -Be 1
        $r2 = & $script:UndoDrive -Execute -PassThru 6>$null
        $r2.Undone | Should -BeTrue
        $r2.SerialNumber | Should -Be 'S011'
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
    It 'Undo keeps the lock while the repair is still running' {
        $null = & $script:Drive -NodeName nic26-01-n01 -Execute 6>$null
        $global:NIC26Test.Health.StorageJobs = @([pscustomobject]@{ Name = 'Repair'; JobState = 'Running'; PercentComplete = 10 })
        $r = & $script:UndoDrive -Execute -ResyncTimeoutMinutes 1 -PassThru 6>$null 3>$null
        $r.Undone | Should -BeFalse
        @(Get-DemoFaultLock).Count | Should -Be 1
    }
    It 'Undo with no lock reports nothing to undo' {
        (& $script:UndoDrive -Execute -PassThru 6>$null).Undone | Should -BeFalse
        Should -Invoke Invoke-DemoRemote -Times 0
    }
}

Describe 'Invoke-IntentDrift / Undo-IntentDrift' {
    BeforeAll {
        $script:Drift = Join-Path $script:ScriptsRoot 'Invoke-IntentDrift.ps1'
        $script:UndoDrift = Join-Path $script:ScriptsRoot 'Undo-IntentDrift.ps1'
    }
    BeforeEach {
        . Initialize-DemoTestDefault
        $global:NIC26Test.Jumbo = '1514'
        Mock Invoke-DemoRemote {
            if ($ArgumentList.Count -eq 1) { return $global:NIC26Test.Jumbo }
            if ($ArgumentList.Count -eq 2 -and $ArgumentList[1] -is [int]) { $before = $global:NIC26Test.Jumbo; $global:NIC26Test.Jumbo = [string]$ArgumentList[1]; return $before }
            if ($ArgumentList.Count -eq 2) { if ($global:NIC26Test.Jumbo -eq [string]$ArgumentList[1]) { return 'already-remediated' }; $global:NIC26Test.Jumbo = [string]$ArgumentList[1]; return 'restored' }
            return @([pscustomobject]@{ IntentName = 'Compute'; Host = 'nic26-01-n02'; ConfigurationStatus = 'Success'; ProvisioningStatus = 'Completed'; LastUpdated = (Get-Date) })
        }
        Mock Get-DemoIntentStatus { @([pscustomobject]@{ IntentName = 'Compute'; Host = 'nic26-01-n02'; ConfigurationStatus = 'Retrying'; ProvisioningStatus = 'Completed'; LastUpdated = (Get-Date) }) }
    }
    It 'WhatIf default prints UNDO and the intent status BEFORE, changes nothing' {
        $out = Invoke-CaptureAll { & $script:Drift -NodeName nic26-01-n02 }
        $out | Should -Match 'Undo-IntentDrift.ps1'
        $out | Should -Match 'Get-NetIntentStatus BEFORE'
        Should -Invoke Invoke-DemoRemote -Times 0
        $global:NIC26Test.Jumbo | Should -Be '1514'
    }
    It '-Execute changes ONE adapter on ONE node, records the original value, prints AFTER; Undo restores it' {
        $plan = & $script:Drift -NodeName nic26-01-n02 -Execute -PassThru 6>$null
        $plan.Adapter | Should -Be 'SLOT 3 Port 1'
        $plan.OriginalValue | Should -Be '1514'
        $global:NIC26Test.Jumbo | Should -Be '4088'
        Should -Invoke Invoke-DemoRemote -Times 2 -ParameterFilter { $ComputerName -eq 'nic26-01-n02' }
        Should -Invoke Get-DemoIntentStatus -Times 1
        (Get-DemoFaultLock)[0].Detail.OriginalValue | Should -Be '1514'
        $r = & $script:UndoDrift -Execute -PassThru 6>$null
        $r.Outcome | Should -Be 'restored'
        $global:NIC26Test.Jumbo | Should -Be '1514'
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
    It 'records the original value in the lock BEFORE the change is made' {
        Mock Invoke-DemoRemote {
            if ($ArgumentList.Count -eq 1) { return '1514' }
            $global:NIC26Test.LockAtChange = @(Get-DemoFaultLock)[0].Detail.OriginalValue
            return '1514'
        }
        $null = & $script:Drift -NodeName nic26-01-n02 -Execute 6>$null
        $global:NIC26Test.LockAtChange | Should -Be '1514'
    }
    It 'KEEPS the lock and names the Undo when the change throws' {
        Mock Invoke-DemoRemote { if ($ArgumentList.Count -eq 1) { return '1514' }; throw 'connection lost' }
        { & $script:Drift -NodeName nic26-01-n02 -Execute 6>$null } | Should -Throw '*outcome is unknown*'
        (Get-DemoFaultLock)[0].Detail.OriginalValue | Should -Be '1514'
    }
    It 'Undo recognises that Network ATC already remediated' {
        $null = & $script:Drift -NodeName nic26-01-n02 -Execute 6>$null
        $global:NIC26Test.Jumbo = '1514'
        (& $script:UndoDrift -Execute -PassThru 6>$null).Outcome | Should -Be 'already-remediated'
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
}

Describe 'Test-Day2Readiness.ps1' {
    BeforeEach { . Initialize-DemoTestDefault }
    BeforeAll {
        $script:Readiness = Join-Path $script:ScriptsRoot 'Test-Day2Readiness.ps1'
        $script:AllPresent = @('insights', 'monitoring-config', 'update-manager', 'backup', 'site-recovery', 'pim-access', 'defender', 'policy-baseline', 'workload-platform') | ForEach-Object { [pscustomobject]@{ Control = $_; Status = 'Present'; Detail = 'ok' } }
    }
    It 'is green when every control is Present and the cluster is healthy' {
        $rows = @(& $script:Readiness -ControlState $script:AllPresent -PassThru 6>$null)
        @($rows | Where-Object { $_.Status -eq 'RED' }).Count | Should -Be 0
        (Get-DemoCheckExitCode -Check $rows) | Should -Be 0
        $rows.Count | Should -BeGreaterOrEqual 18
    }
    It 'is red when a control is Missing or not reported (the 2.6 baseline)' {
        $state = @($script:AllPresent | Where-Object { $_.Control -ne 'monitoring-config' }) + @([pscustomobject]@{ Control = 'insights'; Status = 'Missing'; Detail = 'no DCR' })
        $rows = @(& $script:Readiness -ControlState $state -SkipCluster -PassThru 6>$null)
        @($rows | Where-Object { $_.Check -like 'Azure Local Insights*' }).Status | Should -Be 'RED'
        @($rows | Where-Object { $_.Check -like 'VM Insights DCR*' }).Status | Should -Be 'RED'
        (Get-DemoCheckExitCode -Check $rows) | Should -Be 1
    }
    It 'reads the control state from a JSON file and flags cluster problems' {
        $path = Join-Path $TestDrive 'state.json'
        $script:AllPresent | ConvertTo-Json | Set-Content -LiteralPath $path
        $global:NIC26Test.Health.Intents[0].ConfigurationStatus = 'Failed'
        $rows = @(& $script:Readiness -ControlStatePath $path -PassThru 6>$null)
        @($rows | Where-Object { $_.Check -like 'Network ATC intents*' }).Status | Should -Be 'RED'
        @($rows | Where-Object { $_.Section -like '3.*' -and $_.Status -eq 'RED' }).Count | Should -Be 0
    }
    It 'is red when no Get-Day2ControlState script exists' {
        $rows = @(& $script:Readiness -SkipCluster -ControlStateScript (Join-Path $TestDrive 'nope.ps1') -PassThru 6>$null)
        @($rows | Where-Object { $_.Check -like 'Get-Day2ControlState*' }).Status | Should -Be 'RED'
    }
}

Describe 'Reset-Day2Controls / Restore-Day2Controls' {
    BeforeAll {
        $script:Reset = Join-Path $script:ScriptsRoot 'Reset-Day2Controls.ps1'
        $script:Restore = Join-Path $script:ScriptsRoot 'Restore-Day2Controls.ps1'
        # a registry whose scripts exist under the real cluster-configure root would be another agent's; build a private one
        $script:FakeRoot = Join-Path $TestDrive 'azure-local'
        foreach ($f in @('cluster-configure/monitoring/scripts/Remove-Day2Insights.ps1', 'cluster-configure/monitoring/scripts/Set-Day2Insights.ps1', 'cluster-configure/security/scripts/Remove-Day2PolicyAssignment.ps1', 'cluster-configure/security/scripts/Set-Day2PolicyAssignment.ps1')) {
            $p = Join-Path $script:FakeRoot $f
            $null = New-Item -ItemType Directory -Path (Split-Path $p) -Force
            Set-Content -LiteralPath $p -Value 'param([switch]$Execute) "ran"'
        }
        $script:FakeRegistry = Join-Path $TestDrive 'day2-controls.yml'
        @'
version: 1
controls:
  - { key: insights, outline: "3.1", area: monitoring, name: Insights, solution: cluster-configure/monitoring, remove_script: scripts/Remove-Day2Insights.ps1, apply_script: scripts/Set-Day2Insights.ps1, reversible: true }
  - { key: backup, outline: "3.3", area: bc-dr, name: Backup, solution: cluster-configure/bc-dr, remove_script: "", apply_script: scripts/Set-Day2Backup.ps1, reversible: false }
  - { key: policy-baseline, outline: "3.5", area: governance, name: Policy, solution: cluster-configure/security, remove_script: scripts/Remove-Day2PolicyAssignment.ps1, apply_script: scripts/Set-Day2PolicyAssignment.ps1, reversible: true }
  - { key: defender, outline: "3.5", area: security, name: Defender, solution: cluster-configure/security, remove_script: scripts/Remove-Day2Defender.ps1, apply_script: scripts/Set-Day2Defender.ps1, reversible: true }
'@ | Set-Content -LiteralPath $script:FakeRegistry
    }
    BeforeEach {
        . Initialize-DemoTestDefault
        $global:NIC26Test.Steps = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-DemoControlStep { $global:NIC26Test.Steps.Add((Split-Path $ScriptPath -Leaf) + ':' + [bool]$Execute); 'ok' }
        # point the scripts at the fake solution root by temporarily copying them next to it
        $script:ResetCopy = Join-Path $TestDrive 'demo' 'azure-local' 'scripts' 'Reset-Day2Controls.ps1'
        $script:RestoreCopy = Join-Path $TestDrive 'demo' 'azure-local' 'scripts' 'Restore-Day2Controls.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:ResetCopy) -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'demo' 'shared' 'scripts') -Force
        Copy-Item -LiteralPath $script:Reset -Destination $script:ResetCopy -Force
        Copy-Item -LiteralPath $script:Restore -Destination $script:RestoreCopy -Force
        Copy-Item -LiteralPath (Join-Path $script:ScriptsRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1') -Destination (Join-Path $TestDrive 'demo' 'shared' 'scripts') -Force
        Copy-Item -LiteralPath (Join-Path $script:ScriptsRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psm1') -Destination (Join-Path $TestDrive 'demo' 'shared' 'scripts') -Force
    }
    It 'the real registry covers every outline section 3 control and marks the non-reversible ones' {
        $reg = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $script:RegistryPath -Raw)
        @($reg.controls).Count | Should -BeGreaterOrEqual 9
        @($reg.controls | Where-Object { -not $_.reversible }).key | Should -Contain 'backup'
        @($reg.controls | Where-Object { -not $_.reversible }).key | Should -Contain 'site-recovery'
        @($reg.controls | Where-Object { $_.reversible }).key | Should -Contain 'insights'
    }
    It 'every script and named argument in the real registry exists in the owning solution (no guessed paths)' {
        $reg = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $script:RegistryPath -Raw)
        $azl = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'azure-local')
        foreach ($c in $reg.controls) {
            foreach ($kind in 'remove', 'apply') {
                $rel = [string]$c["${kind}_script"]
                if (-not $rel) { continue }
                $path = Join-Path $azl ([string]$c.solution) $rel
                Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because "$($c.key) $kind script $path"
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
                $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $declared | Should -Contain 'Execute' -Because "$($c.key) $kind script must take -Execute"
                foreach ($argName in @($c["${kind}_args"].Keys)) {
                    $declared | Should -Contain $argName -Because "$($c.key) $kind passes -$argName"
                }
            }
            if (-not $c.reversible) { [string]$c.remove_script | Should -BeNullOrEmpty }
        }
    }
    It 'Reset: WhatIf default lists exactly what it would remove, keeps non-reversible controls, runs nothing' {
        $plan = @(& $script:ResetCopy -RegistryPath $script:FakeRegistry -PassThru 6>$null 3>$null)
        @($plan | Where-Object { $_.Key -eq 'backup' }).Action | Should -BeLike 'KEEP*'
        @($plan | Where-Object { $_.Key -eq 'insights' }).Action | Should -Be 'remove'
        @($plan | Where-Object { $_.Key -eq 'defender' }).Action | Should -BeLike '*MISSING*'
        Should -Invoke Invoke-DemoControlStep -Times 0
    }
    It 'Reset -Execute refuses while a remove step is missing, then removes with -SkipMissing in reverse order and records the state; Restore re-applies in order' {
        { & $script:ResetCopy -RegistryPath $script:FakeRegistry -Execute 6>$null 3>$null } | Should -Throw '*remove steps missing*'
        Should -Invoke Invoke-DemoControlStep -Times 0
        $plan = @(& $script:ResetCopy -RegistryPath $script:FakeRegistry -Execute -SkipMissing -PassThru 6>$null 3>$null)
        @($plan | Where-Object { $_.Result -eq 'removed' }).Key | Should -Be @('policy-baseline', 'insights')
        $global:NIC26Test.Steps | Should -Be @('Remove-Day2PolicyAssignment.ps1:True', 'Remove-Day2Insights.ps1:True')
        (Get-Content -LiteralPath (Join-Path (Get-DemoStateRoot) 'day2-reset.json') -Raw | ConvertFrom-Json).Controls | Should -Be @('policy-baseline', 'insights')
        Should -Invoke Invoke-DemoControlStep -Times 2 -Exactly   # baseline right after Reset: exactly the two removals
        $global:NIC26Test.Steps.Clear()
        $restorePlan = @(& $script:RestoreCopy -RegistryPath $script:FakeRegistry -PassThru 6>$null)
        @($restorePlan.Key) | Should -Be @('insights', 'policy-baseline')
        # the call count is cumulative for this test: the two removals above are all that has run, so the Restore WhatIf added none
        Should -Invoke Invoke-DemoControlStep -Times 2 -Exactly
        $null = & $script:RestoreCopy -RegistryPath $script:FakeRegistry -Execute -PassThru 6>$null
        $global:NIC26Test.Steps | Should -Be @('Set-Day2Insights.ps1:True', 'Set-Day2PolicyAssignment.ps1:True')
        (Test-Path -LiteralPath (Join-Path (Get-DemoStateRoot) 'day2-reset.json')) | Should -BeFalse
    }
    It 'Restore -Control picks one control for a live beat' {
        $plan = @(& $script:RestoreCopy -RegistryPath $script:FakeRegistry -Control insights -Execute -PassThru 6>$null)
        $plan.Count | Should -Be 1
        $global:NIC26Test.Steps | Should -Be @('Set-Day2Insights.ps1:True')
    }
}

Describe 'ASR helpers' {
    BeforeAll {
        $script:StartAsr = Join-Path $script:ScriptsRoot 'Start-AsrPlannedFailover.ps1'
        $script:AsrStatus = Join-Path $script:ScriptsRoot 'Get-AsrFailoverStatus.ps1'
        $script:ShowAsr = Join-Path $script:ScriptsRoot 'Show-AsrState.ps1'
    }
    BeforeEach {
        . Initialize-DemoTestDefault
        $global:NIC26Test.Asr = [pscustomobject]@{
            VaultName      = 'rsv-iic-nic26-azl-eus-01'
            ProtectedItems = @([pscustomobject]@{ Name = 'iic-app-01'; ProtectionState = 'Protected'; ReplicationHealth = 'Normal'; ActiveLocation = 'Primary'; AllowedOperations = @('PlannedFailover', 'TestFailover'); Fabric = 'nic26-clus01'; Id = '/x' })
            RecoveryPlans  = @([pscustomobject]@{ Name = 'rp-iic-nic26-tier1-01'; Direction = 'ResourceManager'; Id = '/rp' })
            Jobs           = @([pscustomobject]@{ Name = 'j1'; DisplayName = 'Test failover'; State = 'Succeeded'; StateDescription = 'Completed'; StartTime = (Get-Date).AddDays(-2); EndTime = (Get-Date).AddDays(-2); TargetObjectName = 'iic-app-01' })
        }
        Mock Get-DemoAsrState { $global:NIC26Test.Asr }
        Mock Start-DemoAsrPlannedFailover { [pscustomobject]@{ JobName = 'job-pf-1'; JobId = '/jobs/1'; State = 'InProgress' } }
        Mock Get-DemoAsrJob { [pscustomobject]@{ Name = 'job-pf-1'; DisplayName = 'Planned failover'; State = 'Succeeded'; StateDescription = 'Completed'; StartTime = (Get-Date); EndTime = (Get-Date); TargetObjectName = 'iic-app-01'; Tasks = @(); Errors = @() } }
    }
    It 'Start: WhatIf is the default, states there is no scripted undo, starts nothing' {
        $out = Invoke-CaptureAll { & $script:StartAsr }
        $out | Should -Match 'Commit -> Re-protect -> Failback'
        Should -Invoke Start-DemoAsrPlannedFailover -Times 0
    }
    It 'Start -Execute starts the job once and returns name/state only' {
        $r = & $script:StartAsr -Execute -PassThru 6>$null
        $r.JobName | Should -Be 'job-pf-1'
        Should -Invoke Start-DemoAsrPlannedFailover -Times 1 -ParameterFilter { $RecoveryPlanName -eq 'rp-iic-nic26-tier1-01' }
    }
    It 'Start refuses when replication is not Normal or a failover is already running' {
        $global:NIC26Test.Asr.ProtectedItems[0].ReplicationHealth = 'Warning'
        { & $script:StartAsr -Execute 6>$null } | Should -Throw '*REFUSED*'
        $global:NIC26Test.Asr.ProtectedItems[0].ReplicationHealth = 'Normal'
        $global:NIC26Test.Asr.Jobs += [pscustomobject]@{ Name = 'j2'; DisplayName = 'Planned failover'; State = 'InProgress'; StateDescription = ''; StartTime = (Get-Date); EndTime = $null; TargetObjectName = 'iic-app-01' }
        { & $script:StartAsr -Execute 6>$null } | Should -Throw '*REFUSED*'
        Should -Invoke Start-DemoAsrPlannedFailover -Times 0
    }
    It 'Status and Show are read-only and return objects' {
        (& $script:AsrStatus -PassThru 6>$null).State | Should -Be 'Succeeded'
        (& $script:ShowAsr -PassThru 6>$null).ProtectedItems.Count | Should -Be 1
    }
}

Describe 'Show-ClusterState / Invoke-LcmReadiness / Test-DemoSmoke' {
    BeforeEach { . Initialize-DemoTestDefault }
    It 'Show-ClusterState prints through the hygiene filter (no registered term, no GUID on screen)' {
        Add-DemoHiddenTerm -Term 'acmecorp'
        $global:NIC26Test.Health.VirtualDisks += [pscustomobject]@{ FriendlyName = 'acmecorp-old-volume'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; ResiliencySettingName = 'Mirror' }
        Mock Get-DemoArbState { [pscustomobject]@{ ApplianceName = 'arb-x'; ApplianceStatus = 'Running'; CustomLocationName = 'cl-x'; CustomLocationState = 'Succeeded' } }
        Mock Get-DemoUpdateState { [pscustomobject]@{ CurrentVersion = '12.2609.1003.7'; State = 'UpdateAvailable'; HealthState = 'Success'; LastChecked = (Get-Date); Updates = @(); Runs = @() } }
        $out = Invoke-CaptureAll { & (Join-Path $script:ScriptsRoot 'Show-ClusterState.ps1') -PassThru | Out-Null }
        $out | Should -Not -Match 'acmecorp'
        $out | Should -Match 'nic26-01-n01'
        $out | Should -Match 'Running'
    }
    It 'Invoke-LcmReadiness is read-only and returns the update state' {
        Mock Get-DemoUpdateState { [pscustomobject]@{ CurrentVersion = '12.2609.1003.7'; State = 'AppliedSuccessfully'; HealthState = 'Success'; LastChecked = (Get-Date); Updates = @([pscustomobject]@{ Version = '12.2610.1'; DisplayName = 'x'; State = 'Ready'; HealthState = 'Success'; InstalledDate = $null }); Runs = @() } }
        $r = & (Join-Path $script:ScriptsRoot 'Invoke-LcmReadiness.ps1') -PassThru 6>$null
        $r.Update.CurrentVersion | Should -Be '12.2609.1003.7'
        Should -Invoke Get-DemoUpdateState -Times 1
    }
    It 'Test-DemoSmoke produces the pass/fail list with mocked reachability' {
        Mock Resolve-DemoDnsName { if ($Name -like 'kv-*') { @('10.100.6.36') } else { @('192.0.2.20') } }
        Mock Test-DemoTcpPort { $true }
        Mock Test-DemoAzContext { $true }
        $rows = @(& (Join-Path $script:ScriptsRoot 'Test-DemoSmoke.ps1') -SkipAzure -PassThru 6>$null)
        @($rows | Where-Object { $_.Check -like 'kv-*resolves*' -and $_.Status -eq 'GREEN' }).Count | Should -Be 2
        @($rows | Where-Object { $_.Check -like '*WinRM 5985' }).Count | Should -Be 2
        @($rows | Where-Object { $_.Section -eq '2.6 cluster' -and $_.Check -eq 'All nodes Up' }).Status | Should -Be 'GREEN'
        @($rows | Where-Object { $_.Check -like 'Get-Day2ControlState*' }).Status | Should -Be 'GREEN'   # the cluster-configure solutions now provide it
    }
}
