// Gap-fill: subscription-scope role assignments (design §6.2) where no AVM module exposes roleAssignments.
targetScope = 'subscription'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Items: { principalId, principalType (Group|ServicePrincipal|User), role (key of builtInRoles), condition?, conditionVersion?, description? }')
param assignments array

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in assignments: {
  name: guid(subscription().id, item.principalId, builtInRoles[item.role])
  properties: {
    principalId: item.principalId
    principalType: item.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    condition: item.?condition
    conditionVersion: contains(item, 'condition') ? '2.0' : null
    description: item.?description
  }
}]
