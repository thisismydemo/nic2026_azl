# Same eligibilities as bicep/main.bicep. azurerm_pim_eligible_role_assignment is idempotent through state and removes
# the eligibility on destroy (the reversible path for Terraform users).

locals {
  sub_id = "/subscriptions/${var.subscription_id}"
  role_ids = {
    "Reader"                         = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
    "Azure Stack HCI Administrator"  = "bda0d508-adf1-4af0-9c28-88919fc3ae06"
    "Azure Stack HCI VM Contributor" = "874d1c73-6003-4e60-a13a-cb31ea190a85"
    "Azure Stack HCI VM Reader"      = "4b3fe76c-f777-4d24-a2d7-b027b0f7b273"
  }
  rows = { for a in var.pim_assignments : "${a.group}|${a.role}" => a }
}

resource "azurerm_pim_eligible_role_assignment" "row" {
  for_each           = local.rows
  scope              = local.sub_id
  role_definition_id = "${local.sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids[each.value.role]}"
  principal_id       = var.group_object_ids[each.value.group]
  justification      = "NIC26 Day-2 Ready 3.4 - PIM-eligible Azure Local role (design 6.3)"
  schedule {
    expiration {
      duration_days = 0 # permanent eligibility (NoExpiration); activation is time-bound by the role setting
    }
  }
  lifecycle { ignore_changes = [schedule] }
}
