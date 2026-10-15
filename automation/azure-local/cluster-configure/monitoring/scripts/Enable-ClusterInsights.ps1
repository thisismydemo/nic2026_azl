#Requires -Version 7.0
<#
.SYNOPSIS
    Enables or disables Insights for the Azure Local instance the SUPPORTED way, scripted (outline §3.1, design §7.2 A):
    Enable = Azure Monitor Agent extension on the cluster arcSettings + association of the Insights DCR to every node,
    plus (unless -SkipHealthAlerts) the AzureEdgeAlerts extension that turns on Azure Local health alerts (Learn:
    Respond to Azure Local health alerts using Azure Monitor alerts, step 1 - the portal tile installs this extension);
    Disable = delete the associations (exactly what the portal's "Disable Insights" does; data is kept).
.DESCRIPTION
    The Insights DCR (names.dcr_insights, resource group rg_mon) comes from Invoke-MonitoringConfigure.ps1 when
    manage_insights_dcr_in_iac is true (D-054: same shape as the dialog's DCR) or once from the Insights dialog;
    this script refuses to Enable while it does not exist.
    -ExtraEventChannels adds channels the fault demos need (for example Microsoft-Windows-Networking-NetworkATC/Operational)
    to the DCR's Microsoft-Event data source; -RemoveExtraEventChannels takes them out again (reversible, D-014).
    Resource shapes: Microsoft.AzureStackHCI/clusters/arcSettings/extensions@2023-08-01 (AzureMonitorWindowsAgent, from
    Learn "Enable Insights at scale using Azure policies") and Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11.
    Default -WhatIf; -Execute changes Azure. Idempotent.
.PARAMETER Action
    Enable | Disable
.EXAMPLE
    .\Enable-ClusterInsights.ps1 -Action Enable
    .\Enable-ClusterInsights.ps1 -Action Enable -ExtraEventChannels 'Microsoft-Windows-Networking-NetworkATC/Operational!*' -Execute
    .\Enable-ClusterInsights.ps1 -Action Disable -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Enable', 'Disable')][string]$Action,
    [string]$InputFile,
    [string[]]$ExtraEventChannels = @(),
    [switch]$RemoveExtraEventChannels,
    [switch]$SkipHealthAlerts,
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
$clusterId = "/subscriptions/$sub/resourceGroups/$($inputs.names.rg_azl)/providers/Microsoft.AzureStackHCI/clusters/$($inputs.cluster_name)"
$dcrId = "/subscriptions/$sub/resourceGroups/$($inputs.names.rg_mon)/providers/Microsoft.Insights/dataCollectionRules/$($inputs.names.dcr_insights)"
$amaPath = "$clusterId/arcSettings/default/extensions/AzureMonitorWindowsAgent?api-version=2023-08-01"
$alertsPath = "$clusterId/arcSettings/default/extensions/AzureEdgeAlerts?api-version=2023-08-01"
function Get-DcraName { param([Parameter(Mandatory)][string]$MachineName) return "$MachineName-dataCollectionRuleAssociations" }   # same name the Day-2 policy uses (details.name), so the policy finds this association and never creates a second one

function Invoke-Day2Put {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Body, [Parameter(Mandatory)][string]$What)
    if ($PSCmdlet.ShouldProcess($What, 'PUT')) {
        $r = Invoke-NIC26WithRetry -Activity "PUT $What" -MaxMinutes 5 -ScriptBlock { Invoke-AzRestMethod -Path $Path -Method PUT -Payload ($Body | ConvertTo-Json -Depth 20) }
        if ($r.StatusCode -ge 400) { throw "PUT $What -> HTTP $($r.StatusCode): $($r.Content)" }
        Write-Day2Log -Message "PUT $What -> HTTP $($r.StatusCode)"
    }
}
function Invoke-Day2Delete {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$What)
    if ($PSCmdlet.ShouldProcess($What, 'DELETE')) {
        $r = Invoke-AzRestMethod -Path $Path -Method DELETE
        if ($r.StatusCode -ge 400 -and $r.StatusCode -ne 404) { throw "DELETE $What -> HTTP $($r.StatusCode)" }
        Write-Day2Log -Message "DELETE $What -> HTTP $($r.StatusCode)"
    }
}

