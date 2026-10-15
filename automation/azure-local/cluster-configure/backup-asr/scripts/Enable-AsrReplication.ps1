#Requires -Version 7.0
<#
.SYNOPSIS
Enables Hyper-V-to-Azure replication for selected Azure Local VMs.
.DESCRIPTION
Prepare the infrastructure first (Install-AsrInfrastructure.ps1, or Prepare infrastructure on the Azure Local resource
in the portal): that step creates the Hyper-V site and installs the ASR agent on the nodes. Trusted launch Azure Local VMs are NOT supported by Azure Site Recovery.
Without -Execute only the plan is printed. This script never starts a failover. The OS and the OS disk name come from the protectable item itself.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Subscription containing the Recovery Services vault.
.PARAMETER VaultResourceGroup
Resource group of the vault.
.PARAMETER VaultName
Recovery Services vault name.
.PARAMETER HyperVSiteName
Friendly name of the portal-prepared Hyper-V site fabric.
.PARAMETER PolicyName
Friendly name of the replication policy used by the container mapping.
.PARAMETER VmName
Names of the Azure Local VMs to protect.
.PARAMETER RecoveryResourceGroupId
Resource ID of the post-failover resource group.
.PARAMETER RecoveryNetworkId
Resource ID of the post-failover virtual network.
.PARAMETER RecoverySubnetName
Post-failover subnet name.
.PARAMETER TestNetworkId
Resource ID of the isolated test-failover virtual network.
.PARAMETER TestSubnetName
Optional test-failover subnet for the primary NIC. Needed when the test network is the recovery network itself (a
separate, NSG-isolated subnet in the same VNet): without it Site Recovery picks the subnet with the recovery subnet's name.
.PARAMETER LogStorageAccountId
Cache storage account for replication to managed disks; passed as both the log and the target storage account (with
the log account alone the service fails with error 70130, storage account not found; seen 13 Oct 2026).
.PARAMETER Size
Optional Azure VM size used at failover (for a Generation 2 source, a size that supports Generation 2).
.PARAMETER Tag
Optional tags written to the failed-over VM, its NICs and its disks (RecoveryVmTag, RecoveryNicTag, DiskTag).
.PARAMETER OS
Operating system to use when the protectable item does not report one (the portal asks for it on the Replication
settings tab; an Azure Local guest without a connected guest agent reports none).
.PARAMETER Execute
Enable replication; omit to preview.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$VaultResourceGroup,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$HyperVSiteName,
    [Parameter(Mandatory)][string]$PolicyName,
    [Parameter(Mandatory)][string[]]$VmName,
    [Parameter(Mandatory)][string]$RecoveryResourceGroupId,
    [Parameter(Mandatory)][string]$RecoveryNetworkId,
    [Parameter(Mandatory)][string]$RecoverySubnetName,
    [Parameter(Mandatory)][string]$TestNetworkId,
    [string]$TestSubnetName,
    [string]$LogStorageAccountId,
    [string]$Size,
    [hashtable]$Tag,
    [ValidateSet('Windows', 'Linux')][string]$OS,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName
if (-not $vault) {
    throw "Recovery Services vault '$VaultName' was not found."
}

$null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fabric = Get-AzRecoveryServicesAsrFabric -FriendlyName $HyperVSiteName
if (-not $fabric) {
    throw "Hyper-V site '$HyperVSiteName' was not found. Run Prepare infrastructure in the portal first."
}

$containers = @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric)
if ($containers.Count -eq 0) {
    throw "No protection container was found for site '$HyperVSiteName'."
}

$selectedContainer = $null
$mapping = $null
foreach ($container in $containers) {
    $candidate = @(Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $container |
            Where-Object { $_.PolicyFriendlyName -eq $PolicyName }) | Select-Object -First 1
    if ($candidate) {
        $selectedContainer = $container
        $mapping = $candidate
        break
    }
}
if (-not $mapping) {
    throw "No protection container mapping uses the replication policy '$PolicyName'."
}

