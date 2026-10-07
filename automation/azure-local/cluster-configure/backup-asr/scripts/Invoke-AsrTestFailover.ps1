#Requires -Version 7.0
<#
.SYNOPSIS
Starts or cleans up an ASR test failover; never starts a live failover.
.DESCRIPTION
A test failover creates an isolated VM in the test network and does not touch production replication. Planned and
unplanned failovers are the owner-driven live demo and are not scripted here. Without -Execute only the plan is printed.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER SubscriptionId
Subscription containing the vault.
.PARAMETER VaultResourceGroup
Resource group of the vault.
.PARAMETER VaultName
Recovery Services vault name.
.PARAMETER HyperVSiteName
Friendly name of the portal-prepared Hyper-V site fabric.
.PARAMETER VmName
Friendly name of the replication-protected VM.
.PARAMETER Action
Start a test failover, or clean up a finished one.
.PARAMETER TestNetworkId
Resource ID of the isolated test virtual network (required for Start).
.PARAMETER WaitMinutes
Maximum time to wait for the ASR job.
.PARAMETER Execute
Start or clean up the test failover; omit to preview.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$VaultResourceGroup,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$HyperVSiteName,
    [Parameter(Mandatory)][string]$VmName,
    [ValidateSet('Start', 'Cleanup')][string]$Action = 'Start',
    [string]$TestNetworkId,
    [ValidateRange(1, 1440)][int]$WaitMinutes = 60,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Action -eq 'Start' -and -not $TestNetworkId) {
    throw 'TestNetworkId is required for Start.'
}

if (-not (Get-Command Invoke-AsrJobWaitSleep -ErrorAction SilentlyContinue)) {
    # Seam so tests can poll without sleeping.
    function Invoke-AsrJobWaitSleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mockable wait wrapper; changes no system state.')]
        param()
        Start-Sleep -Seconds 5
    }
}

$null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName
if (-not $vault) {
    throw "Recovery Services vault '$VaultName' was not found."
}

$null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fabric = Get-AzRecoveryServicesAsrFabric -FriendlyName $HyperVSiteName
if (-not $fabric) {
    throw "Hyper-V site '$HyperVSiteName' was not found."
}

$item = $null
foreach ($container in @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric)) {
    $item = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -FriendlyName $VmName
    if ($item) {
        break
    }
}
if (-not $item) {
    throw "Replication-protected VM '$VmName' was not found."
}

if (-not $Execute) {
    Write-Output "Would run test-failover action '$Action' for '$VmName'."
    return
}
if (-not $PSCmdlet.ShouldProcess($VmName, "ASR test-failover action $Action")) {
    return
}

if ($Action -eq 'Start') {
    $start = @{
        ReplicationProtectedItem = $item
        Direction                = 'PrimaryToRecovery'
        AzureVMNetworkId         = $TestNetworkId
    }
    $job = Start-AzRecoveryServicesAsrTestFailoverJob @start
}
else {
    $cleanup = @{
        ReplicationProtectedItem = $item
        Comment                  = 'Test failover validation complete.'
    }
    $job = Start-AzRecoveryServicesAsrTestFailoverCleanupJob @cleanup
}
if (-not $job) {
    throw 'The test-failover action did not return an ASR job.'
}

$deadline = (Get-Date).AddMinutes($WaitMinutes)
do {
    $currentJob = Get-AzRecoveryServicesAsrJob -Job $job
    if (-not $currentJob) {
        throw 'The ASR job could not be retrieved.'
    }
    if ($currentJob.State -eq 'Succeeded') {
        $currentJob
        return
    }
    if ($currentJob.State -in @('Failed', 'Cancelled', 'Canceled')) {
        # Only the job error summary is surfaced.
        $summary = @($currentJob.Errors | ForEach-Object { $_.ErrorMessage }) -join '; '
        if (-not $summary) {
            $summary = 'No job error summary was provided.'
        }
        throw "ASR job $($currentJob.State): $summary"
    }
    if ((Get-Date) -ge $deadline) {
        throw "The ASR job did not complete within $WaitMinutes minutes."
    }
    Invoke-AsrJobWaitSleep
} while ($true)
