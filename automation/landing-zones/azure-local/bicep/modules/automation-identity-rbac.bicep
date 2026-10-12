// Gap-fill (design §6.2, automation identity): the role assignments the automation identity needs to register the
// nodes with Azure Arc, deploy the cluster (Local Identity with Key Vault, D-008) and, optionally, run simplified machine
// provisioning. Called once per scope from main.bicep: the resource group itself (rg_assignments) and, optionally, one
// Key Vault in it (vault_assignments). Items come from ../automation-identity-roles.json; role IDs from built-in-roles.bicep.
// Items with delegable_roles get Role Based Access Control Administrator constrained by an ABAC condition (version 2.0):
// assign or remove only those roles, only to service principals, and never to the automation identity itself
// (Learn: "Examples to delegate Azure role assignment management with conditions").
// Assignment names are guid(scope, principal, role) as in role-assignment-rg.bicep, so a re-run is an idempotent re-PUT.
targetScope = 'resourceGroup'

import { builtInRoles } from 'built-in-roles.bicep'

@description('Object ID of the automation identity (user-assigned managed identity or service principal).')
param principal_id string
@description('Resource-group-scope items: { key, role (builtInRoles key), delegable_roles? (builtInRoles keys), purpose }.')
param rg_assignments array = []
@description('Key Vault in this resource group that receives vault_assignments; empty = none.')
param key_vault_name string = ''
@description('Vault-scope items, same shape as rg_assignments.')
param vault_assignments array = []

func delegationCondition(roleIds string, selfId string) string =>
  '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${roleIds}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {\'ServicePrincipal\'} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${selfId}})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${roleIds}} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {\'ServicePrincipal\'}))'

resource rgRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in rg_assignments: {
  name: guid(resourceGroup().id, principal_id, builtInRoles[item.role])
  properties: {
    principalId: principal_id
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    condition: contains(item, 'delegable_roles') ? delegationCondition(join(map(item.delegable_roles, r => builtInRoles[r]), ', '), principal_id) : null
    conditionVersion: contains(item, 'delegable_roles') ? '2.0' : null
    description: 'Automation identity: ${item.key}'
  }
}]

// Conditional: ARM only looks the vault up when this call carries a vault.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(key_vault_name)) {
  name: key_vault_name
}

resource vaultRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in vault_assignments: {
  name: guid(vault!.id, principal_id, builtInRoles[item.role])
  scope: vault
  properties: {
    principalId: principal_id
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles[item.role])
    condition: contains(item, 'delegable_roles') ? delegationCondition(join(map(item.delegable_roles, r => builtInRoles[r]), ', '), principal_id) : null
    conditionVersion: contains(item, 'delegable_roles') ? '2.0' : null
    description: 'Automation identity: ${item.key}'
  }
}]

output assigned_keys array = concat(map(rg_assignments, i => i.key), map(vault_assignments, i => i.key))
