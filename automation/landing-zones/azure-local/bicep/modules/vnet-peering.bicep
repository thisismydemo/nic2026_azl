// Gap-fill: one virtual network peering (design §4.2). Used for the spoke-to-hub, hub-to-spoke (cross-subscription,
// the ONLY change to the hub, LZ-04) and spoke-to-AVD peerings. Kept outside the AVM virtual-network module so the
// hub side can be created in the connectivity subscription in a controlled order.
targetScope = 'resourceGroup'

@description('Name of the local VNet (must exist in this resource group).')
param vnet_name string
@description('Peering resource name from the catalog.')
param peering_name string
@description('Remote VNet resource ID.')
param remote_vnet_id string
param allow_virtual_network_access bool = true
param allow_forwarded_traffic bool = true
param allow_gateway_transit bool = false
param use_remote_gateways bool = false

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnet_name
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: peering_name
  parent: vnet
  properties: {
    remoteVirtualNetwork: { id: remote_vnet_id }
    allowVirtualNetworkAccess: allow_virtual_network_access
    allowForwardedTraffic: allow_forwarded_traffic
    allowGatewayTransit: allow_gateway_transit
    useRemoteGateways: use_remote_gateways
  }
}

output peeringId string = peering.id
