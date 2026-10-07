// Stage S2 Network (design §4): NSGs, route table, spoke VNet with five subnets, private DNS zones + links.
// Peerings are created by vnet-peering.bicep from main.bicep (ordering: VNet -> hub side -> spoke side).
// AVM: network-security-group 0.5.3, route-table 0.5.0, virtual-network 0.10.2, private-dns-zone 0.8.1.
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param log_analytics_workspace_id string

param spoke_address_space string
param subnet_jump_prefix string
param subnet_pe_prefix string
param subnet_mgmt_prefix string
param subnet_asr_prefix string
param subnet_asr_test_prefix string
param dns_servers array

param bastion_subnet_prefix string
param p2s_client_pool string
param onprem_prefixes array
param identity_spoke_prefix string
param management_spoke_prefix string
param avd_spoke_prefix string

param identity_spoke_vnet_id string
param avd_spoke_vnet_id string
param privatelink_vaultcore_zone_id string
param enable_private_endpoints bool = true
param enable_monitor_private_link bool

// ---------------------------------------------------------------- helpers
var diagLogs = [
  {
    workspaceResourceId: log_analytics_workspace_id
    logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
  }
]
var peSources = concat(
  [spoke_address_space, identity_spoke_prefix, management_spoke_prefix, p2s_client_pool],
  onprem_prefixes,
  empty(avd_spoke_prefix) ? [] : [avd_spoke_prefix]
)

func rule(name string, priority int, direction string, access string, protocol string, ports array, sources array, destinations array) object => {
  name: name
  properties: {
    priority: priority
    direction: direction
    access: access
    protocol: protocol
    sourcePortRange: '*'
    // NSG validation rejects '*' inside a range list: a wildcard must use the single-value property.
    destinationPortRange: contains(ports, '*') ? '*' : null
    destinationPortRanges: contains(ports, '*') ? null : ports
    // A wildcard or a service tag (VirtualNetwork, Internet) is only valid in the single-value properties.
    sourceAddressPrefix: length(sources) == 1 ? sources[0] : null
    sourceAddressPrefixes: length(sources) == 1 ? null : sources
    destinationAddressPrefix: length(destinations) == 1 ? destinations[0] : null
    destinationAddressPrefixes: length(destinations) == 1 ? null : destinations
  }
}

// ---------------------------------------------------------------- NSGs (design §4.6)
module nsgJump 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-jump'
  params: {
    name: names.nsg_jump
    location: location
    tags: tags
    diagnosticSettings: diagLogs
    securityRules: [
      rule('AllowBastionRdpSshInbound', 100, 'Inbound', 'Allow', 'Tcp', ['3389', '22'], [bastion_subnet_prefix], [subnet_jump_prefix])
      rule('AllowP2sRdpSshInbound', 110, 'Inbound', 'Allow', 'Tcp', ['3389', '22'], [p2s_client_pool], [subnet_jump_prefix])
      rule('AllowP2sWinRmInbound', 120, 'Inbound', 'Allow', 'Tcp', ['5985', '5986'], [p2s_client_pool], [subnet_jump_prefix])
      rule('DenyAllInbound', 4096, 'Inbound', 'Deny', '*', ['*'], ['*'], ['*'])
      // the jump server reaches the isolated test-failover network (the asr-test NSG admits the jump subnet only, design 4.6); isolation is enforced on the asr-test NSG, not here
      rule('AllowVnetOutbound', 100, 'Outbound', 'Allow', '*', ['*'], ['VirtualNetwork'], ['VirtualNetwork'])
      rule('AllowOnPremOutbound', 110, 'Outbound', 'Allow', '*', ['*'], ['*'], onprem_prefixes)
      rule('AllowInternetHttpsOutbound', 120, 'Outbound', 'Allow', 'Tcp', ['443'], ['*'], ['Internet'])
      rule('AllowAzureKmsActivationOutbound', 130, 'Outbound', 'Allow', 'Tcp', ['1688'], ['*'], ['Internet'])
      rule('DenyAllOutbound', 4096, 'Outbound', 'Deny', '*', ['*'], ['*'], ['*'])
    ]
  }
}

