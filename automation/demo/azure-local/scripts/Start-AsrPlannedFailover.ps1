#Requires -Version 7.0
<#
.SYNOPSIS
    Starts the planned ASR failover of the tier-1 recovery plan to Azure (outline §4.5: start only, lands in §5).
    -WhatIf is the default; -Execute starts the job and returns at once.
.DESCRIPTION
    Preflight (read-only): every replicated item in the vault reports ReplicationHealth Normal and a protection state
    that allows PlannedFailover; no failover job is already in progress. Prints what will happen and the explicit
    statement that there is NO scripted undo: a planned failover is reversed only by Commit -> Re-protect -> Failback
    (the ASR procedures handout), and the job can be watched with Get-AsrFailoverStatus.ps1. With -Execute the job is
    started (PrimaryToRecovery) and its name is printed; the script does not wait.
.PARAMETER ResourceGroupName
    Vault resource group.
.PARAMETER VaultName
    Recovery Services vault.
.PARAMETER RecoveryPlanName
    Recovery plan (default: rp-<org>-<token>-tier1-01, the registry convention without a region).
.PARAMETER Execute
    Start the failover.
.PARAMETER PassThru
    Return the job object (name/ID/state only).
.EXAMPLE
    ./Start-AsrPlannedFailover.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $VaultName,

    [Parameter()]
    [string] $RecoveryPlanName,

    [switch] $Execute,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAzlNameSet -Config $config
if (-not $ResourceGroupName) { $ResourceGroupName = $names.BcdrResourceGroup }
if (-not $VaultName) { $VaultName = $names.RecoveryVault }
if (-not $RecoveryPlanName) { $RecoveryPlanName = $names.RecoveryPlan }

Write-DemoUndo -Command ('none by script: a planned failover is reversed by Commit -> Re-protect -> Failback (ASR procedures handout). Watch it: {0}' -f (Join-Path $PSScriptRoot 'Get-AsrFailoverStatus.ps1'))

$state = Get-DemoAsrState -ResourceGroupName $ResourceGroupName -VaultName $VaultName
$checks = @(
    New-DemoCheck -Section 'asr' -Name 'Recovery plan exists' -Passed (@($state.RecoveryPlans | Where-Object { $_.Name -eq $RecoveryPlanName }).Count -eq 1) -Detail $RecoveryPlanName
    New-DemoCheck -Section 'asr' -Name 'Replicated item(s) present' -Passed (@($state.ProtectedItems).Count -ge 1) -Detail "$(@($state.ProtectedItems).Count) item(s)"
    New-DemoCheck -Section 'asr' -Name 'Replication health Normal' -Passed (@($state.ProtectedItems | Where-Object { $_.ReplicationHealth -ne 'Normal' }).Count -eq 0) -Detail ((@($state.ProtectedItems | ForEach-Object { "$($_.Name)=$($_.ReplicationHealth)" })) -join ', ')
    New-DemoCheck -Section 'asr' -Name 'Planned failover allowed' -Passed (@($state.ProtectedItems | Where-Object { $_.AllowedOperations -notcontains 'PlannedFailover' }).Count -eq 0) -Detail 'AllowedOperations contains PlannedFailover'
    New-DemoCheck -Section 'asr' -Name 'No failover job in progress' -Passed (@($state.Jobs | Where-Object { $_.DisplayName -like '*Failover*' -and $_.State -eq 'InProgress' }).Count -eq 0)
)
Write-DemoCheckTable -Check $checks -Title 'Planned failover preflight'
if ((Get-DemoCheckExitCode -Check $checks) -ne 0) { throw 'REFUSED: Site Recovery is not ready for a planned failover (see the table). Nothing was started.' }

$planLines = @(
    "start planned failover of recovery plan '$RecoveryPlanName' (PrimaryToRecovery) in vault '$VaultName'",
    'the source VM is shut down cleanly, final delta synced, VM created in Azure; expect 10-20 minutes',
    'the script returns as soon as the job is accepted; §5 shows the landing with Get-AsrFailoverStatus.ps1'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Start-AsrPlannedFailover.ps1'
    if ($PassThru) { return [pscustomobject]@{ JobName = ''; State = 'NotStarted'; RecoveryPlan = $RecoveryPlanName } }
    return
}

if ($PSCmdlet.ShouldProcess($RecoveryPlanName, 'planned failover PrimaryToRecovery')) {
    $job = Start-DemoAsrPlannedFailover -ResourceGroupName $ResourceGroupName -VaultName $VaultName -RecoveryPlanName $RecoveryPlanName
    Write-DemoScreen -InputObject ('Planned failover started: job {0} ({1}). Running under the close; watch with Get-AsrFailoverStatus.ps1 -JobName {0}' -f $job.JobName, $job.State)
    if ($PassThru) { return [pscustomobject]@{ JobName = $job.JobName; JobId = $job.JobId; State = $job.State; RecoveryPlan = $RecoveryPlanName } }
}
