// NIC 2026 — Azure Local landing zone, Bicep track (design/azure-local/landing-zone.md §10; contract §2/§6/§10).
// Subscription-scope deployment of stages S1 Governance, S2 Network, S3 Security, S4 Monitoring,
// S5 Cluster prerequisites, S6 BC/DR foundation and S7 Management. S-1, S0, S8 and S9 are scripts.
// RULES: no literal tenant/subscription/region/address/name anywhere in this file - every value is a parameter;
// names come from the `names` catalog object (contract §10); shared platform resources are inputs, never created;
// the only change to the hub is the hub-side peering (LZ-04); no secret is created, read or output (contract §3).
targetScope = 'subscription'

import { deployIdentityAssignableRoles } from 'modules/built-in-roles.bicep'

// ------------------------------------------------------------------ inputs (manifest: solution.yml)
@description('Entra tenant ID. Validated against the deployment context.')
param tenant_id string
@description('Landing-zone subscription ID. Validated against the deployment context.')
param subscription_id string
@description('Parent management group ID; used by bicep/initiative.bicep (MG scope). Accepted here for parameter-file parity; empty skips the initiative.')
#disable-next-line no-unused-params
param management_group_id string = ''
@description('Region for every resource (D-010).')
param location string
#disable-next-line no-unused-params
param org string
#disable-next-line no-unused-params
param token string
#disable-next-line no-unused-params
param region_short string
@description('The seven required tags (naming standard §3a).')
param tags object

param budget_monthly_amount int
param budget_contact_emails array
@allowed(['P1', 'P2', 'off'])
param defender_servers_plan string = 'off'
param enable_defender_keyvault bool = false
param enable_defender_storage bool = false

param spoke_address_space string
param subnet_jump_prefix string
param subnet_pe_prefix string
param subnet_mgmt_prefix string
param subnet_asr_prefix string
param subnet_asr_test_prefix string
param dns_servers array
param hub_vnet_id string
param hub_resource_group_name string
param hub_subscription_id string
param bastion_subnet_prefix string
param p2s_client_pool string
param identity_spoke_vnet_id string
param management_spoke_vnet_id string
param onprem_prefixes array
param avd_spoke_vnet_id string = ''
param identity_spoke_prefix string
param management_spoke_prefix string
param avd_spoke_prefix string = ''
@description('P-13: direct spoke<->identity peerings (one resource on the shared identity VNet; owner approval).')
param enable_identity_peering bool = false
@description('P-13: direct spoke<->management peerings (one resource on the shared management VNet; owner approval).')
param enable_management_peering bool = false
@description('Owner decision D-029: false (default) = no private endpoints. Both vaults use their public endpoint (RBAC only), no privatelink zones or links are created and the monitor private link is forced off. true restores the private-endpoint design.')
param enable_private_endpoints bool = false

param enable_monitor_private_link bool = false
param privatelink_vaultcore_zone_id string = ''

@description('Object IDs keyed by catalog key: grp_lab_operators, grp_azl_admins, grp_azl_operators, grp_azl_readers.')
param group_object_ids object
#disable-next-line no-unused-params
param pim_max_activation_hours int = 8
param manage_pim_in_iac bool = false
param kv_soft_delete_days int = 7
@description('{ ops: Enabled|Disabled, azl: Enabled|Disabled } (design §5.3).')
param kv_public_network_access object
param azl_rp_app_object_id string

@description('Resource ID of the centrally managed Log Analytics workspace (platform management subscription). When set, no workload workspace is created and every diagnostic and collection setting points at it.')
param central_log_analytics_workspace_id string = ''
@description('Platform and management-group items (subscription policy and Defender, the activity-log export, and the peerings written into platform-owned VNets) are delivered by their owners. Set true only for a standalone lab where this template owns them.')
param deploy_platform_scope_items bool = false
param law_retention_days int = 30
param law_daily_cap_gb int = 2

param enable_voucher_storage bool = false
param rsv_storage_redundancy string = 'LocallyRedundant'

