// Gap-fill (design §6.3, §10.3): PIM-eligible role assignments as Microsoft.Authorization/roleEligibilityScheduleRequests.
// Subscription scope. NOTE: a schedule request is a one-time request object; re-deploying an identical request
// for an eligibility that already exists fails with RoleAssignmentExists. The default path is therefore
// scripts/Initialize-LzPim.ps1 (idempotent); this module runs only when manage_pim_in_iac = true.
targetScope = 'subscription'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Items: { principalId, role (key of builtInRoles), justification? }')
param eligibilities array
@description('Start time of the eligibility (defaults to deployment time).')
param start_date_time string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

resource req 'Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview' = [for item in eligibilities: {
  name: guid(subscription().id, item.principalId, builtInRoles[item.role], 'eligible')
  properties: {
    principalId: item.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    requestType: 'AdminAssign'
    justification: item.?justification ?? 'NIC26 Azure Local landing zone - PIM-eligible assignment (design §6.3)'
    scheduleInfo: {
      startDateTime: start_date_time
      expiration: {
        type: 'NoExpiration'
      }
    }
  }
}]
