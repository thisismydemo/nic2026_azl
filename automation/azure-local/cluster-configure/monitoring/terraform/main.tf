# Same resources and names as bicep/main.bicep. Gap-fill with azurerm native resources: the Terraform AVM module
# Azure/avm-res-insights-datacollectionrule is at 0.1.0 and no AVM module exists for scheduled query rules or alert
# processing rules (checked 2026-10-03); the Bicep track uses the confirmed Bicep AVM modules.

locals {
  rg_mon_id     = "/subscriptions/${var.subscription_id}/resourceGroups/${var.names["rg_mon"]}"
  cluster_rg_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.names["rg_azl"]}"
  law_id        = var.log_analytics_workspace_id != "" ? var.log_analytics_workspace_id : "${local.rg_mon_id}/providers/Microsoft.OperationalInsights/workspaces/${var.names["law"]}"
  ag_id         = var.action_group_id != "" ? var.action_group_id : "${local.rg_mon_id}/providers/Microsoft.Insights/actionGroups/${var.names["ag_ops"]}"
  tags          = merge(var.tags, { "managed-by" = "terraform" })
  insights_dcr  = "${local.rg_mon_id}/providers/Microsoft.Insights/dataCollectionRules/${var.names["dcr_insights"]}"

  alert_rules = {
    alert_node_down = {
      description = "Azure Local node without AMA heartbeat (node failure demo, outline 4.2)."
      severity    = 1
      query       = "Heartbeat | where ResourceType =~ \"machines\" | summarize LastHeartbeat = max(TimeGenerated) by Computer, _ResourceId | where LastHeartbeat < ago(${var.node_heartbeat_minutes}m)"
      dimension   = "Computer"
      # A node silent for longer than the window has no Heartbeat rows and would drop out of the result: look back one hour.
      window = "PT1H"
    }
    alert_storage_health = {
      description = "Health Service fault (Warning/Error) in Microsoft-Windows-Health/Operational (drive failure demo)."
      severity    = 1
      query       = "Event | where EventLog =~ \"Microsoft-Windows-Health/Operational\" | where EventLevelName in (\"Warning\", \"Error\") | summarize count() by Computer, EventID"
      dimension   = "Computer"
    }
    alert_intent_drift = {
      description = "Network ATC intent drift / failed provisioning (channel added by Enable-ClusterInsights -ExtraEventChannels)."
      severity    = 2
      query       = "Event | where EventLog =~ \"Microsoft-Windows-Networking-NetworkATC/Operational\" | where EventLevelName in (\"Warning\", \"Error\") | summarize count() by Computer, EventID"
      dimension   = "Computer"
    }
    alert_capacity = {
      description = "Storage pool capacity threshold fault (capacity management, outline 4.3)."
      severity    = 2
      query       = "Event | where EventLog =~ \"Microsoft-Windows-Health/Operational\" | where RenderedDescription has \"Capacity\" or RenderedDescription has \"PoolCapacityThresholdExceeded\" | summarize count() by Computer"
      dimension   = "Computer"
    }
  }
}

resource "azurerm_monitor_data_collection_rule" "insights" {
  count               = var.manage_insights_dcr_in_iac ? 1 : 0
  name                = var.names["dcr_insights"]
  resource_group_name = var.names["rg_mon"]
  location            = var.location
  kind                = "Windows"
  description         = "Azure Local Insights (cost-conscious): five counters + health and SDDC channels (design 7.2)."
  tags                = local.tags
  destinations {
    log_analytics {
      workspace_resource_id = local.law_id
      name                  = "law"
    }
  }
  data_flow {
    streams      = ["Microsoft-Perf", "Microsoft-Event"]
    destinations = ["law"]
  }
  data_sources {
    performance_counter {
      name                          = "AzureStackHCI-Perf"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "\\Memory\\Available Bytes",
        "\\Network Interface(*)\\Bytes Total/sec",
        "\\Processor(_Total)\\% Processor Time",
        "\\RDMA Activity(*)\\RDMA Inbound Bytes/sec",
        "\\RDMA Activity(*)\\RDMA Outbound Bytes/sec",
      ]
    }
    windows_event_log {
      name    = "AzureStackHCI-Events"
      streams = ["Microsoft-Event"]
      x_path_queries = [
        "microsoft-windows-health/operational!*",
        "microsoft-windows-sddc-management/operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]",
      ]
    }
  }
}

resource "azurerm_monitor_data_collection_rule" "vminsights" {
  count               = var.enable_vm_insights_dcr ? 1 : 0
  name                = var.names["dcr_vminsights"]
  resource_group_name = var.names["rg_mon"]
  location            = var.location
  kind                = "Windows"
  description         = "VM Insights for Azure Local VMs (InsightsMetrics + dependency map)."
  tags                = local.tags
  destinations {
    log_analytics {
      workspace_resource_id = local.law_id
      name                  = "VMInsightsPerf-Logs-Dest"
    }
  }
  data_flow {
    streams      = ["Microsoft-InsightsMetrics"]
    destinations = ["VMInsightsPerf-Logs-Dest"]
  }
  data_flow {
    streams      = ["Microsoft-ServiceMap"]
    destinations = ["VMInsightsPerf-Logs-Dest"]
  }
  data_sources {
    performance_counter {
      name                          = "VMInsightsPerfCounters"
      streams                       = ["Microsoft-InsightsMetrics"]
      sampling_frequency_in_seconds = 60
      counter_specifiers            = ["\\VmInsights\\DetailedMetrics"]
    }
    extension {
      name           = "DependencyAgentDataSource"
      streams        = ["Microsoft-ServiceMap"]
      extension_name = "DependencyAgent"
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "alert" {
  for_each                = local.alert_rules
  name                    = var.names[each.key]
  resource_group_name     = var.names["rg_mon"]
  location                = var.location
  description             = each.value.description
  severity                = each.value.severity
  enabled                 = true
  auto_mitigation_enabled = true
  evaluation_frequency    = var.alert_evaluation_frequency
  window_duration         = try(each.value.window, var.alert_window_size)
  scopes                  = [local.law_id]
  tags                    = local.tags
  criteria {
    query                   = each.value.query
    operator                = "GreaterThan"
    threshold               = 0
    time_aggregation_method = "Count"
    dynamic "dimension" {
      for_each = each.value.dimension == null ? [] : [each.value.dimension]
      content {
        name     = dimension.value
        operator = "Include"
        values   = ["*"]
      }
    }
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }
  action {
    action_groups = [local.ag_id]
  }
}

resource "azurerm_monitor_alert_processing_rule_action_group" "kv_backup" {
  name                 = var.names["alert_kv_backup"]
  resource_group_name  = var.names["rg_mon"]
  scopes               = [local.cluster_rg_id]
  add_action_group_ids = [local.ag_id]
  description          = "Routes the Azure Local Key Vault backup extension alerts (KeyVaultAccess, KeyVaultDoesNotExist) to the ops action group."
  enabled              = true
  tags                 = local.tags
  condition {
    alert_rule_name {
      operator = "Contains"
      values   = ["KeyVault"]
    }
  }
}
