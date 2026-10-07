// Gap-fill (design §10.3: "Managed identity — AVM not confirmed"): the deployment identity id-<org>-<token>-deploy-<region>-01.
// (avm/res/managed-identity/user-assigned-identity 0.6.0 exists in the registry; it is not on the design's confirmed list, so this
// solution keeps the raw resource and records the AVM option in the README.)
targetScope = 'resourceGroup'

param name string
param location string
param tags object

resource id 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags
}

output resourceId string = id.id
output principalId string = id.properties.principalId
output clientId string = id.properties.clientId
