// Gap-fill: one subscription-scope policy assignment with an optional system-assigned identity and its role assignments
// at the subscription. Same pattern as automation/azure-local/cluster-configure/policy (AVM ptn/authorization/policy-assignment
// is management-group scoped only). Kept as its own copy so automation/shared stays self-contained in both public repos.
targetScope = 'subscription'

param name string
param displayName string
param assignmentDescription string = ''
param policyDefinitionId string
param location string
@allowed(['SystemAssigned', 'None'])
param identityType string = 'SystemAssigned'
@allowed(['Default', 'DoNotEnforce'])
param enforcementMode string = 'Default'
param parameters object = {}
@description('Built-in role definition GUIDs granted to the assignment identity at subscription scope.')
param roleDefinitionIds array = []
param metadata object = {}
param nonComplianceMessage string = ''

resource assignment 'Microsoft.Authorization/policyAssignments@2025-01-01' = {
  name: name
  location: identityType == 'None' ? null : location
  identity: identityType == 'None' ? null : {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: displayName
    description: assignmentDescription
    policyDefinitionId: policyDefinitionId
    enforcementMode: enforcementMode
    parameters: parameters
    metadata: metadata
    nonComplianceMessages: empty(nonComplianceMessage) ? [] : [
      { message: nonComplianceMessage }
    ]
  }
}

// Name derived from the principal id, so a recreated identity gets new role assignments instead of failing.
resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in roleDefinitionIds: if (identityType != 'None') {
    name: guid(subscription().id, name, roleId)
    properties: {
      principalId: assignment.identity.principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalType: 'ServicePrincipal'
      description: 'Remediation identity of policy assignment ${name}'
    }
  }
]

output id string = assignment.id
output name string = assignment.name
output principalId string = identityType == 'None' ? '' : assignment.identity.principalId
