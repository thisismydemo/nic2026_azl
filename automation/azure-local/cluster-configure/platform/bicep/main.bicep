// NIC 2026 — Day-2 Ready 3.6 workload platform (cluster-configure/platform), Bicep track.
// Outline §2.6/§3.6, network-design §4.4, build runbook 3.6–3.8. Resource-group scope (names.rg_azl).
// AVM: avm/res/azure-stack-hci/logical-network:0.3.1 and avm/res/azure-stack-hci/marketplace-gallery-image:0.1.0
// (confirmed on MCR 2026-10-03). Gap-fill: Microsoft.AzureStackHCI/storageContainers and networkSecurityGroups
// (no AVM module) at api 2025-02-01-preview (Learn template reference). Volumes: scripts/New-ClusterWorkloadVolume.ps1.
targetScope = 'resourceGroup'

#disable-next-line no-unused-params
param subscription_id string
param location string
param tags object
#disable-next-line no-unused-params
param cluster_name string
#disable-next-line no-unused-params
param identity object
#disable-next-line no-unused-params
param nodes array
@description('logical_networks[]: name, vlan_id, subnet, gateway, ip_pool { start, end }, dns_servers.')
param logical_networks array
@description('storage.volumes[] and storage.storage_paths[] { name, volume, path }.')
param storage object
param vm_switch_name string = 'ConvergedSwitch(compute)'
@description('{ key, publisher, offer, sku, os_type, version, hyper_v_generation }; key -> names.img_<key>.')
param marketplace_images array = []
param enable_network_security_group bool = false
param names object

var customLocationId = resourceId('Microsoft.ExtendedLocation/customLocations', names.cl_azl)
var allTags = union(tags, { 'managed-by': 'bicep' })
// Logical network names come from the catalog by purpose: the environment entry name must equal the catalog name
// (lnet-<org>-<token>-<purpose>-<region>); the catalog key is lnet_<purpose>.
var lnetKey = map(logical_networks, l => 'lnet_${last(take(split(l.name, '-'), length(split(l.name, '-')) - 1))}')

module logicalNetwork 'br/public:avm/res/azure-stack-hci/logical-network:0.3.1' = [for (l, i) in logical_networks: {
  name: 'platform-lnet-${i}'
  params: {
    name: names[lnetKey[i]]
    location: location
    tags: allTags
    customLocationResourceId: customLocationId
    vmSwitchName: vm_switch_name
    vlanId: l.vlan_id
    ipAllocationMethod: 'Static'
    addressPrefix: l.subnet
    defaultGateway: l.gateway
    dnsServers: l.dns_servers
    routeName: 'default'
    ipPools: [
      {
        name: 'vm-pool'
        ipPoolType: 'vm'
        start: l.ip_pool.start
        end: l.ip_pool.end
      }
    ]
  }
}]

// Storage paths (storage containers) on the workload volumes created by New-ClusterWorkloadVolume.ps1.
resource storagePath 'Microsoft.AzureStackHCI/storageContainers@2025-02-01-preview' = [for sp in storage.storage_paths: {
  name: sp.name
  location: location
  tags: allTags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    path: sp.?path ?? 'C:\\ClusterStorage\\${sp.volume}\\vms'
  }
}]

module image 'br/public:avm/res/azure-stack-hci/marketplace-gallery-image:0.1.0' = [for (img, i) in marketplace_images: {
  name: 'platform-img-${i}'
  params: {
    name: names['img_${img.key}']
    location: location
    tags: allTags
    customLocationResourceId: customLocationId
    osType: img.os_type
    hyperVGeneration: img.?hyper_v_generation ?? 'V2'
    identifier: {
      publisher: img.publisher
      offer: img.offer
      sku: img.sku
    }
    version: {
      name: img.?version ?? ''
    }
    containerResourceId: length(storage.storage_paths) > 0 ? storagePath[0].id : null
  }
}]

resource nsg 'Microsoft.AzureStackHCI/networkSecurityGroups@2025-02-01-preview' = if (enable_network_security_group) {
  name: names.nsg_azl_compute
  location: location
  tags: allTags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {}
}

output logical_network_ids array = [for i in range(0, length(logical_networks)): logicalNetwork[i].outputs.resourceId]
output image_ids array = [for i in range(0, length(marketplace_images)): image[i].outputs.resourceId]
output storage_path_ids array = [for i in range(0, length(storage.storage_paths)): storagePath[i].id]
output network_security_group_id string = enable_network_security_group ? nsg!.id : ''
output custom_location_id string = customLocationId
