data "azurerm_recovery_services_vault" "existing" {
  name                = var.names["rsv_azl"]
  resource_group_name = var.names["rg_bcdr"]
}

# The Hyper-V-to-Azure replication policy is created through ARM (azapi), mirroring the Bicep resource.
resource "azapi_resource" "asr_policy" {
  type      = "Microsoft.RecoveryServices/vaults/replicationPolicies@2023-02-01"
  name      = var.names["asrpol_tier1"]
  parent_id = data.azurerm_recovery_services_vault.existing.id

  body = {
    properties = {
      providerSpecificInput = {
        instanceType                                  = "HyperVReplicaAzure"
        recoveryPointHistoryDuration                  = var.asr_policy.recovery_point_retention_hours
        applicationConsistentSnapshotFrequencyInHours = var.asr_policy.app_consistent_snapshot_frequency_hours
        replicationInterval                           = var.asr_policy.replication_frequency_seconds
      }
    }
  }
}

resource "azurerm_backup_policy_vm" "backup_policy" {
  name                           = var.names["bkp_tier1"]
  resource_group_name            = var.names["rg_bcdr"]
  recovery_vault_name            = data.azurerm_recovery_services_vault.existing.name
  policy_type                    = "V2"
  timezone                       = "UTC"
  instant_restore_retention_days = var.backup_policy.instant_restore_days

  backup {
    frequency = "Daily"
    time      = var.backup_policy.schedule_run_time_utc
  }

  retention_daily {
    count = var.backup_policy.retention_days
  }
}
