// EXAMPLE (IIC values, all-zero GUIDs). Real file: main.generated.bicepparam (git-ignored).
using 'main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param location = 'eastus'
param tags = { project: 'nic26', workload: 'azure-local', environment: 'demo', owner: 'lab-owner@contoso.com', 'managed-by': 'bicep', 'cost-center': 'iic-nic26-lab', lifecycle: 'temporary' }
param maintenance_window = { start_date_time: '2026-10-05 02:00', duration: '03:00', time_zone: 'W. Europe Standard Time', recur_every: 'Week Sunday' }
param patch_classifications = ['Critical', 'Security', 'UpdateRollup', 'Definition']
param reboot_setting = 'IfRequired'
param dynamic_scope_tags = { workload: ['azure-local'] }
param dynamic_scope_os_types = ['Windows', 'Linux']
param names = {
  rg_mon: 'rg-iic-nic26-azl-mon-eus-01'
  mc_azl: 'mc-iic-nic26-azl-eus-01'
  mc_azl_dynscope: 'mc-iic-nic26-azl-dynscope-eus-01'
  deployment_name: 'dep-iic-nic26-azl-update-manager-01'
}
