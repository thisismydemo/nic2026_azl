# Same resources and names as bicep/main.bicep. AVM: Azure/avm-res-azurestackhci-logicalnetwork 2.0.0 (confirmed on the
# registry 2026-10-03). Gap-fill with azapi: marketplace gallery images, storage containers and NSG — no Terraform AVM
# module exists for those types (Azure/avm-res-azurestackhci-marketplacegalleryimage / -storagecontainer: not published).

locals {
  rg_id              = "/subscriptions/${var.subscription_id}/resourceGroups/${var.names["rg_azl"]}"
  custom_location_id = "${local.rg_id}/providers/Microsoft.ExtendedLocation/customLocations/${var.names["cl_azl"]}"
  tags               = merge(var.tags, { "managed-by" = "terraform" })
  # catalog key = lnet_<purpose>; the purpose is the segment before the region in lnet-<org>-<token>-<purpose>-<region>
  lnets = { for l in var.logical_networks : "lnet_${element(split("-", l.name), length(split("-", l.name)) - 2)}" => l }
  paths = { for sp in var.storage.storage_paths : sp.name => coalesce(sp.path, "C:\\ClusterStorage\\${sp.volume}\\vms") }
  imgs  = { for img in var.marketplace_images : img.key => img }
}

module "logical_network" {
  source   = "Azure/avm-res-azurestackhci-logicalnetwork/azurerm"
  version  = "2.0.0"
  for_each = local.lnets

  name                 = var.names[each.key]
  location             = var.location
  resource_group_id    = local.rg_id
  custom_location_id   = local.custom_location_id
  vm_switch_name       = var.vm_switch_name
  vlan_id              = tostring(each.value.vlan_id)
  ip_allocation_method = "Static"
  address_prefix       = each.value.subnet
  default_gateway      = each.value.gateway
  dns_servers          = each.value.dns_servers
  route_name           = "default"
  starting_address     = each.value.ip_pool.start
  ending_address       = each.value.ip_pool.end
  logical_network_tags = local.tags
  enable_telemetry     = false
}

resource "azapi_resource" "storage_path" {
  for_each  = local.paths
  type      = "Microsoft.AzureStackHCI/storageContainers@2025-02-01-preview"
  name      = each.key
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    extendedLocation = { type = "CustomLocation", name = local.custom_location_id }
    properties       = { path = each.value }
  }
}

resource "azapi_resource" "image" {
  for_each  = local.imgs
  type      = "Microsoft.AzureStackHCI/marketplaceGalleryImages@2025-04-01-preview"
  name      = var.names["img_${each.key}"]
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    extendedLocation = { type = "CustomLocation", name = local.custom_location_id }
    properties = merge({
      osType           = each.value.os_type
      hyperVGeneration = each.value.hyper_v_generation
      identifier       = { publisher = each.value.publisher, offer = each.value.offer, sku = each.value.sku }
      version          = { name = each.value.version }
    }, length(var.storage.storage_paths) > 0 ? { containerId = azapi_resource.storage_path[var.storage.storage_paths[0].name].id } : {})
  }
  timeouts {
    create = "3h" # image download time depends on size and the 1 Gb management path (network-design §2.3.1)
    delete = "1h"
  }
}

resource "azapi_resource" "nsg" {
  count     = var.enable_network_security_group ? 1 : 0
  type      = "Microsoft.AzureStackHCI/networkSecurityGroups@2025-02-01-preview"
  name      = var.names["nsg_azl_compute"]
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    extendedLocation = { type = "CustomLocation", name = local.custom_location_id }
    properties       = {}
  }
}
