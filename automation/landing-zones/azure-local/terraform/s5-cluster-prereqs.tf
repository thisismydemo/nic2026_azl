# Stage S5 Cluster prerequisites (design §9, §6.2). AVM: Azure/avm-res-storage-storageaccount 0.10.0.
# The witness KEY is never read by Terraform (the deploy solution's generator script writes it to the cluster vault).

locals {
  st_blob_diag = {
    default = {
      name                  = "to-law"
      workspace_resource_id = local.law_id
      logs                  = [{ category = "StorageRead" }, { category = "StorageWrite" }, { category = "StorageDelete" }]
      metrics               = [{ category = "Transaction" }]
    }
  }
  st_account_diag = {
    default = { name = "to-law", workspace_resource_id = local.law_id, metrics = [{ category = "Transaction" }] }
  }
}

module "st_witness" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"
  count   = local.s5 ? 1 : 0

  name                                = var.names.st_witness
  location                            = var.location
  parent_id                           = local.rg_id.rg_azl
  account_kind                        = "StorageV2"
  account_tier                        = "Standard"
  account_replication_type            = "LRS"
  access_tier                         = "Hot"
  min_tls_version                     = "TLS1_2"
  https_traffic_only_enabled          = true
  allow_nested_items_to_be_public     = false
  shared_access_key_enabled           = true # the cloud witness authenticates with the account key (design §9.1)
  public_network_access_enabled       = true
  network_rules                       = { bypass = ["AzureServices"], default_action = "Allow" }
  diagnostic_settings_blob            = local.st_blob_diag
  diagnostic_settings_storage_account = local.st_account_diag
  tags                                = local.tags
  enable_telemetry                    = false
  depends_on                          = [azurerm_resource_group.this, module.law]
}

module "st_voucher" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.10.0"
  count   = local.s5 && var.enable_voucher_storage ? 1 : 0

  name                            = var.names.st_voucher
  location                        = var.location
  parent_id                       = local.rg_id.rg_azl
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = true
  network_rules                   = { bypass = ["AzureServices"], default_action = "Allow" }
  diagnostic_settings_blob        = local.st_blob_diag
  tags                            = local.tags
  enable_telemetry                = false
  depends_on                      = [azurerm_resource_group.this, module.law]
}

# Active assignments on the cluster resource group (design §6.2)
locals {
  rg_azl_rbac = {
    lab_operators_owner       = { role = "Owner", principal = var.group_object_ids["grp_lab_operators"], type = "Group", description = "Build window: provisioning and Arc onboarding need Owner on the provisioning resource group; convert to eligible after Day-2 Ready" }
    azl_admins_onboarding     = { role = "Azure Connected Machine Onboarding", principal = var.group_object_ids["grp_azl_admins"], type = "Group", description = null }
    azl_admins_resource_admin = { role = "Azure Connected Machine Resource Administrator", principal = var.group_object_ids["grp_azl_admins"], type = "Group", description = null }
    azl_rp_resource_manager   = { role = "Azure Connected Machine Resource Manager", principal = var.azl_rp_app_object_id, type = "ServicePrincipal", description = "Azure Local resource provider first-party application (Marketplace image download)" }
  }
}

resource "azurerm_role_assignment" "rg_azl" {
  for_each = local.s5 ? local.rg_azl_rbac : {}

  scope                = local.rg_id.rg_azl
  role_definition_name = each.value.role
  principal_id         = each.value.principal
  principal_type       = each.value.type
  description          = each.value.description
  depends_on           = [azurerm_resource_group.this]
}
