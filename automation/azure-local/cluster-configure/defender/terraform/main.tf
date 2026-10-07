# Same plans as bicep/main.bicep. azurerm_security_center_subscription_pricing resets the plan to Free on destroy,
# which is the "Remove" semantics of this control.

resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = var.defender_servers_plan == "off" ? "Free" : "Standard"
  resource_type = "VirtualMachines"
  subplan       = var.defender_servers_plan == "off" ? null : var.defender_servers_plan
}

resource "azurerm_security_center_subscription_pricing" "key_vaults" {
  tier          = var.enable_defender_keyvault ? "Standard" : "Free"
  resource_type = "KeyVaults"
  depends_on    = [azurerm_security_center_subscription_pricing.servers]
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  tier          = var.enable_defender_storage ? "Standard" : "Free"
  resource_type = "StorageAccounts"
  subplan       = var.enable_defender_storage ? "DefenderForStorageV2" : null
  depends_on    = [azurerm_security_center_subscription_pricing.key_vaults]
}
