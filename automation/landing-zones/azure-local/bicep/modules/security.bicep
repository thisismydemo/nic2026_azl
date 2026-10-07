// Stage S3 Security (design §5, §6; keyvault-and-secrets.md K-1..K-5): deployment identity, two Key Vaults with
// private endpoints, zone groups, diagnostics and the data-plane role assignments.
// AVM: key-vault/vault 0.14.2 (private endpoints through its privateEndpoints input = avm/res/network/private-endpoint).
// Secrets are NEVER created or read here (contract §3; design §10.4).
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param log_analytics_workspace_id string
param pe_subnet_id string
param vaultcore_zone_id string
param kv_soft_delete_days int
@description('{ ops: Enabled|Disabled, azl: Enabled|Disabled } — phase flag, design §5.3.')
param kv_public_network_access object
param enable_private_endpoints bool = true
param group_object_ids object

// ---------------------------------------------------------------- deployment identity (gap-fill)
module deployIdentity 'user-assigned-identity.bicep' = {
  name: 'id-deploy'
  params: {
    name: names.id_deploy
    location: location
    tags: tags
  }
}

var kvDiagnostics = [
  {
    workspaceResourceId: log_analytics_workspace_id
    logCategoriesAndGroups: [{ category: 'AuditEvent' }, { category: 'AzurePolicyEvaluationDetails' }]
    metricCategories: [{ category: 'AllMetrics' }]
  }
]

func privateEndpoint(name string, subnetId string, zoneId string, tagSet object) object => {
  name: name
  customNetworkInterfaceName: 'nic-${name}-01'
  subnetResourceId: subnetId
  service: 'vault'
  privateDnsZoneGroup: {
    privateDnsZoneGroupConfigs: [{ name: 'vaultcore', privateDnsZoneResourceId: zoneId }]
  }
  tags: tagSet
}

// ---------------------------------------------------------------- operations vault (purge protection OFF, K-5)
module kvOps 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'kv-ops'
  params: {
    name: names.kv_ops
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: kv_soft_delete_days
    enablePurgeProtection: false
    publicNetworkAccess: kv_public_network_access.ops
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    diagnosticSettings: kvDiagnostics
    privateEndpoints: enable_private_endpoints ? [privateEndpoint(names.pep_kv_ops, pe_subnet_id, vaultcore_zone_id, tags)] : []
    roleAssignments: [
      { principalId: group_object_ids.grp_lab_operators, principalType: 'Group', roleDefinitionIdOrName: 'Key Vault Secrets Officer' }
      { principalId: deployIdentity.outputs.principalId, principalType: 'ServicePrincipal', roleDefinitionIdOrName: 'Key Vault Secrets User' }
    ]
  }
}

// ---------------------------------------------------------------- cluster vault (purge protection ON, K-5)
module kvAzl 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'kv-azl'
  params: {
    name: names.kv_azl
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: kv_soft_delete_days
    enablePurgeProtection: true
    publicNetworkAccess: kv_public_network_access.azl
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    diagnosticSettings: kvDiagnostics
    privateEndpoints: enable_private_endpoints ? [privateEndpoint(names.pep_kv_azl, pe_subnet_id, vaultcore_zone_id, tags)] : []
    roleAssignments: [
      { principalId: group_object_ids.grp_lab_operators, principalType: 'Group', roleDefinitionIdOrName: 'Key Vault Secrets User' }
      { principalId: group_object_ids.grp_azl_admins, principalType: 'Group', roleDefinitionIdOrName: 'Key Vault Secrets User' }
      // Node Arc identities (Secrets Officer + Certificates Officer) are assigned by the cluster deployment, not here (design §5.4).
    ]
  }
}

output deployIdentityId string = deployIdentity.outputs.resourceId
output deployIdentityPrincipalId string = deployIdentity.outputs.principalId
output deployIdentityClientId string = deployIdentity.outputs.clientId
output kvOpsId string = kvOps.outputs.resourceId
output kvOpsUri string = kvOps.outputs.uri
output kvAzlId string = kvAzl.outputs.resourceId
output kvAzlUri string = kvAzl.outputs.uri
