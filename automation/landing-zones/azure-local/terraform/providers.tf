# Default provider = the landing-zone subscription. Aliased providers target the SHARED VNets' subscriptions for the
# remote-side peering resources only (hub: hub_subscription_id; identity/management: parsed from the VNet IDs).
provider "azurerm" {
  subscription_id                 = var.subscription_id
  tenant_id                       = var.tenant_id
  storage_use_azuread             = true
  resource_provider_registrations = "none" # registration is a script (Register-LzProviders.ps1), design §2.2
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false # purge is an explicit teardown step (naming standard §3b, K-5)
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azurerm" {
  alias                           = "hub"
  subscription_id                 = var.hub_subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  features {}
}

provider "azurerm" {
  alias                           = "identity"
  subscription_id                 = local.identity_vnet.subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  features {}
}

provider "azurerm" {
  alias                           = "management"
  subscription_id                 = local.management_vnet.subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