param enable_jump_server bool = true
param jump_vm_size string = 'Standard_D4s_v4'
param jump_data_disk_gb int = 256
@description('Static private IP for the jump server (MP-02); empty = dynamic.')
param jump_private_ip string = ''
param jump_encryption_at_host bool = false
// The two *_secret parameters hold keyvault:// REFERENCES (vault and secret names, contract §3), never values;
// they are consumed by the deploy script and accepted here only so the generated parameter file round-trips.
#disable-next-line secure-secrets-in-params no-unused-params
param jump_admin_username_secret string = ''
#disable-next-line secure-secrets-in-params no-unused-params
param jump_admin_password_secret string = ''
@secure()
@description('Supplied in memory by Invoke-LzAzureLocalDeploy.ps1 at S7; never persisted.')
param jump_admin_username string = ''
@secure()
@description('Supplied in memory by Invoke-LzAzureLocalDeploy.ps1 at S7; never persisted.')
param jump_admin_password string = ''

@description('Stages deployed in this run. Earlier stages are assumed to exist when omitted.')
param enabled_stages array = ['S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7']
@description('Resolved name catalog (contract §10) - the ONLY source of resource names.')
param names object

// ------------------------------------------------------------------ guards and locals
// Fail fast if the parameter file does not belong to the deployment context (no literal IDs: both are parameters).
var contextOk = subscription().subscriptionId == subscription_id && tenant().tenantId == tenant_id
resource contextGuard 'Microsoft.Resources/tags@2022-09-01' = if (!contextOk) {
  name: 'default'
  properties: {
    tags: { 'context-guard': 'subscription_id or tenant_id does not match the deployment context - aborting' }
  }
}

var s1 = contains(enabled_stages, 'S1')
var s2 = contains(enabled_stages, 'S2')
var s3 = contains(enabled_stages, 'S3')
var s4 = contains(enabled_stages, 'S4')
var s5 = contains(enabled_stages, 'S5')
var s6 = contains(enabled_stages, 'S6')
var s7 = contains(enabled_stages, 'S7') && enable_jump_server

var tagsBicep = union(tags, { 'managed-by': 'bicep' })
var requiredTagNames = ['project', 'workload', 'environment', 'owner', 'managed-by', 'lifecycle', 'cost-center']
var allowedLocations = [location, 'global']
var rgKeys = ['rg_azl', 'rg_net', 'rg_mon', 'rg_sec', 'rg_bcdr', 'rg_dr', 'rg_mgmt']

// IDs derived from the catalog so later stages can run without earlier module outputs (partial runs).
// The central workspace of the platform management subscription when one is given; otherwise the workload's own.
var lawId = !empty(central_log_analytics_workspace_id) ? central_log_analytics_workspace_id : resourceId(subscription_id, names.rg_mon, 'Microsoft.OperationalInsights/workspaces', names.law)
var vnetId = resourceId(subscription_id, names.rg_net, 'Microsoft.Network/virtualNetworks', names.spoke_vnet)
var subnetId = {
  jump: '${vnetId}/subnets/${names.snet_jump}'
  pe: '${vnetId}/subnets/${names.snet_pe}'
  mgmt: '${vnetId}/subnets/${names.snet_mgmt}'
  asr: '${vnetId}/subnets/${names.snet_asr}'
  asr_test: '${vnetId}/subnets/${names.snet_asr_test}'
}
var useMonitorPrivateLink = enable_private_endpoints && enable_monitor_private_link
var kvPublicEffective = enable_private_endpoints ? kv_public_network_access : { ops: 'Enabled', azl: 'Enabled' }
var vaultcoreZoneId = !enable_private_endpoints ? '' : !empty(privatelink_vaultcore_zone_id)
  ? privatelink_vaultcore_zone_id
  : resourceId(subscription_id, names.rg_net, 'Microsoft.Network/privateDnsZones', names.pdns_vaultcore)
var kvOpsId = resourceId(subscription_id, names.rg_sec, 'Microsoft.KeyVault/vaults', names.kv_ops)
var kvAzlId = resourceId(subscription_id, names.rg_sec, 'Microsoft.KeyVault/vaults', names.kv_azl)
var hubVnetName = last(split(hub_vnet_id, '/'))
// Shared identity / management VNets: subscription, resource group and name are parsed from the input IDs (never built).
var identityVnetParts = split(identity_spoke_vnet_id, '/')
var managementVnetParts = split(management_spoke_vnet_id, '/')

