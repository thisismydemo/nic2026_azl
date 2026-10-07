// EXAMPLE parameter file (IIC values from the designs, all-zero GUIDs). The real file is main.generated.bicepparam,
// produced by ConvertTo-NIC26BicepParam -Solution automation/azure-local/cluster-deploy -Config (Get-NIC26Config -Scope azure-local) -Execute
// and git-ignored. deployment_mode is NOT in the generated file: Invoke-ClusterDeploy.ps1 -Pass passes it per run.
using 'main.bicep'

param tenant_id = '00000000-0000-0000-0000-000000000000'
param subscription_id = '00000000-0000-0000-0000-000000000000'
param location = 'eastus'
param token = 'nic26'
param tags = {
  project: 'nic26'
  workload: 'azure-local'
  environment: 'demo'
  owner: 'lab-owner@contoso.com'
  'managed-by': 'bicep'
  'cost-center': 'iic-nic26-lab'
  lifecycle: 'temporary'
}

param cluster_name = 'nic26-clus01'
param identity = {
  model: 'local-identity-keyvault'
  dns_zone: 'nic26.iic.local'
  deployment_identity_name: 'id-iic-nic26-deploy-eus-01'
  local_admin_username_secret: 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-azl-nic26-clus01-local-admin-username'
  local_admin_password_secret: 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-azl-nic26-clus01-local-admin-password'
}
param kv_azl_name = 'kv-iic-nic26-azl-eus-01'
param witness = {
  type: 'cloud'
  storage_account_name: 'stiicnic26witeus01'
  storage_key_secret: 'keyvault://kv-iic-nic26-azl-eus-01/WitnessStorageKey'
}
param azl_rp_app_object_id = '00000000-0000-0000-0000-000000000000'

param nodes = [
  { name: 'nic26-01-n01', management_ip: '192.168.100.11', storage_ips: { smb1: '172.30.71.11', smb2: '172.30.72.11' } }
  { name: 'nic26-01-n02', management_ip: '192.168.100.12', storage_ips: { smb1: '172.30.71.12', smb2: '172.30.72.12' } }
]
param intents = [
  { name: 'Management', traffic_types: ['Management'], adapters: ['NIC1', 'NIC2'], overrides: { jumbo_packet: 1514 } }
  { name: 'Compute', traffic_types: ['Compute'], adapters: ['SLOT 3 Port 1', 'SLOT 6 Port 2'], overrides: { jumbo_packet: 1514, rdma_enabled: false } }
  { name: 'Storage', traffic_types: ['Storage'], adapters: ['SLOT 3 Port 2', 'SLOT 6 Port 1'], overrides: { jumbo_packet: 9014, storage_vlans: [711, 712], enable_storage_auto_ip: false } }
]
param ip_plan = {
  management_subnet: '192.168.100.0/24'
  default_gateway: '192.168.100.1'
  infrastructure_pool: { start: '192.168.100.20', end: '192.168.100.29' }
  cluster_ip: '192.168.100.20'
  dns_servers: ['10.100.4.36', '10.100.4.37']
  dns_zone: 'nic26.iic.local'
  ntp_servers: ['192.168.100.1']
  reserved_ranges: ['10.96.0.0/12', '10.244.0.0/16']
  storage_auto_ip: false
}
param vlans = {
  management: { id: 100, name: 'nic26-mgmt-100', subnet: '192.168.100.0/24', gateway: '192.168.100.1', routed: true }
  compute: { id: 110, name: 'nic26-compute-110', subnet: '192.168.110.0/24', gateway: '192.168.110.1', routed: true }
  storage_a: { id: 711, name: 'nic26-storage-a-711', subnet: '172.30.71.0/24', gateway: null, routed: false }
  storage_b: { id: 712, name: 'nic26-storage-b-712', subnet: '172.30.72.0/24', gateway: null, routed: false }
  avd: { id: 120, name: 'nic26-avd-120', subnet: '192.168.120.0/24', gateway: '192.168.120.1', routed: true }
  oob: { id: 90, name: 'nic26-oob-90', subnet: '10.101.64.0/24', gateway: '10.101.64.1', routed: true }
}
param qos = {
  storage_priority: 3
  cluster_priority: 7
  storage_bandwidth_percent: 50
  cluster_bandwidth_percent: 2
  jumbo_frame_size: 9014
}
param rdma_protocol = ''           // set from the confirmed NIC model only (R-03)
param networking_type = 'switchedMultiServerDeployment'
param networking_pattern = 'custom'

param release = { azure_local_version: '12.2609.1003.7', sbe_version: '4.1.2609.1' }
param sbe = {}
param storage_configuration_mode = 'InfraOnly'
param logs_retention_days = 30
param assign_hci_rp_role = false
param deployment_mode = 'Validate'

param names = {
  rg_azl: 'rg-iic-nic26-azl-eus-01'
  rg_sec: 'rg-iic-nic26-azl-sec-eus-01'
  kv_azl: 'kv-iic-nic26-azl-eus-01'
  st_witness: 'stiicnic26witeus01'
  st_diag: 'stiicnic26diageus01'
  cl_azl: 'cl-iic-nic26-azl-eus-01'
  arb_azl: 'arb-iic-nic26-azl-eus-01'
  deployment_name: 'dep-iic-nic26-azl-deploy-01'
}
