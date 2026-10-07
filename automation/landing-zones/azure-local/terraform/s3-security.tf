# Stage S3 Security (design §5, §6; K-1..K-5). AVM: Azure/avm-res-keyvault-vault 0.11.0 (legacy_access_policies_enabled = false,
# private endpoints through its private_endpoints input). Gap-fill azurerm: user-assigned identity, subscription RBAC, PIM.
# No secret is created or read here: this solution has no Key Vault secret data source (contract §3).

resource "azurerm_user_assigned_identity" "deploy" {
  count = local.s3 ? 1 : 0

  name                = var.names.id_deploy
  location            = var.location
  resource_group_name = var.names.rg_sec
  tags                = local.tags
  depends_on          = [azurerm_resource_group.this]
}

locals {
  kv_diag = {
    default = {
      name                  = "to-law"
      workspace_resource_id = local.law_id
      log_categories        = ["AuditEvent", "AzurePolicyEvaluationDetails"]
      log_groups            = []
      metric_categories     = ["AllMetrics"]
    }
  }
}

module "kv_ops" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.11.0"
  count   = local.s3 ? 1 : 0

  name                            = var.names.kv_ops
  location                        = var.location
  resource_group_name             = var.names.rg_sec
  tenant_id                       = var.tenant_id
  sku_name                        = "standard"
  legacy_access_policies_enabled  = false
  purge_protection_enabled        = false # K-5 ops vault
  soft_delete_retention_days      = var.kv_soft_delete_days
  public_network_access_enabled   = local.kv_public["ops"] == "Enabled"
  network_acls                    = { bypass = "AzureServices", default_action = "Allow" }
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  tags                            = local.tags
  enable_telemetry                = false
  diagnostic_settings             = local.kv_diag

  private_endpoints = !var.enable_private_endpoints ? {} : {
    vault = {
      name                          = var.names.pep_kv_ops
      network_interface_name        = "nic-${var.names.pep_kv_ops}-01"
      subnet_resource_id            = local.subnet_id.pe
      private_dns_zone_resource_ids = [local.vaultcore_zone_id]
      tags                          = local.tags
    }
  }

  role_assignments = {
    lab_operators_secrets_officer = { role_definition_id_or_name = "Key Vault Secrets Officer", principal_id = var.group_object_ids["grp_lab_operators"], principal_type = "Group" }
    deploy_identity_secrets_user  = { role_definition_id_or_name = "Key Vault Secrets User", principal_id = azurerm_user_assigned_identity.deploy[0].principal_id, principal_type = "ServicePrincipal" }
  }
  depends_on = [azurerm_resource_group.this, module.vnet, azurerm_private_dns_zone.vaultcore, module.law]
}

module "kv_azl" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.11.0"
  count   = local.s3 ? 1 : 0

  name                            = var.names.kv_azl
  location                        = var.location
  resource_group_name             = var.names.rg_sec
  tenant_id                       = var.tenant_id
  sku_name                        = "standard"
  legacy_access_policies_enabled  = false
  purge_protection_enabled        = true # K-5 cluster vault
  soft_delete_retention_days      = var.kv_soft_delete_days
  public_network_access_enabled   = local.kv_public["azl"] == "Enabled"
  network_acls                    = { bypass = "AzureServices", default_action = "Allow" }
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  tags                            = local.tags
  enable_telemetry                = false
  diagnostic_settings             = local.kv_diag

  private_endpoints = !var.enable_private_endpoints ? {} : {
    vault = {
      name                          = var.names.pep_kv_azl
      network_interface_name        = "nic-${var.names.pep_kv_azl}-01"
      subnet_resource_id            = local.subnet_id.pe
      private_dns_zone_resource_ids = [local.vaultcore_zone_id]
      tags                          = local.tags
    }
  }

  role_assignments = {
    lab_operators_secrets_user = { role_definition_id_or_name = "Key Vault Secrets User", principal_id = var.group_object_ids["grp_lab_operators"], principal_type = "Group" }
    azl_admins_secrets_user    = { role_definition_id_or_name = "Key Vault Secrets User", principal_id = var.group_object_ids["grp_azl_admins"], principal_type = "Group" }
    # Node Arc identities (Secrets Officer + Certificates Officer) are assigned by the cluster deployment (design §5.4).
  }
  depends_on = [azurerm_resource_group.this, module.vnet, azurerm_private_dns_zone.vaultcore, module.law]
}

