# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "servers_pricing_tier" { value = azurerm_security_center_subscription_pricing.servers.tier }
output "servers_sub_plan" { value = var.defender_servers_plan == "off" ? "" : var.defender_servers_plan }
