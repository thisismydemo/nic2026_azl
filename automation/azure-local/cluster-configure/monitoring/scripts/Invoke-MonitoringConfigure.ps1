#Requires -Version 7.0
<#
.SYNOPSIS
    Applies or removes the monitoring IaC (outline §3.1): alert rules, VM Insights DCR, Key Vault backup alert routing
    (and, behind manage_insights_dcr_in_iac, the Insights DCR). Default -WhatIf; -Execute changes Azure.
    Insights enable/disable itself is Enable-ClusterInsights.ps1 (supported flow).
.PARAMETER Action
    Apply | Remove (Remove deletes the rules, the processing rule and the VM Insights DCR; the Insights DCR only when
    manage_insights_dcr_in_iac is true).
.EXAMPLE
    .\Invoke-MonitoringConfigure.ps1 -Action Apply -Execute
    .\Invoke-MonitoringConfigure.ps1 -Action Remove -Execute
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
    $mon = "/subscriptions/$($inputs.subscription_id)/resourceGroups/$($inputs.names.rg_mon)/providers"
    foreach ($k in 'alert_node_down', 'alert_storage_health', 'alert_intent_drift', 'alert_capacity') {
        Remove-Day2ArmResource -ResourceId "$mon/Microsoft.Insights/scheduledQueryRules/$($inputs.names.$k)" -ApiVersion '2023-12-01'
    }
    Remove-Day2ArmResource -ResourceId "$mon/Microsoft.AlertsManagement/actionRules/$($inputs.names.alert_kv_backup)" -ApiVersion '2021-08-08'
    if ($inputs.enable_vm_insights_dcr) { Remove-Day2ArmResource -ResourceId "$mon/Microsoft.Insights/dataCollectionRules/$($inputs.names.dcr_vminsights)" -ApiVersion '2023-03-11' }
    if ($inputs.manage_insights_dcr_in_iac) { Remove-Day2ArmResource -ResourceId "$mon/Microsoft.Insights/dataCollectionRules/$($inputs.names.dcr_insights)" -ApiVersion '2023-03-11' }
}

Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-monitoring' -Action $Action -Tool $Tool -DeploymentScope group -ResourceGroupKey rg_mon -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -Execute:$Execute
