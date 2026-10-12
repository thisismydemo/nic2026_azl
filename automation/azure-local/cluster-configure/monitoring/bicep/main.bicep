// NIC 2026 — Day-2 Ready 3.1 monitoring (cluster-configure/monitoring), Bicep track. Resource-group scope: names.rg_mon.
// AVM (confirmed on MCR 2026-10-03): avm/res/insights/data-collection-rule:0.11.0, avm/res/insights/scheduled-query-rule:0.6.0.
// Gap-fill: Microsoft.AlertsManagement/actionRules@2021-08-08 (alert processing rule; no AVM module),
// Microsoft.OperationalInsights/workspaces@2025-02-01 and Microsoft.Insights/metricAlerts@2018-03-01 (native resources).
// The Insights DCR (dcr_insights): manage_insights_dcr_in_iac=true authors it here in the exact shape the Insights
// dialog creates (perfCounterDataSource, five counters at 10 s; eventLogsDataSource with the health and SDDC 3000-3004
// channels; Learn: Monitor a single Azure Local system with Insights), plus insights_extra_event_channels. The node
// associations, the AMA and health-alert extensions are scripts/Enable-ClusterInsights.ps1 (12 Oct, D-054).
// create_workspace=true creates the nic26 lab workspace names.law (design §7.1; D-054) instead of using
// log_analytics_workspace_id.
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
@description('Create the lab workspace names.law in rg_mon (D-054). When false, log_analytics_workspace_id (or the derived ID) is used.')
param create_workspace bool = false
param law_retention_days int = 30
param law_daily_cap_gb int = 2
@description('Extra event channels (XPath) added to the Insights DCR, for example the Network ATC channel the intent-drift alert reads.')
param insights_extra_event_channels array = []
@description('Sampling interval of the five Insights counters (the Insights dialog uses 10 s).')
param insights_sampling_seconds int = 10
@description('Create the Learn recommended metric alert rules on the cluster resource (Enable recommended alert rules for Azure Local).')
param enable_recommended_metric_alerts bool = true
@description('Route the Azure Local health alerts (AzureEdgeAlerts extension) on the cluster to the action group.')
param enable_health_alert_routing bool = true
@description('VM Insights selection, used by scripts/Enable-VmInsights.ps1 (declared because the converters render every input).')
#disable-next-line no-unused-params
param vm_insights_scope_tags object = {}
param names object

var derivedLawId = resourceId(subscription_id, names.rg_mon, 'Microsoft.OperationalInsights/workspaces', names.law)
var lawId = create_workspace ? derivedLawId : (empty(log_analytics_workspace_id) ? derivedLawId : log_analytics_workspace_id)
var clusterId = resourceId(subscription_id, names.rg_azl, 'Microsoft.AzureStackHCI/clusters', cluster_name)
var agId = empty(action_group_id) ? resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/actionGroups', names.ag_ops) : action_group_id
var clusterRgId = resourceId(subscription_id, 'Microsoft.Resources/resourceGroups', names.rg_azl)
var allTags = union(tags, { 'managed-by': 'bicep' })
var insightsDcrId = resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/dataCollectionRules', names.dcr_insights)

