#Requires -Version 7.0
<#
.SYNOPSIS
    Assigns (Apply) or removes (-Action Remove / -Remove) the governance baseline (outline §3.5): the initiative
    assignment at subscription scope plus the Azure Local Insights and Key Vault backup extension policies.
    Default -WhatIf; -Execute changes Azure. -StartComplianceScan triggers the on-demand evaluation after Apply.
.DESCRIPTION
    Remove deletes the four assignments (their system-assigned identities' role assignments are removed by Azure with the
    assignment; stale ones are swept here) and the three custom definitions. The initiative DEFINITION at the
    management group belongs to lz-azure-local and is never touched.
.EXAMPLE
    .\Invoke-PolicyBaseline.ps1 -Action Apply -Execute -StartComplianceScan
    .\Invoke-PolicyBaseline.ps1 -Remove -Execute            # alias for -Action Remove
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Apply', 'Remove')][string]$Action = 'Apply',
    [switch]$Remove,
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [string]$BackendConfig,
    [switch]$StartComplianceScan,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
$solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($Remove) { $Action = 'Remove' }

$removeWithAz = {
    param($inputs)
    $sub = "/subscriptions/$($inputs.subscription_id)"
    foreach ($k in 'asg_hybrid_baseline', 'asg_insights_ama', 'asg_insights_dcra', 'asg_akv_backup_ext') {
        $id = "$sub/providers/Microsoft.Authorization/policyAssignments/$($inputs.names.$k)"
        $existing = Get-Day2Resource -Path "${id}?api-version=2025-01-01"
        if ($existing -and $existing.identity -and $existing.identity.principalId) {
            foreach ($ra in @(Get-AzRoleAssignment -ObjectId $existing.identity.principalId -Scope $sub -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess("$($ra.RoleDefinitionName) for assignment identity $($inputs.names.$k)", 'Remove-AzRoleAssignment')) { Remove-AzRoleAssignment -InputObject $ra -ErrorAction SilentlyContinue | Out-Null }
            }
        }
        Remove-Day2ArmResource -ResourceId $id -ApiVersion '2025-01-01'
    }
    foreach ($k in 'pol_insights_ama', 'pol_insights_dcra', 'pol_akv_backup_ext') {
        Remove-Day2ArmResource -ResourceId "$sub/providers/Microsoft.Authorization/policyDefinitions/$($inputs.names.$k)" -ApiVersion '2023-04-01'
    }
}

Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-policy' -Action $Action -Tool $Tool -DeploymentScope sub -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -Execute:$Execute

if ($Action -eq 'Apply' -and $StartComplianceScan -and $Execute) {
    $inputs = Get-Day2Inputs -SolutionRoot $solutionRoot
    if ($PSCmdlet.ShouldProcess("subscription $($inputs.subscription_id)", 'Start-AzPolicyComplianceScan')) {
        Start-AzPolicyComplianceScan -AsJob | Out-Null
        Write-Day2Log -Message 'Compliance scan started (runs in the background; evaluation is not instant - outline §3.5).'
    }
}
