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
Cache (log) storage account for replication to managed disks (Learn: Hyper-V to Azure, managed disks).
.PARAMETER Size
Optional Azure VM size used at failover (for a Generation 2 source, a size that supports Generation 2).
.PARAMETER Tag
Optional tags written to the failed-over VM, its NICs and its disks (RecoveryVmTag, RecoveryNicTag, DiskTag).
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
    $set = @{ InputObject = $ProtectedItem; TestNetworkId = $TestNetworkId }
    if ($TestSubnetName) {
        $nics = @(if ($ProtectedItem.PSObject.Properties['NicDetailsList']) { $ProtectedItem.NicDetailsList })
        if ($nics.Count -eq 0 -or $null -eq $nics[0]) { throw "Protected item $($ProtectedItem.FriendlyName) reports no NIC; cannot set the test subnet." }
        $set.UpdateNic = [string]$nics[0].NicId
        $set.RecoveryNetworkId = $RecoveryNetworkId
        $set.RecoveryNicSubnetName = $RecoverySubnetName
        $set.TestNicSubnetName = $TestSubnetName
    }
    $null = Set-AzRecoveryServicesAsrReplicationProtectedItem @set
}

foreach ($vm in $VmName) {
    $item = Get-AzRecoveryServicesAsrProtectableItem -ProtectionContainer $selectedContainer -FriendlyName $vm
    if (-not $item) {
        throw "Protectable VM '$vm' was not found."
    }

    $existing = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $selectedContainer -FriendlyName $vm
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

    # The protectable item states its own OS and OS disk: nothing is guessed.
    if (-not $item.OSDiskName) {
        throw "Protectable VM '$vm' does not report an OS disk name."
    }
    if ($item.OS -notin @('Windows', 'Linux')) {
        throw "Protectable VM '$vm' reports the operating system '$($item.OS)'; expected Windows or Linux."
    }

    if (-not $Execute) {
        Write-Output "Would enable replication for '$vm' ($($item.OS), OS disk '$($item.OSDiskName)')."
        continue
    }

    if ($PSCmdlet.ShouldProcess($vm, 'Enable Hyper-V-to-Azure replication')) {
        $replication = @{
            HyperVToAzure              = $true
            ProtectableItem            = $item
            Name                       = $vm
            ProtectionContainerMapping = $mapping
            RecoveryAzureNetworkId     = $RecoveryNetworkId
            RecoveryAzureSubnetName    = $RecoverySubnetName
            RecoveryResourceGroupId    = $RecoveryResourceGroupId
            UseManagedDisk             = 'true'
            OS                         = $item.OS
            OSDiskName                 = $item.OSDiskName
            WaitForCompletion          = $true
        }
        if ($LogStorageAccountId) { $replication.LogStorageAccountId = $LogStorageAccountId }
        if ($Size) { $replication.Size = $Size }
        if ($Tag -and $Tag.Count -gt 0) {
            $tags = [System.Collections.Generic.Dictionary[string, string]]::new()
            foreach ($k in $Tag.Keys) { $tags[[string]$k] = [string]$Tag[$k] }
            $replication.RecoveryVmTag = $tags
            $replication.RecoveryNicTag = $tags
            $replication.DiskTag = $tags
        }
        $null = New-AzRecoveryServicesAsrReplicationProtectedItem @replication
        # The Hyper-V-to-Azure enable-replication parameter set has no test-network parameter: set it on the new item.
        $created = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $selectedContainer -FriendlyName $vm
        if (-not $created) {
            throw "Replication of $vm was started but the protected item was not found afterwards."
        }
        Invoke-TestNetworkUpdate $created
    }
}
