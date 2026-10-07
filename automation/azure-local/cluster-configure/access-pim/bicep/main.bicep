// NIC 2026 — Day-2 Ready 3.4 PIM-eligible access (cluster-configure/access-pim), Bicep track. Subscription scope.
// Gap-fill: Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview (no AVM module; same resource
// as the landing zone's pim-eligibility module). A schedule request is a one-shot object: re-deploying an identical
// request for an eligibility that already exists fails with RoleAssignmentExists, so the idempotent path is
// scripts/Invoke-PimEligibility.ps1 (-Tool Az, default); this template is the take-home parity track.
targetScope = 'subscription'

#disable-next-line no-unused-params
param subscription_id string
param group_object_ids object
#disable-next-line no-unused-params
param pim_max_activation_hours int = 8
@description('{ group (key of group_object_ids), role (built-in role display name) }')
param pim_assignments array = [
  { group: 'azl_admins', role: 'Azure Stack HCI Administrator' }
  { group: 'azl_admins', role: 'Reader' }
  { group: 'azl_operators', role: 'Azure Stack HCI VM Contributor' }
  { group: 'azl_operators', role: 'Reader' }
]
#disable-next-line no-unused-params
param names object
param start_date_time string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

// Built-in role definition IDs (platform constants; documented GUID allow-list).
var roleIds = {
  Reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  'Azure Stack HCI Administrator': 'bda0d508-adf1-4af0-9c28-88919fc3ae06'
  'Azure Stack HCI VM Contributor': '874d1c73-6003-4e60-a13a-cb31ea190a85'
  'Azure Stack HCI VM Reader': '4b3fe76c-f777-4d24-a2d7-b027b0f7b273'
}

resource eligibility 'Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview' = [for a in pim_assignments: {
  name: guid(subscription().id, group_object_ids[a.group], roleIds[a.role], 'eligible')
  properties: {
    principalId: group_object_ids[a.group]
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds[a.role])
    requestType: 'AdminAssign'
    justification: 'NIC26 Day-2 Ready 3.4 - PIM-eligible Azure Local role (design §6.3)'
    scheduleInfo: {
      startDateTime: start_date_time
      expiration: { type: 'NoExpiration' }
    }
  }
}]

output eligibility_request_names array = [for (a, i) in pim_assignments: eligibility[i].name]
output pim_scope string = subscription().id
