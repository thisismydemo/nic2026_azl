#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the Site Recovery chain for the Azure Local VMs in environment asr.protected_vms (T-5.5.3), step by step, with
    every value from environment/azure-local/environment.yml. Preview by default; -Execute changes Azure.
.DESCRIPTION
    Actions, in the order Microsoft Learn gives them ("Protect VM workloads with Azure Site Recovery on Azure Local"):
      NodeState     read-only node check (Get-AsrNodeState.ps1): last boot, pending reboot, Hyper-V service, ASR services.
      Prepare       Install-AsrInfrastructure.ps1: Hyper-V site, node identities on the vault, ASRExtension, policy mapping.
      Enable        Enable-AsrReplication.ps1: replication to managed disks (cache account asr.cache_storage_account),
                    recovery RG/VNet/subnet, failover size, project tags on the Azure VM/NIC/disks, and the test
                    network = the recovery VNet with the NSG-isolated test subnet asr.test_subnet_name.
      WaitProtected waits until every protected VM is Protected with Normal health (initial replication done) and prints
                    the elapsed time.
      RecoveryPlan  creates asr.recovery_plan_name with the protected VMs (Hyper-V site -> Azure) when it does not exist.
      TestFailover  Invoke-AsrTestFailover.ps1 -Action Start (latest processed point, isolated test network) and times it.
      Verify        read-only: the test VM in the recovery RG, its power state, NIC subnet and tags; with
                    -BootScreenshotPath the boot-diagnostics screenshot (managed boot diagnostics are switched on for
                    the temporary test VM if off: it is deleted by Cleanup).
      Cleanup       Invoke-AsrTestFailover.ps1 -Action Cleanup and times it.
      Status        read-only: protection state, health, test-failover state, last jobs.
    A planned or unplanned failover is never started here (demo/azure-local Start-AsrPlannedFailover.ps1, owner-driven).
