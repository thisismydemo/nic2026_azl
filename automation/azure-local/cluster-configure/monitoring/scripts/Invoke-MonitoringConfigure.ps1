#Requires -Version 7.0
<#
.SYNOPSIS
    Applies or removes the monitoring IaC (outline §3.1): alert rules, VM Insights DCR, Key Vault backup alert routing
    (and, behind manage_insights_dcr_in_iac, the Insights DCR). Default -WhatIf; -Execute changes Azure.
    Insights enable/disable itself is Enable-ClusterInsights.ps1 (supported flow).
.PARAMETER Action
    Apply | Remove (Remove deletes the log and metric alert rules, both processing rules and the VM Insights DCR; the
    Insights DCR and the workspace are kept, D-054).
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
    if ($inputs.enable_vm_insights_dcr) {
        # Associations first (Enable-VmInsights.ps1 creates them; re-run it after Apply on stage), then the DCR itself.
        $vmiDcr = "$mon/Microsoft.Insights/dataCollectionRules/$($inputs.names.dcr_vminsights)"
        $list = Invoke-AzRestMethod -Path "$vmiDcr/associations?api-version=2023-03-11" -Method GET
        if ($list.StatusCode -eq 200) {
            foreach ($a in @(($list.Content | ConvertFrom-Json -Depth 20).value)) { Remove-Day2ArmResource -ResourceId ([string]$a.id) -ApiVersion '2023-03-11' }
        }
        Remove-Day2ArmResource -ResourceId $vmiDcr -ApiVersion '2023-03-11'
    }
    # The recommended metric alerts and the health-alert routing rule go with the other rules (re-created by Apply).
    foreach ($k in 'alert_cpu', 'alert_memory', 'alert_vol_read_latency', 'alert_vol_write_latency', 'alert_net_in', 'alert_net_out') {
        if ($inputs.names.PSObject.Properties.Name -contains $k) { Remove-Day2ArmResource -ResourceId "$mon/Microsoft.Insights/metricAlerts/$($inputs.names.$k)" -ApiVersion '2018-03-01' }
    }
    if ($inputs.names.PSObject.Properties.Name -contains 'alert_health_routing') { Remove-Day2ArmResource -ResourceId "$mon/Microsoft.AlertsManagement/actionRules/$($inputs.names.alert_health_routing)" -ApiVersion '2021-08-08' }
    # The Insights DCR and the workspace are kept (D-054): the Insights enable beat (control 'insights') needs the DCR,
    # exactly as when the dialog created it; data in the workspace is never deleted by a reset.
}

Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-monitoring' -Action $Action -Tool $Tool -DeploymentScope group -ResourceGroupKey rg_mon -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -Execute:$Execute

# VM Insights associations follow the VM Insights DCR (D-054): after an executed Apply, associate the tagged workload VMs.
if ($Action -eq 'Apply' -and $Execute) {
    & (Join-Path $PSScriptRoot 'Enable-VmInsights.ps1') -Action Enable -Execute -Confirm:$false | Out-Null
}
