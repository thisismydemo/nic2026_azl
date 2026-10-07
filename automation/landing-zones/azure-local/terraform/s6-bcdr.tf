# Stage S6 BC/DR foundation (design §8). AVM: Azure/avm-res-recoveryservices-vault 1.3.2, Azure/avm-res-storage-storageaccount 0.10.0.
# Replication/backup policies and the recovery plan are Day-2 Ready (names reserved in the catalog).

module "rsv" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "1.3.2"
  count   = local.s6 ? 1 : 0

  name                          = var.names.rsv_azl
  location                      = var.location
  resource_group_name           = var.names.rg_bcdr
  sku                           = "Standard"
  storage_mode_type             = var.rsv_storage_redundancy
  cross_region_restore_enabled  = false
  soft_delete_enabled           = "Enabled"
  immutability                  = "Disabled"
  public_network_access_enabled = true # nodes replicate from the site over direct egress (design §8.2)
  managed_identities            = { system_assigned = true }
  tags                          = local.tags
  enable_telemetry              = false

  # Learn (Monitor Site Recovery with Azure Monitor Logs): only AzureSiteRecoveryJobs and ASRReplicatedItems are resource-specific;
  # sending the legacy categories in resource-specific mode stops that data. Two settings, one per mode.
  diagnostic_settings = {
    legacy = {
      name                           = "to-law-azure-diagnostics"
      workspace_resource_id          = local.law_id
      log_analytics_destination_type = "AzureDiagnostics"
      log_categories                 = ["AzureBackupReport", "AzureSiteRecoveryEvents", "AzureSiteRecoveryReplicatedItems", "AzureSiteRecoveryReplicationStats", "AzureSiteRecoveryRecoveryPoints"]
      log_groups                     = []
      metric_categories              = []
    }
    resource_specific = {
      name                           = "to-law-resource-specific"
      workspace_resource_id          = local.law_id
      log_analytics_destination_type = "Dedicated"
      log_categories                 = ["AzureSiteRecoveryJobs", "ASRReplicatedItems"]
      log_groups                     = []
      metric_categories              = []
    }
  }
  depends_on = [azurerm_resource_group.this, module.law]
}

module "st_asr_cache" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"
  count   = local.s6 ? 1 : 0

  name                            = var.names.st_asr_cache
  location                        = var.location
  parent_id                       = local.rg_id.rg_bcdr
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  public_network_access_enabled   = true
  network_rules                   = { bypass = ["AzureServices"], default_action = "Allow" }
  blob_properties = {
    delete_retention_policy           = { enabled = false }
    container_delete_retention_policy = { enabled = false }
  }
  diagnostic_settings_blob = local.st_blob_diag
  tags                     = local.tags
  enable_telemetry         = false
  depends_on               = [azurerm_resource_group.this, module.law]
}

# Recovery Services vault identity: Contributor on the DR target group (design §6.2)
resource "azurerm_role_assignment" "rsv_dr_rg" {
  count = local.s6 ? 1 : 0

  scope                = local.rg_id.rg_dr
  role_definition_name = "Contributor"
  principal_id         = module.rsv[0].resource.identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Recovery Services vault identity on the post-failover resource group"
  depends_on           = [azurerm_resource_group.this]
}
