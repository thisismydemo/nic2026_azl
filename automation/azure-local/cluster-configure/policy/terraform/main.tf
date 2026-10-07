# Same definitions and assignments as bicep/main.bicep (azurerm native; the AVM policy-assignment pattern is Bicep-only).
# Remediation identities get the same roles the Bicep track grants through the AVM module.

locals {
  sub_id     = "/subscriptions/${var.subscription_id}"
  rg_mon_id  = "${local.sub_id}/resourceGroups/${var.names["rg_mon"]}"
  law_id     = var.log_analytics_workspace_id != "" ? var.log_analytics_workspace_id : "${local.rg_mon_id}/providers/Microsoft.OperationalInsights/workspaces/${var.names["law"]}"
  dcr_id     = "${local.rg_mon_id}/providers/Microsoft.Insights/dataCollectionRules/${var.names["dcr_insights"]}"
  initiative = var.management_group_id != "" ? "/providers/Microsoft.Management/managementGroups/${var.management_group_id}/providers/Microsoft.Authorization/policySetDefinitions/${var.names["init_hybrid_baseline"]}" : "${local.sub_id}/providers/Microsoft.Authorization/policySetDefinitions/${var.names["init_hybrid_baseline"]}"
  role_ids = {
    contributor                              = "b24988ac-6180-42a0-ab88-20f7382dd24c"
    log_analytics_contributor                = "92aaf0da-9dab-42b6-94a3-d43ce8d16293"
    monitoring_contributor                   = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
    guest_configuration_resource_contributor = "088ab73d-1256-47ae-bea9-9de8e7131f31"
    security_admin                           = "fb1c8493-542b-48eb-b624-b4c8fea62acd"
  }
  baseline_roles = [local.role_ids.log_analytics_contributor, local.role_ids.monitoring_contributor, local.role_ids.guest_configuration_resource_contributor, local.role_ids.security_admin, local.role_ids.contributor]
  insights_roles = [local.role_ids.contributor, local.role_ids.guest_configuration_resource_contributor]

  ama_rule = jsonencode({
    if = { field = "type", equals = "Microsoft.AzureStackHCI/clusters" }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type               = "Microsoft.AzureStackHCI/clusters/arcSettings/extensions"
        name               = "[concat(field('name'), '/default/AzureMonitorWindowsAgent')]"
        roleDefinitionIds  = ["/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.contributor}"]
        existenceCondition = { field = "Microsoft.AzureStackHCI/clusters/arcSettings/extensions/extensionParameters.type", equals = "AzureMonitorWindowsAgent" }
        deployment = {
          properties = {
            mode = "incremental"
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters     = { clusterName = { type = "string" } }
              resources = [{
                type       = "Microsoft.AzureStackHCI/clusters/arcSettings/extensions"
                apiVersion = "2023-08-01"
                name       = "[concat(parameters('clusterName'), '/default/AzureMonitorWindowsAgent')]"
                properties = { extensionParameters = { publisher = "Microsoft.Azure.Monitor", type = "AzureMonitorWindowsAgent", autoUpgradeMinorVersion = false, enableAutomaticUpgrade = false } }
              }]
            }
            parameters = { clusterName = { value = "[field('Name')]" } }
          }
        }
      }
    }
  })

  dcra_rule = jsonencode({
    if = { field = "type", equals = "Microsoft.HybridCompute/machines" }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type              = "Microsoft.Insights/dataCollectionRuleAssociations"
        name              = "[concat(field('name'), '-dataCollectionRuleAssociations')]"
        roleDefinitionIds = ["/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.contributor}"]
        deployment = {
          properties = {
            mode = "incremental"
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters     = { machineName = { type = "string" }, dataCollectionResourceId = { type = "string" } }
              resources = [{
                type       = "Microsoft.Insights/dataCollectionRuleAssociations"
                apiVersion = "2022-06-01"
                name       = "[concat(parameters('machineName'), '-dataCollectionRuleAssociations')]"
                scope      = "[format('Microsoft.HybridCompute/machines/{0}', parameters('machineName'))]"
                properties = { description = "Association of data collection rule. Deleting this association will break the data collection for this machine", dataCollectionRuleId = "[parameters('dataCollectionResourceId')]" }
              }]
            }
            parameters = { machineName = { value = "[field('Name')]" }, dataCollectionResourceId = { value = "[parameters('dcrResourceId')]" } }
          }
        }
      }
    }
  })

  akv_rule = jsonencode({
    if = { field = "type", equals = "Microsoft.HybridCompute/machines" }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type = "Microsoft.HybridCompute/machines/extensions"
        existenceCondition = {
          allOf = [
            { field = "Microsoft.HybridCompute/machines/extensions/type", equals = "AKVBackupForWindows" },
            { field = "Microsoft.HybridCompute/machines/extensions/publisher", equals = "Microsoft.Edge.Backup" },
            { field = "Microsoft.HybridCompute/machines/extensions/provisioningState", equals = "Succeeded" },
          ]
        }
      }
    }
  })
}

