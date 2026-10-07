#Requires -Version 7.0
<#
.SYNOPSIS
    Applies or removes the Day-2 backup and DR policies (outline 3.3): the Hyper-V-to-Azure replication policy and the
    Azure VM backup policy on the existing Recovery Services vault. Default -WhatIf; -Execute changes Azure.
    Remove deletes ONLY the two policies, never the vault (reversible, D-014).
.EXAMPLE
    .\Invoke-BackupAsrConfigure.ps1 -Action Apply -Execute
    .\Invoke-BackupAsrConfigure.ps1 -Action Remove -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Apply', 'Remove')][string]$Action,
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [string]$BackendConfig,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
$solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$removeWithAz = {
    param($inputs)
    $vault = "/subscriptions/$($inputs.subscription_id)/resourceGroups/$($inputs.names.rg_bcdr)/providers/Microsoft.RecoveryServices/vaults/$($inputs.names.rsv_azl)"
    Remove-Day2ArmResource -ResourceId "$vault/backupPolicies/$($inputs.names.bkp_tier1)" -ApiVersion '2023-02-01'
    Remove-Day2ArmResource -ResourceId "$vault/replicationPolicies/$($inputs.names.asrpol_tier1)" -ApiVersion '2023-02-01'
}

$solution = @{
    SolutionRoot     = $solutionRoot
    SolutionName     = 'cluster-configure-backup-asr'
    Action           = $Action
    Tool             = $Tool
    DeploymentScope  = 'group'
    ResourceGroupKey = 'rg_bcdr'
    BackendConfig    = $BackendConfig
    RemoveWithAz     = $removeWithAz
    Execute          = $Execute
}
Invoke-Day2Solution @solution
