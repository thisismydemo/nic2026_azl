#Requires -Version 7.0
<#
.SYNOPSIS
    The live beat of outline §3.4: activates an ELIGIBLE Azure Local role for the signed-in IIC user (SelfActivate) with
    a justification; the role setting enforces MFA and the maximum duration. Default -WhatIf; -Execute submits.
.DESCRIPTION
    Runs under the DEMO USER's own Az context (not the operator's). Lists the user's eligible schedules at the
    subscription, picks -Role, submits New-AzRoleAssignmentScheduleRequest -RequestType SelfActivate with
    -ExpirationDuration (ISO 8601, default PT1H) and reports the request status (Provisioned / PendingApproval).
    The PIM audit entry is what the session shows afterwards.
.EXAMPLE
    .\Request-PimActivation.ps1 -SubscriptionId <id> -Role 'Azure Stack HCI Administrator' -Justification 'NIC 2026 live demo: node repair' -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Role,
    [string]$Justification = 'NIC 2026 session - Day-2 operations',
    [string]$Duration = 'PT1H',
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
if (-not $Execute) { $WhatIfPreference = $true }
Assert-Day2AzContext -SubscriptionId $SubscriptionId
$scope = "/subscriptions/$SubscriptionId"
$me = (Get-AzContext).Account
$eligible = @(Get-AzRoleEligibilitySchedule -Scope $scope -Filter 'asTarget()' | Where-Object { $_.RoleDefinitionDisplayName -eq $Role })
if ($eligible.Count -eq 0) { throw "No eligible '$Role' schedule for $($me.Id) at $scope (run Invoke-PimEligibility.ps1 -Action Apply first, and sign in as the IIC demo user)." }
$target = $eligible[0]
[pscustomobject]@{ User = $me.Id; Role = $Role; Scope = $scope; Duration = $Duration; Justification = $Justification } | Format-List | Out-String | Write-Information -InformationAction Continue
if (-not $Execute) { Write-Warning 'WhatIf (default): activation not submitted. Re-run with -Execute.'; return }
if ($PSCmdlet.ShouldProcess("$Role at $scope", 'SelfActivate')) {
    $req = New-AzRoleAssignmentScheduleRequest -Name (New-Guid).Guid -Scope $scope -PrincipalId $target.PrincipalId -RoleDefinitionId $target.RoleDefinitionId `
        -RequestType SelfActivate -Justification $Justification -ScheduleInfoStartDateTime (Get-Date).ToUniversalTime() -ExpirationDuration $Duration -ExpirationType AfterDuration
    Write-Day2Log -Message "Activation request $($req.Name): status $($req.Status)"
    return $req | Select-Object Name, Status, RoleDefinitionDisplayName, ScopeDisplayName, ExpirationDuration
}
