# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6; tests/cluster-deploy.Tests.ps1 parity check).
output "cluster_id" { value = azapi_resource.cluster.id }
output "cluster_name" { value = var.cluster_name }
output "deployment_settings_id" { value = azapi_resource.deployment_settings.id }
output "custom_location_name" { value = var.names["cl_azl"] }
output "custom_location_id" { value = "${local.rg_id}/providers/Microsoft.ExtendedLocation/customLocations/${var.names["cl_azl"]}" }
output "arc_node_resource_ids" { value = local.arc_node_id_list }
output "key_vault_name" { value = var.kv_azl_name }
output "diagnostic_storage_account_name" { value = var.names["st_diag"] }
output "deployment_mode" { value = var.deployment_mode }
output "networking_pattern" { value = var.networking_pattern }
