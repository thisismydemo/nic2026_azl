#Requires -Version 7.0
<#
.SYNOPSIS
Reports the read-only state of the Azure Local Day-2 controls.
.DESCRIPTION
Emits one row per selected control with Control, Status, Detail and Section properties. Only Applied means the control
matches its expected state; Removed, Partial and Unknown are all not ready. The script reads ARM and Entra only and
changes nothing. The control keys are the ones in automation/demo/azure-local/day2-controls.yml, which the demo scripts
Test-Day2Readiness, Reset-Day2Controls and Restore-Day2Controls read.
Authored by gpt-6-sol via the HCS Foundry gateway; reviewed by non-Anthropic models (design/shared/verification-log.md).
.PARAMETER Control
Optional control keys to report.
.PARAMETER AllowExample
Allow Get-Day2Inputs to fall back to a solution's example inputs (never for a real readiness run).
.PARAMETER InputRoot
Folder that holds the solution folders; defaults to the cluster-configure folder.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string[]]$Control,
    [switch]$AllowExample,
    [string]$InputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Day2.Common.ps1')

function Get-Day2Field {
    [OutputType([object])]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Day2RequiredText {
    [OutputType([string])]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-Day2Field -Object $Object -Name $Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Missing input: $Name."
    }
    return [string]$value
}

function Get-Day2OptionalArray {
    [OutputType([object[]])]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-Day2Field -Object $Object -Name $Name
    if ($null -eq $value) { return , @() }
    return , @($value)
}

function Get-Day2InputBoolean {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-Day2Field -Object $Inputs -Name $Name
    if ($null -eq $value) { return $true }
    if ($value -is [bool]) { return $value }
    throw "Invalid Boolean input: $Name."
}

function New-Day2Row {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object factory; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Control,
        [Parameter(Mandatory)][ValidateSet('Applied', 'Removed', 'Partial', 'Unknown')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [Parameter(Mandatory)][string]$Section
    )

    return [pscustomobject]@{
        Control = $Control
        Status  = $Status
        Detail  = $Detail
        Section = $Section
    }
}

function New-Day2CountRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object factory; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Control,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][int]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Missing
    )

    $status = if ($Expected -eq 0) {
        'Unknown'
    }
    else {
        Resolve-Day2State -Present ($Expected - $Missing.Count) -Expected $Expected
    }

    return New-Day2Row -Control $Control -Section $Section -Status $status -Detail ($Missing -join ', ')
}

function Get-Day2FailureDetail {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Message)

    $firstLine = ($Message -split '\r?\n', 2)[0]
    $firstLine = $firstLine -replace '(?i)\bBearer\s+\S+', 'Bearer [redacted]'
    $firstLine = $firstLine -replace '(?i)\b(token|password|secret|credential|authorization|api[_-]?key)\s*[:=]\s*\S+', '$1=[redacted]'
    return $firstLine
}

function Get-Day2NodeName {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Node)

    $name = if ($Node -is [string]) { $Node } else { [string](Get-Day2Field -Object $Node -Name 'name') }
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Missing input: nodes name.' }
    return $name
}

function Test-Day2InsightsState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_azl'
    $dcr = Get-Day2RequiredText -Object $names -Name 'dcr_insights'
    $cluster = Get-Day2RequiredText -Object $Inputs -Name 'cluster_name'
    $base = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
    $missing = [System.Collections.Generic.List[string]]::new()
    $expected = 1

    $amaPath = "$base/providers/Microsoft.AzureStackHCI/clusters/$cluster/arcSettings/default/extensions/AzureMonitorWindowsAgent?api-version=2023-08-01"
    $ama = Get-Day2Resource -Path $amaPath
    $amaState = Get-Day2Field -Object (Get-Day2Field -Object $ama -Name 'properties') -Name 'provisioningState'
    if ($amaState -ne 'Succeeded') { $missing.Add('AzureMonitorWindowsAgent') }

    foreach ($node in (Get-Day2OptionalArray -Object $Inputs -Name 'nodes')) {
        $nodeName = Get-Day2NodeName -Node $node
        $expected++
        $path = "$base/providers/Microsoft.HybridCompute/machines/$nodeName/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11"
        $response = Get-Day2Resource -Path $path
        $found = $false
        $value = Get-Day2Field -Object $response -Name 'value'
        if ($null -ne $value) {
            foreach ($association in @($value)) {
                $ruleId = [string](Get-Day2Field -Object (Get-Day2Field -Object $association -Name 'properties') -Name 'dataCollectionRuleId')
                if ($ruleId.EndsWith("/dataCollectionRules/$dcr", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $found = $true
                    break
                }
            }
        }
        if (-not $found) { $missing.Add($nodeName) }
    }

    return New-Day2CountRow -Control 'insights' -Section 'monitoring' -Expected $expected -Missing $missing.ToArray()
}

