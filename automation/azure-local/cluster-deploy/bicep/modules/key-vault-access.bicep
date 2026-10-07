// Gap-fill (cluster-deploy): what the Local Identity deployment needs on the EXISTING cluster vault, which lives in
// rg_sec (design §5.2 option A) and is therefore outside the deployment resource group:
//   - node Arc identities: Key Vault Secrets Officer + Key Vault Certificates Officer on the vault only
//     (keyvault-and-secrets.md §4; Learn "Alerts for Key Vault extension": KeyVaultAccess);
//   - vault audit log to the diagnostics storage account (template parameters diagnosticStorageAccountName /
//     logsRetentionInDays). The landing zone already sends AuditEvent to the workspace; this adds the storage sink.
// No secret is created, read or output here (contract §3).
targetScope = 'resourceGroup'

param key_vault_name string
param node_principal_ids array
// Built-in role definition GUID (platform constant), not a secret: the linter keys on the word "secret".
#disable-next-line secure-secrets-in-params
param secrets_officer_role_id string
param certificates_officer_role_id string
param diagnostic_storage_account_id string
@minValue(0)
@maxValue(365)
param logs_retention_days int = 30

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: key_vault_name
}

resource secretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in node_principal_ids: {
  name: guid(vault.id, principalId, secrets_officer_role_id)
  scope: vault
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secrets_officer_role_id)
  }
}]

resource certificatesOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in node_principal_ids: {
  name: guid(vault.id, principalId, certificates_officer_role_id)
  scope: vault
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', certificates_officer_role_id)
  }
}]

resource auditToStorage 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'audit-to-storage'
  scope: vault
  properties: {
    storageAccountId: diagnostic_storage_account_id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        retentionPolicy: {
          enabled: logs_retention_days > 0
          days: logs_retention_days
        }
      }
    ]
  }
}

output key_vault_id string = vault.id
