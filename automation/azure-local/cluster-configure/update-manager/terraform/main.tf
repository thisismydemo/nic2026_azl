# Same resources and names as bicep/main.bicep. Gap-fill with azurerm native resources: Azure/avm-res-maintenance-
# maintenanceconfiguration is at 0.1.0 (install_patches shape not documented in its README) and no Terraform AVM module
# exists for the dynamic-scope assignment; the Bicep track uses avm/res/maintenance/maintenance-configuration:0.4.0.

locals {
  tags = merge(var.tags, { "managed-by" = "terraform" })
}

resource "azurerm_maintenance_configuration" "guest" {
  name                     = var.names["mc_azl"]
  resource_group_name      = var.names["rg_mon"]
  location                 = var.location
  scope                    = "InGuestPatch"
  visibility               = "Custom"
  in_guest_user_patch_mode = "User"
  tags                     = local.tags

  window {
    start_date_time = var.maintenance_window.start_date_time
    duration        = var.maintenance_window.duration
    time_zone       = var.maintenance_window.time_zone
    recur_every     = var.maintenance_window.recur_every
  }

  install_patches {
    reboot = var.reboot_setting
    windows {
      classifications_to_include = var.patch_classifications
    }
    linux {
      classifications_to_include = ["Critical", "Security"]
    }
  }
}

resource "azurerm_maintenance_assignment_dynamic_scope" "arc" {
  name                         = var.names["mc_azl_dynscope"]
  maintenance_configuration_id = azurerm_maintenance_configuration.guest.id

  filter {
    resource_types = ["microsoft.hybridcompute/machines"] # (verify) accepted spelling for Arc-enabled servers
    os_types       = var.dynamic_scope_os_types
    tag_filter     = "All"
    dynamic "tags" {
      for_each = var.dynamic_scope_tags
      content {
        tag    = tags.key
        values = tags.value
      }
    }
  }
}