function Test-Day2MonitoringConfigState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_mon'
    $base = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers"
    $missing = [System.Collections.Generic.List[string]]::new()
    $expected = 0

    if (Get-Day2InputBoolean -Inputs $Inputs -Name 'enable_vm_insights_dcr') {
        $name = Get-Day2RequiredText -Object $names -Name 'dcr_vminsights'
        $expected++
        if ($null -eq (Get-Day2Resource -Path "$base/Microsoft.Insights/dataCollectionRules/${name}?api-version=2023-03-11")) {
            $missing.Add($name)
        }
    }

    foreach ($key in @('alert_node_down', 'alert_storage_health', 'alert_intent_drift', 'alert_capacity')) {
        $name = Get-Day2RequiredText -Object $names -Name $key
        $expected++
        if ($null -eq (Get-Day2Resource -Path "$base/Microsoft.Insights/scheduledQueryRules/${name}?api-version=2023-03-15-preview")) {
            $missing.Add($name)
        }
    }

    $name = Get-Day2RequiredText -Object $names -Name 'alert_kv_backup'
    $expected++
    if ($null -eq (Get-Day2Resource -Path "$base/Microsoft.AlertsManagement/actionRules/${name}?api-version=2021-08-08")) {
        $missing.Add($name)
    }

    return New-Day2CountRow -Control 'monitoring-config' -Section 'monitoring' -Expected $expected -Missing $missing.ToArray()
}

function Test-Day2UpdateManagerState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_mon'
    $configuration = Get-Day2RequiredText -Object $names -Name 'mc_azl'
    $assignment = Get-Day2RequiredText -Object $names -Name 'mc_azl_dynscope'
    $missing = [System.Collections.Generic.List[string]]::new()

    $configurationPath = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.Maintenance/maintenanceConfigurations/${configuration}?api-version=2023-04-01"
    if ($null -eq (Get-Day2Resource -Path $configurationPath)) {
        $missing.Add($configuration)
    }

    $assignmentPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Maintenance/configurationAssignments/${assignment}?api-version=2023-04-01"
    $resource = Get-Day2Resource -Path $assignmentPath
    $configurationId = [string](Get-Day2Field -Object (Get-Day2Field -Object $resource -Name 'properties') -Name 'maintenanceConfigurationId')
    if (-not $configurationId.EndsWith("/maintenanceConfigurations/$configuration", [System.StringComparison]::OrdinalIgnoreCase)) {
        $missing.Add($assignment)
    }

    return New-Day2CountRow -Control 'update-manager' -Section 'update-manager' -Expected 2 -Missing $missing.ToArray()
}

function Test-Day2BackupState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_bcdr'
    $vault = Get-Day2RequiredText -Object $names -Name 'rsv_azl'
    $name = Get-Day2RequiredText -Object $names -Name 'bkp_tier1'
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.RecoveryServices/vaults/$vault/backupPolicies/${name}?api-version=2023-02-01"
    $missing = @(if ($null -eq (Get-Day2Resource -Path $path)) { $name })
    return New-Day2CountRow -Control 'backup' -Section 'backup-asr' -Expected 1 -Missing $missing
}

function Test-Day2SiteRecoveryState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_bcdr'
    $vault = Get-Day2RequiredText -Object $names -Name 'rsv_azl'
    $name = Get-Day2RequiredText -Object $names -Name 'asrpol_tier1'
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.RecoveryServices/vaults/$vault/replicationPolicies/${name}?api-version=2023-02-01"
    $missing = @(if ($null -eq (Get-Day2Resource -Path $path)) { $name })
    return New-Day2CountRow -Control 'site-recovery' -Section 'backup-asr' -Expected 1 -Missing $missing
}

