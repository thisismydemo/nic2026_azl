#Requires -Version 7.0
# Pester 5 — cluster-configure/monitoring gates via the shared kit.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-monitoring' `
    -RequiredInputs 'cluster_name', 'nodes', 'log_analytics_workspace_id', 'action_group_id' `
    -EntryScripts 'Invoke-MonitoringConfigure.ps1'

Describe 'monitoring specifics' {
    It 'pins the confirmed AVM modules and the documented Insights streams' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $b | Should -Match 'br/public:avm/res/insights/data-collection-rule:0\.11\.0'
        $b | Should -Match 'br/public:avm/res/insights/scheduled-query-rule:0\.6\.0'
        $b | Should -Match 'RDMA Activity\(\*\)\\\\RDMA Inbound Bytes/sec'
        $b | Should -Match 'microsoft-windows-sddc-management/operational'
    }
    It 'Insights enable script uses the supported extension type and refuses to author the DCR' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\scripts\Enable-ClusterInsights.ps1') -Raw
        $t | Should -Match 'AzureMonitorWindowsAgent'
        $t | Should -Match 'arcSettings/default/extensions'
        $t | Should -Match 'dataCollectionRuleAssociations'
        $t | Should -Match "ValidateSet\('Enable', 'Disable'\)"
        $t | Should -Match 'SupportsShouldProcess'
    }
    It 'the four alert rules and the Key Vault routing rule are named from the catalog' {
        $m = Get-Content (Join-Path $PSScriptRoot '..\solution.yml') -Raw
        foreach ($k in 'alert_node_down', 'alert_storage_health', 'alert_intent_drift', 'alert_capacity', 'alert_kv_backup') { $m | Should -Match $k }
    }
}

Describe 'Day-2 build 12 Oct (D-054): workspace, Insights DCR shape, recommended and health alerts' {
    It 'Bicep and Terraform create the lab workspace only behind create_workspace and author the Insights DCR in the dialog shape' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $t = Get-Content (Join-Path $PSScriptRoot '..\terraform\main.tf') -Raw
        $b | Should -Match "Microsoft.OperationalInsights/workspaces@[0-9-]+' = if \(create_workspace\)"
        $t | Should -Match 'count\s+= var\.create_workspace \? 1 : 0'
        foreach ($x in $b, $t) {
            $x | Should -Match 'perfCounterDataSource'
            $x | Should -Match 'eventLogsDataSource'
            $x | Should -Match 'insights_extra_event_channels'
        }
    }
    It 'the six Learn recommended metric alerts and the health routing rule are in both tracks and named from the catalog' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $t = Get-Content (Join-Path $PSScriptRoot '..\terraform\main.tf') -Raw
        $m = Get-Content (Join-Path $PSScriptRoot '..\solution.yml') -Raw
        foreach ($k in 'alert_cpu', 'alert_memory', 'alert_vol_read_latency', 'alert_vol_write_latency', 'alert_net_in', 'alert_net_out', 'alert_health_routing') {
            $m | Should -Match $k; $b | Should -Match $k; $t | Should -Match $k
        }
        $b | Should -Match 'Microsoft.Insights/metricAlerts@'
        $t | Should -Match 'azurerm_monitor_metric_alert'
    }
    It 'Enable-ClusterInsights installs the health-alerts extension with the portal publisher and type' {
        $s = Get-Content (Join-Path $PSScriptRoot '..\scripts\Enable-ClusterInsights.ps1') -Raw
        $s | Should -Match 'AzureEdgeAlerts'
        $s | Should -Match "Microsoft\.AzureStack\.HCI\.Alerts"
        $s | Should -Match "AlertsForWindowsHCI"
    }
}

Describe 'node-down rule looks back far enough (review R-35)' {
    It 'Bicep and Terraform give the node-down rule a one-hour window and every rule a Computer dimension' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $t = Get-Content (Join-Path $PSScriptRoot '..\terraform\main.tf') -Raw
        $b | Should -Match "windowSize: 'PT1H'"
        $b | Should -Match 'windowSize: r\.windowSize'
        $b | Should -Not -Match 'dimensions: \[\]'
        $t | Should -Match 'window\s+= "PT1H"'
        $t | Should -Match 'try\(each\.value\.window, var\.alert_window_size\)'
        $t | Should -Not -Match 'dimension\s+= null'
    }
    It 'the heartbeat threshold is bounded so the one-hour look-back always contains it' {
        (Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw) | Should -Match '@minValue\(5\)\s+@maxValue\(45\)\s+param node_heartbeat_minutes'
        (Get-Content (Join-Path $PSScriptRoot '..\terraform\variables.tf') -Raw) | Should -Match 'node_heartbeat_minutes >= 5 && var\.node_heartbeat_minutes <= 45'
    }
}