resource "azurerm_policy_definition" "insights_ama" {
  name         = var.names["pol_insights_ama"]
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "NIC26: Azure Local systems run the Azure Monitor Agent (Insights)"
  metadata     = jsonencode({ category = "NIC26", version = "1.0.0" })
  parameters   = jsonencode({ effect = { type = "String", allowedValues = ["DeployIfNotExists", "Disabled"], defaultValue = "DeployIfNotExists" } })
  policy_rule  = local.ama_rule
}

resource "azurerm_policy_definition" "insights_dcra" {
  name         = var.names["pol_insights_dcra"]
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "NIC26: Azure Local nodes are associated with the Insights data collection rule"
  metadata     = jsonencode({ category = "NIC26", version = "1.0.0" })
  parameters   = jsonencode({ effect = { type = "String", allowedValues = ["DeployIfNotExists", "Disabled"], defaultValue = "DeployIfNotExists" }, dcrResourceId = { type = "String", metadata = { displayName = "dcrResourceId", description = "Resource Id of the DCR" } } })
  policy_rule  = local.dcra_rule
}

resource "azurerm_policy_definition" "akv_backup_ext" {
  name         = var.names["pol_akv_backup_ext"]
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "NIC26: Azure Local nodes carry the Key Vault backup extension (Local Identity)"
  metadata     = jsonencode({ category = "NIC26", version = "1.0.0" })
  parameters   = jsonencode({ effect = { type = "String", allowedValues = ["AuditIfNotExists", "Disabled"], defaultValue = "AuditIfNotExists" } })
  policy_rule  = local.akv_rule
}

resource "azurerm_subscription_policy_assignment" "baseline" {
  name                 = var.names["asg_hybrid_baseline"]
  display_name         = "NIC26 hybrid baseline (Azure Local landing zone)"
  description          = "Compliance baseline assigned in Day-2 Ready (outline 3.5, design 7.4)."
  subscription_id      = local.sub_id
  policy_definition_id = local.initiative
  location             = var.location
  enforce              = var.enforcement_mode == "Default"
  parameters           = jsonencode({ listOfAllowedLocations = { value = [var.location, "global"] }, logAnalytics = { value = local.law_id } })
  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "baseline" {
  for_each           = toset(local.baseline_roles)
  scope              = local.sub_id
  role_definition_id = "${local.sub_id}/providers/Microsoft.Authorization/roleDefinitions/${each.value}"
  principal_id       = azurerm_subscription_policy_assignment.baseline.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "insights_ama" {
  count                = var.assign_insights_policies ? 1 : 0
  name                 = var.names["asg_insights_ama"]
  display_name         = "NIC26: Azure Local Insights - Azure Monitor Agent"
  subscription_id      = local.sub_id
  policy_definition_id = azurerm_policy_definition.insights_ama.id
  location             = var.location
  enforce              = var.enforcement_mode == "Default"
  identity { type = "SystemAssigned" }
}

resource "azurerm_subscription_policy_assignment" "insights_dcra" {
  count                = var.assign_insights_policies ? 1 : 0
  name                 = var.names["asg_insights_dcra"]
  display_name         = "NIC26: Azure Local Insights - DCR association"
  subscription_id      = local.sub_id
  policy_definition_id = azurerm_policy_definition.insights_dcra.id
  location             = var.location
  enforce              = var.enforcement_mode == "Default"
  parameters           = jsonencode({ dcrResourceId = { value = local.dcr_id } })
  identity { type = "SystemAssigned" }
}

resource "azurerm_role_assignment" "insights" {
  for_each           = var.assign_insights_policies ? { for pair in setproduct(["ama", "dcra"], local.insights_roles) : "${pair[0]}-${pair[1]}" => pair } : {}
  scope              = local.sub_id
  role_definition_id = "${local.sub_id}/providers/Microsoft.Authorization/roleDefinitions/${each.value[1]}"
  principal_id       = each.value[0] == "ama" ? azurerm_subscription_policy_assignment.insights_ama[0].identity[0].principal_id : azurerm_subscription_policy_assignment.insights_dcra[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "akv_backup_ext" {
  name                 = var.names["asg_akv_backup_ext"]
  display_name         = "NIC26: Key Vault backup extension present on Azure Local nodes"
  subscription_id      = local.sub_id
  policy_definition_id = azurerm_policy_definition.akv_backup_ext.id
  enforce              = var.enforcement_mode == "Default"
}
