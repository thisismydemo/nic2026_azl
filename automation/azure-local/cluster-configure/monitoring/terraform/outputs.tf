# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "insights_dcr_id" { value = var.manage_insights_dcr_in_iac ? azurerm_monitor_data_collection_rule.insights[0].id : local.insights_dcr }
output "vm_insights_dcr_id" { value = var.enable_vm_insights_dcr ? azurerm_monitor_data_collection_rule.vminsights[0].id : "" }
output "alert_rule_ids" { value = [for k in sort(keys(local.alert_rules)) : azurerm_monitor_scheduled_query_rules_alert_v2.alert[k].id] }
output "kv_backup_processing_rule_id" { value = azurerm_monitor_alert_processing_rule_action_group.kv_backup.id }
output "action_group_id" { value = local.ag_id }
output "log_analytics_workspace_id" { value = local.law_id }
output "metric_alert_rule_ids" { value = [for k in sort(keys(local.metric_alerts)) : var.enable_recommended_metric_alerts ? azurerm_monitor_metric_alert.recommended[k].id : ""] }
output "health_processing_rule_id" { value = var.enable_health_alert_routing ? azurerm_monitor_alert_processing_rule_action_group.health[0].id : "" }
