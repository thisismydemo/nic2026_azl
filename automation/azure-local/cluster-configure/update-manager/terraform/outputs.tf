# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "maintenance_configuration_id" { value = azurerm_maintenance_configuration.guest.id }
output "dynamic_scope_assignment_id" { value = azurerm_maintenance_assignment_dynamic_scope.arc.id }
