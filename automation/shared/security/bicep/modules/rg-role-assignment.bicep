// Gap-fill: role assignments for one principal on one resource group (used for cross-subscription grants, e.g. a policy
// identity in the AVD subscription that writes diagnostic settings or DCR associations pointing at the security workspace).
targetScope = 'resourceGroup'

param principalId string
@description('Built-in role definition GUIDs.')
param roleDefinitionIds array
param descriptionText string = ''

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in roleDefinitionIds: {
    name: guid(resourceGroup().id, principalId, roleId)
    properties: {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalType: 'ServicePrincipal'
      description: descriptionText
    }
  }
]
