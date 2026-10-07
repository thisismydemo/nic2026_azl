# Locals, stage flags and S1 Governance (design §2, §3). Stages S2..S7 are in s2-network.tf .. s7-management.tf.
# Resource names come ONLY from var.names (contract §10). Shared platform resources are inputs, never created.

data "azurerm_client_config" "current" {}

locals {
  s1 = contains(var.enabled_stages, "S1")
  s2 = contains(var.enabled_stages, "S2")
  s3 = contains(var.enabled_stages, "S3")
  s4 = contains(var.enabled_stages, "S4")
  s5 = contains(var.enabled_stages, "S5")
  s6 = contains(var.enabled_stages, "S6")
  s7 = contains(var.enabled_stages, "S7") && var.enable_jump_server

  tags               = merge(var.tags, { "managed-by" = "terraform" })
  required_tag_names = ["project", "workload", "environment", "owner", "managed-by", "lifecycle", "cost-center"]
  allowed_locations  = [var.location, "global"]
  rg_keys            = ["rg_azl", "rg_net", "rg_mon", "rg_sec", "rg_bcdr", "rg_dr", "rg_mgmt"]

  subscription_scope = "/subscriptions/${var.subscription_id}"
  rg_id              = { for k in local.rg_keys : k => "${local.subscription_scope}/resourceGroups/${var.names[k]}" }

  # IDs derived from the catalog so later stages can run without earlier stage outputs (partial runs).
  # The central workspace of the platform management subscription when one is given; otherwise the workload's own.
  law_id             = var.central_log_analytics_workspace_id != "" ? var.central_log_analytics_workspace_id : "${local.rg_id.rg_mon}/providers/Microsoft.OperationalInsights/workspaces/${var.names.law}"
  action_group_id    = "${local.rg_id.rg_mon}/providers/Microsoft.Insights/actionGroups/${var.names.ag_ops}"
  vnet_id            = "${local.rg_id.rg_net}/providers/Microsoft.Network/virtualNetworks/${var.names.spoke_vnet}"
  subnet_id          = { for k in ["jump", "pe", "mgmt", "asr", "asr_test"] : k => "${local.vnet_id}/subnets/${var.names["snet_${k}"]}" }
  kv_public          = var.enable_private_endpoints ? var.kv_public_network_access : { ops = "Enabled", azl = "Enabled" }
  monitor_pl         = var.enable_private_endpoints && var.enable_monitor_private_link
  vaultcore_zone_id  = !var.enable_private_endpoints ? "" : var.privatelink_vaultcore_zone_id != "" ? var.privatelink_vaultcore_zone_id : "${local.rg_id.rg_net}/providers/Microsoft.Network/privateDnsZones/${var.names.pdns_vaultcore}"
  kv_ops_id          = "${local.rg_id.rg_sec}/providers/Microsoft.KeyVault/vaults/${var.names.kv_ops}"
  kv_azl_id          = "${local.rg_id.rg_sec}/providers/Microsoft.KeyVault/vaults/${var.names.kv_azl}"
  deploy_identity_id = "${local.rg_id.rg_sec}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${var.names.id_deploy}"

  # Shared VNets: subscription / resource group / name parsed from the input IDs (never built).
  hub_vnet        = { subscription_id = split("/", var.hub_vnet_id)[2], resource_group_name = split("/", var.hub_vnet_id)[4], name = element(split("/", var.hub_vnet_id), length(split("/", var.hub_vnet_id)) - 1) }
  identity_vnet   = { subscription_id = split("/", var.identity_spoke_vnet_id)[2], resource_group_name = split("/", var.identity_spoke_vnet_id)[4], name = element(split("/", var.identity_spoke_vnet_id), length(split("/", var.identity_spoke_vnet_id)) - 1) }
  management_vnet = { subscription_id = split("/", var.management_spoke_vnet_id)[2], resource_group_name = split("/", var.management_spoke_vnet_id)[4], name = element(split("/", var.management_spoke_vnet_id), length(split("/", var.management_spoke_vnet_id)) - 1) }

  # Role NAMES only (no GUIDs): azurerm resolves them; the ABAC condition below uses the IDs it looks up.
  deploy_identity_assignable_roles = [
    "Reader", "Contributor",
    "Key Vault Secrets User", "Key Vault Secrets Officer", "Key Vault Certificates Officer",
    "Storage Account Contributor",
    "Azure Connected Machine Onboarding", "Azure Connected Machine Resource Administrator", "Azure Connected Machine Resource Manager",
    "Azure Stack HCI Administrator", "Azure Stack HCI VM Contributor", "Azure Stack HCI VM Reader",
    "Log Analytics Reader", "Log Analytics Contributor", "Monitoring Reader", "Monitoring Contributor",
  ]
}