function Test-Day2PimAccessState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $scope = "/subscriptions/$SubscriptionId"
    $groups = Get-Day2Field -Object $Inputs -Name 'group_object_ids'
    $missing = [System.Collections.Generic.List[string]]::new()
    $expected = 0

    foreach ($assignment in (Get-Day2OptionalArray -Object $Inputs -Name 'pim_assignments')) {
        $group = Get-Day2RequiredText -Object $assignment -Name 'group'
        $role = Get-Day2RequiredText -Object $assignment -Name 'role'
        $id = [string](Get-Day2Field -Object $groups -Name $group)
        if ([string]::IsNullOrWhiteSpace($id) -or $id -eq '00000000-0000-0000-0000-000000000000') {
            throw "Placeholder or missing group ID: $group."
        }

        $definition = Get-AzRoleDefinition -Name $role
        if ($null -eq $definition -or [string]::IsNullOrWhiteSpace([string]$definition.Id)) {
            throw "Unknown role: $role."
        }

        $expected++
        $definitionId = "$scope/providers/Microsoft.Authorization/roleDefinitions/$($definition.Id)"
        $schedules = Get-AzRoleEligibilitySchedule -Scope $scope -Filter "principalId eq '$id'"
        $found = $false
        foreach ($schedule in @($schedules)) {
            if ($null -ne $schedule -and
                [string]$schedule.RoleDefinitionId -eq $definitionId -and
                [string]$schedule.Scope -eq $scope) {
                $found = $true
                break
            }
        }
        if (-not $found) { $missing.Add("${group}:$role") }
    }

    return New-Day2CountRow -Control 'pim-access' -Section 'access-pim' -Expected $expected -Missing $missing.ToArray()
}

function Test-Day2DefenderState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $plan = Get-Day2RequiredText -Object $Inputs -Name 'defender_servers_plan'
    if ($plan -notin @('P1', 'P2', 'off')) {
        throw 'Invalid input: defender_servers_plan.'
    }

    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01"
    $resource = Get-Day2Resource -Path $path
    if ($null -eq $resource) {
        return New-Day2Row -Control 'defender' -Section 'defender' -Status 'Unknown' -Detail 'VirtualMachines pricing not found'
    }

    $properties = Get-Day2Field -Object $resource -Name 'properties'
    $tier = [string](Get-Day2Field -Object $properties -Name 'pricingTier')
    $subPlan = [string](Get-Day2Field -Object $properties -Name 'subPlan')
    $detail = "tier=$tier; subPlan=$subPlan"

    $status = if ($plan -eq 'off' -and $tier -eq 'Free') {
        'Applied'
    }
    elseif ($plan -ne 'off' -and $tier -eq 'Standard' -and $subPlan -eq $plan) {
        'Applied'
    }
    elseif ($plan -ne 'off' -and $tier -eq 'Free') {
        'Removed'
    }
    elseif ($tier -eq 'Standard') {
        'Partial'
    }
    else {
        'Unknown'
    }

    return New-Day2Row -Control 'defender' -Section 'defender' -Status $status -Detail $detail
}

function Test-Day2PolicyBaselineState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $keys = [System.Collections.Generic.List[string]]::new()
    $keys.Add('asg_hybrid_baseline')
    $keys.Add('asg_akv_backup_ext')
    if (Get-Day2InputBoolean -Inputs $Inputs -Name 'assign_insights_policies') {
        $keys.Add('asg_insights_ama')
        $keys.Add('asg_insights_dcra')
    }

    $expectedMode = [string](Get-Day2Field -Object $Inputs -Name 'enforcement_mode')
    if ([string]::IsNullOrWhiteSpace($expectedMode)) { $expectedMode = 'Default' }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $keys) {
        $name = Get-Day2RequiredText -Object $names -Name $key
        $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments/${name}?api-version=2023-04-01"
        $assignment = Get-Day2Resource -Path $path
        $mode = [string](Get-Day2Field -Object (Get-Day2Field -Object $assignment -Name 'properties') -Name 'enforcementMode')
        if ($null -eq $assignment -or ($mode -and $mode -ne $expectedMode)) { $missing.Add($name) }
    }

    return New-Day2CountRow -Control 'policy-baseline' -Section 'policy' -Expected $keys.Count -Missing $missing.ToArray()
}

