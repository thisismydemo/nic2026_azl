# Same resources, names and outputs as bicep/main.bicep (contract §6). Secrets: none created, read or stored here.
# The two ECE secrets are written by scripts/Set-ClusterDeploymentSecrets.ps1 under the operator's sign-in.

locals {
  rg_id    = "/subscriptions/${var.subscription_id}/resourceGroups/${var.names["rg_azl"]}"
  sec_rg   = var.names["rg_sec"]
  kv_id    = "/subscriptions/${var.subscription_id}/resourceGroups/${local.sec_rg}/providers/Microsoft.KeyVault/vaults/${var.kv_azl_name}"
  kv_uri   = "https://${var.kv_azl_name}.vault.azure.net"
  validate = var.deployment_mode == "Validate"

  # Platform constants: built-in role definition IDs (identical in every tenant; documented GUID allow-list).
  role_ids = {
    azure_connected_machine_resource_manager = "f5819b54-e033-4d82-ac66-4fec3cbf3f4c"
    azure_stack_hci_device_management        = "865ae368-6a45-4bd1-8fbf-0d5151f56fc1"
    azure_stack_hci_connected_infra_vms      = "c99c945f-8bd1-4fb1-a903-01460aae6068" # Azure Stack HCI Connected InfraVMs (confirmed against the Learn built-in roles list, 2026-10-04)
    key_vault_secrets_officer                = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
    key_vault_certificates_officer           = "a4417e6f-fecd-4de8-b567-7b0420556985"
  }

  ece_secrets        = { local_admin = "LocalAdminCredential", witness_key = "WitnessStorageKey" }
  local_admin_secret = var.local_admin_secret_name != "" ? var.local_admin_secret_name : "${var.cluster_name}-${local.ece_secrets.local_admin}"
  witness_key_secret = var.witness_key_secret_name != "" ? var.witness_key_secret_name : "${var.cluster_name}-${local.ece_secrets.witness_key}"
  arc_node_ids       = { for n in var.nodes : n.name => "${local.rg_id}/providers/Microsoft.HybridCompute/machines/${n.name}" }
  arc_node_id_list   = [for n in var.nodes : local.arc_node_ids[n.name]]
  node_principal_ids = { for n in var.nodes : n.name => data.azapi_resource.arc_machine[n.name].output.identity.principalId }
  storage_intent     = one([for i in var.intents : i if contains(i.traffic_types, "Storage")])
  storage_nets       = [{ key = "storage_a", ip_key = "smb1", name = "StorageNetwork1" }, { key = "storage_b", ip_key = "smb2", name = "StorageNetwork2" }]
  mgmt_netmask       = cidrnetmask(var.ip_plan.management_subnet)
  guards_ok          = var.kv_azl_name == var.names["kv_azl"] && var.witness.storage_account_name == var.names["st_witness"]
  tags               = merge(var.tags, { "managed-by" = "terraform" })

  intent_list = [for i in var.intents : {
    name                                = i.name
    trafficType                         = i.traffic_types
    adapter                             = i.adapters
    overrideVirtualSwitchConfiguration  = false
    virtualSwitchConfigurationOverrides = { enableIov = "", loadBalancingAlgorithm = "" }
    overrideQosPolicy                   = contains(i.traffic_types, "Storage")
    qosPolicyOverrides = contains(i.traffic_types, "Storage") ? {
      priorityValue8021Action_Cluster = tostring(var.qos.cluster_priority)
      priorityValue8021Action_SMB     = tostring(var.qos.storage_priority)
      bandwidthPercentage_SMB         = tostring(var.qos.storage_bandwidth_percent)
      } : {
      priorityValue8021Action_Cluster = ""
      priorityValue8021Action_SMB     = ""
      bandwidthPercentage_SMB         = ""
    }
    overrideAdapterProperty = true
    adapterPropertyOverrides = {
      jumboPacket             = tostring(try(i.overrides.jumbo_packet, null) != null ? i.overrides.jumbo_packet : 1514)
      networkDirect           = contains(i.traffic_types, "Storage") ? "Enabled" : "Disabled"
      networkDirectTechnology = contains(i.traffic_types, "Storage") ? var.rdma_protocol : ""
    }
  }]

  storage_network_list = [for idx, s in local.storage_nets : {
    name               = s.name
    networkAdapterName = local.storage_intent.adapters[idx]
    vlanId             = tostring(var.vlans[s.key].id)
    storageAdapterIPInfo = [for n in var.nodes : {
      physicalNode = n.name
      ipv4Address  = n.storage_ips[s.ip_key]
      subnetMask   = cidrnetmask(var.vlans[s.key].subnet)
    }]
  }]

  physical_nodes = [for n in var.nodes : { name = n.name, ipv4Address = n.management_ip }]

  infrastructure_network = [{
    useDhcp         = false
    subnetMask      = local.mgmt_netmask
    gateway         = var.ip_plan.default_gateway
    ipPools         = [{ startingAddress = var.ip_plan.infrastructure_pool.start, endingAddress = var.ip_plan.infrastructure_pool.end }]
    dnsServers      = var.ip_plan.dns_servers
    dnsServerConfig = "UseDnsServer"
    dnsZones        = [{ dnsZoneName = var.ip_plan.dns_zone, dnsForwarder = [] }]
  }]

  sbe_configured = length(compact([for v in values(var.sbe) : v == null ? "" : v])) > 0
  sbe_partner_info = {
    sbeDeploymentInfo = {
      version                 = coalesce(var.sbe.version, var.release.sbe_version, "")
      family                  = coalesce(var.sbe.family, "")
      publisher               = coalesce(var.sbe.publisher, "")
      sbeManifestSource       = coalesce(var.sbe.manifest_source, "")
      sbeManifestCreationDate = coalesce(var.sbe.manifest_creation_date, "")
    }
    partnerProperties = []
    credentialList    = []
  }

  deployment_data = merge({
    securitySettings = {
      hvciProtection                = true
      drtmProtection                = true
      driftControlEnforced          = var.security_settings.drift_control_enforced
      credentialGuardEnforced       = var.security_settings.credential_guard_enforced
      smbSigningEnforced            = var.security_settings.smb_signing_enforced
      smbClusterEncryption          = var.security_settings.smb_cluster_encryption
      sideChannelMitigationEnforced = true
      bitlockerBootVolume           = var.security_settings.bitlocker_boot_volume
      bitlockerDataVolumes          = var.security_settings.bitlocker_data_volumes
      wdacEnforced                  = var.security_settings.wdac_enforced
    }
    observability = {
      streamingDataClient = var.observability.streaming_data_client
      euLocation          = var.observability.eu_location
      episodicDataUpload  = var.observability.episodic_data_upload
    }
    cluster = {
      name                 = var.cluster_name
      witnessType          = "Cloud"
      witnessPath          = ""
      cloudAccountName     = var.witness.storage_account_name
      azureServiceEndpoint = "core.windows.net"
    }
    storage               = { configurationMode = var.storage_configuration_mode }
    namingPrefix          = var.token
    infrastructureNetwork = local.infrastructure_network
    physicalNodes         = local.physical_nodes
    hostNetwork = {
      intents                       = local.intent_list
      storageNetworks               = local.storage_network_list
      storageConnectivitySwitchless = var.networking_type == "switchlessMultiServerDeployment"
      enableStorageAutoIp           = var.ip_plan.storage_auto_ip
    }
    secrets = [
      { secretName = local.witness_key_secret, eceSecretName = local.ece_secrets.witness_key, secretLocation = "${local.kv_uri}/secrets/${local.witness_key_secret}" },
      { secretName = local.local_admin_secret, eceSecretName = local.ece_secrets.local_admin, secretLocation = "${local.kv_uri}/secrets/${local.local_admin_secret}" },
    ]
    identityProvider = "LocalIdentity"
    optionalServices = { customLocation = var.names["cl_azl"] }
  }, {})
}

