output "asr_replication_policy_id" {
  value = azapi_resource.asr_policy.id
}

output "backup_policy_id" {
  value = azurerm_backup_policy_vm.backup_policy.id
}
