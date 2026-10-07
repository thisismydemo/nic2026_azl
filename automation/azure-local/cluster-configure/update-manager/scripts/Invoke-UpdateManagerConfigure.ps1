#Requires -Version 7.0
<#
.SYNOPSIS
    Applies or removes the Azure Update Manager guest-patching control (outline §3.2): maintenance configuration
    mc_azl + tag-based dynamic scope. Default -WhatIf; -Execute changes Azure. Remove = delete (reversible, D-014).
.EXAMPLE
    .\Invoke-UpdateManagerConfigure.ps1 -Action Apply -Execute
    .\Invoke-UpdateManagerConfigure.ps1 -Action Remove -Execute      # live replay: then Apply again on stage
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
    $sub = "/subscriptions/$($inputs.subscription_id)"
    Remove-Day2ArmResource -ResourceId "$sub/providers/Microsoft.Maintenance/configurationAssignments/$($inputs.names.mc_azl_dynscope)" -ApiVersion '2023-04-01'
    Remove-Day2ArmResource -ResourceId "$sub/resourceGroups/$($inputs.names.rg_mon)/providers/Microsoft.Maintenance/maintenanceConfigurations/$($inputs.names.mc_azl)" -ApiVersion '2023-04-01'
}

$preApply = {
    param($inputs)
    $window = if ($inputs.PSObject.Properties.Name -contains 'maintenance_window') { $inputs.maintenance_window } else { $null }
    if ($window -and $window.start_date_time -and -not (Test-Day2MaintenanceStart -StartDateTime ([string]$window.start_date_time) -TimeZone ([string]$window.time_zone))) {
        throw "maintenance_window.start_date_time '$($window.start_date_time)' is before today; Azure Update Manager accepts today or a later date. Set the start in environment/azure-local before Apply (a live replay needs the day of the session or later). Nothing was sent to Azure."
    }
}

Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-update-manager' -Action $Action -Tool $Tool -DeploymentScope sub -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -PreApplyCheck $preApply -Execute:$Execute