using 'main.bicep'

// Example only: neutral documentation values (RFC 5737 addresses, example VLAN IDs). Replace every value with your own,
// or generate the parameter file from your environment file. Order: logical networks first (nsg: ''), then the NSGs,
// then attach each NSG to its logical network (see ../README.md: the CLI script is the build path).

param location = 'eastus'
param customLocationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.ExtendedLocation/customLocations/cl-example'
param vmSwitchName = 'ConvergedSwitch(compute)'
param dnsServers = [
  '192.0.2.10'
  '192.0.2.11'
]
param tags = {
  project: 'example'
  environment: 'demo'
  'managed-by': 'bicep'
}

param logicalNetworks = [
  { name: 'lnet-example-workload-vlan100-eus', purpose: 'workload-vms', vlan: 100, addressPrefix: '198.51.100.0/25', gateway: '198.51.100.1', poolStart: '198.51.100.20', poolEnd: '198.51.100.99', nsg: 'nsg-example-workload-eus-01' }
  { name: 'lnet-example-desktops-vlan200-eus', purpose: 'avd-session-hosts', vlan: 200, addressPrefix: '203.0.113.0/25', gateway: '203.0.113.1', poolStart: '203.0.113.20', poolEnd: '203.0.113.99', nsg: 'nsg-example-desktops-eus-01' }
]

param nsgs = [
  {
    name: 'nsg-example-workload-eus-01'
    rules: [
      { name: 'nsgsr-allow-rdp-admin-in', description: 'RDP from the admin network only', priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefixes: [ '192.0.2.128/26' ], destinationAddressPrefixes: [ '*' ], destinationPortRanges: [ '3389' ] }
      { name: 'nsgsr-deny-all-in', description: 'Explicit deny of all other inbound traffic', priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefixes: [ '*' ], destinationAddressPrefixes: [ '*' ], destinationPortRanges: [ '*' ] }
    ]
  }
  {
    name: 'nsg-example-desktops-eus-01'
    rules: [
      { name: 'nsgsr-allow-rdpshortpath-vpn-in', description: 'RDP Shortpath from the VPN pool', priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Udp', sourceAddressPrefixes: [ '192.0.2.192/26' ], destinationAddressPrefixes: [ '*' ], destinationPortRanges: [ '3390' ] }
      { name: 'nsgsr-deny-all-in', description: 'Explicit deny of all other inbound traffic', priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefixes: [ '*' ], destinationAddressPrefixes: [ '*' ], destinationPortRanges: [ '*' ] }
    ]
  }
]
