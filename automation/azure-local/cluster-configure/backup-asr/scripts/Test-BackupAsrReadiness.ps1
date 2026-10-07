#Requires -Version 7.0
<#
.SYNOPSIS
Read-only readiness check: vault, both policies, Hyper-V site, replication health and a jump-VM recovery point.
.DESCRIPTION
Uses only Get-* cmdlets (it changes nothing). With -PassThru the rows are returned even when checks fail; otherwise the
script throws when any check fails.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Subscription containing the vault.
.PARAMETER VaultResourceGroup
Resource group of the vault.
.PARAMETER VaultName
Recovery Services vault name.
.PARAMETER AsrPolicyName
ASR replication policy name.
.PARAMETER BackupPolicyName
Azure VM backup policy name.
.PARAMETER HyperVSiteName
Friendly name of the portal-prepared Hyper-V site fabric.
.PARAMETER VmName
Azure Local VM names expected to be replication-protected.
.PARAMETER AzureVmName
Azure VM (jump server) expected to have a backup recovery point.
.PARAMETER PassThru
Return the check rows even when a check fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$VaultResourceGroup,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$AsrPolicyName,
    [Parameter(Mandatory)][string]$BackupPolicyName,
    [Parameter(Mandatory)][string]$HyperVSiteName,
    [Parameter(Mandatory)][string[]]$VmName,
    [Parameter(Mandatory)][string]$AzureVmName,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CheckRow {
    param([string]$Check, [bool]$Passed, [string]$Pass, [string]$Fail)
    [pscustomobject]@{ Check = $Check; Passed = $Passed; Detail = if ($Passed) { $Pass } else { $Fail } }
}

$rows = [System.Collections.Generic.List[object]]::new()
$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName
$vaultReady = [bool]($vault -and $vault.Properties.ProvisioningState -eq 'Succeeded')
$rows.Add((ConvertTo-CheckRow -Check 'Vault' -Passed $vaultReady -Pass 'Provisioning succeeded.' -Fail 'Vault missing or not Succeeded.'))

$asrPolicy = $null
$backupPolicy = $null
$fabric = $null
if ($vault) {
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault
    $asrPolicy = Get-AzRecoveryServicesAsrPolicy -Name $AsrPolicyName
    $backupPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $BackupPolicyName -VaultId $vault.ID
    $fabric = Get-AzRecoveryServicesAsrFabric -FriendlyName $HyperVSiteName
}
$rows.Add((ConvertTo-CheckRow -Check 'ASR policy' -Passed ([bool]$asrPolicy) -Pass 'Found.' -Fail 'Not found.'))
$rows.Add((ConvertTo-CheckRow -Check 'Backup policy' -Passed ([bool]$backupPolicy) -Pass 'Found.' -Fail 'Not found.'))
$rows.Add((ConvertTo-CheckRow -Check 'Hyper-V site' -Passed ([bool]$fabric) -Pass 'Found.' -Fail 'Not found.'))

foreach ($vm in $VmName) {
    $protected = $null
    if ($fabric) {
        foreach ($container in @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric)) {
            $protected = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -FriendlyName $vm
            if ($protected) {
                break
            }
        }
    }
    $healthy = [bool]($protected -and $protected.ReplicationHealth -eq 'Normal' -and $protected.ProtectionState -eq 'Protected')
    $rows.Add((ConvertTo-CheckRow -Check "Replication: $vm" -Passed $healthy -Pass 'Protected; health Normal.' -Fail 'Missing, unprotected or unhealthy.'))
}

$recoveryPoints = @()
if ($vault) {
    $query = @{
        BackupManagementType = 'AzureVM'
        WorkloadType         = 'AzureVM'
        FriendlyName         = $AzureVmName
        VaultId              = $vault.ID
    }
    $backupItem = @(Get-AzRecoveryServicesBackupItem @query) | Select-Object -First 1
    if ($backupItem) {
        $recoveryPoints = @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem -VaultId $vault.ID)
    }
}
$rows.Add((ConvertTo-CheckRow -Check "Azure VM recovery point: $AzureVmName" -Passed ($recoveryPoints.Count -gt 0) -Pass 'At least one recovery point found.' -Fail 'No recovery point found.'))

if ($PassThru) {
    $rows.ToArray()
    return
}
$failed = @($rows | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "Backup and ASR readiness failed: $(($failed.Check) -join ', ')."
}
$rows.ToArray()
