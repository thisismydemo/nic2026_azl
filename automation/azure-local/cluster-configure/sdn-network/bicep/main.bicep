// SDN enabled by Azure Arc: logical networks and network security groups on the Azure Local instance (network-design 4.6).
// API version 2026-04-01-preview for the VM management resources. Requires SDN enabled by Arc (Add-EceFeature -Name NC)
// before NSGs are created. Every value comes from the environment file (sdn, logical_networks, network_security_groups,
// tags, location) through ConvertTo-NIC26BicepParam; nothing here is specific to one deployment.
// Every NSG has at least one rule (Learn: an empty NSG blocks all inbound traffic).

targetScope = 'resourceGroup'

@description('Azure region of the Azure Local instance.')
param location string

#disable-next-line no-unused-params
param subscription_id string

@description('Tags on every resource.')
param tags object

@description('sdn block of the environment file; vm_switch_name is the Hyper-V switch the compute intent created.')
param sdn object

@description('vm_management block of the environment file; custom_location is the custom location of the Azure Local instance (same resource group).')
param vm_management object

@description('Logical networks: name, purpose, vlan_id, subnet, gateway, ip_pool { start, end }, dns_servers, nsg (name of an NSG or empty).')
param logical_networks array

@description('Network security groups: name and rules (name, priority, direction, access, protocol, source[], destination[], ports[]).')
param network_security_groups array

@description('Pass switch: false creates the logical networks only (pass 1), true adds the NSGs, their rules and the attachment (pass 2).')
param deploy_network_security_groups bool = true

@description('Resolved name catalog (deployment_name).')
#disable-next-line no-unused-params
param names object

var customLocationId = resourceId('Microsoft.ExtendedLocation/customLocations', vm_management.custom_location)
var extendedLocation = {
  type: 'CustomLocation'
  name: customLocationId
}
var nsgs = deploy_network_security_groups ? network_security_groups : []

resource nsg 'Microsoft.AzureStackHCI/networkSecurityGroups@2026-04-01-preview' = [for n in nsgs: {
  name: n.name
  location: location
  extendedLocation: extendedLocation
  tags: tags
  properties: {}
}]

// Rules flattened (one deployment resource per rule), parented by name.
var rules = flatten(map(range(0, length(nsgs)), i => map(nsgs[i].rules, r => union(r, { nsgIndex: i }))))

resource rule 'Microsoft.AzureStackHCI/networkSecurityGroups/securityRules@2026-04-01-preview' = [for r in rules: {
  parent: nsg[r.nsgIndex]
  name: r.name
  extendedLocation: extendedLocation
  properties: {
    description: r.?description ?? r.name
    priority: r.priority
    direction: r.direction
    access: r.access
    protocol: r.protocol
    sourceAddressPrefixes: r.source
    sourcePortRanges: [
      '*'
    ]
    destinationAddressPrefixes: r.destination
    destinationPortRanges: r.ports
  }
}]

resource lnet 'Microsoft.AzureStackHCI/logicalNetworks@2026-04-01-preview' = [for l in logical_networks: {
  name: l.name
  location: location
  extendedLocation: extendedLocation
  tags: union(tags, { vlan: string(l.vlan_id), purpose: l.purpose })
  properties: {
    vmSwitchName: sdn.vm_switch_name
    dhcpOptions: {
      dnsServers: l.dns_servers
    }
    subnets: [
      {
        name: '${l.name}-subnet'
        properties: union({
          addressPrefix: l.subnet
          ipAllocationMethod: 'Static'
          vlan: l.vlan_id
          ipPools: [
            {
              name: 'vm-pool'
              ipPoolType: 'vm'
              start: l.ip_pool.start
              end: l.ip_pool.end
            }
          ]
          routeTable: {
            properties: {
              routes: [
                {
                  name: 'default'
                  properties: {
                    addressPrefix: '0.0.0.0/0'
                    nextHopIpAddress: l.gateway
                  }
                }
              ]
            }
          }
        }, (!deploy_network_security_groups || empty(l.?nsg ?? '')) ? {} : {
          networkSecurityGroup: {
            id: resourceId('Microsoft.AzureStackHCI/networkSecurityGroups', l.nsg)
          }
        })
      }
    ]
  }
  dependsOn: [
    rule
  ]
}]

output logicalNetworkIds array = [for (l, i) in logical_networks: lnet[i].id]
output nsgIds array = [for (n, i) in nsgs: nsg[i].id]
