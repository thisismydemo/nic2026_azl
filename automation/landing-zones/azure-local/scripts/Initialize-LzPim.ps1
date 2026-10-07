#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the PIM-eligible role assignments of the Azure Local landing zone (design §6.2, §6.3) idempotently.
.DESCRIPTION
    Default path for PIM (manage_pim_in_iac = false): roleEligibilityScheduleRequests are one-shot request objects that
    cannot be re-applied by IaC, so this script checks the existing eligibility schedules first and submits an
    AdminAssign request only for the missing ones. Default is -WhatIf; -Execute submits the requests.
    -Remove submits AdminRemove requests instead (the reversible Day-2 control, D-014).
    Scope is always inside -SubscriptionId; the script refuses any scope outside it.
.PARAMETER Config
    Canonical config object from Get-NIC26Config -Scope azure-local (needs subscription_id, group_object_ids, names).
.PARAMETER Execute
    Submit the requests. Without it the script prints the plan.
.PARAMETER Remove
    Remove the eligibilities instead of creating them (still needs -Execute to act).
.EXAMPLE
    ./Initialize-LzPim.ps1 -Config (Get-NIC26Config -Scope azure-local)
    ./Initialize-LzPim.ps1 -Config $cfg -Execute
.NOTES
    Requires Az.Resources >= 6 (New-AzRoleEligibilityScheduleRequest, Get-AzRoleEligibilitySchedule) and an Az context
    holding Owner or User Access Administrator at the subscription. PIM role settings (8 h max activation, MFA,
    justification) are a one-time portal/Graph step (design §6.3) and are not changed here.
    Built-in role names only; GUIDs are resolved from the tenant with Get-AzRoleDefinition.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [object] $Config,
    [switch] $Execute,
    [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$subscriptionId = [string] $Config.subscription_id
if ($subscriptionId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Config.subscription_id is not a GUID.' }
$subScope = "/subscriptions/$subscriptionId"
$names = $Config.names
$groups = $Config.group_object_ids

function Get-LzPimPlan {
    [CmdletBinding()]
    param([object] $Config)
    $kvAzl = "$subScope/resourceGroups/$($names.rg_sec)/providers/Microsoft.KeyVault/vaults/$($names.kv_azl)"
    $rgAzl = "$subScope/resourceGroups/$($names.rg_azl)"
    # design §6.2 - eligible rows only
    @(
        @{ Group = 'grp_lab_operators'; Role = 'Owner'; Scope = $subScope }
        @{ Group = 'grp_azl_admins'; Role = 'Azure Stack HCI Administrator'; Scope = $subScope }
        @{ Group = 'grp_azl_admins'; Role = 'Reader'; Scope = $subScope }
        @{ Group = 'grp_azl_operators'; Role = 'Azure Stack HCI VM Contributor'; Scope = $subScope }
        @{ Group = 'grp_azl_operators'; Role = 'Reader'; Scope = $subScope }
        @{ Group = 'grp_azl_admins'; Role = 'Storage Account Contributor'; Scope = $rgAzl }
        @{ Group = 'grp_azl_admins'; Role = 'Key Vault Data Access Administrator'; Scope = $kvAzl }
        @{ Group = 'grp_azl_admins'; Role = 'Key Vault Secrets Officer'; Scope = $kvAzl }
        @{ Group = 'grp_azl_admins'; Role = 'Key Vault Contributor'; Scope = $kvAzl }
    ) | ForEach-Object { [pscustomobject]$_ }
}

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }

$plan = foreach ($item in (Get-LzPimPlan -Config $Config)) {
    if (-not $item.Scope.StartsWith($subScope, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing scope outside the subscription: $($item.Scope)" }
    $principalId = [string] $groups.($item.Group)
    if ([string]::IsNullOrWhiteSpace($principalId)) { throw "group_object_ids.$($item.Group) is empty - run New-LzEntraGroups.ps1 first." }
    $roleDef = Get-AzRoleDefinition -Name $item.Role
    if (-not $roleDef) { throw "Built-in role not found in this tenant: $($item.Role)" }
    $roleDefId = "$subScope/providers/Microsoft.Authorization/roleDefinitions/$($roleDef.Id)"
    $existing = Get-AzRoleEligibilitySchedule -Scope $item.Scope -Filter "principalId eq '$principalId'" -ErrorAction SilentlyContinue |
        Where-Object { $_.RoleDefinitionId -eq $roleDefId -and $_.Scope -eq $item.Scope } | Select-Object -First 1
    [pscustomobject]@{
        Group       = $item.Group
        Role        = $item.Role
        Scope       = $item.Scope
        PrincipalId = $principalId
        RoleDefId   = $roleDefId
        Exists      = [bool] $existing
        ScheduleId  = $existing ? $existing.Id : $null
        Action      = $Remove ? ($existing ? 'AdminRemove' : 'none') : ($existing ? 'none' : 'AdminAssign')
    }
}

$plan | Select-Object Group, Role, Scope, Exists, Action | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
$pending = @($plan | Where-Object Action -NE 'none')
if ($pending.Count -eq 0) { Write-Information 'Nothing to do.' -InformationAction Continue; return $plan }
if (-not $Execute) {
    Write-Warning "WhatIf (default): $($pending.Count) request(s) would be submitted. Re-run with -Execute."
    return $plan
}

foreach ($p in $pending) {
    $target = "$($p.Role) for $($p.Group) at $($p.Scope)"
    if ($PSCmdlet.ShouldProcess($target, "New-AzRoleEligibilityScheduleRequest ($($p.Action))")) {
        $request = @{
            Name             = (New-Guid).Guid
            Scope            = $p.Scope
            PrincipalId      = $p.PrincipalId
            RoleDefinitionId = $p.RoleDefId
            RequestType      = $p.Action
            Justification    = 'NIC26 Azure Local landing zone - PIM-eligible assignment (design §6.3)'
        }
        if ($p.Action -eq 'AdminAssign') {
            $request.ScheduleInfoStartDateTime = (Get-Date).ToUniversalTime()
            $request.ExpirationType = 'NoExpiration'
        }
        else {
            $request.TargetRoleEligibilityScheduleId = $p.ScheduleId
        }
        $null = Invoke-NIC26WithRetry -ScriptBlock { New-AzRoleEligibilityScheduleRequest @request } -MaxMinutes 5 -Activity 'PIM eligibility request'
    }
}
return $plan
