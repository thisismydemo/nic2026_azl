// Gap-fill: one subscription-scope policy assignment with an optional system-assigned identity and role assignments.
// Why gap-fill: avm/ptn/authorization/policy-assignment 0.5.3 is a management-group-scoped template and cannot be
// deployed from this subscription-scoped solution (same limit the AVD landing zone documents).
// Role assignments live in a child module so their names can include the (runtime) principal id: a recreated policy
// identity then gets new role assignments instead of failing with RoleAssignmentUpdateNotPermitted.
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
param roleDefinitionIds array = []
param metadata object = {}

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
  }
}

module roleAssignments 'policy-role-assignment.bicep' = [
  for roleId in roleDefinitionIds: if (identityType != 'None') {
    name: 'policy-ra-${uniqueString(subscription().id, name, roleId)}'
    params: {
      principalId: assignment.identity.principalId
      roleDefinitionId: roleId
    }
  }
]

output id string = assignment.id
output principalId string = identityType == 'None' ? '' : assignment.identity.principalId