// ------------------------------------------------------------------ S1 Governance (design §2, §3)
module resourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [for key in rgKeys: if (s1) {
  name: 'rg-${key}'
  params: {
    name: names[key]
    location: location
    tags: tagsBicep
  }
}]

module defender 'modules/defender-pricing.bicep' = if (s1 && deploy_platform_scope_items) {
  name: 'defender'
  params: {
    defender_servers_plan: defender_servers_plan
    enable_defender_keyvault: enable_defender_keyvault
    enable_defender_storage: enable_defender_storage
  }
}

// The initiative definition lives at management-group scope (LZ-01) and cannot be nested in a subscription
// deployment; it is its own entry point, bicep/initiative.bicep, run by Invoke-LzAzureLocalDeploy.ps1 in S1
// when management_group_id is set.

// ------------------------------------------------------------------ S4 Monitoring (design §7) - before S2/S3 because their diagnostics target the workspace
module monitoring 'modules/monitoring.bicep' = if (s4) {
  name: 'monitoring'
  scope: resourceGroup(names.rg_mon)
  dependsOn: [resourceGroups]
  params: {
    names: names
    location: location
    tags: tagsBicep
    law_retention_days: law_retention_days
    law_daily_cap_gb: law_daily_cap_gb
    budget_contact_emails: budget_contact_emails
    enable_monitor_private_link: useMonitorPrivateLink
    central_log_analytics_workspace_id: central_log_analytics_workspace_id
  }
}

// S1 items that need the workspace / action group
module governancePolicy 'modules/governance-policy.bicep' = if (s1 && deploy_platform_scope_items) {
  name: 'governance-policy'
  dependsOn: [monitoring]
  params: {
    names: names
    location: location
    allowed_locations: allowedLocations
    required_tag_names: requiredTagNames
    log_analytics_workspace_id: lawId
  }
}

module activityLog 'modules/activity-log-diagnostics.bicep' = if (s1 && deploy_platform_scope_items) {
  name: 'activity-log'
  dependsOn: [monitoring]
  params: {
    name: names.asg_activity_log
    log_analytics_workspace_id: lawId
  }
}

// A monthly amount of 0 skips the budget (its what-if needs Cost Management read access that not every operator has).
module budget 'modules/budget.bicep' = if (s1 && budget_monthly_amount > 0) {
  name: 'budget'
  dependsOn: [monitoring]
  params: {
    name: names.budget_azl
    amount: budget_monthly_amount
    contact_emails: budget_contact_emails
    action_group_id: resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/actionGroups', names.ag_ops)
  }
}

// ------------------------------------------------------------------ S2 Network (design §4)
module network 'modules/network.bicep' = if (s2) {
  name: 'network'
  scope: resourceGroup(names.rg_net)
  dependsOn: [resourceGroups, monitoring]
  params: {
    names: names
    location: location
    tags: tagsBicep
    log_analytics_workspace_id: lawId
    spoke_address_space: spoke_address_space
    subnet_jump_prefix: subnet_jump_prefix
    subnet_pe_prefix: subnet_pe_prefix
    subnet_mgmt_prefix: subnet_mgmt_prefix
    subnet_asr_prefix: subnet_asr_prefix
    subnet_asr_test_prefix: subnet_asr_test_prefix
    dns_servers: dns_servers
    bastion_subnet_prefix: bastion_subnet_prefix
    p2s_client_pool: p2s_client_pool
    onprem_prefixes: onprem_prefixes
    identity_spoke_prefix: identity_spoke_prefix
    management_spoke_prefix: management_spoke_prefix
    avd_spoke_prefix: avd_spoke_prefix
    identity_spoke_vnet_id: identity_spoke_vnet_id
    avd_spoke_vnet_id: avd_spoke_vnet_id
    privatelink_vaultcore_zone_id: privatelink_vaultcore_zone_id
    enable_private_endpoints: enable_private_endpoints
    enable_monitor_private_link: useMonitorPrivateLink
  }
}

