// Gap-fill (design §6.2/§6.3): PIM-eligible assignments scoped to a resource group or to a Key Vault in it
// (the deployment-user set on the cluster resource group and on the cluster vault). See pim-eligibility.bicep
// for the re-run caveat; default path is scripts/Initialize-LzPim.ps1.
targetScope = 'resourceGroup'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Resource-group-scoped items: { principalId, role }')
param rg_eligibilities array = []
@description('Key-Vault-scoped items: { principalId, role }')
param kv_eligibilities array = []
@description('Key Vault name in this resource group for kv_eligibilities (empty when none).')
param key_vault_name string = ''
param start_date_time string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (!empty(key_vault_name)) {
  name: key_vault_name
}

resource rgReq 'Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview' = [for item in rg_eligibilities: {
  name: guid(resourceGroup().id, item.principalId, builtInRoles[item.role], 'eligible')
  properties: {
    principalId: item.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    requestType: 'AdminAssign'
    justification: 'NIC26 Azure Local landing zone - PIM-eligible assignment (design §6.2)'
    scheduleInfo: {
      startDateTime: start_date_time
      expiration: { type: 'NoExpiration' }
    }
  }
}]

resource kvReq 'Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview' = [for item in kv_eligibilities: if (!empty(key_vault_name)) {
  name: guid(resourceGroup().id, key_vault_name, item.principalId, builtInRoles[item.role], 'eligible')
  scope: kv
  properties: {
    principalId: item.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    requestType: 'AdminAssign'
    justification: 'NIC26 Azure Local landing zone - deployment-user set on the cluster vault (design §5.4)'
    scheduleInfo: {
      startDateTime: start_date_time
      expiration: { type: 'NoExpiration' }
    }
  }
}]
