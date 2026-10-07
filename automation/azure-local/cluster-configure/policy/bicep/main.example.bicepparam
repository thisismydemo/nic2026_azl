// EXAMPLE (IIC values, all-zero GUIDs). Real file: main.generated.bicepparam (git-ignored).
using 'main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param location = 'eastus'
param management_group_id = 'mg-iic-landingzones'
param log_analytics_workspace_id = ''
param enforcement_mode = 'Default'
param assign_insights_policies = true
param names = {
  rg_mon: 'rg-iic-nic26-azl-mon-eus-01'
  law: 'law-iic-nic26-eus-01'
  init_hybrid_baseline: 'init-iic-nic26-hybrid-baseline'
  asg_hybrid_baseline: 'asg-iic-nic26-hybrid-baseline'
  pol_insights_ama: 'pol-iic-nic26-azl-insights-ama'
  pol_insights_dcra: 'pol-iic-nic26-azl-insights-dcra'
  pol_akv_backup_ext: 'pol-iic-nic26-akv-backup-ext'
  asg_insights_ama: 'asg-iic-nic26-azl-insights-ama'
  asg_insights_dcra: 'asg-iic-nic26-azl-insights-dcra'
  asg_akv_backup_ext: 'asg-iic-nic26-akv-backup-ext'
  dcr_insights: 'dcr-iic-nic26-azl-insights-eus-01'
  deployment_name: 'dep-iic-nic26-azl-policy-01'
}
