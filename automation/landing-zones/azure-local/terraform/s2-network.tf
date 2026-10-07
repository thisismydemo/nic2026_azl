# Stage S2 Network (design §4). AVM: Azure/avm-res-network-virtualnetwork 0.22.2 (subnets), Azure/avm-res-network-routetable 0.5.0.
# Gap-fill azurerm (design §10.3): NSGs, private DNS zones + links. Peerings: azurerm_virtual_network_peering with
# aliased providers so the remote-side resources are created in the shared subscriptions in a controlled order.

locals {
  pe_sources = concat(
    [var.spoke_address_space, var.identity_spoke_prefix, var.management_spoke_prefix, var.p2s_client_pool],
    var.onprem_prefixes,
    var.avd_spoke_prefix == "" ? [] : [var.avd_spoke_prefix]
  )

  # name, priority, direction, access, protocol, ports, sources, destinations (mirrors bicep/modules/network.bicep)
  nsg_rules = {
    nsg_jump = concat([
      ["AllowBastionRdpSshInbound", 100, "Inbound", "Allow", "Tcp", ["3389", "22"], [var.bastion_subnet_prefix], [var.subnet_jump_prefix]],
      ["AllowP2sRdpSshInbound", 110, "Inbound", "Allow", "Tcp", ["3389", "22"], [var.p2s_client_pool], [var.subnet_jump_prefix]],
      ["AllowP2sWinRmInbound", 120, "Inbound", "Allow", "Tcp", ["5985", "5986"], [var.p2s_client_pool], [var.subnet_jump_prefix]],
      ["DenyAllInbound", 4096, "Inbound", "Deny", "*", ["*"], ["*"], ["*"]],
      # the jump server reaches the isolated test-failover network (the asr-test NSG admits the jump subnet only, design 4.6); isolation is enforced on the asr-test NSG, not here
      ["AllowVnetOutbound", 100, "Outbound", "Allow", "*", ["*"], ["VirtualNetwork"], ["VirtualNetwork"]],
      ["AllowOnPremOutbound", 110, "Outbound", "Allow", "*", ["*"], ["*"], var.onprem_prefixes],
      ["AllowInternetHttpsOutbound", 120, "Outbound", "Allow", "Tcp", ["443"], ["*"], ["Internet"]],
      ["AllowAzureKmsActivationOutbound", 130, "Outbound", "Allow", "Tcp", ["1688"], ["*"], ["Internet"]],
      ["DenyAllOutbound", 4096, "Outbound", "Deny", "*", ["*"], ["*"], ["*"]],
    ])
    nsg_pe = [
      ["AllowHttpsFromConsumersInbound", 100, "Inbound", "Allow", "Tcp", ["443"], local.pe_sources, [var.subnet_pe_prefix]],
      ["DenyAllInbound", 4096, "Inbound", "Deny", "*", ["*"], ["*"], ["*"]],
    ]
    nsg_mgmt = [
      ["AllowBastionRdpSshInbound", 100, "Inbound", "Allow", "Tcp", ["3389", "22"], [var.bastion_subnet_prefix], [var.subnet_mgmt_prefix]],
      ["AllowP2sSshWinRmInbound", 110, "Inbound", "Allow", "Tcp", ["22", "5985", "5986"], [var.p2s_client_pool], [var.subnet_mgmt_prefix]],
      ["DenyAllInbound", 4096, "Inbound", "Deny", "*", ["*"], ["*"], ["*"]],
      ["AllowVnetOutbound", 100, "Outbound", "Allow", "*", ["*"], ["VirtualNetwork"], ["VirtualNetwork"]],
      ["AllowOnPremOutbound", 110, "Outbound", "Allow", "*", ["*"], ["*"], var.onprem_prefixes],
      ["AllowInternetHttpsOutbound", 120, "Outbound", "Allow", "Tcp", ["443"], ["*"], ["Internet"]],
      ["AllowAzureKmsActivationOutbound", 130, "Outbound", "Allow", "Tcp", ["1688"], ["*"], ["Internet"]],
      ["DenyAllOutbound", 4096, "Outbound", "Deny", "*", ["*"], ["*"], ["*"]],
    ]
    nsg_asr = [
      ["AllowJumpRdpSshInbound", 100, "Inbound", "Allow", "Tcp", ["3389", "22"], [var.subnet_jump_prefix], [var.subnet_asr_prefix]],
      ["DenyAllInbound", 4096, "Inbound", "Deny", "*", ["*"], ["*"], ["*"]],
      ["AllowVnetOutbound", 100, "Outbound", "Allow", "*", ["*"], ["VirtualNetwork"], ["VirtualNetwork"]],
      ["AllowOnPremOutbound", 110, "Outbound", "Allow", "*", ["*"], ["*"], var.onprem_prefixes],
      ["AllowAzureKmsActivationOutbound", 120, "Outbound", "Allow", "Tcp", ["1688"], ["*"], ["Internet"]],
      ["DenyAllOutbound", 4096, "Outbound", "Deny", "*", ["*"], ["*"], ["*"]],
    ]
    nsg_asr_test = concat([
      ["AllowJumpInbound", 100, "Inbound", "Allow", "*", ["*"], [var.subnet_jump_prefix], [var.subnet_asr_test_prefix]],
      ["DenyAllInbound", 4096, "Inbound", "Deny", "*", ["*"], ["*"], ["*"]],
      ["AllowIntraSubnetOutbound", 100, "Outbound", "Allow", "*", ["*"], [var.subnet_asr_test_prefix], [var.subnet_asr_test_prefix]],
      ["DenyOnPremOutbound", 110, "Outbound", "Deny", "*", ["*"], ["*"], var.onprem_prefixes],
      ], var.avd_spoke_prefix == "" ? [] : [
      ["DenyAvdSpokeOutbound", 120, "Outbound", "Deny", "*", ["*"], ["*"], [var.avd_spoke_prefix]],
      ], [
      ["DenyVnetOutbound", 130, "Outbound", "Deny", "*", ["*"], ["*"], ["VirtualNetwork"]],
      ["AllowInternetHttpsOutbound", 140, "Outbound", "Allow", "Tcp", ["443"], ["*"], ["Internet"]],
      ["AllowAzureKmsActivationOutbound", 150, "Outbound", "Allow", "Tcp", ["1688"], ["*"], ["Internet"]],
      ["DenyAllOutbound", 4096, "Outbound", "Deny", "*", ["*"], ["*"], ["*"]],
    ])
  }

  nsg_diag_logs = { default = { name = "to-law", workspace_resource_id = local.law_id, log_groups = ["allLogs"], metric_categories = [] } }

  zone_links = merge(
    {
      azl      = { name = var.names.link_azl, vnet_id = local.vnet_id }
      identity = { name = var.names.link_identity, vnet_id = var.identity_spoke_vnet_id }
    },
    var.avd_spoke_vnet_id == "" ? {} : { avd = { name = var.names.link_avd, vnet_id = var.avd_spoke_vnet_id } }
  )
  monitor_zone_keys = ["pdns_monitor", "pdns_oms", "pdns_ods", "pdns_agentsvc"]
}

