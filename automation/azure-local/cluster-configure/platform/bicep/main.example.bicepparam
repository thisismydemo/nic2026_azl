// EXAMPLE (IIC values, all-zero GUIDs). Real file: main.generated.bicepparam (ConvertTo-NIC26BicepParam, git-ignored).
using 'main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param location = 'eastus'
param tags = { project: 'nic26', workload: 'azure-local', environment: 'demo', owner: 'lab-owner@contoso.com', 'managed-by': 'bicep', 'cost-center': 'iic-nic26-lab', lifecycle: 'temporary' }
param cluster_name = 'nic26-clus01'
param identity = {
  model: 'local-identity-keyvault'
  dns_zone: 'nic26.iic.local'
  deployment_identity_name: 'id-iic-nic26-deploy-eus-01'
  local_admin_username_secret: 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-azl-nic26-clus01-local-admin-username'
  local_admin_password_secret: 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-azl-nic26-clus01-local-admin-password'
}
param nodes = [
  { name: 'nic26-01-n01', management_ip: '192.168.100.11', storage_ips: { smb1: '172.30.71.11', smb2: '172.30.72.11' } }
  { name: 'nic26-01-n02', management_ip: '192.168.100.12', storage_ips: { smb1: '172.30.71.12', smb2: '172.30.72.12' } }
]
param logical_networks = [
  { name: 'lnet-iic-nic26-compute-eus', vlan_id: 110, subnet: '192.168.110.0/24', gateway: '192.168.110.1', ip_pool: { start: '192.168.110.20', end: '192.168.110.99' }, dns_servers: ['10.100.4.36', '10.100.4.37'] }
  { name: 'lnet-iic-nic26-avd-eus', vlan_id: 120, subnet: '192.168.120.0/24', gateway: '192.168.120.1', ip_pool: { start: '192.168.120.20', end: '192.168.120.99' }, dns_servers: ['10.100.9.132', '10.100.4.36'] }
]
param storage = {
  volumes: [{ name: 'csv-nic26-m2-vmstore-01', resiliency: 'two-way-mirror', size_gb: 2048 }]
  storage_paths: [{ name: 'sp-nic26-m2-vmstore-01', volume: 'csv-nic26-m2-vmstore-01', path: 'C:\\ClusterStorage\\csv-nic26-m2-vmstore-01\\vms' }]
}
param vm_switch_name = 'ConvergedSwitch(compute)'
param marketplace_images = [
  { key: 'win11_avd', publisher: 'microsoftwindowsdesktop', offer: 'office-365', sku: 'win11-25h2-avd-m365', os_type: 'Windows', version: '', hyper_v_generation: 'V2' }
  { key: 'ws2025', publisher: 'microsoftwindowsserver', offer: 'windowsserver', sku: '2025-datacenter-azure-edition', os_type: 'Windows', version: '', hyper_v_generation: 'V2' }
]
param enable_network_security_group = false
param names = {
  rg_azl: 'rg-iic-nic26-azl-eus-01'
  cl_azl: 'cl-iic-nic26-azl-eus-01'
  lnet_compute: 'lnet-iic-nic26-compute-eus'
  lnet_avd: 'lnet-iic-nic26-avd-eus'
  img_win11_avd: 'img-iic-nic26-win11-avd-25h2'
  img_ws2025: 'img-iic-nic26-ws2025-dc'
  csv_vmstore_01: 'csv-nic26-m2-vmstore-01'
  sp_vmstore_01: 'sp-nic26-m2-vmstore-01'
  nsg_azl_compute: 'nsg-iic-nic26-azl-compute-eus-01'
  deployment_name: 'dep-iic-nic26-azl-platform-01'
}
