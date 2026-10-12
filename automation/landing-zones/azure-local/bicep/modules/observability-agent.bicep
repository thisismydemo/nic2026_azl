// NIC 2026 - Azure Copilot Observability Agent (preview) prerequisites, on-demand use only (D-047, LZ-13, T-5.7.2).
// Resource-group scope (the Azure Local monitoring resource group). Creates the Azure Monitor workspace that holds
// Azure Monitor issues and grants Issue Contributor on it. No Microsoft.Monitor/observabilityAgents resource is created:
// the on-demand chat and deep investigations work without one, and autonomous deep investigations (billed since
// 1 Jul 2026) need one (Learn: Azure Copilot Observability Agent resource (preview)).
// The subscription association (Microsoft.Monitor/settings/default, defaultAzureMonitorWorkspace) is a subscription-level
// setting with a preview-only API; scripts/Set-ObservabilityAgentPrereqs.ps1 sets and reads it back per subscription
// (Learn: Use Azure Monitor issues - Associate an AMW with a subscription).
targetScope = 'resourceGroup'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Azure Monitor workspace name (amw-<org>-<token>-<region>-01).')
param amw_name string
param location string
param tags object
@description('Principals that receive Issue Contributor on the workspace: [{ object_id, type: User|Group|ServicePrincipal }].')
param issue_contributors array = []

// Built-in role: Issue Contributor (Microsoft.AlertsManagement/Issues/*, microsoft.monitor/accounts/issues/*).
var issueContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.IssueContributor)

resource amw 'Microsoft.Monitor/accounts@2025-10-03' = {
  name: amw_name
  location: location
  tags: tags
  properties: {}
}

resource issueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in issue_contributors: {
  name: guid(amw.id, p.object_id, issueContributorRoleId)
  scope: amw
  properties: {
    roleDefinitionId: issueContributorRoleId
    principalId: p.object_id
    principalType: p.type
    description: 'Observability Agent (preview): save investigations as Azure Monitor issues (D-047).'
  }
}]

output amw_id string = amw.id
output issue_contributor_assignment_ids array = [for (p, i) in issue_contributors: issueContributor[i].id]