# ---------------------------------------------------------------- NSGs (design §4.6)
resource "azurerm_network_security_group" "this" {
  for_each = local.s2 ? local.nsg_rules : {}

  name                = var.names[each.key]
  location            = var.location
  resource_group_name = var.names.rg_net
  tags                = local.tags

  dynamic "security_rule" {
    for_each = { for r in each.value : r[0] => r }
    content {
      name                         = security_rule.value[0]
      priority                     = security_rule.value[1]
      direction                    = security_rule.value[2]
      access                       = security_rule.value[3]
      protocol                     = security_rule.value[4]
      source_port_range            = "*"
      destination_port_range       = contains(security_rule.value[5], "*") ? "*" : null
      destination_port_ranges      = contains(security_rule.value[5], "*") ? null : security_rule.value[5]
      source_address_prefix        = length(security_rule.value[6]) == 1 ? security_rule.value[6][0] : null
      source_address_prefixes      = length(security_rule.value[6]) == 1 ? null : security_rule.value[6]
      destination_address_prefix   = length(security_rule.value[7]) == 1 ? security_rule.value[7][0] : null
      destination_address_prefixes = length(security_rule.value[7]) == 1 ? null : security_rule.value[7]
    }
  }
  depends_on = [azurerm_resource_group.this]
}

