// Stage S4 Monitoring (design §7.1, §7.2): workspace (skipped when a central workspace is given), action group, optional DCE.
// AVM: operational-insights/workspace 0.16.1. Action group and DCE are gap-fill (design §10.3).
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param law_retention_days int
param law_daily_cap_gb int
param budget_contact_emails array
param enable_monitor_private_link bool
@description('Central workspace resource ID; when set the workload workspace is not created.')
param central_log_analytics_workspace_id string = ''

module law 'br/public:avm/res/operational-insights/workspace:0.16.1' = if (empty(central_log_analytics_workspace_id)) {
  name: 'law'
  params: {
    name: names.law
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: law_retention_days
    dailyQuotaGb: string(law_daily_cap_gb) // the AVM module types this as string
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    diagnosticSettings: [
      {
        useThisWorkspace: true
        logCategoriesAndGroups: [{ category: 'Audit' }]
      }
    ]
  }
}

module actionGroup 'action-group.bicep' = {
  name: 'ag-ops'
  params: {
    name: names.ag_ops
    tags: tags
    emails: budget_contact_emails
  }
}

module dce 'data-collection-endpoint.bicep' = if (enable_monitor_private_link) {
  name: 'dce-azl'
  params: {
    name: names.dce_azl
    location: location
    tags: tags
  }
}

output workspaceId string = empty(central_log_analytics_workspace_id) ? law!.outputs.resourceId : central_log_analytics_workspace_id
output workspaceCustomerId string = empty(central_log_analytics_workspace_id) ? law!.outputs.logAnalyticsWorkspaceId : ''
output actionGroupId string = actionGroup.outputs.resourceId
output dceId string = enable_monitor_private_link ? dce!.outputs.resourceId : ''
