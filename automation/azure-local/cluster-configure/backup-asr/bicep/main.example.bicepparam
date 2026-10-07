using './main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param location = 'eastus'
param tags = { environment: 'example' }
param names = {
  rg_bcdr: 'example-bcdr-rg'
  rg_dr: 'example-dr-rg'
  rsv_azl: 'example-recovery-vault'
  asrpol_tier1: 'example-asr-policy'
  bkp_tier1: 'example-vm-backup-policy'
  rp_tier1: 'example-recovery-plan'
  st_asr_cache: 'exampleasrcache'
  snet_asr: 'example-asr-subnet'
  snet_asr_test: 'example-asr-test-subnet'
  vnet_azl: 'example-spoke-vnet'
  deployment_name: 'example-backup-asr-deployment'
}
param asr_policy = {
  replication_frequency_seconds: 300
  recovery_point_retention_hours: 24
  app_consistent_snapshot_frequency_hours: 1
}
param backup_policy = {
  schedule_run_time_utc: '02:00'
  retention_days: 30
  instant_restore_days: 2
}
