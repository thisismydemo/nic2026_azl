#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the PIM-eligible role assignments of the Azure Local landing zone (design section 6.2, section 6.3) idempotently.
.DESCRIPTION
    Default path for PIM (manage_pim_in_iac = false): roleEligibilityScheduleRequests are one-shot request objects that
    cannot be re-applied by IaC, so this script checks the existing eligibility schedules first and submits an
    AdminAssign request only for the missing ones. Default is -WhatIf; -Execute submits the requests.
    -Remove submits AdminRemove requests instead (the reversible Day-2 control, D-014).
    Scope is always inside -SubscriptionId; the script refuses any scope outside it.
    Missing eligibilities use the duration allowed by their role-management policy. NIC26_PIM_ELIGIBILITY_DURATION
    can request a shorter ISO 8601 duration; an invalid or excessive duration is rejected before any request is sent.
    Service errors terminate the run. Existing eligibilities are preserved; read them back after execution to verify.
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
    Requires Az.Resources >= 6 (Get-AzRoleEligibilitySchedule and role-management policy commands), Invoke-AzRestMethod and an Az context
    holding Owner or User Access Administrator at the subscription. PIM role settings (8 h max activation, MFA,
    justification) are a one-time portal/Graph step (design section 6.3) and are not changed here.
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

function Get-LzEligibilityDuration {
    [CmdletBinding()]
    param([string] $Scope, [string] $RoleDefinitionId)
    $roleId = ($RoleDefinitionId -split '/')[-1]
    $assignments = @(Get-AzRoleManagementPolicyAssignment -Scope $Scope -ErrorAction Stop |
        Where-Object { ($_.RoleDefinitionId -split '/')[-1] -eq $roleId })
    if ($assignments.Count -ne 1) { throw 'Cannot resolve one applicable PIM role-management policy.' }
    $policyId = [string] $assignments[0].PolicyId
    $policyScope = $policyId -replace '/providers/Microsoft.Authorization/roleManagementPolicies/[^/]+$', ''
    $policy = Get-AzRoleManagementPolicy -Scope $policyScope -Name (($policyId -split '/')[-1]) -ErrorAction Stop
    $rules = @($policy.Rule | Where-Object Id -EQ 'Expiration_Admin_Eligibility')
    if ($rules.Count -ne 1 -or -not $rules[0].MaximumDuration) { throw 'PIM eligibility expiry policy is missing.' }
    $maximum = [string] $rules[0].MaximumDuration
    $duration = if ($env:NIC26_PIM_ELIGIBILITY_DURATION) { $env:NIC26_PIM_ELIGIBILITY_DURATION } else { $maximum }
    try {
        $requested = [System.Xml.XmlConvert]::ToTimeSpan($duration)
        $limit = [System.Xml.XmlConvert]::ToTimeSpan($maximum)
    }
    catch { throw 'PIM eligibility duration must be a valid ISO 8601 duration.' }
    if ($requested -le [timespan]::Zero -or $requested -gt $limit) { throw 'PIM eligibility duration exceeds the policy or is not positive.' }
    return $duration
}

function Get-LzPimPlan {
    [CmdletBinding()]
    param([object] $Config)
    $subScope = "/subscriptions/$($Config.subscription_id)"
    $names = $Config.names
    $kvAzl = "$subScope/resourceGroups/$($names.rg_sec)/providers/Microsoft.KeyVault/vaults/$($names.kv_azl)"
    $rgAzl = "$subScope/resourceGroups/$($names.rg_azl)"
    # design section 6.2 - eligible rows only
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
    $existing = Get-AzRoleEligibilitySchedule -Scope $item.Scope -Filter "principalId eq '$principalId'" -ErrorAction Stop |
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
        Duration    = if (-not $Remove -and -not $existing) { Get-LzEligibilityDuration -Scope $item.Scope -RoleDefinitionId $roleDefId } else { $null }
    }
}

$plan | Select-Object Group, Role, Scope, Exists, Action, Duration | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
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
            Justification    = 'NIC26 Azure Local landing zone - PIM-eligible assignment (design section 6.3)'
        }
        if ($p.Action -eq 'AdminAssign') {
            $request.ScheduleInfoStartDateTime = (Get-Date).ToUniversalTime()
            $request.ExpirationType = 'AfterDuration'
            $request.ExpirationDuration = $p.Duration
        }
        else {
            $request.TargetRoleEligibilityScheduleId = $p.ScheduleId
        }
        $null = Invoke-NIC26WithRetry -MaxMinutes 5 -Activity 'PIM eligibility request' -ScriptBlock {
            # The Az expanded cmdlet rejected valid groups while this exact ARM payload succeeded.
            $properties = @{
                principalId = $request.PrincipalId
                roleDefinitionId = $request.RoleDefinitionId
                requestType = $request.RequestType
                justification = $request.Justification
            }
            if ($request.RequestType -eq 'AdminAssign') {
                $properties.scheduleInfo = @{
                    startDateTime = ([datetimeoffset]$request.ScheduleInfoStartDateTime).ToUniversalTime().ToString('o')
                    expiration = @{ type = $request.ExpirationType; duration = $request.ExpirationDuration }
                }
            }
            else { $properties.targetRoleEligibilityScheduleId = $request.TargetRoleEligibilityScheduleId }
            $path = "$($request.Scope)/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/$($request.Name)?api-version=2020-10-01"
            $payload = @{ properties = $properties } | ConvertTo-Json -Depth 8 -Compress
            $response = Invoke-AzRestMethod -Method PUT -Path $path -Payload $payload -ErrorAction Stop
            $http = [int]$response.StatusCode
            $data = $response.Content | ConvertFrom-Json -AsHashtable
            if ($http -lt 200 -or $http -ge 300) {
                $code = 'Unknown'
                if ($data.ContainsKey('error') -and $data.error.code -match '^[A-Za-z0-9_.-]+$') { $code = $data.error.code }
                throw "HTTP $http PIM eligibility request failed: $code"
            }
            if (-not $data.ContainsKey('properties') -or -not $data.properties.ContainsKey('status')) { throw 'PIM response has no request status.' }
            $status = [string]$data.properties.status
            if ($status -notmatch '^[A-Za-z][A-Za-z0-9_-]*$' -or $status -in @('Denied', 'Failed', 'Canceled')) { throw 'PIM eligibility request returned an unsuccessful status.' }
            Write-Information "PIM eligibility request status: $status" -InformationAction Continue
        }
    }
}
return $plan