// Hub-side peering: the ONLY change to the shared hub (LZ-04). Cross-subscription module; needs Network Contributor on the hub VNet.
module hubPeering 'modules/vnet-peering.bicep' = if (s2 && deploy_platform_scope_items) {
  name: 'peer-hub-to-spoke'
  scope: resourceGroup(hub_subscription_id, hub_resource_group_name)
  dependsOn: [network]
  params: {
    vnet_name: hubVnetName
    peering_name: names.peer_hub_to_spoke
    remote_vnet_id: vnetId
    allow_virtual_network_access: true
    allow_forwarded_traffic: true
    allow_gateway_transit: true
    use_remote_gateways: false
  }
}

module spokePeering 'modules/vnet-peering.bicep' = if (s2) {
  name: 'peer-spoke-to-hub'
  scope: resourceGroup(names.rg_net)
  dependsOn: [network]
  params: {
    vnet_name: names.spoke_vnet
    peering_name: names.peer_spoke_to_hub
    remote_vnet_id: hub_vnet_id
    allow_virtual_network_access: true
    allow_forwarded_traffic: true
    allow_gateway_transit: false
    use_remote_gateways: true
  }
}

// Spoke-to-AVD peering (this side only); the AVD landing zone creates its side (design §4.2, §10.5).
module avdPeering 'modules/vnet-peering.bicep' = if (s2 && !empty(avd_spoke_vnet_id)) {
  name: 'peer-spoke-to-avd'
  scope: resourceGroup(names.rg_net)
  dependsOn: [network]
  params: {
    vnet_name: names.spoke_vnet
    peering_name: names.peer_spoke_to_avd
    remote_vnet_id: avd_spoke_vnet_id
    allow_virtual_network_access: true
    allow_forwarded_traffic: true
  }
}

// P-13 / LZ-04 / MP-05: direct peerings to the identity VNet (the spoke's DNS servers live there) and the management
// VNet. Peering is non-transitive and the hub has no NVA. One resource of each pair lives on a shared VNet,
// so both pairs are behind owner-approval flags. No gateway options on any of the four.
module identityPeeringRemote 'modules/vnet-peering.bicep' = if (s2 && enable_identity_peering && deploy_platform_scope_items) {
  name: 'peer-identity-to-spoke'
  scope: resourceGroup(identityVnetParts[2], identityVnetParts[4])
  dependsOn: [network]
  params: {
    vnet_name: last(identityVnetParts)
    peering_name: names.peer_identity_to_spoke
    remote_vnet_id: vnetId
  }
}

module identityPeeringLocal 'modules/vnet-peering.bicep' = if (s2 && enable_identity_peering) {
  name: 'peer-spoke-to-identity'
  scope: resourceGroup(names.rg_net)
  dependsOn: [network]
  params: {
    vnet_name: names.spoke_vnet
    peering_name: names.peer_spoke_to_identity
    remote_vnet_id: identity_spoke_vnet_id
  }
}

module managementPeeringRemote 'modules/vnet-peering.bicep' = if (s2 && enable_management_peering && deploy_platform_scope_items) {
  name: 'peer-mgmt-to-spoke'
  scope: resourceGroup(managementVnetParts[2], managementVnetParts[4])
  dependsOn: [network]
  params: {
    vnet_name: last(managementVnetParts)
    peering_name: names.peer_mgmt_to_spoke
    remote_vnet_id: vnetId
  }
}

module managementPeeringLocal 'modules/vnet-peering.bicep' = if (s2 && enable_management_peering) {
  name: 'peer-spoke-to-mgmt'
  scope: resourceGroup(names.rg_net)
  dependsOn: [network]
  params: {
    vnet_name: names.spoke_vnet
    peering_name: names.peer_spoke_to_mgmt
    remote_vnet_id: management_spoke_vnet_id
  }
}