function Get-TfoSubnet($ProtectedItem) {
    # Test-failover subnet of the primary NIC, wherever this module version reports it; '' when not reported.
    $nics = @(if ($ProtectedItem.PSObject.Properties['NicDetailsList']) { $ProtectedItem.NicDetailsList })
    if ($nics.Count -eq 0 -or $null -eq $nics[0]) { return '' }
    foreach ($p in 'TfoVMSubnetName', 'TfoSubnetName') { if ($nics[0].PSObject.Properties[$p] -and $nics[0].$p) { return [string]$nics[0].$p } }
    if ($nics[0].PSObject.Properties['IpConfigs'] -and $nics[0].IpConfigs) {
        $ip = @($nics[0].IpConfigs)[0]
        if ($ip.PSObject.Properties['TfoSubnetName'] -and $ip.TfoSubnetName) { return [string]$ip.TfoSubnetName }
    }
    return ''
}
function Invoke-TestNetworkUpdate($ProtectedItem) {
    # The service accepts Compute and Network settings only once initial replication has finished (13 Oct 2026:
    # ErrorInVMConfigurationAsProtectionFailed while the item was still being protected). Run this script again then.
    if ($ProtectedItem.PSObject.Properties['ProtectionState'] -and $ProtectedItem.ProtectionState -and $ProtectedItem.ProtectionState -ne 'Protected') {
        Write-Warning "Protected item $($ProtectedItem.Name) is '$($ProtectedItem.ProtectionState)': the test network and subnet are set by a rerun once it is Protected."
        return
    }
    $set = @{ InputObject = $ProtectedItem; TestNetworkId = $TestNetworkId }
    if ($TestSubnetName) {
        $nics = @(if ($ProtectedItem.PSObject.Properties['NicDetailsList']) { $ProtectedItem.NicDetailsList })
        if ($nics.Count -eq 0 -or $null -eq $nics[0]) {
            # NIC details arrive with the first replication data; a rerun of this script sets the subnet then.
            Write-Warning "Protected item $($ProtectedItem.Name) reports no NIC yet: test network set, test subnet not yet set. Run this script again once replication has started."
            $null = Set-AzRecoveryServicesAsrReplicationProtectedItem @set
            return
        }
        $set.UpdateNic = [string]$nics[0].NicId
        $set.RecoveryNetworkId = $RecoveryNetworkId
        $set.RecoveryNicSubnetName = $RecoverySubnetName
        $set.TestNicSubnetName = $TestSubnetName
    }
    $null = Set-AzRecoveryServicesAsrReplicationProtectedItem @set
}

