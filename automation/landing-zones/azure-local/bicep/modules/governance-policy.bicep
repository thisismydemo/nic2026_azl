// Gap-fill (no confirmed AVM in design §10.3): landing-zone build-time guardrails, design §2.4.
// Subscription scope (decision LZ-01 / P-06). Only guardrails that cannot block the cluster deployment.
targetScope = 'subscription'

import { builtInPolicies } from 'policy-definitions.bicep'
import { builtInRoles } from 'built-in-roles.bicep'

@description('Resolved name catalog (contract §10).')
param names object
@description('Region for the policy assignment managed identity.')
param location string
@description('Allowed locations (Deny).')
param allowed_locations array
@description('Required tag names (Deny on resource groups; Modify-inherit on resources).')
param required_tag_names array
@description('Log Analytics workspace resource ID for the activity-log DeployIfNotExists assignment.')
param log_analytics_workspace_id string

// tenantResourceId() with an empty name drops the type segment and yields an invalid definition id, so the prefix is written out.
var policyDefScope = '/providers/Microsoft.Authorization/policyDefinitions/'

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: names.asg_allowed_locations
  properties: {
    displayName: 'NIC26 Azure Local LZ - allowed locations'
    description: 'Deny resources outside the landing-zone region set (design §2.4).'
    policyDefinitionId: '${policyDefScope}${builtInPolicies.allowedLocations}'
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: { value: allowed_locations }
    }
  }
}

// One assignment per tag: the built-in definitions take a single tagName. The catalog name is suffixed
// with the tag index (documented deviation; every assignment name still carries the catalog key).
resource requireTagsOnRg 'Microsoft.Authorization/policyAssignments@2024-04-01' = [for (tag, i) in required_tag_names: {
  name: '${names.asg_require_tags_rg}-${i}'
  properties: {
    displayName: 'NIC26 Azure Local LZ - require tag ${tag} on resource groups'
    policyDefinitionId: '${policyDefScope}${builtInPolicies.requireTagOnResourceGroups}'
    enforcementMode: 'Default'
    parameters: {
      tagName: { value: tag }
    }
  }
}]

resource inheritTags 'Microsoft.Authorization/policyAssignments@2024-04-01' = [for (tag, i) in required_tag_names: {
  name: '${names.asg_inherit_tags}-${i}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'NIC26 Azure Local LZ - inherit tag ${tag} from resource group'
    policyDefinitionId: '${policyDefScope}${builtInPolicies.inheritTagFromResourceGroupIfMissing}'
    enforcementMode: 'Default'
    parameters: {
      tagName: { value: tag }
    }
  }
}]

// Modify needs Tag Contributor-equivalent rights; Contributor covers Microsoft.Resources/tags/write.
resource inheritTagsRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (tag, i) in required_tag_names: {
  name: guid(subscription().id, names.asg_inherit_tags, tag, 'contributor')
  properties: {
    principalId: inheritTags[i].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.Contributor)
  }
}]

resource activityLog 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: names.asg_activity_log
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'NIC26 Azure Local LZ - activity log to Log Analytics'
    policyDefinitionId: '${policyDefScope}${builtInPolicies.activityLogToLogAnalytics}'
    enforcementMode: 'Default'
    parameters: {
      logAnalytics: { value: log_analytics_workspace_id }
      logsEnabled: { value: 'True' }
    }
  }
}

resource activityLogRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in ['LogAnalyticsContributor', 'MonitoringContributor']: {
  name: guid(subscription().id, names.asg_activity_log, role)
  properties: {
    principalId: activityLog.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[role])
  }
}]

output allowedLocationsAssignmentId string = allowedLocations.id
output activityLogAssignmentId string = activityLog.id
