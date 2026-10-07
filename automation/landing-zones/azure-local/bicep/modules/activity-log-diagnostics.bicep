// Gap-fill (design §10.3 "activity log gap-fill"): subscription activity log to the workspace, design §7.5.
targetScope = 'subscription'

@description('Diagnostic setting name (the catalog key of the activity-log policy assignment is reused for traceability).')
param name string
@description('Log Analytics workspace resource ID.')
param log_analytics_workspace_id string

resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: name
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [for category in ['Administrative', 'Security', 'Policy', 'Alert', 'Autoscale', 'ResourceHealth']: {
      category: category
      enabled: true
    }]
  }
}
