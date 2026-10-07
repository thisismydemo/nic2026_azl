// NIC 2026 — Day-2 Ready 3.5 governance baseline (cluster-configure/policy), Bicep track. Subscription scope.
// Gap-fill (no AVM): modules/policy-assignment.bicep for every assignment (avm/ptn/authorization/policy-assignment 0.5.3
// is management-group scoped only) and Microsoft.Authorization/policyDefinitions@2023-04-01 for the three custom
// definitions. Rule bodies: Learn "Enable Insights for Azure Local at scale using Azure policies" (AMA on clusters,
// DCR association on nodes) and an audit that every Arc machine carries the Key Vault backup extension (D-008).
targetScope = 'subscription'

param subscription_id string
param location string
param management_group_id string = ''
param log_analytics_workspace_id string = ''
@allowed(['Default', 'DoNotEnforce'])
param enforcement_mode string = 'Default'
param assign_insights_policies bool = true
param names object

var lawId = empty(log_analytics_workspace_id) ? resourceId(subscription_id, names.rg_mon, 'Microsoft.OperationalInsights/workspaces', names.law) : log_analytics_workspace_id
var insightsDcrId = resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/dataCollectionRules', names.dcr_insights)
var initiativeId = empty(management_group_id)
  ? subscriptionResourceId('Microsoft.Authorization/policySetDefinitions', names.init_hybrid_baseline)
  : tenantResourceId('Microsoft.Management/managementGroups/providers/policySetDefinitions', management_group_id, names.init_hybrid_baseline)

// Built-in role definition IDs (platform constants; documented GUID allow-list for the sweep).
var roleIds = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  logAnalyticsContributor: '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  monitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  guestConfigurationResourceContributor: '088ab73d-1256-47ae-bea9-9de8e7131f31'
  securityAdmin: 'fb1c8493-542b-48eb-b624-b4c8fea62acd'
}

// ---------------------------------------------------------------- custom definitions
resource polInsightsAma 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: names.pol_insights_ama
  properties: {
    displayName: 'NIC26: Azure Local systems run the Azure Monitor Agent (Insights)'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: 'NIC26', version: '1.0.0', source: 'learn.microsoft.com/azure/azure-local/manage/monitor-multi-azure-policies' }
    parameters: {
      effect: { type: 'String', allowedValues: ['DeployIfNotExists', 'Disabled'], defaultValue: 'DeployIfNotExists' }
    }
    policyRule: {
      if: { field: 'type', equals: 'Microsoft.AzureStackHCI/clusters' }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions'
          name: '[concat(field(\'name\'), \'/default/AzureMonitorWindowsAgent\')]'
          roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/${roleIds.contributor}']
          existenceCondition: { field: 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions/extensionParameters.type', equals: 'AzureMonitorWindowsAgent' }
          deployment: {
            properties: {
              mode: 'incremental'
              template: {
                '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                contentVersion: '1.0.0.0'
                parameters: { clusterName: { type: 'string' } }
                resources: [
                  {
                    type: 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions'
                    apiVersion: '2023-08-01'
                    name: '[concat(parameters(\'clusterName\'), \'/default/AzureMonitorWindowsAgent\')]'
                    properties: { extensionParameters: { publisher: 'Microsoft.Azure.Monitor', type: 'AzureMonitorWindowsAgent', autoUpgradeMinorVersion: false, enableAutomaticUpgrade: false } }
                  }
                ]
              }
              parameters: { clusterName: { value: '[field(\'Name\')]' } }
            }
          }
        }
      }
    }
  }
}

resource polInsightsDcra 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: names.pol_insights_dcra
  properties: {
    displayName: 'NIC26: Azure Local nodes are associated with the Insights data collection rule'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: 'NIC26', version: '1.0.0', source: 'learn.microsoft.com/azure/azure-local/manage/monitor-multi-azure-policies' }
    parameters: {
      effect: { type: 'String', allowedValues: ['DeployIfNotExists', 'Disabled'], defaultValue: 'DeployIfNotExists' }
      dcrResourceId: { type: 'String', metadata: { displayName: 'dcrResourceId', description: 'Resource Id of the DCR' } }
    }
    policyRule: {
      if: { field: 'type', equals: 'Microsoft.HybridCompute/machines' }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Insights/dataCollectionRuleAssociations'
          name: '[concat(field(\'name\'), \'-dataCollectionRuleAssociations\')]'
          roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/${roleIds.contributor}']
          deployment: {
            properties: {
              mode: 'incremental'
              template: {
                '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                contentVersion: '1.0.0.0'
                parameters: { machineName: { type: 'string' }, dataCollectionResourceId: { type: 'string' } }
                resources: [
                  {
                    type: 'Microsoft.Insights/dataCollectionRuleAssociations'
                    apiVersion: '2022-06-01'
                    name: '[concat(parameters(\'machineName\'), \'-dataCollectionRuleAssociations\')]'
                    scope: '[format(\'Microsoft.HybridCompute/machines/{0}\', parameters(\'machineName\'))]'
                    properties: { description: 'Association of data collection rule. Deleting this association will break the data collection for this machine', dataCollectionRuleId: '[parameters(\'dataCollectionResourceId\')]' }
                  }
                ]
              }
              parameters: { machineName: { value: '[field(\'Name\')]' }, dataCollectionResourceId: { value: '[parameters(\'dcrResourceId\')]' } }
            }
          }
        }
      }
    }
  }
}

