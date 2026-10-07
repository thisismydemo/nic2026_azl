// Gap-fill: the compliance baseline initiative init-<org>-<token>-hybrid-baseline (design §7.4).
// DEFINED here at management-group scope (decision LZ-01: "stored at the management group so that B is a
// one-line change"); ASSIGNED in Day-2 Ready, not by this landing zone.
// Members: the built-in definitions from design §7.4. The two custom Azure Local Insights definitions
// (monitor-multi-azure-policies) and the custom "Key Vault backup extension present" audit are NOT included
// here because they must be imported from Microsoft's published definitions during Day-2 Ready (README: parity gaps).
targetScope = 'managementGroup'

import { builtInPolicies } from 'policy-definitions.bicep'

@description('Resolved name catalog (contract §10).')
param names object
@description('Allowed locations (Deny).')
param allowed_locations array
@description('Log Analytics workspace resource ID (DeployIfNotExists destinations).')
param log_analytics_workspace_id string

// tenantResourceId() with an empty name drops the type segment and yields an invalid definition id, so the prefix is written out.
var policyDefScope = '/providers/Microsoft.Authorization/policyDefinitions/'

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: names.init_hybrid_baseline
  properties: {
    displayName: 'NIC26 hybrid baseline (Azure Local landing zone)'
    description: 'Compliance baseline for the Azure Local landing zone; assigned at subscription scope in Day-2 Ready (design §7.4).'
    policyType: 'Custom'
    metadata: { category: 'NIC26', version: '0.1.0' }
    parameters: {
      listOfAllowedLocations: { type: 'Array', defaultValue: allowed_locations }
      logAnalytics: { type: 'String', defaultValue: log_analytics_workspace_id }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'allowed-locations'
        policyDefinitionId: '${policyDefScope}${builtInPolicies.allowedLocations}'
        parameters: { listOfAllowedLocations: { value: '[parameters(\'listOfAllowedLocations\')]' } }
      }
      {
        policyDefinitionReferenceId: 'activity-log-to-law'
        policyDefinitionId: '${policyDefScope}${builtInPolicies.activityLogToLogAnalytics}'
        parameters: { logAnalytics: { value: '[parameters(\'logAnalytics\')]' }, logsEnabled: { value: 'True' } }
      }
      {
        policyDefinitionReferenceId: 'ama-on-arc-windows'
        policyDefinitionId: '${policyDefScope}${builtInPolicies.amaOnArcWindows}'
      }
      {
        policyDefinitionReferenceId: 'periodic-assessment-arc'
        policyDefinitionId: '${policyDefScope}${builtInPolicies.periodicAssessmentOnArc}'
      }
      {
        policyDefinitionReferenceId: 'defender-for-servers'
        policyDefinitionId: '${policyDefScope}${builtInPolicies.defenderForServersEnabled}'
      }
    ]
  }
}

output initiativeId string = initiative.id