# ---------------------------------------------------------------- subscription RBAC (design §6.2)
data "azurerm_role_definition" "assignable" {
  for_each = local.s3 ? toset(local.deploy_identity_assignable_roles) : toset([])
  name     = each.value
}

locals {
  # Role definition GUIDs are resolved at plan time from the names above (no literal GUIDs in source).
  assignable_role_guids = [for r in local.deploy_identity_assignable_roles : element(split("/", data.azurerm_role_definition.assignable[r].id), length(split("/", data.azurerm_role_definition.assignable[r].id)) - 1)]
  rbac_admin_condition  = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.assignable_role_guids)}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.assignable_role_guids)}}))"
}

resource "azurerm_role_assignment" "deploy_contributor" {
  count = local.s3 ? 1 : 0

  scope                = local.subscription_scope
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deploy[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Deployment identity (design §6.2)"
}

resource "azurerm_role_assignment" "deploy_rbac_admin" {
  count = local.s3 ? 1 : 0

  scope                = local.subscription_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.deploy[0].principal_id
  principal_type       = "ServicePrincipal"
  condition            = local.rbac_admin_condition
  condition_version    = "2.0"
  description          = "Deployment identity, constrained to the landing-zone role set"
}

resource "azurerm_role_assignment" "readers" {
  for_each = local.s3 ? toset(["Reader", "Azure Stack HCI VM Reader", "Log Analytics Reader", "Monitoring Reader"]) : toset([])

  scope                = local.subscription_scope
  role_definition_name = each.value
  principal_id         = var.group_object_ids["grp_azl_readers"]
  principal_type       = "Group"
}

# ---------------------------------------------------------------- PIM-eligible assignments (design §6.3) - default path is Initialize-LzPim.ps1
locals {
  pim_subscription = {
    lab_operators_owner      = { group = "grp_lab_operators", role = "Owner" }
    azl_admins_hci_admin     = { group = "grp_azl_admins", role = "Azure Stack HCI Administrator" }
    azl_admins_reader        = { group = "grp_azl_admins", role = "Reader" }
    azl_operators_vm_contrib = { group = "grp_azl_operators", role = "Azure Stack HCI VM Contributor" }
    azl_operators_reader     = { group = "grp_azl_operators", role = "Reader" }
  }
  pim_scoped = {
    azl_admins_storage_contrib = { group = "grp_azl_admins", role = "Storage Account Contributor", scope = local.rg_id.rg_azl }
    azl_admins_kv_data_admin   = { group = "grp_azl_admins", role = "Key Vault Data Access Administrator", scope = local.kv_azl_id }
    azl_admins_kv_secrets_off  = { group = "grp_azl_admins", role = "Key Vault Secrets Officer", scope = local.kv_azl_id }
    azl_admins_kv_contributor  = { group = "grp_azl_admins", role = "Key Vault Contributor", scope = local.kv_azl_id }
  }
  pim_all = merge(
    { for k, v in local.pim_subscription : k => merge(v, { scope = local.subscription_scope }) },
    local.pim_scoped
  )
}

data "azurerm_role_definition" "pim" {
  for_each = local.s3 && var.manage_pim_in_iac ? toset(distinct([for v in local.pim_all : v.role])) : toset([])
  name     = each.value
}

resource "azurerm_pim_eligible_role_assignment" "this" {
  for_each = local.s3 && var.manage_pim_in_iac ? local.pim_all : {}

  scope              = each.value.scope
  role_definition_id = "${local.subscription_scope}${data.azurerm_role_definition.pim[each.value.role].id}"
  principal_id       = var.group_object_ids[each.value.group]
  justification      = "NIC26 Azure Local landing zone - PIM-eligible assignment (design §6.3)"
  schedule {
    expiration {}
  }
  depends_on = [module.kv_azl, azurerm_resource_group.this]
}
