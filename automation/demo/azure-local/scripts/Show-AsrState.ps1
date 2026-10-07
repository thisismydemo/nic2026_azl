#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only Site Recovery view for outline §3.3 / §4.5: protected items, replication health, recovery plans, recent jobs.
.DESCRIPTION
    Reads the lab Recovery Services vault (Az.RecoveryServices) and prints through the screen-hygiene filter. Changes nothing.
.PARAMETER ResourceGroupName
    Vault resource group (default: rg-<org>-<token>-azl-bcdr-<region>-01).
.PARAMETER VaultName
    Recovery Services vault (default: rsv-<org>-<token>-azl-<region>-01).
.PARAMETER PassThru
    Return the state object.
.EXAMPLE
    ./Show-AsrState.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $VaultName,

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

$state = Get-DemoAsrState -ResourceGroupName $ResourceGroupName -VaultName $VaultName

Write-DemoScreen -InputObject ('== Site Recovery: {0} ==' -f $VaultName)
Write-DemoScreen -InputObject '-- Replicated items --' -Raw
$state.ProtectedItems | Format-Table -Property Name, ProtectionState, ReplicationHealth, ActiveLocation, Fabric -AutoSize | Out-String | Write-DemoScreen
Write-DemoScreen -InputObject '-- Recovery plans --' -Raw
$state.RecoveryPlans | Format-Table -Property Name, Direction -AutoSize | Out-String | Write-DemoScreen
Write-DemoScreen -InputObject '-- Recent jobs --' -Raw
$state.Jobs | Format-Table -Property DisplayName, State, TargetObjectName, StartTime, EndTime -AutoSize | Out-String | Write-DemoScreen
$testFailover = @($state.Jobs | Where-Object { $_.DisplayName -like '*Test failover*' -and $_.State -eq 'Succeeded' })
Write-DemoScreen -InputObject ('test failover completed: {0}' -f $(if ($testFailover.Count -gt 0) { 'yes (' + $testFailover[0].EndTime + ')' } else { 'not found in the last 10 jobs' }))
if ($PassThru) { return $state }
