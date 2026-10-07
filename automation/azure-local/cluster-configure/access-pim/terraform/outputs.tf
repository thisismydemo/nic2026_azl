# Outputs = solution.yml outputs = bicep/main.bicep outputs (contract §6).
output "eligibility_request_names" { value = [for k in sort(keys(local.rows)) : azurerm_pim_eligible_role_assignment.row[k].id] }
output "pim_scope" { value = local.sub_id }