resource "azurerm_monitor_diagnostic_setting" "nsg" {
  for_each = azurerm_network_security_group.this

  name                       = "to-law"
  target_resource_id         = each.value.id
  log_analytics_workspace_id = local.law_id
  enabled_log {
    category_group = "allLogs"
  }
  depends_on = [module.law]
}

# ---------------------------------------------------------------- route table (design §4.4)
module "route_table" {
  source  = "Azure/avm-res-network-routetable/azurerm"
  version = "0.5.0"
  count   = local.s2 ? 1 : 0

  name                          = var.names.rt_azl
  location                      = var.location
  resource_group_name           = var.names.rg_net
  bgp_route_propagation_enabled = true
  routes                        = {}
  tags                          = local.tags
  enable_telemetry              = false
  depends_on                    = [azurerm_resource_group.this]
}

# ---------------------------------------------------------------- VNet + subnets (design §4.1)
module "vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.2"
  count   = local.s2 ? 1 : 0

  name             = var.names.spoke_vnet
  location         = var.location
  parent_id        = local.rg_id.rg_net
  address_space    = [var.spoke_address_space]
  dns_servers      = { dns_servers = var.dns_servers }
  tags             = local.tags
  enable_telemetry = false

  diagnostic_settings = {
    default = { name = "to-law", workspace_resource_id = local.law_id, log_groups = ["allLogs"], metric_categories = ["AllMetrics"] }
  }

  subnets = {
    jump = {
      name                   = var.names.snet_jump
      address_prefixes       = [var.subnet_jump_prefix]
      network_security_group = { id = azurerm_network_security_group.this["nsg_jump"].id }
      route_table            = { id = module.route_table[0].resource_id }
    }
    pe = {
      name                              = var.names.snet_pe
      address_prefixes                  = [var.subnet_pe_prefix]
      network_security_group            = { id = azurerm_network_security_group.this["nsg_pe"].id }
      route_table                       = { id = module.route_table[0].resource_id }
      private_endpoint_network_policies = "Enabled"
    }
    mgmt = {
      name                   = var.names.snet_mgmt
      address_prefixes       = [var.subnet_mgmt_prefix]
      network_security_group = { id = azurerm_network_security_group.this["nsg_mgmt"].id }
      route_table            = { id = module.route_table[0].resource_id }
    }
    asr = {
      name                   = var.names.snet_asr
      address_prefixes       = [var.subnet_asr_prefix]
      network_security_group = { id = azurerm_network_security_group.this["nsg_asr"].id }
      route_table            = { id = module.route_table[0].resource_id }
    }
    asr_test = {
      name                   = var.names.snet_asr_test
      address_prefixes       = [var.subnet_asr_test_prefix]
      network_security_group = { id = azurerm_network_security_group.this["nsg_asr_test"].id }
      route_table            = { id = module.route_table[0].resource_id }
    }
  }
  depends_on = [azurerm_resource_group.this, module.law]
}

# ---------------------------------------------------------------- peerings (design §4.2; P-13)
# Order: VNet -> remote side -> local side, so useRemoteGateways finds allowGatewayTransit on the hub.
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count    = local.s2 && var.deploy_platform_scope_items ? 1 : 0
  provider = azurerm.hub

  name                         = var.names.peer_hub_to_spoke
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = local.hub_vnet.name
  remote_virtual_network_id    = local.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
  depends_on                   = [module.vnet]
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count = local.s2 ? 1 : 0

  name                         = var.names.peer_spoke_to_hub
  resource_group_name          = var.names.rg_net
  virtual_network_name         = var.names.spoke_vnet
  remote_virtual_network_id    = var.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = true
  depends_on                   = [module.vnet]
}

