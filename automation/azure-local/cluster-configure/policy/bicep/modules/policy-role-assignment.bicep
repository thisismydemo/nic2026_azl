// Gap-fill: one subscription-scope role assignment for a policy assignment's managed identity.
// The name is derived from the principal id so replacing the identity never tries to update an existing assignment.
targetScope = 'subscription'

param principalId string
param roleDefinitionId string

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    roleDefinitionId: roleDefinitionId
    principalType: 'ServicePrincipal'
  }
}