# ------------------------------------------------------------------ existing inputs (never created here)
data "azapi_resource" "arc_machine" {
  for_each               = local.arc_node_ids
  type                   = "Microsoft.HybridCompute/machines@2024-07-10"
  resource_id            = each.value
  response_export_values = ["identity.principalId"]
}

data "azurerm_key_vault" "azl" {
  name                = var.kv_azl_name
  resource_group_name = local.sec_rg
}

# ------------------------------------------------------------------ Key Vault audit-log storage (design §9.2 st_diag)
# Gap-fill: azurerm native resources (the Bicep track uses avm/res/storage/storage-account:0.33.1; same resource shape).
resource "azurerm_storage_account" "diag" {
  name                            = var.names["st_diag"]
  resource_group_name             = var.names["rg_azl"]
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  tags                            = merge(local.tags, { purpose = "key-vault-audit-logs" })
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
  lifecycle {
    precondition {
      condition     = local.guards_ok
      error_message = "cluster-deploy guard failed: kv_azl_name and witness.storage_account_name must equal names.kv_azl / names.st_witness."
    }
  }
}

resource "azurerm_management_lock" "diag" {
  name       = "lock-${var.names["st_diag"]}"
  scope      = azurerm_storage_account.diag.id
  lock_level = "CanNotDelete"
  notes      = "Key Vault audit logs for the Azure Local deployment (design §9.2)."
}