.EXAMPLE
    .\Invoke-AsrFromEnvironment.ps1 -Action Status
    .\Invoke-AsrFromEnvironment.ps1 -Action Enable -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('NodeState', 'Prepare', 'Enable', 'WaitProtected', 'RecoveryPlan', 'TestFailover', 'Verify', 'Cleanup', 'Status')][string]$Action,
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\shared\environment.yml'),
    [ValidateRange(5, 1440)][int]$WaitMinutes = 240,
    [string]$BootScreenshotPath,
    [switch]$Execute,
    [string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml

$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$asr = $envy.asr
$sub = [string]$envy.subscription_id
$null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription $sub -Scope Process -WhatIf:$false

$vmNames = @($asr.protected_vms | ForEach-Object { [string]$_.name })
$vnetId = "/subscriptions/$sub/resourceGroups/$($asr.network_resource_group)/providers/Microsoft.Network/virtualNetworks/$($asr.vnet_name)"
$recoveryRgId = "/subscriptions/$sub/resourceGroups/$($asr.recovery_resource_group)"
$cacheId = "/subscriptions/$sub/resourceGroups/$($asr.vault_resource_group)/providers/Microsoft.Storage/storageAccounts/$($asr.cache_storage_account)"
$common = @{ SubscriptionId = $sub; VaultResourceGroup = [string]$asr.vault_resource_group; VaultName = [string]$asr.vault_name; HyperVSiteName = [string]$asr.hyperv_site_name }

function L([string]$m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }
function Get-TagSet {
    $t = @{}; foreach ($k in $shared.tags.Keys) { $t[$k] = [string]$shared.tags[$k] }
    $t.workload = 'iic'; $t.'managed-by' = 'script'; $t.purpose = 'asr-demo'
    return $t
}
function Get-ProtectedItemList {
    # No Hyper-V site yet: nothing to read (and the vault-context cmdlet needs the vault's extended information, which
    # Prepare creates).
    $siteRest = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$sub/resourceGroups/$($asr.vault_resource_group)/providers/Microsoft.RecoveryServices/vaults/$($asr.vault_name)/replicationFabrics/$($asr.hyperv_site_name)?api-version=2024-04-01"
    if ($siteRest.StatusCode -eq 404) { return @() }
    $vault =Get-AzRecoveryServicesVault -ResourceGroupName $asr.vault_resource_group -Name $asr.vault_name
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    $fabric = Get-AzRecoveryServicesAsrFabric -FriendlyName $asr.hyperv_site_name -ErrorAction SilentlyContinue
    if (-not $fabric) { return @() }
    $items = foreach ($c in @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric)) { Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $c }
    return @($items | Where-Object { $vmNames -contains $_.FriendlyName })
}
function Find-TestVm([string]$name) {
    # Site Recovery names the test VM after the recovery VM name with a '-test' suffix.
    $vms = @(Get-AzVM -ResourceGroupName $asr.recovery_resource_group -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$name*-test" -or $_.Name -like "$name*test*" })
    return $vms | Select-Object -First 1
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()

switch ($Action) {
    'NodeState' { & (Join-Path $PSScriptRoot 'Get-AsrNodeState.ps1') -EnvironmentFile $EnvironmentFile -SharedEnvironmentFile $SharedEnvironmentFile }
    'Prepare' { & (Join-Path $PSScriptRoot 'Install-AsrInfrastructure.ps1') -EnvironmentFile $EnvironmentFile -SharedEnvironmentFile $SharedEnvironmentFile -Execute:$Execute -LogFile $LogFile }
    'Enable' {
        foreach ($pv in @($asr.protected_vms)) {
            $p = $common.Clone()
            $p.PolicyName = [string]$asr.replication_policy_name
            $p.VmName = @([string]$pv.name)
            $p.RecoveryResourceGroupId = $recoveryRgId
            $p.RecoveryNetworkId = $vnetId
            $p.RecoverySubnetName = [string]$asr.recovery_subnet_name
            $p.TestNetworkId = $vnetId
            $p.TestSubnetName = [string]$asr.test_subnet_name
            $p.LogStorageAccountId = $cacheId
            $p.Size = [string]$pv.target_vm_size
            $p.Tag = Get-TagSet
            & (Join-Path $PSScriptRoot 'Enable-AsrReplication.ps1') @p -Execute:$Execute
            L "$($pv.name): enable step done in $([int]$sw.Elapsed.TotalSeconds) s"
        }
    }
    'WaitProtected' {
        $deadline = (Get-Date).AddMinutes($WaitMinutes)
        while ($true) {
            $items = @(Get-ProtectedItemList)
            $line = ($items | ForEach-Object { "$($_.FriendlyName)=$($_.ProtectionState)/$($_.ReplicationHealth)" }) -join ' '
            L "elapsed $([int]$sw.Elapsed.TotalMinutes) min: $line"
            if ($items.Count -eq $vmNames.Count -and @($items | Where-Object { $_.ProtectionState -ne 'Protected' }).Count -eq 0) { L "all Protected after $([int]$sw.Elapsed.TotalMinutes) min"; break }
            if ((Get-Date) -ge $deadline) { throw "Not all VMs Protected after $WaitMinutes min." }
            Start-Sleep -Seconds 60
        }
    }
    'RecoveryPlan' {
        $items = @(Get-ProtectedItemList)
        $plan = Get-AzRecoveryServicesAsrRecoveryPlan -Name $asr.recovery_plan_name -ErrorAction SilentlyContinue
        if ($plan) { L "recovery plan $($asr.recovery_plan_name): exists ($(@($plan.Groups | ForEach-Object { $_.ReplicationProtectedItems }).Count) items)" }
        elseif ($items.Count -eq 0) { throw 'No protected VM yet: run Enable and WaitProtected first.' }
        elseif (-not $Execute) { L "PLAN create recovery plan $($asr.recovery_plan_name) (Hyper-V site -> Azure, Resource Manager) with $($items.FriendlyName -join ', ')" }
        else {
            $fabric = Get-AzRecoveryServicesAsrFabric -FriendlyName $asr.hyperv_site_name
            $job = New-AzRecoveryServicesAsrRecoveryPlan -Name $asr.recovery_plan_name -PrimaryFabric $fabric -Azure -FailoverDeploymentModel ResourceManager -ReplicationProtectedItem $items
            do { Start-Sleep -Seconds 10; $job = Get-AzRecoveryServicesAsrJob -Job $job } while ($job.State -in 'InProgress', 'NotStarted')
            L "recovery plan $($asr.recovery_plan_name): $($job.State)"
        }
    }
    'TestFailover' {
        foreach ($n in $vmNames) {
            & (Join-Path $PSScriptRoot 'Invoke-AsrTestFailover.ps1') @common -VmName $n -Action Start -TestNetworkId $vnetId -WaitMinutes $WaitMinutes -Execute:$Execute | Out-Null
            L "$n test failover $(if ($Execute) { 'completed' } else { 'previewed' }) in $([int]$sw.Elapsed.TotalSeconds) s"
        }
    }
    'Verify' {
        foreach ($n in $vmNames) {
            $vm = Find-TestVm $n
            if (-not $vm) { throw "No test-failover VM for $n in $($asr.recovery_resource_group)." }
            $iv = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            $power = @($iv.Statuses | Where-Object Code -like 'PowerState/*')[0].DisplayStatus
            $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id
            $subnet = ($nic.IpConfigurations[0].Subnet.Id -split '/')[-1]
            L "$n -> test VM $($vm.Name): $power, size $($vm.HardwareProfile.VmSize), subnet $subnet, private IP $($nic.IpConfigurations[0].PrivateIpAddress), project=$($vm.Tags['project'])"
            if ($subnet -ne $asr.test_subnet_name) { L "WARNING: the test VM is not in the isolated test subnet $($asr.test_subnet_name)" }
            if ($BootScreenshotPath) {
                if (-not $vm.DiagnosticsProfile -or -not $vm.DiagnosticsProfile.BootDiagnostics -or -not $vm.DiagnosticsProfile.BootDiagnostics.Enabled) {
                    if (-not $Execute) { L "PLAN enable managed boot diagnostics on the temporary test VM $($vm.Name)"; continue }
                    $null = Set-AzVMBootDiagnostic -VM $vm -Enable
                    $null = Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm
                    Start-Sleep -Seconds 60
                }
                $uri = (Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status).BootDiagnostics.ConsoleScreenshotBlobUri
                $sas = Invoke-AzRestMethod -Method POST -Path "$($vm.Id)/retrieveBootDiagnosticsData?api-version=2024-07-01&sasUriExpirationTimeInMinutes=10"
                $shot = ($sas.Content | ConvertFrom-Json).consoleScreenshotBlobUri
                if ($shot) { Invoke-WebRequest -Uri $shot -OutFile $BootScreenshotPath; L "boot screenshot saved to $BootScreenshotPath" } else { L "no boot screenshot yet ($uri)" }
            }
        }
    }
    'Cleanup' {
        foreach ($n in $vmNames) {
            & (Join-Path $PSScriptRoot 'Invoke-AsrTestFailover.ps1') @common -VmName $n -Action Cleanup -WaitMinutes $WaitMinutes -Execute:$Execute | Out-Null
            L "$n test failover cleanup $(if ($Execute) { 'completed' } else { 'previewed' }) in $([int]$sw.Elapsed.TotalSeconds) s"
        }
    }
    'Status' {
        $items = @(Get-ProtectedItemList)
        if ($items.Count -eq 0) { L 'no protected VM (Hyper-V site or replication not set up yet)' }
        foreach ($i in $items) {
            L "$($i.FriendlyName): $($i.ProtectionState) / health $($i.ReplicationHealth) / test failover $($i.TestFailoverState) / allowed $(@($i.AllowedOperations) -join ',')"
        }
        $since = (Get-Date).AddDays(-2)
        Get-AzRecoveryServicesAsrJob -StartTime $since -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object { L "job $($_.DisplayName) [$($_.TargetObjectName)]: $($_.State) $($_.StartTime) -> $($_.EndTime)" }
    }
}