function Test-Day2WorkloadPlatformState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $names = Get-Day2Field -Object $Inputs -Name 'names'
    $rg = Get-Day2RequiredText -Object $names -Name 'rg_azl'
    $base = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.AzureStackHCI"
    $missing = [System.Collections.Generic.List[string]]::new()
    $imageStates = [System.Collections.Generic.List[string]]::new()
    $expected = 0

    foreach ($network in (Get-Day2OptionalArray -Object $Inputs -Name 'logical_networks')) {
        $name = Get-Day2RequiredText -Object $network -Name 'name'
        $expected++
        if ($null -eq (Get-Day2Resource -Path "$base/logicalNetworks/${name}?api-version=2025-02-01-preview")) {
            $missing.Add($name)
        }
    }

    foreach ($key in @('img_win11_avd', 'img_ws2025')) {
        $catalogName = Get-Day2Field -Object $names -Name $key
        if ([string]::IsNullOrWhiteSpace([string]$catalogName)) { continue }

        $name = [string]$catalogName
        $expected++
        $resource = Get-Day2Resource -Path "$base/marketplaceGalleryImages/${name}?api-version=2025-04-01-preview"
        if ($null -eq $resource) {
            $missing.Add($name)
            continue
        }

        $state = [string](Get-Day2Field -Object (Get-Day2Field -Object $resource -Name 'properties') -Name 'provisioningState')
        if ($state -ne 'Succeeded') {
            if ([string]::IsNullOrWhiteSpace($state)) { $state = 'Unknown' }
            $imageStates.Add("image $name $state")
        }
    }

    $storage = Get-Day2Field -Object $Inputs -Name 'storage'
    foreach ($storagePath in (Get-Day2OptionalArray -Object $storage -Name 'storage_paths')) {
        $name = Get-Day2RequiredText -Object $storagePath -Name 'name'
        $expected++
        if ($null -eq (Get-Day2Resource -Path "$base/storageContainers/${name}?api-version=2025-02-01-preview")) {
            $missing.Add($name)
        }
    }

    $row = New-Day2CountRow -Control 'workload-platform' -Section 'platform' -Expected $expected -Missing $missing.ToArray()
    if ($imageStates.Count -gt 0) {
        $detailParts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $missing) { $detailParts.Add($item) }
        foreach ($item in $imageStates) { $detailParts.Add($item) }
        if ($row.Status -eq 'Applied') { $row.Status = 'Partial' }
        $row.Detail = $detailParts -join ', '
    }
    return $row
}

if ($MyInvocation.InvocationName -ne '.') {
    $definitions = @(
        @{ Key = 'insights'; Section = 'monitoring'; Test = 'Test-Day2InsightsState' }
        @{ Key = 'monitoring-config'; Section = 'monitoring'; Test = 'Test-Day2MonitoringConfigState' }
        @{ Key = 'update-manager'; Section = 'update-manager'; Test = 'Test-Day2UpdateManagerState' }
        @{ Key = 'backup'; Section = 'backup-asr'; Test = 'Test-Day2BackupState' }
        @{ Key = 'site-recovery'; Section = 'backup-asr'; Test = 'Test-Day2SiteRecoveryState' }
        @{ Key = 'pim-access'; Section = 'access-pim'; Test = 'Test-Day2PimAccessState' }
        @{ Key = 'defender'; Section = 'defender'; Test = 'Test-Day2DefenderState' }
        @{ Key = 'policy-baseline'; Section = 'policy'; Test = 'Test-Day2PolicyBaselineState' }
        @{ Key = 'workload-platform'; Section = 'platform'; Test = 'Test-Day2WorkloadPlatformState' }
    )

    $root = if ([string]::IsNullOrWhiteSpace($InputRoot)) { Get-Day2ConfigureRoot } else { $InputRoot }

    foreach ($definition in $definitions) {
        if ($null -ne $Control -and $Control.Count -gt 0 -and $definition.Key -notin $Control) {
            continue
        }

        try {
            $solutionRoot = Join-Path -Path $root -ChildPath $definition.Section
            $inputs = Get-Day2Inputs -SolutionRoot $solutionRoot -AllowExample:$AllowExample
            $subscriptionId = Get-Day2RequiredText -Object $inputs -Name 'subscription_id'
            Assert-Day2AzContext -SubscriptionId $subscriptionId
            & $definition.Test -Inputs $inputs -SubscriptionId $subscriptionId
        }
        catch {
            New-Day2Row -Control $definition.Key -Section $definition.Section -Status 'Unknown' `
                -Detail (Get-Day2FailureDetail -Message $_.Exception.Message)
        }
    }
}
