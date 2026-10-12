# Stage S3 - automation identity (parity with bicep/main.bicep automationIdentity* + modules/automation-identity-rbac.bicep).
# Least-privilege roles for Arc registration, the cluster deployment (Local Identity with Key Vault, D-008) and, with
# simplified_provisioning, os-provisioning. Single source: ../automation-identity-roles.json (role names resolved here,
# no literal GUIDs). delegable_roles become an ABAC condition (version 2.0): assign or remove only those roles, only to
# service principals, never to the automation identity itself.

locals {
  ai_map        = jsondecode(file("${path.module}/../automation-identity-roles.json"))
  ai_role_names = local.ai_map.role_display_names
  ai_grant      = local.s3 && try(tobool(var.automation_identity.grant_roles), false)
  ai_type       = try(tostring(var.automation_identity.type), "managed-identity")
  ai_mi_name    = try(tostring(var.automation_identity.managed_identity_name), var.names.id_deploy)
  ai_sp_object  = try(tostring(var.automation_identity.service_principal_object_id), "")
  ai_is_deploy  = local.ai_type == "managed-identity" && local.ai_mi_name == var.names.id_deploy
  ai_features   = try(tobool(var.automation_identity.simplified_provisioning), false) ? ["core", "simplified_provisioning"] : ["core"]
  # Normalised so every value has the same type (delegable roles as a comma-joined string).
  ai_items = {
    for a in local.ai_map.assignments : a.key => {
      scope     = a.scope
      role      = a.role
      delegable = join(",", try(a.delegable_roles, []))
    } if contains(local.ai_features, a.feature) && !(local.ai_is_deploy && try(tobool(a.granted_by_s3), false))
  }
  ai_scope_id = {
    rg_azl = local.rg_id.rg_azl
    rg_sec = local.rg_id.rg_sec
    kv_azl = local.kv_azl_id
    kv_ops = local.kv_ops_id
  }
  ai_delegable_keys = toset(compact(flatten([for v in values(local.ai_items) : split(",", v.delegable)])))
}

data "azurerm_user_assigned_identity" "automation" {
  count = local.ai_grant && local.ai_type == "managed-identity" && !local.ai_is_deploy ? 1 : 0

  name                = local.ai_mi_name
  resource_group_name = var.names.rg_sec
}

data "azurerm_role_definition" "automation_delegable" {
  for_each = local.ai_grant ? local.ai_delegable_keys : toset([])
  name     = local.ai_role_names[each.value]
}

locals {
  ai_principal_id = !local.ai_grant ? "" : (
    local.ai_type == "service-principal" ? local.ai_sp_object : (
      local.ai_is_deploy ? azurerm_user_assigned_identity.deploy[0].principal_id : data.azurerm_user_assigned_identity.automation[0].principal_id
    )
  )
  ai_role_guid = { for k, d in data.azurerm_role_definition.automation_delegable : k => element(split("/", d.id), length(split("/", d.id)) - 1) }
}

resource "azurerm_role_assignment" "automation" {
  for_each = local.ai_grant ? local.ai_items : {}

  scope                = local.ai_scope_id[each.value.scope]
  role_definition_name = local.ai_role_names[each.value.role]
  principal_id         = local.ai_principal_id
  principal_type       = "ServicePrincipal"
  description          = "Automation identity: ${each.key}"
  condition_version    = each.value.delegable == "" ? null : "2.0"
  condition = each.value.delegable == "" ? null : format(
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%s} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {%s})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%s} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))",
    join(", ", [for r in split(",", each.value.delegable) : local.ai_role_guid[r]]),
    local.ai_principal_id,
    join(", ", [for r in split(",", each.value.delegable) : local.ai_role_guid[r]])
  )

  lifecycle {
    precondition {
      condition     = local.ai_type != "service-principal" || local.ai_sp_object != ""
      error_message = "automation_identity.type is service-principal: service_principal_object_id is required to grant roles."
    }
  }
  depends_on = [azurerm_resource_group.this, module.kv_azl, module.kv_ops]
}
