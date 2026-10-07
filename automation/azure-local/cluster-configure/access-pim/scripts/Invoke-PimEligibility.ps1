#Requires -Version 7.0
<#
.SYNOPSIS
    Creates (Apply) or removes (Remove) the PIM-eligible Azure Local role assignments for the IIC groups (outline §3.4,
    design §6.2/§6.3). Default -WhatIf; -Execute submits the requests. Idempotent: existing eligibilities are detected
    with Get-AzRoleEligibilitySchedule and only the missing (Apply) or present (Remove) rows are submitted.
.DESCRIPTION
    -Tool Az (default): New-AzRoleEligibilityScheduleRequest AdminAssign / AdminRemove (requires Az.Resources >= 6 and
    Owner or User Access Administrator at the subscription; PIM needs Entra ID P2 / Governance licences - verify live).
    -Tool Bicep / Terraform: the parity tracks (Bicep requests are one-shot: use Az for re-runs). Role NAMES are resolved
    in the tenant with Get-AzRoleDefinition; no GUID is typed here.
.EXAMPLE
    .\Invoke-PimEligibility.ps1 -Action Apply -Execute
    .\Invoke-PimEligibility.ps1 -Action Remove -Execute      # before the session; Apply again live, then Request-PimActivation.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Apply', 'Remove')][string]$Action,
    [ValidateSet('Az', 'Bicep', 'Terraform')][string]$Tool = 'Az',
    [string]$BackendConfig,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
$solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ($Tool -ne 'Az') {
    $removeWithAz = { param($inputs) & (Join-Path $PSScriptRoot 'Invoke-PimEligibility.ps1') -Action Remove -Tool Az -Execute:$Execute }
    Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-access-pim' -Action $Action -Tool $Tool -DeploymentScope sub -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -Execute:$Execute
    return
}

if (-not $Execute) { $WhatIfPreference = $true }
[void](Import-Day2AutomationModule)
$inputs = Get-Day2Inputs -SolutionRoot $solutionRoot -AllowExample:$false
Assert-Day2AzContext -SubscriptionId $inputs.subscription_id
foreach ($cmd in 'Get-AzRoleEligibilitySchedule', 'New-AzRoleEligibilityScheduleRequest', 'Get-AzRoleDefinition') {
    if (-not (Test-Day2Command -Name $cmd)) { throw "Az cmdlet '$cmd' not available (Az.Resources >= 6)." }
}
$scope = "/subscriptions/$($inputs.subscription_id)"

$plan = foreach ($row in @($inputs.pim_assignments)) {
    $principalId = [string]$inputs.group_object_ids.($row.group)
    if ([string]::IsNullOrWhiteSpace($principalId) -or $principalId -eq '00000000-0000-0000-0000-000000000000') { throw "group_object_ids.$($row.group) is empty or a placeholder - run the landing-zone group script first." }
    $roleDef = Get-AzRoleDefinition -Name $row.role
    if (-not $roleDef) { throw "Built-in role not found in this tenant: $($row.role)" }
    $roleDefId = "$scope/providers/Microsoft.Authorization/roleDefinitions/$($roleDef.Id)"
    $existing = Get-AzRoleEligibilitySchedule -Scope $scope -Filter "principalId eq '$principalId'" -ErrorAction SilentlyContinue |
        Where-Object { $_.RoleDefinitionId -eq $roleDefId -and $_.Scope -eq $scope } | Select-Object -First 1
    [pscustomobject]@{
        Group = $row.group; Role = $row.role; Scope = $scope; PrincipalId = $principalId; RoleDefId = $roleDefId
        Exists = [bool]$existing; ScheduleId = $existing ? $existing.Id : $null
        Action = ($Action -eq 'Remove') ? ($existing ? 'AdminRemove' : 'none') : ($existing ? 'none' : 'AdminAssign')
    }
}
$plan | Select-Object Group, Role, Exists, Action | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
$pending = @($plan | Where-Object { $_.Action -ne 'none' })
if ($pending.Count -eq 0) { Write-Day2Log -Message 'Nothing to do.'; return $plan }
if (-not $Execute) { Write-Warning "WhatIf (default): $($pending.Count) PIM request(s) would be submitted. Re-run with -Execute."; return $plan }

foreach ($p in $pending) {
    if ($PSCmdlet.ShouldProcess("$($p.Role) for $($p.Group) at $($p.Scope)", "New-AzRoleEligibilityScheduleRequest ($($p.Action))")) {
        $request = @{
            Name = (New-Guid).Guid; Scope = $p.Scope; PrincipalId = $p.PrincipalId; RoleDefinitionId = $p.RoleDefId
            RequestType = $p.Action; Justification = 'NIC26 Day-2 Ready 3.4 - PIM-eligible Azure Local role (design 6.3)'
        }
        if ($p.Action -eq 'AdminAssign') { $request.ScheduleInfoStartDateTime = (Get-Date).ToUniversalTime(); $request.ExpirationType = 'NoExpiration' }
        else { $request.TargetRoleEligibilityScheduleId = $p.ScheduleId }
        $null = Invoke-NIC26WithRetry -Activity "PIM $($p.Action) $($p.Role)" -MaxMinutes 5 -ScriptBlock { New-AzRoleEligibilityScheduleRequest @request }
        Write-Day2Log -Message "$($p.Action) submitted: $($p.Role) for $($p.Group)"
    }
}
return $plan