// ---------------------------------------------------------------- nic26 lab workspace (optional, D-054)
resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = if (create_workspace) {
  name: names.law
  location: location
  tags: allTags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: law_retention_days
    workspaceCapping: { dailyQuotaGb: law_daily_cap_gb }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------- Azure Local Insights DCR (optional, documented streams)
module insightsDcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = if (manage_insights_dcr_in_iac) {
  name: 'monitoring-dcr-insights'
  params: {
    name: names.dcr_insights
    location: location
    tags: allTags
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'Azure Local Insights: the five counters and the health and SDDC channels the Insights dialog configures, plus the demo channels (design §7.2, D-054).'
      dataSources: {
        performanceCounters: [
          {
            name: 'perfCounterDataSource'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: insights_sampling_seconds
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
            name: 'eventLogsDataSource'
            streams: ['Microsoft-Event']
            xPathQueries: concat([
              'Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]'
              'microsoft-windows-health/operational!*'
            ], insights_extra_event_channels)
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
  dependsOn: [law]
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
  dependsOn: [law]
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
    description: 'Network ATC intent drift / failed provisioning (Network ATC channel in the Insights DCR, D-054).'
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
  dependsOn: [law]
}]

// ---------------------------------------------------------------- recommended metric alerts on the cluster resource
// Learn: Enable recommended alert rules for Azure Local (table "Recommended alert rules"); metric names as the
// Microsoft.AzureStackHCI/clusters metric definitions return them (read live 12 Oct). Thresholds in the metric's unit.
var metricAlerts = [
  { key: 'alert_cpu', metric: 'Hyper-V Hypervisor Logical Processor\\% Total Run Time', op: 'GreaterThan', threshold: 80, text: 'Percentage CPU above 80 % (recommended alert rule)' }
  { key: 'alert_memory', metric: 'Memory\\Available Bytes', op: 'LessThan', threshold: 1073741824, text: 'Available memory below 1 GB (recommended alert rule)' }
  { key: 'alert_vol_read_latency', metric: 'Cluster CSVFS\\Avg. sec/Read', op: 'GreaterThan', threshold: json('0.5'), text: 'Volume read latency above 500 ms (recommended alert rule)' }
  { key: 'alert_vol_write_latency', metric: 'Cluster CSVFS\\Avg. sec/Write', op: 'GreaterThan', threshold: json('0.5'), text: 'Volume write latency above 500 ms (recommended alert rule)' }
  { key: 'alert_net_in', metric: 'Network Adapter\\Bytes Received/sec', op: 'GreaterThan', threshold: 500000000000, text: 'Network in above 500 GB/s (recommended alert rule, Learn threshold)' }
  { key: 'alert_net_out', metric: 'Network Adapter\\Bytes Sent/sec', op: 'GreaterThan', threshold: 200000000000, text: 'Network out above 200 GB/s (recommended alert rule, Learn threshold)' }
]

resource metricAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = [for m in metricAlerts: if (enable_recommended_metric_alerts) {
  name: names[m.key]
  location: 'global'
  tags: allTags
  properties: {
    description: '${cluster_name}: ${m.text}.'
    severity: 3
    enabled: true
    scopes: [clusterId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'c1'
          metricNamespace: 'Microsoft.AzureStackHCI/clusters'
          metricName: m.metric
          dimensions: [{ name: 'ClusterNodeName', operator: 'Include', values: ['*'] }]
          operator: m.op
          threshold: m.threshold
          timeAggregation: 'Average'
          skipMetricValidation: false
        }
      ]
    }
    actions: [{ actionGroupId: agId }]
  }
}]

// ---------------------------------------------------------------- health alerts (AzureEdgeAlerts) -> action group
// Learn: Respond to Azure Local health alerts using Azure Monitor alerts, step 2 (alert processing rule). Health alerts
// fire on the cluster resource; the metric rules above already notify the action group, so metric signals are excluded.
resource healthRouting 'Microsoft.AlertsManagement/actionRules@2021-08-08' = if (enable_health_alert_routing) {
  name: names.alert_health_routing
  location: 'Global'
  tags: allTags
  properties: {
    enabled: true
    description: 'Routes the Azure Local OS health alerts (AzureEdgeAlerts extension) raised on ${cluster_name} to the ops action group.'
    scopes: [clusterId]
    conditions: [
      {
        field: 'SignalType'
        operator: 'NotEquals'
        values: ['Metric']
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
output log_analytics_workspace_id string = lawId
output metric_alert_rule_ids array = [for (m, i) in metricAlerts: enable_recommended_metric_alerts ? metricAlert[i].id : '']
output health_processing_rule_id string = enable_health_alert_routing ? healthRouting.id : ''
