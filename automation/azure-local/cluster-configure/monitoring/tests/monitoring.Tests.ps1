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
