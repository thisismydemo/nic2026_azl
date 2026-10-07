#Requires -Version 7.0
<#
.SYNOPSIS
Enables vault backup for Azure VMs only (the jump server, failed-over VMs).
.DESCRIPTION
Azure Local guest backup is NOT configured here (an open owner decision). A VM that is already protected is skipped.
Without -Execute only the plan is printed.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Subscription containing the vault and the Azure VMs.
.PARAMETER VaultResourceGroup
Resource group of the vault.
.PARAMETER VaultName
Recovery Services vault name.
.PARAMETER PolicyName
Azure VM backup policy name.
.PARAMETER VmResourceGroup
Resource group of the Azure VMs.
.PARAMETER VmName
Azure VM names.
.PARAMETER ReassignPolicy
Move a VM that is protected under a different policy to the requested policy (explicit; retention can change).
.PARAMETER RunInitialBackup
Request an initial backup after protection is enabled.
.PARAMETER Execute
Enable the protection; omit to preview.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$VaultResourceGroup,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$PolicyName,
    [Parameter(Mandatory)][string]$VmResourceGroup,
    [Parameter(Mandatory)][string[]]$VmName,
    [switch]$ReassignPolicy,
    [switch]$RunInitialBackup,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName
if (-not $vault) {
    throw "Recovery Services vault '$VaultName' was not found."
}

$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $PolicyName -VaultId $vault.ID
if (-not $policy) {
    throw "Azure VM backup policy '$PolicyName' was not found."
}

foreach ($vm in $VmName) {
    $query = @{
        BackupManagementType = 'AzureVM'
        WorkloadType         = 'AzureVM'
        FriendlyName         = $vm
        VaultId              = $vault.ID
    }
    # Filtering by -Policy asks the service which items already use the requested policy: no property is assumed.
    $onPolicy = @(Get-AzRecoveryServicesBackupItem -Policy $policy -FriendlyName $vm -VaultId $vault.ID)
    if ($onPolicy.Count -gt 0) {
        Write-Output "Skipping '$vm': it already uses policy '$PolicyName'."
        continue
    }

    $existing = @(Get-AzRecoveryServicesBackupItem @query)
    if ($existing.Count -gt 0) {
        # Protected under another policy: only an explicit -ReassignPolicy moves it (retention can change).
        if (-not $ReassignPolicy) {
            Write-Output "Skipping '$vm': it is protected under a different policy. Use -ReassignPolicy to move it to '$PolicyName'."
        }
        elseif (-not $Execute) {
            Write-Output "Would move '$vm' to policy '$PolicyName'."
        }
        elseif ($PSCmdlet.ShouldProcess($vm, "Move the Azure VM backup to policy $PolicyName")) {
            $move = @{ Item = $existing[0]; Policy = $policy; VaultId = $vault.ID }
            $null = Enable-AzRecoveryServicesBackupProtection @move
        }
        continue
    }

    if (-not $Execute) {
        Write-Output "Would enable Azure VM backup for '$vm'."
        continue
    }

    if ($PSCmdlet.ShouldProcess($vm, 'Enable Azure VM backup protection')) {
        $protection = @{
            Policy            = $policy
            Name              = $vm
            ResourceGroupName = $VmResourceGroup
            VaultId           = $vault.ID
        }
        $null = Enable-AzRecoveryServicesBackupProtection @protection
    }

    if ($RunInitialBackup -and $PSCmdlet.ShouldProcess($vm, 'Run the initial Azure VM backup')) {
        $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $vm -VaultId $vault.ID
        if (-not $container) {
            throw "The backup container of '$vm' was not found after enabling protection."
        }
        $item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vault.ID
        if (-not $item) {
            throw "The backup item of '$vm' was not found after enabling protection."
        }
        $null = Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $vault.ID
    }
}
