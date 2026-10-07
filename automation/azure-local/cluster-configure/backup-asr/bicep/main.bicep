// NIC 2026 — Day-2 Ready 3.3 backup and DR (cluster-configure/backup-asr), Bicep track. Resource-group scope: the wrapper
// deploys into names.rg_bcdr, where lz-azure-local created the Recovery Services vault. The vault is referenced as
// 'existing' and never declared here. Policy child resources have no location or tags.
targetScope = 'resourceGroup'

#disable-next-line no-unused-params
param subscription_id string
#disable-next-line no-unused-params
param location string
#disable-next-line no-unused-params
param tags object
param names object
param asr_policy object = {
  replication_frequency_seconds: 300
  recovery_point_retention_hours: 24
  app_consistent_snapshot_frequency_hours: 1
}
param backup_policy object = {
  schedule_run_time_utc: '02:00'
  retention_days: 30
  instant_restore_days: 2
}

var scheduleRunTime = '2026-01-01T${backup_policy.schedule_run_time_utc}:00Z'

resource vault 'Microsoft.RecoveryServices/vaults@2023-02-01' existing = {
  name: names.rsv_azl
}

resource asrPolicy 'Microsoft.RecoveryServices/vaults/replicationPolicies@2023-02-01' = {
  parent: vault
  name: names.asrpol_tier1
  properties: {
    providerSpecificInput: {
      instanceType: 'HyperVReplicaAzure'
      recoveryPointHistoryDuration: asr_policy.recovery_point_retention_hours
      applicationConsistentSnapshotFrequencyInHours: asr_policy.app_consistent_snapshot_frequency_hours
      replicationInterval: asr_policy.replication_frequency_seconds
    }
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-02-01' = {
  parent: vault
  name: names.bkp_tier1
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    instantRpRetentionRangeInDays: backup_policy.instant_restore_days
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [
          scheduleRunTime
        ]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          scheduleRunTime
        ]
        retentionDuration: {
          count: backup_policy.retention_days
          durationType: 'Days'
        }
      }
    }
    timeZone: 'UTC'
  }
}

output asr_replication_policy_id string = asrPolicy.id
output backup_policy_id string = backupPolicy.id