# ---------------------------------------------------------------- S1 resource groups (gap-fill: azurerm_resource_group; design §10.3)
resource "azurerm_resource_group" "this" {
  for_each = local.s1 ? toset(local.rg_keys) : toset([])

  name     = var.names[each.key]
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------- S1 policy guardrails (design §2.4; built-in definitions looked up by display name - no GUIDs)
data "azurerm_policy_definition_built_in" "allowed_locations" {
  display_name = "Allowed locations"
}
data "azurerm_policy_definition_built_in" "require_tag_rg" {
  display_name = "Require a tag on resource groups"
}
data "azurerm_policy_definition_built_in" "inherit_tag" {
  display_name = "Inherit a tag from the resource group if missing"
}
data "azurerm_policy_definition_built_in" "activity_log" {
  display_name = "Configure Azure Activity logs to stream to specified Log Analytics workspace"
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  name                 = var.names.asg_allowed_locations
  display_name         = "NIC26 Azure Local LZ - allowed locations"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition_built_in.allowed_locations.id
  parameters           = jsonencode({ listOfAllowedLocations = { value = local.allowed_locations } })
}

resource "azurerm_subscription_policy_assignment" "require_tags_rg" {
  for_each = local.s1 && var.deploy_platform_scope_items ? { for i, t in local.required_tag_names : tostring(i) => t } : {}

  name                 = "${var.names.asg_require_tags_rg}-${each.key}"
  display_name         = "NIC26 Azure Local LZ - require tag ${each.value} on resource groups"
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_definition_built_in.require_tag_rg.id
  parameters           = jsonencode({ tagName = { value = each.value } })
}

resource "azurerm_subscription_policy_assignment" "inherit_tags" {
  for_each = local.s1 && var.deploy_platform_scope_items ? { for i, t in local.required_tag_names : tostring(i) => t } : {}

  name                 = "${var.names.asg_inherit_tags}-${each.key}"
  display_name         = "NIC26 Azure Local LZ - inherit tag ${each.value} from resource group"
  subscription_id      = local.subscription_scope
  location             = var.location
  policy_definition_id = data.azurerm_policy_definition_built_in.inherit_tag.id
  parameters           = jsonencode({ tagName = { value = each.value } })
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "inherit_tags_remediation" {
  for_each = azurerm_subscription_policy_assignment.inherit_tags

  scope                = local.subscription_scope
  role_definition_name = "Contributor"
  principal_id         = each.value.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "activity_log" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  name                 = var.names.asg_activity_log
  display_name         = "NIC26 Azure Local LZ - activity log to Log Analytics"
  subscription_id      = local.subscription_scope
  location             = var.location
  policy_definition_id = data.azurerm_policy_definition_built_in.activity_log.id
  parameters           = jsonencode({ logAnalytics = { value = local.law_id }, logsEnabled = { value = "True" } })
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "activity_log_remediation" {
  for_each = local.s1 && var.deploy_platform_scope_items ? toset(["Log Analytics Contributor", "Monitoring Contributor"]) : toset([])

  scope                = local.subscription_scope
  role_definition_name = each.value
  principal_id         = azurerm_subscription_policy_assignment.activity_log[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Activity log diagnostic setting (design §7.5) - gap-fill azurerm_monitor_diagnostic_setting
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  name                       = var.names.asg_activity_log
  target_resource_id         = local.subscription_scope
  log_analytics_workspace_id = local.law_id
  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "Policy", "Alert", "Autoscale", "ResourceHealth"]
    content {
      category = enabled_log.value
    }
  }
  depends_on = [module.law]
}

# Budget (design §2.5) - azurerm_consumption_budget_subscription (design §10.3)
resource "time_static" "budget_start" {
  count = local.s1 ? 1 : 0
}

resource "azurerm_consumption_budget_subscription" "this" {
  count = local.s1 && var.budget_monthly_amount > 0 ? 1 : 0

  name            = var.names.budget_azl
  subscription_id = local.subscription_scope
  amount          = var.budget_monthly_amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", time_static.budget_start[0].rfc3339)
  }

  dynamic "notification" {
    for_each = [
      { threshold = 50, type = "Actual" },
      { threshold = 80, type = "Actual" },
      { threshold = 100, type = "Actual" },
      { threshold = 100, type = "Forecasted" },
    ]
    content {
      enabled        = true
      operator       = "GreaterThan"
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      contact_emails = var.budget_contact_emails
      contact_groups = [local.action_group_id]
    }
  }
  depends_on = [azurerm_monitor_action_group.ops]
}

# Defender for Cloud plans (design §7.3) - azurerm_security_center_subscription_pricing (design §10.3)
resource "azurerm_security_center_subscription_pricing" "cspm" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  resource_type = "CloudPosture"
  tier          = "Free"
}