module nsgPe 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-pe'
  params: {
    name: names.nsg_pe
    location: location
    tags: tags
    diagnosticSettings: diagLogs
    securityRules: [
      rule('AllowHttpsFromConsumersInbound', 100, 'Inbound', 'Allow', 'Tcp', ['443'], peSources, [subnet_pe_prefix])
      rule('DenyAllInbound', 4096, 'Inbound', 'Deny', '*', ['*'], ['*'], ['*'])
    ]
  }
}

module nsgMgmt 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-mgmt'
  params: {
    name: names.nsg_mgmt
    location: location
    tags: tags
    diagnosticSettings: diagLogs
    securityRules: [
      rule('AllowBastionRdpSshInbound', 100, 'Inbound', 'Allow', 'Tcp', ['3389', '22'], [bastion_subnet_prefix], [subnet_mgmt_prefix])
      rule('AllowP2sSshWinRmInbound', 110, 'Inbound', 'Allow', 'Tcp', ['22', '5985', '5986'], [p2s_client_pool], [subnet_mgmt_prefix])
      rule('DenyAllInbound', 4096, 'Inbound', 'Deny', '*', ['*'], ['*'], ['*'])
      rule('AllowVnetOutbound', 100, 'Outbound', 'Allow', '*', ['*'], ['VirtualNetwork'], ['VirtualNetwork'])
      rule('AllowOnPremOutbound', 110, 'Outbound', 'Allow', '*', ['*'], ['*'], onprem_prefixes)
      rule('AllowInternetHttpsOutbound', 120, 'Outbound', 'Allow', 'Tcp', ['443'], ['*'], ['Internet'])
      rule('AllowAzureKmsActivationOutbound', 130, 'Outbound', 'Allow', 'Tcp', ['1688'], ['*'], ['Internet'])
      rule('DenyAllOutbound', 4096, 'Outbound', 'Deny', '*', ['*'], ['*'], ['*'])
    ]
  }
}

// Production failover network: application ports are opened at failover-test time (Day-2 runbook);
// at build time only operator access from the jump subnet is allowed.
module nsgAsr 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-asr'
  params: {
    name: names.nsg_asr
    location: location
    tags: tags
    diagnosticSettings: diagLogs
    securityRules: [
      rule('AllowJumpRdpSshInbound', 100, 'Inbound', 'Allow', 'Tcp', ['3389', '22'], [subnet_jump_prefix], [subnet_asr_prefix])
      rule('DenyAllInbound', 4096, 'Inbound', 'Deny', '*', ['*'], ['*'], ['*'])
      rule('AllowVnetOutbound', 100, 'Outbound', 'Allow', '*', ['*'], ['VirtualNetwork'], ['VirtualNetwork'])
      rule('AllowOnPremOutbound', 110, 'Outbound', 'Allow', '*', ['*'], ['*'], onprem_prefixes)
      rule('AllowAzureKmsActivationOutbound', 120, 'Outbound', 'Allow', 'Tcp', ['1688'], ['*'], ['Internet'])
      rule('DenyAllOutbound', 4096, 'Outbound', 'Deny', '*', ['*'], ['*'], ['*'])
    ]
  }
}

// Test failover network: isolated (design §4.1 chooses its own NSG so production rules are never relaxed by a test).
module nsgAsrTest 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-asr-test'
  params: {
    name: names.nsg_asr_test
    location: location
    tags: tags
    diagnosticSettings: diagLogs
    securityRules: concat([
      rule('AllowJumpInbound', 100, 'Inbound', 'Allow', '*', ['*'], [subnet_jump_prefix], [subnet_asr_test_prefix])
      rule('DenyAllInbound', 4096, 'Inbound', 'Deny', '*', ['*'], ['*'], ['*'])
      rule('AllowIntraSubnetOutbound', 100, 'Outbound', 'Allow', '*', ['*'], [subnet_asr_test_prefix], [subnet_asr_test_prefix])
      rule('DenyOnPremOutbound', 110, 'Outbound', 'Deny', '*', ['*'], ['*'], onprem_prefixes)
    ], empty(avd_spoke_prefix) ? [] : [
      rule('DenyAvdSpokeOutbound', 120, 'Outbound', 'Deny', '*', ['*'], ['*'], [avd_spoke_prefix])
    ], [
      rule('DenyVnetOutbound', 130, 'Outbound', 'Deny', '*', ['*'], ['*'], ['VirtualNetwork'])
      rule('AllowInternetHttpsOutbound', 140, 'Outbound', 'Allow', 'Tcp', ['443'], ['*'], ['Internet'])
      rule('AllowAzureKmsActivationOutbound', 150, 'Outbound', 'Allow', 'Tcp', ['1688'], ['*'], ['Internet'])
      rule('DenyAllOutbound', 4096, 'Outbound', 'Deny', '*', ['*'], ['*'], ['*'])
    ])
  }
}