resource "azurerm_monitor_diagnostic_setting" "kv_audit_to_storage" {
  name               = "audit-to-storage"
  target_resource_id = data.azurerm_key_vault.azl.id
  storage_account_id = azurerm_storage_account.diag.id
  enabled_log {
    category = "AuditEvent"
  }
}

# ------------------------------------------------------------------ RBAC the deployment needs (quickstart parity)
resource "azurerm_role_assignment" "hci_rp" {
  count                            = var.assign_hci_rp_role ? 1 : 0
  scope                            = local.rg_id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.azure_connected_machine_resource_manager}"
  principal_id                     = var.azl_rp_app_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "node_device_management" {
  for_each                         = local.node_principal_ids
  scope                            = local.rg_id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.azure_stack_hci_device_management}"
  principal_id                     = each.value
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "node_infra_vms" {
  for_each                         = local.node_principal_ids
  scope                            = local.rg_id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.azure_stack_hci_connected_infra_vms}"
  principal_id                     = each.value
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "node_kv_secrets_officer" {
  for_each                         = local.node_principal_ids
  scope                            = data.azurerm_key_vault.azl.id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.key_vault_secrets_officer}"
  principal_id                     = each.value
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "node_kv_certificates_officer" {
  for_each                         = local.node_principal_ids
  scope                            = data.azurerm_key_vault.azl.id
  role_definition_id               = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_ids.key_vault_certificates_officer}"
  principal_id                     = each.value
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# ------------------------------------------------------------------ edge devices + cluster resource
# The quickstart PUTs these only in the Validate pass. Terraform keeps them in state across both passes and ignores body
# drift so the Deploy pass never re-PUTs the cluster resource (same effect as the quickstart condition).
resource "azapi_resource" "edge_device" {
  for_each  = local.arc_node_ids
  type      = "Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview"
  name      = "default"
  parent_id = each.value
  body = {
    kind       = "HCI"
    properties = {}
  }
  depends_on = [azurerm_role_assignment.node_device_management]
  lifecycle { ignore_changes = [body] }
}

resource "azapi_resource" "cluster" {
  type      = "Microsoft.AzureStackHCI/clusters@2025-09-15-preview"
  name      = var.cluster_name
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  identity { type = "SystemAssigned" }
  body = {
    properties = {
      secretsLocations = [{ secretsType = "BackupSecrets", secretsLocation = local.kv_uri }]
    }
  }
  depends_on = [azapi_resource.edge_device, azurerm_role_assignment.node_kv_secrets_officer, azurerm_role_assignment.node_kv_certificates_officer]
  lifecycle { ignore_changes = [body, tags] }
}

# ------------------------------------------------------------------ both passes: deployment settings
resource "azapi_resource" "deployment_settings" {
  type      = "Microsoft.AzureStackHCI/clusters/deploymentSettings@2025-09-15-preview"
  name      = "default"
  parent_id = azapi_resource.cluster.id
  body = {
    properties = {
      arcNodeResourceIds = local.arc_node_id_list
      deploymentMode     = var.deployment_mode
      deploymentConfiguration = {
        version = "10.0.0.0"
        scaleUnits = [
          merge({ deploymentData = local.deployment_data }, local.sbe_configured ? { sbePartnerInfo = local.sbe_partner_info } : {})
        ]
      }
    }
  }
  timeouts {
    create = "4h"
    update = "4h"
    delete = "1h"
  }
  depends_on = [azurerm_role_assignment.node_infra_vms, azurerm_role_assignment.hci_rp, azurerm_monitor_diagnostic_setting.kv_audit_to_storage]
}
