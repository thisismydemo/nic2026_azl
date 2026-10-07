// Gap-fill: resource-group-scope role assignments (design §6.2) on resource groups created in S1.
targetScope = 'resourceGroup'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Items: { principalId, principalType (Group|ServicePrincipal|User), role (key of builtInRoles), description? }')
param assignments array

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in assignments: {
  name: guid(resourceGroup().id, item.principalId, builtInRoles[item.role])
  properties: {
    principalId: item.principalId
    principalType: item.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    description: item.?description
  }
}]