# --- current state (read-only) ------------------------------------------------------------------------------------
$dcr = Get-Day2Resource -Path "${dcrId}?api-version=2023-03-11"
$ama = Get-Day2Resource -Path $amaPath
$healthAlerts = Get-Day2Resource -Path $alertsPath
$assoc = foreach ($n in $inputs.nodes) {
    $machineId = "/subscriptions/$sub/resourceGroups/$($inputs.names.rg_azl)/providers/Microsoft.HybridCompute/machines/$($n.name)"
    $a = Get-Day2Resource -Path "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$(Get-DcraName $n.name)?api-version=2023-03-11"
    [pscustomobject]@{ Node = $n.name; MachineId = $machineId; DcraName = (Get-DcraName $n.name); Associated = [bool]$a -and ($a.properties.dataCollectionRuleId -eq $dcrId) }
}
[pscustomobject]@{
    InsightsDcrExists  = [bool]$dcr
    AmaExtensionState  = if ($ama) { $ama.properties.provisioningState } else { 'absent' }
    HealthAlertsState  = if ($healthAlerts) { $healthAlerts.properties.provisioningState } else { 'absent' }
    NodesAssociated    = @($assoc | Where-Object { $_.Associated }).Count
    NodesTotal         = @($assoc).Count
    Action             = $Action
} | Format-List | Out-String | Write-Information -InformationAction Continue

if ($Action -eq 'Enable') {
    if (-not $dcr) {
        throw "Insights DCR '$($inputs.names.dcr_insights)' not found in $($inputs.names.rg_mon). Run Invoke-MonitoringConfigure.ps1 -Action Apply -Execute with manage_insights_dcr_in_iac=true, or create it once through the portal (Azure Local resource > Capabilities > Insights > Get started > Create New, name $($inputs.names.dcr_insights)). Then re-run."
    }
    if (-not $ama -or $ama.properties.provisioningState -ne 'Succeeded') {
        Invoke-Day2Put -Path $amaPath -What "AzureMonitorWindowsAgent on $($inputs.cluster_name)" -Body @{
            properties = @{ extensionParameters = @{ publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorWindowsAgent'; autoUpgradeMinorVersion = $false; enableAutomaticUpgrade = $true } }
        }
    }
    if (-not $SkipHealthAlerts -and (-not $healthAlerts -or $healthAlerts.properties.provisioningState -ne 'Succeeded')) {
        # Same publisher/type the portal's Health alerts tile installs (AzureEdgeAlerts, AlertsForWindowsHCI).
        Invoke-Day2Put -Path $alertsPath -What "AzureEdgeAlerts (health alerts) on $($inputs.cluster_name)" -Body @{
            properties = @{ extensionParameters = @{ publisher = 'Microsoft.AzureStack.HCI.Alerts'; type = 'AlertsForWindowsHCI'; autoUpgradeMinorVersion = $false; enableAutomaticUpgrade = $true; settings = @{} } }
        }
    }
    foreach ($a in $assoc | Where-Object { -not $_.Associated }) {
        Invoke-Day2Put -Path "$($a.MachineId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($a.DcraName)?api-version=2023-03-11" -What "DCR association on $($a.Node)" -Body @{
            properties = @{ dataCollectionRuleId = $dcrId; description = 'Azure Local Insights (Day-2 Ready 3.1). Deleting this association disables Insights for this node.' }
        }
    }
    if ($ExtraEventChannels.Count -gt 0) {
        $events = @($dcr.properties.dataSources.windowsEventLogs)
        if ($events.Count -eq 0) { throw 'The Insights DCR has no windowsEventLogs data source to extend.' }
        $current = @($events[0].xPathQueries)
        $missing = @($ExtraEventChannels | Where-Object { $current -notcontains $_ })
        if ($missing.Count -gt 0) {
            $events[0].xPathQueries = @($current + $missing)
            $dcr.properties.dataSources.windowsEventLogs = $events
            Invoke-Day2Put -Path "${dcrId}?api-version=2023-03-11" -What "extra event channels on $($inputs.names.dcr_insights): $($missing -join ', ')" -Body @{ location = $dcr.location; kind = $dcr.kind; tags = $dcr.tags; properties = $dcr.properties }
        }
        else { Write-Day2Log -Message 'Extra event channels already present.' }
    }
}
else {
    foreach ($a in $assoc | Where-Object { $_.Associated }) {
        Invoke-Day2Delete -Path "$($a.MachineId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($a.DcraName)?api-version=2023-03-11" -What "DCR association on $($a.Node)"
    }
    if ($RemoveExtraEventChannels -and $dcr -and $ExtraEventChannels.Count -gt 0) {
        $events = @($dcr.properties.dataSources.windowsEventLogs)
        $events[0].xPathQueries = @($events[0].xPathQueries | Where-Object { $ExtraEventChannels -notcontains $_ })
        $dcr.properties.dataSources.windowsEventLogs = $events
        Invoke-Day2Put -Path "${dcrId}?api-version=2023-03-11" -What "remove extra event channels from $($inputs.names.dcr_insights)" -Body @{ location = $dcr.location; kind = $dcr.kind; tags = $dcr.tags; properties = $dcr.properties }
    }
    Write-Day2Log -Message 'The AMA extension stays installed (the portal flow keeps it too); existing data is kept in the workspace.'
}
if (-not $Execute) { Write-Warning "WhatIf (default): no change made. Re-run with -Execute." }
