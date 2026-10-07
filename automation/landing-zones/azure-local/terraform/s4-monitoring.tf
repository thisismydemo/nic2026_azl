# Stage S4 Monitoring (design §7.1, §7.2). AVM: Azure/avm-res-operationalinsights-workspace 0.5.1.
# Action group and DCE: gap-fill azurerm (design §10.3: AVM not confirmed).
module "law" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.5.1"
  count   = local.s4 && var.central_log_analytics_workspace_id == "" ? 1 : 0

  name                                               = var.names.law
  location                                           = var.location
  resource_group_name                                = var.names.rg_mon
  log_analytics_workspace_sku                        = "PerGB2018"
  log_analytics_workspace_retention_in_days          = var.law_retention_days
  log_analytics_workspace_daily_quota_gb             = var.law_daily_cap_gb
  log_analytics_workspace_internet_ingestion_enabled = true
  log_analytics_workspace_internet_query_enabled     = true
  tags                                               = local.tags
  enable_telemetry                                   = false

  diagnostic_settings = {
    audit = {
      name                  = "audit-to-self"
      workspace_resource_id = local.law_id
      log_categories        = ["Audit"]
      log_groups            = []
      metric_categories     = []
    }
  }
  depends_on = [azurerm_resource_group.this]
}

resource "azurerm_monitor_action_group" "ops" {
  count = local.s4 ? 1 : 0

  name                = var.names.ag_ops
  resource_group_name = var.names.rg_mon
  short_name          = substr(replace(var.names.ag_ops, "-", ""), 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = { for i, e in var.budget_contact_emails : tostring(i) => e }
    content {
      name                    = "owner-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
  depends_on = [azurerm_resource_group.this]
}

resource "azurerm_monitor_data_collection_endpoint" "azl" {
  count = local.s4 && local.monitor_pl ? 1 : 0

  name                          = var.names.dce_azl
  resource_group_name           = var.names.rg_mon
  location                      = var.location
  kind                          = "Windows"
  public_network_access_enabled = true
  tags                          = local.tags
  depends_on                    = [azurerm_resource_group.this]
}