function Test-VmNameMatch([string]$Candidate, [string]$Name) {
    # Azure Local names the Hyper-V VM '<resource name>-<guid>'; a plain Hyper-V VM keeps its own name.
    return ($Candidate -eq $Name) -or ($Candidate -match ('^' + [regex]::Escape($Name) + '-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
}
function Find-ProtectedItem([string]$Name) {
    @(Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $selectedContainer) |
        Where-Object { $_.Name -eq $Name -or (Test-VmNameMatch $_.FriendlyName $Name) } | Select-Object -First 1
}

foreach ($vm in $VmName) {
    $matched = @(Get-AzRecoveryServicesAsrProtectableItem -ProtectionContainer $selectedContainer | Where-Object { Test-VmNameMatch $_.FriendlyName $vm })
    if ($matched.Count -eq 0) {
        throw "Protectable VM '$vm' was not found."
    }
    if ($matched.Count -gt 1) {
        throw "More than one protectable VM matches '$vm': $($matched.FriendlyName -join ', ')."
    }
    $item = $matched[0]

    $existing = Find-ProtectedItem $vm
    if ($existing -and $existing.PSObject.Properties['ProtectionState'] -and $existing.ProtectionState -eq 'EnablingFailed') {
        # A failed enable leaves an item that cannot be updated: disable it, then enable again below.
        if (-not $Execute) { Write-Output "Would remove the failed replication item of '$vm' and enable it again." }
        elseif ($PSCmdlet.ShouldProcess($vm, 'Remove the failed replication item')) {
            $job = Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $existing -Force
            do { Start-Sleep -Seconds 10; $job = Get-AzRecoveryServicesAsrJob -Job $job } while ($job.State -in 'InProgress', 'NotStarted')
            Write-Output "Removed the failed replication item of '$vm' ($($job.State))."
        }
        $existing = $null
    }
    if ($existing) {
        # Reconcile the test network (and subnet) on a VM that is already replicating (a failed earlier run may have left it unset).
        $subnetDiffers = $TestSubnetName -and ((Get-TfoSubnet $existing) -ne $TestSubnetName)
        if ($existing.SelectedTfoAzureNetworkId -ne $TestNetworkId -or $subnetDiffers) {
            if (-not $Execute) {
                Write-Output "Would set the test network of '$vm' (replication is already enabled)."
            }
            elseif ($PSCmdlet.ShouldProcess($vm, 'Set the test-failover network')) {
                Invoke-TestNetworkUpdate $existing
            }
        }
        else {
            Write-Output "Skipping '$vm': replication is already enabled with the requested test network."
        }
        continue
    }

    # OS disk: the one the item reports; otherwise its only disk, or the single disk Azure Local names '*-OSDisk'.
    $osDisk = [string]$item.OSDiskName
    if (-not $osDisk) {
        $disks = @($item.Disks)
        $named = @($disks | Where-Object { $_.Name -like '*-OSDisk' })
        if ($disks.Count -eq 1) { $osDisk = [string]$disks[0].Name }
        elseif ($named.Count -eq 1) { $osDisk = [string]$named[0].Name }
        else { throw "Protectable VM '$vm' does not report an OS disk and it cannot be identified from its disks." }
    }
    $osType = if ($item.OS -in @('Windows', 'Linux')) { [string]$item.OS } else { $OS }
    if ($osType -notin @('Windows', 'Linux')) {
        throw "Protectable VM '$vm' reports no usable operating system ('$($item.OS)'); pass -OS Windows or -OS Linux."
    }

    if (-not $Execute) {
        Write-Output "Would enable replication for '$vm' ($osType, OS disk '$osDisk')."
        continue
    }

    if ($PSCmdlet.ShouldProcess($vm, 'Enable Hyper-V-to-Azure replication')) {
        $replication = @{
            HyperVToAzure              = $true
            ProtectableItem            = $item
            Name                       = $vm
            RecoveryVmName             = $vm
            ProtectionContainerMapping = $mapping
            RecoveryAzureNetworkId     = $RecoveryNetworkId
            RecoveryAzureSubnetName    = $RecoverySubnetName
            RecoveryResourceGroupId    = $RecoveryResourceGroupId
            UseManagedDisk             = 'true'
            OS                         = $osType
            OSDiskName                 = $osDisk
            WaitForCompletion          = $true
        }
        if ($LogStorageAccountId) {
            $replication.LogStorageAccountId = $LogStorageAccountId
            $replication.RecoveryAzureStorageAccountId = $LogStorageAccountId
        }
        if ($Size) { $replication.Size = $Size }
        if ($Tag -and $Tag.Count -gt 0) {
            $tags = [System.Collections.Generic.Dictionary[string, string]]::new()
            foreach ($k in $Tag.Keys) { $tags[[string]$k] = [string]$Tag[$k] }
            $replication.RecoveryVmTag = $tags
            $replication.RecoveryNicTag = $tags
            $replication.DiskTag = $tags
        }
        $job = New-AzRecoveryServicesAsrReplicationProtectedItem @replication
        if ($job -and $job.PSObject.Properties['State'] -and $job.State -in 'Failed', 'Cancelled', 'Canceled') {
            $summary = @($job.Errors | ForEach-Object { if ($_.ServiceErrorDetails) { "$($_.ServiceErrorDetails.Code) $($_.ServiceErrorDetails.Message) $($_.ServiceErrorDetails.PossibleCauses)" } }) -join '; '
            throw "Enable replication of $vm $($job.State): $summary"
        }
        # The Hyper-V-to-Azure enable-replication parameter set has no test-network parameter: set it on the new item.
        $created = Find-ProtectedItem $vm
        if (-not $created) {
            throw "Replication of $vm was started but the protected item was not found afterwards."
        }
        Invoke-TestNetworkUpdate $created
    }
}