resource "azurerm_virtual_network_peering" "spoke_to_avd" {
  count = local.s2 && var.avd_spoke_vnet_id != "" ? 1 : 0

  name                         = var.names.peer_spoke_to_avd
  resource_group_name          = var.names.rg_net
  virtual_network_name         = var.names.spoke_vnet
  remote_virtual_network_id    = var.avd_spoke_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  depends_on                   = [module.vnet]
}

resource "azurerm_virtual_network_peering" "identity_to_spoke" {
  count    = local.s2 && var.enable_identity_peering && var.deploy_platform_scope_items ? 1 : 0
  provider = azurerm.identity

  name                         = var.names.peer_identity_to_spoke
  resource_group_name          = local.identity_vnet.resource_group_name
  virtual_network_name         = local.identity_vnet.name
  remote_virtual_network_id    = local.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  depends_on                   = [module.vnet]
}

resource "azurerm_virtual_network_peering" "spoke_to_identity" {
  count = local.s2 && var.enable_identity_peering ? 1 : 0

  name                         = var.names.peer_spoke_to_identity
  resource_group_name          = var.names.rg_net
  virtual_network_name         = var.names.spoke_vnet
  remote_virtual_network_id    = var.identity_spoke_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  depends_on                   = [azurerm_virtual_network_peering.identity_to_spoke]
}

resource "azurerm_virtual_network_peering" "management_to_spoke" {
  count    = local.s2 && var.enable_management_peering && var.deploy_platform_scope_items ? 1 : 0
  provider = azurerm.management

  name                         = var.names.peer_mgmt_to_spoke
  resource_group_name          = local.management_vnet.resource_group_name
  virtual_network_name         = local.management_vnet.name
  remote_virtual_network_id    = local.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  depends_on                   = [module.vnet]
}

resource "azurerm_virtual_network_peering" "spoke_to_management" {
  count = local.s2 && var.enable_management_peering ? 1 : 0

  name                         = var.names.peer_spoke_to_mgmt
  resource_group_name          = var.names.rg_net
  virtual_network_name         = var.names.spoke_vnet
  remote_virtual_network_id    = var.management_spoke_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  depends_on                   = [azurerm_virtual_network_peering.management_to_spoke]
}

# ---------------------------------------------------------------- private DNS (design §4.5; P-11 own zone)
resource "azurerm_private_dns_zone" "vaultcore" {
  count = local.s2 && var.enable_private_endpoints && var.privatelink_vaultcore_zone_id == "" ? 1 : 0

  name                = var.names.pdns_vaultcore
  resource_group_name = var.names.rg_net
  tags                = local.tags
  depends_on          = [azurerm_resource_group.this]
}

resource "azurerm_private_dns_zone_virtual_network_link" "vaultcore" {
  for_each = local.s2 && var.enable_private_endpoints && var.privatelink_vaultcore_zone_id == "" ? local.zone_links : {}

  name                  = each.value.name
  resource_group_name   = var.names.rg_net
  private_dns_zone_name = azurerm_private_dns_zone.vaultcore[0].name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = false
  tags                  = local.tags
  depends_on            = [module.vnet]
}

resource "azurerm_private_dns_zone" "monitor" {
  for_each = local.s2 && local.monitor_pl ? toset(local.monitor_zone_keys) : toset([])

  name                = var.names[each.key]
  resource_group_name = var.names.rg_net
  tags                = local.tags
  depends_on          = [azurerm_resource_group.this]
}

resource "azurerm_private_dns_zone_virtual_network_link" "monitor" {
  for_each = local.s2 && local.monitor_pl ? { for pair in setproduct(local.monitor_zone_keys, keys(local.zone_links)) : "${pair[0]}-${pair[1]}" => { zone = pair[0], link = pair[1] } } : {}

  name                  = local.zone_links[each.value.link].name
  resource_group_name   = var.names.rg_net
  private_dns_zone_name = azurerm_private_dns_zone.monitor[each.value.zone].name
  virtual_network_id    = local.zone_links[each.value.link].vnet_id
  registration_enabled  = false
  tags                  = local.tags
  depends_on            = [module.vnet]
}