// ------------------------------------------------------------------ S3 Security (design §5, §6)
module security 'modules/security.bicep' = if (s3) {
  name: 'security'
  scope: resourceGroup(names.rg_sec)
  dependsOn: [resourceGroups, monitoring, network]
  params: {
    names: names
    location: location
    tags: tagsBicep
    log_analytics_workspace_id: lawId
    pe_subnet_id: subnetId.pe
    vaultcore_zone_id: vaultcoreZoneId
    kv_soft_delete_days: kv_soft_delete_days
    kv_public_network_access: kvPublicEffective
    enable_private_endpoints: enable_private_endpoints
    group_object_ids: group_object_ids
  }
}

// Deployment identity: Contributor + RBAC Administrator constrained to the roles in design §6.2 (ABAC condition, version 2.0).
var rbacAdminCondition = format(
  '((!(ActionMatches{{\'Microsoft.Authorization/roleAssignments/write\'}})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {{{0}}})) AND ((!(ActionMatches{{\'Microsoft.Authorization/roleAssignments/delete\'}})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {{{0}}}))',
  join(deployIdentityAssignableRoles, ', ')
)

module subscriptionRbac 'modules/role-assignment-sub.bicep' = if (s3) {
  name: 'rbac-subscription'
  params: {
    assignments: [
      { principalId: security!.outputs.deployIdentityPrincipalId, principalType: 'ServicePrincipal', role: 'Contributor', description: 'Deployment identity (design §6.2)' }
      { principalId: security!.outputs.deployIdentityPrincipalId, principalType: 'ServicePrincipal', role: 'RoleBasedAccessControlAdministrator', condition: rbacAdminCondition, description: 'Deployment identity, constrained to the landing-zone role set' }
      { principalId: group_object_ids.grp_azl_readers, principalType: 'Group', role: 'Reader' }
      { principalId: group_object_ids.grp_azl_readers, principalType: 'Group', role: 'AzureStackHCIVMReader' }
      { principalId: group_object_ids.grp_azl_readers, principalType: 'Group', role: 'LogAnalyticsReader' }
      { principalId: group_object_ids.grp_azl_readers, principalType: 'Group', role: 'MonitoringReader' }
    ]
  }
}

// PIM-eligible assignments (design §6.2/§6.3). Default path is scripts/Initialize-LzPim.ps1; see module header.
module pimSubscription 'modules/pim-eligibility.bicep' = if (s3 && manage_pim_in_iac) {
  name: 'pim-subscription'
  params: {
    eligibilities: [
      { principalId: group_object_ids.grp_lab_operators, role: 'Owner' }
      { principalId: group_object_ids.grp_azl_admins, role: 'AzureStackHCIAdministrator' }
      { principalId: group_object_ids.grp_azl_admins, role: 'Reader' }
      { principalId: group_object_ids.grp_azl_operators, role: 'AzureStackHCIVMContributor' }
      { principalId: group_object_ids.grp_azl_operators, role: 'Reader' }
    ]
  }
}

module pimClusterRg 'modules/pim-eligibility-rg.bicep' = if (s3 && manage_pim_in_iac) {
  name: 'pim-rg-azl'
  scope: resourceGroup(names.rg_azl)
  dependsOn: [resourceGroups]
  params: {
    rg_eligibilities: [
      { principalId: group_object_ids.grp_azl_admins, role: 'StorageAccountContributor' }
    ]
  }
}

module pimClusterVault 'modules/pim-eligibility-rg.bicep' = if (s3 && manage_pim_in_iac) {
  name: 'pim-kv-azl'
  scope: resourceGroup(names.rg_sec)
  dependsOn: [security]
  params: {
    key_vault_name: names.kv_azl
    kv_eligibilities: [
      { principalId: group_object_ids.grp_azl_admins, role: 'KeyVaultDataAccessAdministrator' }
      { principalId: group_object_ids.grp_azl_admins, role: 'KeyVaultSecretsOfficer' }
      { principalId: group_object_ids.grp_azl_admins, role: 'KeyVaultContributor' }
    ]
  }
}

