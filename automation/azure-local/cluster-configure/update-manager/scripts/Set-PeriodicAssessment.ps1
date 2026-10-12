#Requires -Version 7.0
<#
.SYNOPSIS
    Turns on Azure Update Manager periodic assessment (every 24 hours, no install) on the machines the dynamic scope
    selects, and sets the Azure VM prerequisite for schedule patching (T-5.4.2). Reads back.
.DESCRIPTION
    Machines = the solution's dynamic-scope filter (dynamic_scope_tags, dynamic_scope_resource_types,
    dynamic_scope_os_types) in the subscription. For each:
      - Arc-enabled server (Azure Local VM): patchSettings.assessmentMode = AutomaticByPlatform
        (Learn: Enable periodic assessment - Arc-enabled servers, REST PATCH on Microsoft.HybridCompute/machines);
      - Azure VM: assessmentMode = AutomaticByPlatform, patchMode stays AutomaticByPlatform and
        automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule = true, the prerequisite for a maintenance
        configuration schedule (Learn: Configure schedule patching on Azure VMs for business continuity). With it the
        platform no longer patches the VM on its own; only the maintenance window does.
    Guard: an Arc machine that carries the AzureEdgeLifecycleManager extension is an Azure Local node and is never
    touched (the cluster is updated through solution updates). Assessment only reads; nothing installs or reboots.
    Default -WhatIf; -Execute changes Azure.
.EXAMPLE
    .\Set-PeriodicAssessment.ps1             # list what would change
    .\Set-PeriodicAssessment.ps1 -Execute    # apply and read back
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param([string]$InputFile, [switch]$Execute)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
if (-not $Execute) { $WhatIfPreference = $true }

[void](Import-Day2AutomationModule)
$inputs = Get-Day2Inputs -SolutionRoot (Join-Path $PSScriptRoot '..') -InputFile $InputFile
Assert-Day2AzContext -SubscriptionId $inputs.subscription_id
$types = @($inputs.dynamic_scope_resource_types | ForEach-Object { ([string]$_).ToLowerInvariant() })
$osTypes = @($inputs.dynamic_scope_os_types)
$tagFilter = if ($inputs.PSObject.Properties.Name -contains 'assessment_scope_tags' -and @($inputs.assessment_scope_tags.PSObject.Properties).Count -gt 0) { $inputs.assessment_scope_tags } else { $inputs.dynamic_scope_tags }

function Get-Path {
    # Safe nested read under StrictMode: returns $null when any segment is missing.
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Path)
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur -or -not ($cur.PSObject.Properties.Name -contains $seg)) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}

$candidates = foreach ($p in $tagFilter.PSObject.Properties) {
    foreach ($value in @($p.Value)) { Get-AzResource -TagName $p.Name -TagValue ([string]$value) }
}
$machines = @($candidates | Where-Object { $types -contains $_.ResourceType.ToLowerInvariant() } | Sort-Object ResourceId -Unique)

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($m in $machines) {
    $isArc = $m.ResourceType -eq 'Microsoft.HybridCompute/machines'
    $api = if ($isArc) { '2024-07-10' } else { '2024-07-01' }
    $body = (Invoke-AzRestMethod -Path "$($m.ResourceId)?api-version=$api" -Method GET).Content | ConvertFrom-Json -Depth 50
    $os = if (-not $isArc) { [string](Get-Path $body 'properties.storageProfile.osDisk.osType') }
    elseif (Get-Path $body 'properties.osType') { [string](Get-Path $body 'properties.osType') }
    elseif ([string](Get-Path $body 'properties.osName') -match 'windows') { 'Windows' }
    else { 'unknown (agent not reporting)' }
    if ($osTypes.Count -gt 0 -and -not ($osTypes | Where-Object { $_ -ieq $os })) { $rows.Add([pscustomobject]@{ machine = $m.Name; kind = $m.ResourceType; state = "skipped (os $os)" }); continue }
    if ($isArc) {
        $ext = (Invoke-AzRestMethod -Path "$($m.ResourceId)/extensions?api-version=$api" -Method GET).Content | ConvertFrom-Json -Depth 20
        if (@($ext.value | Where-Object { $_.name -eq 'AzureEdgeLifecycleManager' }).Count -gt 0) { $rows.Add([pscustomobject]@{ machine = $m.Name; kind = 'Azure Local node'; state = 'skipped (cluster node: solution updates only)' }); continue }
        $current = Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.assessmentMode'
        $patch = @{ properties = @{ osProfile = @{ windowsConfiguration = @{ patchSettings = @{ assessmentMode = 'AutomaticByPlatform' } } } } }
        $needs = ($current -ne 'AutomaticByPlatform')
    }
    else {
        $bypass = [bool](Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule')
        $hotpatch = [bool](Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.enableHotpatching')
        if ($hotpatch) {
            # Hotpatch requires the platform safety checks (bypass must stay false, HTTP 400 on 12 Oct), so a hotpatch VM
            # cannot follow a maintenance-configuration schedule: only periodic assessment is set; the platform orchestrates it.
            $needs = ((Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.assessmentMode') -ne 'AutomaticByPlatform')
            $patch = @{ properties = @{ osProfile = @{ windowsConfiguration = @{ patchSettings = @{ assessmentMode = 'AutomaticByPlatform' } } } } }
        }
        else {
            $needs = ((Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.assessmentMode') -ne 'AutomaticByPlatform' -or (Get-Path $body 'properties.osProfile.windowsConfiguration.patchSettings.patchMode') -ne 'AutomaticByPlatform' -or -not $bypass)
            $patch = @{ properties = @{ osProfile = @{ windowsConfiguration = @{ patchSettings = @{ assessmentMode = 'AutomaticByPlatform'; patchMode = 'AutomaticByPlatform'; automaticByPlatformSettings = @{ bypassPlatformSafetyChecksOnUserSchedule = $true } } } } } }
        }
    }
    $state = 'compliant'
    if ($needs) {
        if ($PSCmdlet.ShouldProcess($m.Name, 'periodic assessment AutomaticByPlatform')) {
            $r = Invoke-AzRestMethod -Path "$($m.ResourceId)?api-version=$api" -Method PATCH -Payload ($patch | ConvertTo-Json -Depth 10)
            if ($r.StatusCode -ge 400) { throw "PATCH $($m.Name) -> HTTP $($r.StatusCode): $($r.Content)" }
            $state = "set (HTTP $($r.StatusCode))"
        }
        else { $state = 'would set' }
    }
    $rows.Add([pscustomobject]@{ machine = $m.Name; kind = $m.ResourceType; state = $state })
}

if ($Execute) {
    foreach ($row in @($rows | Where-Object { $_.state -like 'set*' -or $_.state -eq 'compliant' })) {
        $m = $machines | Where-Object Name -EQ $row.machine | Select-Object -First 1
        $api = if ($m.ResourceType -eq 'Microsoft.HybridCompute/machines') { '2024-07-10' } else { '2024-07-01' }
        $b = (Invoke-AzRestMethod -Path "$($m.ResourceId)?api-version=$api" -Method GET).Content | ConvertFrom-Json -Depth 50
        $row.state = "$($row.state); read back assessmentMode=$(Get-Path $b 'properties.osProfile.windowsConfiguration.patchSettings.assessmentMode')"
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Information -InformationAction Continue
return $rows