resource polAkvBackupExt 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: names.pol_akv_backup_ext
  properties: {
    displayName: 'NIC26: Azure Local nodes carry the Key Vault backup extension (Local Identity)'
    description: 'Audits that each Arc machine in scope has the AzureEdgeAKVBackupForWindows extension (design §7.4; D-008).'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: { category: 'NIC26', version: '1.0.0' }
    parameters: {
      effect: { type: 'String', allowedValues: ['AuditIfNotExists', 'Disabled'], defaultValue: 'AuditIfNotExists' }
    }
    policyRule: {
      if: { field: 'type', equals: 'Microsoft.HybridCompute/machines' }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.HybridCompute/machines/extensions'
          existenceCondition: {
            allOf: [
              { field: 'Microsoft.HybridCompute/machines/extensions/type', equals: 'AKVBackupForWindows' }
              { field: 'Microsoft.HybridCompute/machines/extensions/publisher', equals: 'Microsoft.Edge.Backup' }
              { field: 'Microsoft.HybridCompute/machines/extensions/provisioningState', equals: 'Succeeded' }
            ]
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------- assignments (AVM pattern module)
module baseline 'modules/policy-assignment.bicep' = {
  name: 'policy-asg-baseline'
  params: {
    name: names.asg_hybrid_baseline
    displayName: 'NIC26 hybrid baseline (Azure Local landing zone)'
    assignmentDescription: 'Compliance baseline assigned in Day-2 Ready (outline §3.5, design §7.4). Removed before the session and re-assigned live.'
    policyDefinitionId: initiativeId
    location: location
    identityType: 'SystemAssigned'
    enforcementMode: enforcement_mode
    parameters: {
      listOfAllowedLocations: { value: [location, 'global'] }
      logAnalytics: { value: lawId }
    }
    roleDefinitionIds: [
      '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.logAnalyticsContributor}'
      '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.monitoringContributor}'
      '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.guestConfigurationResourceContributor}'
      '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.securityAdmin}'
      '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.contributor}'
    ]
    metadata: { category: 'NIC26', assignedBy: 'cluster-configure/policy' }
  }
}

module asgInsightsAma 'modules/policy-assignment.bicep' = if (assign_insights_policies) {
  name: 'policy-asg-insights-ama'
  params: {
    name: names.asg_insights_ama
    displayName: 'NIC26: Azure Local Insights - Azure Monitor Agent'
    policyDefinitionId: polInsightsAma.id
    location: location
    identityType: 'SystemAssigned'
    enforcementMode: enforcement_mode
    roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/${roleIds.contributor}', '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.guestConfigurationResourceContributor}']
  }
}

module asgInsightsDcra 'modules/policy-assignment.bicep' = if (assign_insights_policies) {
  name: 'policy-asg-insights-dcra'
  params: {
    name: names.asg_insights_dcra
    displayName: 'NIC26: Azure Local Insights - DCR association'
    policyDefinitionId: polInsightsDcra.id
    location: location
    identityType: 'SystemAssigned'
    enforcementMode: enforcement_mode
    parameters: { dcrResourceId: { value: insightsDcrId } }
    roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/${roleIds.contributor}', '/providers/Microsoft.Authorization/roleDefinitions/${roleIds.guestConfigurationResourceContributor}']
  }
}

module asgAkvBackup 'modules/policy-assignment.bicep' = {
  name: 'policy-asg-akv-backup'
  params: {
    name: names.asg_akv_backup_ext
    displayName: 'NIC26: Key Vault backup extension present on Azure Local nodes'
    policyDefinitionId: polAkvBackupExt.id
    location: location
    identityType: 'None'
    enforcementMode: enforcement_mode
  }
}

output baseline_assignment_id string = subscriptionResourceId('Microsoft.Authorization/policyAssignments', names.asg_hybrid_baseline)
output baseline_principal_id string = baseline.outputs.principalId
output insights_assignment_ids array = assign_insights_policies ? [
  subscriptionResourceId('Microsoft.Authorization/policyAssignments', names.asg_insights_ama)
  subscriptionResourceId('Microsoft.Authorization/policyAssignments', names.asg_insights_dcra)
] : []
output custom_definition_ids array = [polInsightsAma.id, polInsightsDcra.id, polAkvBackupExt.id]