resource "azurerm_security_center_subscription_pricing" "servers" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  resource_type = "VirtualMachines"
  tier          = var.defender_servers_plan == "off" ? "Free" : "Standard"
  subplan       = var.defender_servers_plan == "off" ? null : var.defender_servers_plan
  depends_on    = [azurerm_security_center_subscription_pricing.cspm]
}

resource "azurerm_security_center_subscription_pricing" "keyvaults" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  resource_type = "KeyVaults"
  tier          = var.enable_defender_keyvault ? "Standard" : "Free"
  depends_on    = [azurerm_security_center_subscription_pricing.servers]
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  count = local.s1 && var.deploy_platform_scope_items ? 1 : 0

  resource_type = "StorageAccounts"
  tier          = var.enable_defender_storage ? "Standard" : "Free"
  subplan       = var.enable_defender_storage ? "DefenderForStorageV2" : null
  depends_on    = [azurerm_security_center_subscription_pricing.keyvaults]
}

# Compliance-baseline initiative DEFINITION at management-group scope (design §7.4; assigned in Day-2 Ready).
# Built-in members only; the custom Insights and Key Vault backup-extension definitions are Day-2 (README: parity gaps).
data "azurerm_policy_definition_built_in" "ama_arc_windows" {
  display_name = "Configure Windows Arc-enabled machines to run Azure Monitor Agent"
}
data "azurerm_policy_definition_built_in" "periodic_assessment_arc" {
  display_name = "Configure periodic checking for missing system updates on azure Arc-enabled servers"
}
data "azurerm_policy_definition_built_in" "defender_servers" {
  display_name = "Configure Azure Defender for servers to be enabled"
}

resource "azurerm_policy_set_definition" "hybrid_baseline" {
  count = local.s1 && var.deploy_platform_scope_items && var.management_group_id != "" ? 1 : 0

  name                = var.names.init_hybrid_baseline
  display_name        = "NIC26 hybrid baseline (Azure Local landing zone)"
  description         = "Compliance baseline for the Azure Local landing zone; assigned at subscription scope in Day-2 Ready (design §7.4)."
  policy_type         = "Custom"
  management_group_id = "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
  metadata            = jsonencode({ category = "NIC26", version = "0.1.0" })
  parameters = jsonencode({
    listOfAllowedLocations = { type = "Array", defaultValue = local.allowed_locations }
    logAnalytics           = { type = "String", defaultValue = local.law_id }
  })

  policy_definition_reference {
    reference_id         = "allowed-locations"
    policy_definition_id = data.azurerm_policy_definition_built_in.allowed_locations.id
    parameter_values     = jsonencode({ listOfAllowedLocations = { value = "[parameters('listOfAllowedLocations')]" } })
  }
  policy_definition_reference {
    reference_id         = "activity-log-to-law"
    policy_definition_id = data.azurerm_policy_definition_built_in.activity_log.id
    parameter_values     = jsonencode({ logAnalytics = { value = "[parameters('logAnalytics')]" }, logsEnabled = { value = "True" } })
  }
  policy_definition_reference {
    reference_id         = "ama-on-arc-windows"
    policy_definition_id = data.azurerm_policy_definition_built_in.ama_arc_windows.id
  }
  policy_definition_reference {
    reference_id         = "periodic-assessment-arc"
    policy_definition_id = data.azurerm_policy_definition_built_in.periodic_assessment_arc.id
  }
  policy_definition_reference {
    reference_id         = "defender-for-servers"
    policy_definition_id = data.azurerm_policy_definition_built_in.defender_servers.id
  }
}
