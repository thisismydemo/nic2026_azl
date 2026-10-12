// SDN enabled by Azure Arc: logical networks and network security groups on nic26-clus01 (design network-design.md §4.6, D-048).
// API version 2026-04-01-preview for the VM management resources. Requires SDN enabled by Arc (Add-EceFeature -Name NC)
// before NSGs are created. Values come from the environment file; main.example.bicepparam shows the shape with neutral values.
// Every NSG has at least one rule (Learn: an empty NSG blocks all inbound traffic).

targetScope = 'resourceGroup'

@description('Azure region of the Azure Local instance.')
param location string = 'eastus'

@description('Resource ID of the custom location of nic26-clus01.')
param customLocationId string

@description('VM switch the compute intent created (live: ComputeSwitch(compute), 11 Oct 2026).')
param vmSwitchName string = 'ComputeSwitch(compute)'

@description('DNS servers handed to every logical network (the domain controllers).')
param dnsServers array

@description('Tags on every resource.')
param tags object = {}

@description('Network security groups: name and rules (priority, direction, access, protocol, prefixes, ports).')
param nsgs array

@description('Logical networks: name, vlan, prefix, gateway, pool start/end, nsg (name of an NSG in nsgs, or empty).')
param logicalNetworks array

var extendedLocation = {
  type: 'CustomLocation'
  name: customLocationId
}

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
    description: r.description
    priority: r.priority
    direction: r.direction
    access: r.access
    protocol: r.protocol
    sourceAddressPrefixes: r.sourceAddressPrefixes
    sourcePortRanges: [
      '*'
    ]
    destinationAddressPrefixes: r.destinationAddressPrefixes
    destinationPortRanges: r.destinationPortRanges
  }
}]

resource lnet 'Microsoft.AzureStackHCI/logicalNetworks@2026-04-01-preview' = [for l in logicalNetworks: {
  name: l.name
  location: location
  extendedLocation: extendedLocation
  tags: union(tags, { vlan: string(l.vlan), purpose: l.purpose })
  properties: {
    vmSwitchName: vmSwitchName
    dhcpOptions: {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: '${l.name}-subnet'
        properties: union({
          addressPrefix: l.addressPrefix
          ipAllocationMethod: 'Static'
          vlan: l.vlan
          ipPools: [
            {
              name: 'vm-pool'
              ipPoolType: 'vm'
              start: l.poolStart
              end: l.poolEnd
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
        }, empty(l.nsg) ? {} : {
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

output logicalNetworkIds array = [for (l, i) in logicalNetworks: lnet[i].id]
output nsgIds array = [for (n, i) in nsgs: nsg[i].id]