// ---------------------------------------------------------------- route table (design §4.4: no routes, propagation on)
module routeTable 'br/public:avm/res/network/route-table:0.5.0' = {
  name: 'rt-azl'
  params: {
    name: names.rt_azl
    location: location
    tags: tags
    disableBgpRoutePropagation: false
    routes: []
  }
}

// ---------------------------------------------------------------- VNet (design §4.1)
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-azl'
  params: {
    name: names.spoke_vnet
    location: location
    tags: tags
    addressPrefixes: [spoke_address_space]
    dnsServers: dns_servers
    diagnosticSettings: [
      {
        workspaceResourceId: log_analytics_workspace_id
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
        metricCategories: [{ category: 'AllMetrics' }]
      }
    ]
    subnets: [
      {
        name: names.snet_jump
        addressPrefix: subnet_jump_prefix
        networkSecurityGroupResourceId: nsgJump.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
      }
      {
        name: names.snet_pe
        addressPrefix: subnet_pe_prefix
        networkSecurityGroupResourceId: nsgPe.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
        privateEndpointNetworkPolicies: 'Enabled' // so the NSG applies to the private endpoints (design §4.1)
      }
      {
        name: names.snet_mgmt
        addressPrefix: subnet_mgmt_prefix
        networkSecurityGroupResourceId: nsgMgmt.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
      }
      {
        name: names.snet_asr
        addressPrefix: subnet_asr_prefix
        networkSecurityGroupResourceId: nsgAsr.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
      }
      {
        name: names.snet_asr_test
        addressPrefix: subnet_asr_test_prefix
        networkSecurityGroupResourceId: nsgAsrTest.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
      }
    ]
  }
}

// ---------------------------------------------------------------- private DNS (design §4.5, decision P-11)
var zoneLinks = concat(
  [
    { name: names.link_azl, virtualNetworkResourceId: vnet.outputs.resourceId, registrationEnabled: false }
    { name: names.link_identity, virtualNetworkResourceId: identity_spoke_vnet_id, registrationEnabled: false }
  ],
  empty(avd_spoke_vnet_id) ? [] : [
    { name: names.link_avd, virtualNetworkResourceId: avd_spoke_vnet_id, registrationEnabled: false }
  ]
)

// Own zone unless a shared zone is reused (then links on the shared zone are the zone owner's change, not ours).
module pdnsVaultcore 'br/public:avm/res/network/private-dns-zone:0.8.1' = if (enable_private_endpoints && empty(privatelink_vaultcore_zone_id)) {
  name: 'pdns-vaultcore'
  params: {
    name: names.pdns_vaultcore
    location: 'global'
    tags: tags
    virtualNetworkLinks: zoneLinks
  }
}

var monitorZoneKeys = ['pdns_monitor', 'pdns_oms', 'pdns_ods', 'pdns_agentsvc']
module pdnsMonitor 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for key in monitorZoneKeys: if (enable_monitor_private_link) {
  name: 'pdns-${key}'
  params: {
    name: names[key]
    location: 'global'
    tags: tags
    virtualNetworkLinks: zoneLinks
  }
}]

// ---------------------------------------------------------------- outputs
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output subnetIds object = {
  jump: vnet.outputs.subnetResourceIds[0]
  pe: vnet.outputs.subnetResourceIds[1]
  mgmt: vnet.outputs.subnetResourceIds[2]
  asr: vnet.outputs.subnetResourceIds[3]
  asr_test: vnet.outputs.subnetResourceIds[4]
}
output vaultcoreZoneId string = !enable_private_endpoints ? '' : (empty(privatelink_vaultcore_zone_id) ? pdnsVaultcore!.outputs.resourceId : privatelink_vaultcore_zone_id)
