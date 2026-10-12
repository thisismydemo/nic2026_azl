#Requires -Version 7.0
<#
.SYNOPSIS
    VM Insights for the workload VMs on the cluster (outline 3.1: the AVD session hosts and the SOFS nodes, D-048; the
    IIC servers): Azure Monitor Agent extension and the association with the VM Insights DCR (names.dcr_vminsights) on
    every Arc-enabled Azure Local VM selected by tag. Reads back. Reversible.
.DESCRIPTION
    Machines = Microsoft.HybridCompute/machines in the subscription carrying vm_insights_scope_tags (tag -> values, any
    value matches). An Arc machine with the AzureEdgeLifecycleManager extension is an Azure Local node and is skipped
    (the nodes use the Insights DCR). A machine whose agent is not Connected is skipped and reported. The AMA extension
    (publisher Microsoft.Azure.Monitor, type AzureMonitorWindowsAgent) is created only when missing; the association
    is named <machine>-vminsights-dcra. -Action Disable deletes the associations only. Default -WhatIf; -Execute changes.
.EXAMPLE
    .\Enable-VmInsights.ps1 -Action Enable             # plan
    .\Enable-VmInsights.ps1 -Action Enable -Execute    # apply + read back
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidateSet('Enable', 'Disable')][string]$Action,
    [string]$InputFile,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
if (-not $Execute) { $WhatIfPreference = $true }

[void](Import-Day2AutomationModule)
$inputs = Get-Day2Inputs -SolutionRoot (Join-Path $PSScriptRoot '..') -InputFile $InputFile
Assert-Day2AzContext -SubscriptionId $inputs.subscription_id
$sub = [string]$inputs.subscription_id
$dcrId = "/subscriptions/$sub/resourceGroups/$($inputs.names.rg_mon)/providers/Microsoft.Insights/dataCollectionRules/$($inputs.names.dcr_vminsights)"
if (-not ($inputs.PSObject.Properties.Name -contains 'vm_insights_scope_tags') -or @($inputs.vm_insights_scope_tags.PSObject.Properties).Count -eq 0) {
    Write-Day2Log -Message 'vm_insights_scope_tags is empty: no VM Insights association to manage.'
    return
}

$found = foreach ($p in $inputs.vm_insights_scope_tags.PSObject.Properties) {
    foreach ($value in @($p.Value)) { Get-AzResource -ResourceType 'Microsoft.HybridCompute/machines' -TagName $p.Name -TagValue ([string]$value) }
}
$machines = @($found | Sort-Object ResourceId -Unique)
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($m in $machines) {
    $api = '2024-07-10'
    $body = (Invoke-AzRestMethod -Path "$($m.ResourceId)?api-version=$api" -Method GET).Content | ConvertFrom-Json -Depth 30
    $ext = @(((Invoke-AzRestMethod -Path "$($m.ResourceId)/extensions?api-version=$api" -Method GET).Content | ConvertFrom-Json -Depth 30).value)
    if (@($ext | Where-Object { $_.name -eq 'AzureEdgeLifecycleManager' }).Count -gt 0) { $rows.Add([pscustomobject]@{ machine = $m.Name; ama = '-'; association = 'skipped (Azure Local node)' }); continue }
    $status = if ($body.properties.PSObject.Properties.Name -contains 'status') { [string]$body.properties.status } else { '' }
    $assocPath = "$($m.ResourceId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($m.Name)-vminsights-dcra?api-version=2023-03-11"
    $assoc = Invoke-AzRestMethod -Path $assocPath -Method GET
    $associated = ($assoc.StatusCode -eq 200)
    $ama = @($ext | Where-Object { $_.properties.type -eq 'AzureMonitorWindowsAgent' }) | Select-Object -First 1
    $amaState = if ($ama) { [string]$ama.properties.provisioningState } else { 'missing' }
    if ($Action -eq 'Enable') {
        if ($status -ne 'Connected') { $rows.Add([pscustomobject]@{ machine = $m.Name; ama = $amaState; association = "skipped (agent $status)" }); continue }
        if (-not $ama -and $PSCmdlet.ShouldProcess($m.Name, 'install AzureMonitorWindowsAgent')) {
            $b = @{ location = $body.location; properties = @{ publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorWindowsAgent'; autoUpgradeMinorVersion = $true; enableAutomaticUpgrade = $true } } | ConvertTo-Json -Depth 5
            $r = Invoke-AzRestMethod -Path "$($m.ResourceId)/extensions/AzureMonitorWindowsAgent?api-version=$api" -Method PUT -Payload $b
            if ($r.StatusCode -ge 400) { throw "AMA on $($m.Name) -> HTTP $($r.StatusCode)" }
            $amaState = 'installing'
        }
        if (-not $associated -and $PSCmdlet.ShouldProcess($m.Name, "associate $($inputs.names.dcr_vminsights)")) {
            $b = @{ properties = @{ dataCollectionRuleId = $dcrId; description = 'VM Insights for Azure Local VMs (outline 3.1).' } } | ConvertTo-Json -Depth 5
            $r = Invoke-AzRestMethod -Path $assocPath -Method PUT -Payload $b
            if ($r.StatusCode -ge 400) { throw "association on $($m.Name) -> HTTP $($r.StatusCode)" }
            $associated = $true
        }
    }
    elseif ($associated -and $PSCmdlet.ShouldProcess($m.Name, 'delete the VM Insights association')) {
        $r = Invoke-AzRestMethod -Path $assocPath -Method DELETE
        if ($r.StatusCode -ge 400 -and $r.StatusCode -ne 404) { throw "DELETE association on $($m.Name) -> HTTP $($r.StatusCode)" }
        $associated = $false
    }
    $rows.Add([pscustomobject]@{ machine = $m.Name; ama = $amaState; association = $(if ($associated) { 'associated' } else { 'none' }) })
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Information -InformationAction Continue
return $rows
