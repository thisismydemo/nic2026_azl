# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "logical_network_ids" { value = [for k in sort(keys(local.lnets)) : module.logical_network[k].resource_id] }
output "image_ids" { value = [for k in sort(keys(local.imgs)) : azapi_resource.image[k].id] }
output "storage_path_ids" { value = [for k in sort(keys(local.paths)) : azapi_resource.storage_path[k].id] }
output "network_security_group_id" { value = var.enable_network_security_group ? azapi_resource.nsg[0].id : "" }
output "custom_location_id" { value = local.custom_location_id }
