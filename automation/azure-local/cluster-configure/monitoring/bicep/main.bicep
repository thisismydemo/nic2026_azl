// NIC 2026 — Day-2 Ready 3.1 monitoring (cluster-configure/monitoring), Bicep track. Resource-group scope: names.rg_mon.
// AVM (confirmed on MCR 2026-10-03): avm/res/insights/data-collection-rule:0.11.0, avm/res/insights/scheduled-query-rule:0.6.0.
// Gap-fill: Microsoft.AlertsManagement/actionRules@2021-08-08 (alert processing rule; no AVM module).
// The Insights DCR (dcr_insights) is created ONCE through the Insights dialog (design §7.2 A); the association to the
// nodes is scripts/Enable-ClusterInsights.ps1. manage_insights_dcr_in_iac=true authors it here with the documented
// five counters and two channels (Learn: Monitor a single Azure Local system with Insights) — against Microsoft's
// recommendation, documented in the README.
targetScope = 'resourceGroup'

param subscription_id string
param location string
param tags object
#disable-next-line no-unused-params
param cluster_name string
#disable-next-line no-unused-params
param nodes array
param log_analytics_workspace_id string = ''
param action_group_id string = ''
param alert_evaluation_frequency string = 'PT5M'
param alert_window_size string = 'PT15M'
@minValue(5)
@maxValue(45)
param node_heartbeat_minutes int = 10
param enable_vm_insights_dcr bool = true
param manage_insights_dcr_in_iac bool = false
param names object

var lawId = empty(log_analytics_workspace_id) ? resourceId(subscription_id, names.rg_mon, 'Microsoft.OperationalInsights/workspaces', names.law) : log_analytics_workspace_id
var agId = empty(action_group_id) ? resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/actionGroups', names.ag_ops) : action_group_id
var clusterRgId = resourceId(subscription_id, 'Microsoft.Resources/resourceGroups', names.rg_azl)
var allTags = union(tags, { 'managed-by': 'bicep' })
var insightsDcrId = resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/dataCollectionRules', names.dcr_insights)

// ---------------------------------------------------------------- Azure Local Insights DCR (optional, documented streams)
module insightsDcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = if (manage_insights_dcr_in_iac) {
  name: 'monitoring-dcr-insights'
  params: {
    name: names.dcr_insights
    location: location
    tags: allTags
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'Azure Local Insights (cost-conscious): five counters + health and SDDC channels (design §7.2).'
      dataSources: {
        performanceCounters: [
          {
            name: 'AzureStackHCI-Perf'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: [
              '\\Memory\\Available Bytes'
              '\\Network Interface(*)\\Bytes Total/sec'
              '\\Processor(_Total)\\% Processor Time'
              '\\RDMA Activity(*)\\RDMA Inbound Bytes/sec'
              '\\RDMA Activity(*)\\RDMA Outbound Bytes/sec'
            ]
          }
        ]
        windowsEventLogs: [
          {
            name: 'AzureStackHCI-Events'
            streams: ['Microsoft-Event']
            xPathQueries: [
              'microsoft-windows-health/operational!*'
              'microsoft-windows-sddc-management/operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]'
            ]
          }
        ]
      }
      destinations: {
        logAnalytics: [{ name: 'law', workspaceResourceId: lawId }]
      }
      dataFlows: [
        { streams: ['Microsoft-Perf', 'Microsoft-Event'], destinations: ['law'] }
      ]
    }
  }
}

// ---------------------------------------------------------------- VM Insights DCR for the workload VMs (Arc)
module vmInsightsDcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = if (enable_vm_insights_dcr) {
  name: 'monitoring-dcr-vminsights'
  params: {
    name: names.dcr_vminsights
    location: location
    tags: allTags
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'VM Insights for Azure Local VMs (InsightsMetrics + dependency map).'
      dataSources: {
        performanceCounters: [
          {
            name: 'VMInsightsPerfCounters'
            streams: ['Microsoft-InsightsMetrics']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: ['\\VmInsights\\DetailedMetrics']
          }
        ]
        extensions: [
          {
            name: 'DependencyAgentDataSource'
            streams: ['Microsoft-ServiceMap']
            extensionName: 'DependencyAgent'
            extensionSettings: {}
          }
        ]
      }
      destinations: {
        logAnalytics: [{ name: 'VMInsightsPerf-Logs-Dest', workspaceResourceId: lawId }]
      }
      dataFlows: [
        { streams: ['Microsoft-InsightsMetrics'], destinations: ['VMInsightsPerf-Logs-Dest'] }
        { streams: ['Microsoft-ServiceMap'], destinations: ['VMInsightsPerf-Logs-Dest'] }
      ]
    }
  }
}

