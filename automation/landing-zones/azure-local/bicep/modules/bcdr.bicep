// Stage S6 BC/DR foundation (design §8): Recovery Services vault and ASR cache storage account.
// Replication/backup policies and the recovery plan are Day-2 Ready (names reserved in the catalog).
// AVM: recovery-services/vault 0.13.2, storage/storage-account 0.33.1.
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param log_analytics_workspace_id string
@allowed(['LocallyRedundant', 'ZoneRedundant', 'GeoRedundant'])
param rsv_storage_redundancy string

// Literal objects per value so the AVM discriminated union type-checks (lab: LocallyRedundant, design §8.2).
var redundancy = rsv_storage_redundancy == 'GeoRedundant'
  ? { standardTierStorageRedundancy: 'GeoRedundant', crossRegionRestore: 'Disabled' }
  : rsv_storage_redundancy == 'ZoneRedundant'
      ? { standardTierStorageRedundancy: 'ZoneRedundant' }
      : { standardTierStorageRedundancy: 'LocallyRedundant' }

module rsv 'br/public:avm/res/recovery-services/vault:0.13.2' = {
  name: 'rsv-azl'
  params: {
    name: names.rsv_azl
    location: location
    tags: tags
    managedIdentities: { systemAssigned: true }
    publicNetworkAccess: 'Enabled' // nodes replicate from the site over direct egress (design §8.2)
    redundancySettings: redundancy
    softDeleteSettings: {
      // The vault API version in use only accepts AlwaysON for both (BMSUserErrorSoftDeleteStateNotSetToAlwaysON on 7 Oct 2026).
      softDeleteState: 'AlwaysON'
      enhancedSecurityState: 'AlwaysON'
      softDeleteRetentionPeriodInDays: 14
    }
    immutabilitySettingState: 'Disabled'
    // Learn (Monitor Site Recovery with Azure Monitor Logs): only AzureSiteRecoveryJobs and ASRReplicatedItems are resource-specific;
    // sending the legacy categories in resource-specific mode stops that data. Two settings, one per mode.
    diagnosticSettings: [
      {
        name: 'to-law-azure-diagnostics'
        workspaceResourceId: log_analytics_workspace_id
        logAnalyticsDestinationType: 'AzureDiagnostics'
        logCategoriesAndGroups: [
          { category: 'AzureBackupReport' }
          { category: 'AzureSiteRecoveryEvents' }
          { category: 'AzureSiteRecoveryReplicatedItems' }
          { category: 'AzureSiteRecoveryReplicationStats' }
          { category: 'AzureSiteRecoveryRecoveryPoints' }
        ]
      }
      {
        name: 'to-law-resource-specific'
        workspaceResourceId: log_analytics_workspace_id
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: [
          { category: 'AzureSiteRecoveryJobs' }
          { category: 'ASRReplicatedItems' }
        ]
      }
    ]
  }
}

// ASR cache: GPv2, Standard_LRS, public access on, shared key on, soft delete off (design §8.3).
module asrCache 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-asrcache'
  params: {
    name: names.st_asr_cache
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    blobServices: {
      deleteRetentionPolicyEnabled: false
      containerDeleteRetentionPolicyEnabled: false
      diagnosticSettings: [
        {
          workspaceResourceId: log_analytics_workspace_id
          logCategoriesAndGroups: [{ category: 'StorageRead' }, { category: 'StorageWrite' }, { category: 'StorageDelete' }]
          metricCategories: [{ category: 'Transaction' }]
        }
      ]
    }
  }
}

output recoveryVaultId string = rsv.outputs.resourceId
output recoveryVaultPrincipalId string = rsv.outputs.?systemAssignedMIPrincipalId ?? ''
output asrCacheStorageAccountName string = asrCache.outputs.name
