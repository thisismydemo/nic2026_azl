# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "baseline_assignment_id" { value = azurerm_subscription_policy_assignment.baseline.id }
output "baseline_principal_id" { value = azurerm_subscription_policy_assignment.baseline.identity[0].principal_id }
output "insights_assignment_ids" { value = var.assign_insights_policies ? [azurerm_subscription_policy_assignment.insights_ama[0].id, azurerm_subscription_policy_assignment.insights_dcra[0].id] : [] }
output "custom_definition_ids" { value = [azurerm_policy_definition.insights_ama.id, azurerm_policy_definition.insights_dcra.id, azurerm_policy_definition.akv_backup_ext.id] }