// ---------------------------------------------------------------- alert rules (outline §3.1: faults section 4 shows)
var alertRules = [
  {
    key: 'alert_node_down'
    description: 'Azure Local node without AMA heartbeat (node failure demo, outline §4.2).'
    severity: 1
    query: 'Heartbeat | where ResourceType =~ "machines" | summarize LastHeartbeat = max(TimeGenerated) by Computer, _ResourceId | where LastHeartbeat < ago(${node_heartbeat_minutes}m)'
    operator: 'GreaterThan'
    threshold: 0
    timeAggregation: 'Count'
    dimensions: [{ name: 'Computer', operator: 'Include', values: ['*'] }]
    // A node silent for longer than the window has no Heartbeat rows and would drop out of the result: look back one hour so it keeps firing
    // from node_heartbeat_minutes of silence until it has been down for an hour (node_heartbeat_minutes is capped at 45).
    windowSize: 'PT1H'
  }
  {
    key: 'alert_storage_health'
    description: 'Health Service fault (Warning/Error) in Microsoft-Windows-Health/Operational (drive failure demo).'
    severity: 1
    query: 'Event | where EventLog =~ "Microsoft-Windows-Health/Operational" | where EventLevelName in ("Warning", "Error") | summarize count() by Computer, EventID'
    operator: 'GreaterThan'
    threshold: 0
    timeAggregation: 'Count'
    dimensions: [{ name: 'Computer', operator: 'Include', values: ['*'] }]
    windowSize: alert_window_size
  }
  {
    key: 'alert_intent_drift'
    description: 'Network ATC intent drift / failed provisioning (channel added by Enable-ClusterInsights -ExtraEventChannels).'
    severity: 2
    query: 'Event | where EventLog =~ "Microsoft-Windows-Networking-NetworkATC/Operational" | where EventLevelName in ("Warning", "Error") | summarize count() by Computer, EventID'
    operator: 'GreaterThan'
    threshold: 0
    timeAggregation: 'Count'
    dimensions: [{ name: 'Computer', operator: 'Include', values: ['*'] }]
    windowSize: alert_window_size
  }
  {
    key: 'alert_capacity'
    description: 'Storage pool capacity threshold fault (capacity management, outline §4.3).'
    severity: 2
    query: 'Event | where EventLog =~ "Microsoft-Windows-Health/Operational" | where RenderedDescription has "Capacity" or RenderedDescription has "PoolCapacityThresholdExceeded" | summarize count() by Computer'
    operator: 'GreaterThan'
    threshold: 0
    timeAggregation: 'Count'
    dimensions: [{ name: 'Computer', operator: 'Include', values: ['*'] }]
    windowSize: alert_window_size
  }
]

module alert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = [for (r, i) in alertRules: {
  name: 'monitoring-alert-${i}'
  params: {
    name: names[r.key]
    location: location
    tags: allTags
    kind: 'LogAlert'
    alertDescription: r.description
    severity: r.severity
    enabled: true
    autoMitigate: true
    evaluationFrequency: alert_evaluation_frequency
    windowSize: r.windowSize
    scopes: [lawId]
    criterias: {
      allOf: [
        {
          query: r.query
          operator: r.operator
          threshold: r.threshold
          timeAggregation: r.timeAggregation
          dimensions: r.dimensions
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroupResourceIds: [agId]
    }
  }
}]

// ---------------------------------------------------------------- platform alerts KeyVaultAccess / KeyVaultDoesNotExist -> action group
resource kvBackupRouting 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: names.alert_kv_backup
  location: 'Global'
  tags: allTags
  properties: {
    enabled: true
    description: 'Routes the Azure Local Key Vault backup extension alerts (KeyVaultAccess, KeyVaultDoesNotExist) from the cluster resource group to the ops action group (landing-zone §7.2 alert_kv_backup).'
    scopes: [clusterRgId]
    conditions: [
      {
        field: 'AlertRuleName'
        operator: 'Contains'
        values: ['KeyVault']
      }
    ]
    actions: [
      {
        actionType: 'AddActionGroups'
        actionGroupIds: [agId]
      }
    ]
  }
}

output insights_dcr_id string = manage_insights_dcr_in_iac ? insightsDcr!.outputs.resourceId : insightsDcrId
output vm_insights_dcr_id string = enable_vm_insights_dcr ? vmInsightsDcr!.outputs.resourceId : ''
output alert_rule_ids array = [for i in range(0, length(alertRules)): alert[i].outputs.resourceId]
output kv_backup_processing_rule_id string = kvBackupRouting.id
output action_group_id string = agId
