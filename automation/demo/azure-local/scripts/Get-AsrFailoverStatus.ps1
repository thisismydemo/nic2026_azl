#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only status of the (latest or named) ASR failover job - the §5 "failover lands" view, with optional waiting.
.DESCRIPTION
    Prints the job state, its tasks and any errors through the screen-hygiene filter. -Wait polls until the job is no
    longer InProgress or -TimeoutMinutes elapses. Changes nothing.
.PARAMETER ResourceGroupName
    Vault resource group.
.PARAMETER VaultName
    Recovery Services vault.
.PARAMETER JobName
    Job name from Start-AsrPlannedFailover (default: most recent failover job).
.PARAMETER Wait
    Poll until the job completes.
.PARAMETER TimeoutMinutes
    Maximum wait (default 30).
.PARAMETER PassThru
    Return the job object.
.EXAMPLE
    ./Get-AsrFailoverStatus.ps1 -Wait
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $VaultName,

    [Parameter()]
    [string] $JobName,

    [switch] $Wait,

    [Parameter()]
    [ValidateRange(1, 240)]
    [int] $TimeoutMinutes = 30,

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

$jobParams = @{ ResourceGroupName = $ResourceGroupName; VaultName = $VaultName }
if ($JobName) { $jobParams['JobName'] = $JobName }
$job = Get-DemoAsrJob @jobParams
if ($null -eq $job) {
    Write-DemoScreen -InputObject 'No failover job found in the vault.' -Raw
    if ($PassThru) { return $null }
    return
}
if ($Wait -and $job.State -eq 'InProgress') {
    $null = Wait-DemoCondition -TimeoutMinutes $TimeoutMinutes -IntervalSeconds 20 -Activity "job $($job.Name)" -Condition {
        $script:latest = Get-DemoAsrJob -ResourceGroupName $ResourceGroupName -VaultName $VaultName -JobName $job.Name
        $script:latest.State -ne 'InProgress'
    }
    $job = $script:latest
}
Write-DemoScreen -InputObject ('== {0}: {1} ({2}) ==' -f $job.DisplayName, $job.State, $job.StateDescription)
Write-DemoScreen -InputObject ('target {0}; started {1}; ended {2}' -f $job.TargetObjectName, $job.StartTime, $job.EndTime)
$job.Tasks | Format-Table -Property Name, State -AutoSize | Out-String | Write-DemoScreen
if (@($job.Errors).Count -gt 0) { $job.Errors | ForEach-Object { Write-DemoScreen -InputObject ('error: ' + $_) } }
if ($job.State -eq 'Succeeded') { Write-DemoScreen -InputObject 'Failover landed: the VM runs in Azure. Next (not scripted): Commit, then Re-protect / Failback per the ASR procedures handout.' -Raw }
if ($PassThru) { return $job }