// ------------------------------------------------------------------ S5 Cluster prerequisites (design §9)
module clusterPrereqs 'modules/cluster-prereqs.bicep' = if (s5) {
  name: 'cluster-prereqs'
  scope: resourceGroup(names.rg_azl)
  dependsOn: [resourceGroups, monitoring, security]
  params: {
    names: names
    location: location
    tags: tagsBicep
    log_analytics_workspace_id: lawId
    enable_voucher_storage: enable_voucher_storage
    group_object_ids: group_object_ids
    azl_rp_app_object_id: azl_rp_app_object_id
  }
}

// ------------------------------------------------------------------ S6 BC/DR foundation (design §8)
module bcdr 'modules/bcdr.bicep' = if (s6) {
  name: 'bcdr'
  scope: resourceGroup(names.rg_bcdr)
  dependsOn: [resourceGroups, monitoring, network]
  params: {
    names: names
    location: location
    tags: tagsBicep
    log_analytics_workspace_id: lawId
    rsv_storage_redundancy: rsv_storage_redundancy
  }
}

// Recovery Services vault identity: Contributor on the DR target group (design §6.2).
module drRgRbac 'modules/role-assignment-rg.bicep' = if (s6) {
  name: 'rbac-rg-dr'
  scope: resourceGroup(names.rg_dr)
  dependsOn: [resourceGroups]
  params: {
    assignments: [
      { principalId: bcdr!.outputs.recoveryVaultPrincipalId, principalType: 'ServicePrincipal', role: 'Contributor', description: 'Recovery Services vault identity on the post-failover resource group' }
    ]
  }
}

// ------------------------------------------------------------------ S7 Management (design §3, K-8)
module management 'modules/management.bicep' = if (s7) {
  name: 'management'
  scope: resourceGroup(names.rg_mgmt)
  dependsOn: [resourceGroups, network]
  params: {
    names: names
    location: location
    tags: tagsBicep
    jump_subnet_id: subnetId.jump
    jump_vm_size: jump_vm_size
    jump_data_disk_gb: jump_data_disk_gb
    jump_private_ip: jump_private_ip
    jump_encryption_at_host: jump_encryption_at_host
    jump_admin_username: jump_admin_username
    jump_admin_password: jump_admin_password
  }
}

// ------------------------------------------------------------------ outputs = manifest outputs (contract §6)
output cluster_resource_group_name string = names.rg_azl
output witness_storage_account_name string = names.st_witness
output witness_storage_account_id string = resourceId(subscription_id, names.rg_azl, 'Microsoft.Storage/storageAccounts', names.st_witness)
output kv_ops_id string = kvOpsId
output kv_ops_uri string = 'https://${names.kv_ops}${environment().suffixes.keyvaultDns}/'
output kv_azl_id string = kvAzlId
output kv_azl_uri string = 'https://${names.kv_azl}${environment().suffixes.keyvaultDns}/'
output log_analytics_workspace_id string = lawId
output action_group_id string = resourceId(subscription_id, names.rg_mon, 'Microsoft.Insights/actionGroups', names.ag_ops)
output recovery_vault_id string = resourceId(subscription_id, names.rg_bcdr, 'Microsoft.RecoveryServices/vaults', names.rsv_azl)
output dr_resource_group_name string = names.rg_dr
output asr_subnet_id string = subnetId.asr
output asr_test_subnet_id string = subnetId.asr_test
output deploy_identity_principal_id string = s3 ? security!.outputs.deployIdentityPrincipalId : ''
output deploy_identity_id string = resourceId(subscription_id, names.rg_sec, 'Microsoft.ManagedIdentity/userAssignedIdentities', names.id_deploy)
output spoke_vnet_id string = vnetId
output pe_subnet_id string = subnetId.pe
output jump_subnet_id string = subnetId.jump
output private_dns_zone_vaultcore_id string = vaultcoreZoneId
output security_resource_group_name string = names.rg_sec
output network_resource_group_name string = names.rg_net
output monitoring_resource_group_name string = names.rg_mon
output asr_cache_storage_account_name string = names.st_asr_cache
output jump_vm_id string = enable_jump_server ? resourceId(subscription_id, names.rg_mgmt, 'Microsoft.Compute/virtualMachines', names.vm_jump) : ''
