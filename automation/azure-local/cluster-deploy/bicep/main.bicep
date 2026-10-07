// NIC 2026 — Azure Local cluster deployment (cluster-deploy), Bicep track.
// Design: planning/sessions/azure-local/outline.md §2.4–2.6 · design/azure-local/landing-zone.md §5.3, §5.5, §9.2 ·
//         design/azure-local/network-design.md §4, §6 (R-03) · decisions D-008, D-019, D-024.
// Source of the resource shapes: the Microsoft quickstart "create-adless-cluster-external-dns-public-preview"
// referenced by Learn "Deploy using local identity with Key Vault via ARM template" (azloc-2609):
//   Microsoft.AzureStackHCI/edgeDevices, clusters and clusters/deploymentSettings @ 2025-09-15-preview.
// Why raw resources and not avm/res/azure-stack-hci/cluster (0.6.0): that module hard-requires domainFqdn/domainOUPath
// (Active Directory) and has no identityProvider/dnsZones inputs, so it cannot express Local Identity (README: AVM).
// RULES (contract §3/§7): no literal tenant/subscription/address/name; the template receives only the CLUSTER VAULT NAME —
// the two ECE secrets are written by scripts/Set-ClusterDeploymentSecrets.ps1 (never by IaC); no secret is read or output.
// Deployed TWICE at resource-group scope (names.rg_azl): deployment_mode = Validate, then Deploy.
targetScope = 'resourceGroup'

// ------------------------------------------------------------------ inputs (manifest: solution.yml)
#disable-next-line no-unused-params
param tenant_id string
#disable-next-line no-unused-params
param subscription_id string
@description('Region of the cluster resource (D-010).')
param location string
@description('Lab token; used as the deployment namingPrefix (max 8 chars).')
@maxLength(8)
param token string
param tags object

param cluster_name string
@description('identity block: model, dns_zone, deployment_identity_name, local_admin_*_secret (names only).')
param identity object
@description('Cluster vault NAME (landing-zone output kv_azl). Only the name crosses into the template.')
param kv_azl_name string
@description('witness block: type (cloud), storage_account_name, storage_key_secret (name only).')
param witness object
param azl_rp_app_object_id string
// The next two parameters are Key Vault secret NAMES (never values): the linter keys on the word "secret".
#disable-next-line secure-secrets-in-params
param local_admin_secret_name string = ''
#disable-next-line secure-secrets-in-params
param witness_key_secret_name string = ''

@description('nodes[]: name, management_ip, storage_ips { smb1, smb2 }.')
param nodes array
@description('Network ATC intents: name, traffic_types[], adapters[], overrides { jumbo_packet, rdma_enabled, ... }.')
param intents array
param ip_plan object
param vlans object
param qos object
@description('R-03: networkDirectTechnology as a string (RoCEv2 | iWARP | RoCE); empty = leave Network ATC detection.')
@allowed(['', 'RoCEv2', 'iWARP', 'RoCE'])
param rdma_protocol string = ''
@allowed(['switchedMultiServerDeployment', 'switchlessMultiServerDeployment', 'singleServerDeployment'])
param networking_type string = 'switchedMultiServerDeployment'
@allowed(['custom', 'hyperConverged', 'convergedManagementCompute', 'convergedComputeStorage'])
param networking_pattern string = 'custom'

param release object
param sbe object = {}
param security_settings object = {
  drift_control_enforced: true
  credential_guard_enforced: true
  smb_signing_enforced: true
  smb_cluster_encryption: true
  bitlocker_boot_volume: true
  bitlocker_data_volumes: true
  wdac_enforced: true
}
param observability object = {
  streaming_data_client: true
  eu_location: false
  episodic_data_upload: true
}
@allowed(['Express', 'InfraOnly', 'KeepStorage'])
param storage_configuration_mode string = 'InfraOnly'
@minValue(0)
@maxValue(365)
param logs_retention_days int = 30
param assign_hci_rp_role bool = false

@description('Validate creates the prerequisite resources and runs the Environment Checker (~10 min); Deploy performs the deployment (2.5–3 h).')
@allowed(['Validate', 'Deploy'])
param deployment_mode string = 'Validate'
@description('Resolved name catalog (contract §10): rg_azl, rg_sec, kv_azl, st_witness, st_diag, cl_azl, arb_azl, deployment_name.')
param names object

// ------------------------------------------------------------------ guards (fail at validation time, not at hour 2)
var identityModelOk = identity.model == 'local-identity-keyvault'
var witnessIsCloud = witness.type == 'cloud'
var clusterNameNotANode = !contains(map(nodes, n => toLower(n.name)), toLower(cluster_name))
var vaultNameMatchesCatalog = kv_azl_name == names.kv_azl
var witnessMatchesCatalog = witness.storage_account_name == names.st_witness
var guardsOk = identityModelOk && witnessIsCloud && clusterNameNotANode && vaultNameMatchesCatalog && witnessMatchesCatalog
var guardMessage = 'cluster-deploy guard failed: identity.model must be local-identity-keyvault, witness.type must be cloud, cluster_name must differ from every node name, kv_azl_name and witness.storage_account_name must equal the name catalog (kv_azl, st_witness)'

// ------------------------------------------------------------------ platform constants
// Built-in role definition IDs are Azure platform constants (identical in every tenant); this is the documented GUID
// allow-list for the secrets sweep (tests/cluster-deploy.Tests.ps1). Source: the quickstart template above.
var roleIds = {
  azureConnectedMachineResourceManager: 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c'
  azureStackHciDeviceManagement: '865ae368-6a45-4bd1-8fbf-0d5151f56fc1'
  azureStackHciConnectedInfraVMs: 'c99c945f-8bd1-4fb1-a903-01460aae6068' // Azure Stack HCI Connected InfraVMs (confirmed against the Learn built-in roles list, 2026-10-04)
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  keyVaultCertificatesOfficer: 'a4417e6f-fecd-4de8-b567-7b0420556985'
}
// ECE secret names are fixed by the platform (EceDeploymentSecrets.eceSecretName); the Key Vault secret names follow the
// quickstart convention <cluster>-<eceName> unless overridden. DefaultARBApplication is NOT part of the Local Identity
// external-DNS template (it belongs to the AD / service-principal path) — see README "design inconsistencies".
var eceSecrets = {
  localAdmin: 'LocalAdminCredential'
  witnessKey: 'WitnessStorageKey'
}
var localAdminSecret = empty(local_admin_secret_name) ? '${cluster_name}-${eceSecrets.localAdmin}' : local_admin_secret_name
var witnessKeySecret = empty(witness_key_secret_name) ? '${cluster_name}-${eceSecrets.witnessKey}' : witness_key_secret_name
var keyVaultUri = 'https://${kv_azl_name}${environment().suffixes.keyvaultDns}'
var storageEndpointSuffix = environment().suffixes.storage

// ------------------------------------------------------------------ derived deployment data
var managementCidr = parseCidr(ip_plan.management_subnet)
var storageIntents = filter(intents, i => contains(i.traffic_types, 'Storage'))
var storageIntent = storageIntents[0]
var storageAdapters = storageIntent.adapters
var storageNets = [
  { key: 'storage_a', ipKey: 'smb1', name: 'StorageNetwork1' }
  { key: 'storage_b', ipKey: 'smb2', name: 'StorageNetwork2' }
]

var intentList = [for i in intents: {
  name: i.name
  trafficType: i.traffic_types
  adapter: i.adapters
  overrideVirtualSwitchConfiguration: false
  virtualSwitchConfigurationOverrides: {
    enableIov: ''
    loadBalancingAlgorithm: ''
  }
  // QoS (network-design §6.2) is declared on the intent that carries Storage; the others keep Network ATC defaults.
  overrideQosPolicy: contains(i.traffic_types, 'Storage')
  qosPolicyOverrides: contains(i.traffic_types, 'Storage') ? {
    priorityValue8021Action_Cluster: string(qos.cluster_priority)
    priorityValue8021Action_SMB: string(qos.storage_priority)
    bandwidthPercentage_SMB: string(qos.storage_bandwidth_percent)
  } : {
    priorityValue8021Action_Cluster: ''
    priorityValue8021Action_SMB: ''
    bandwidthPercentage_SMB: ''
  }
  // Jumbo 9014 on Storage only (network-design §2.8); RDMA enabled only on Storage; the protocol is the rdma_protocol input.
  overrideAdapterProperty: true
  adapterPropertyOverrides: {
    jumboPacket: string(i.?overrides.?jumbo_packet ?? 1514)
    networkDirect: contains(i.traffic_types, 'Storage') ? 'Enabled' : 'Disabled'
    networkDirectTechnology: contains(i.traffic_types, 'Storage') ? rdma_protocol : ''
  }
}]

var storageNetworkList = [for (s, idx) in storageNets: {
  name: s.name
  networkAdapterName: storageAdapters[idx]
  vlanId: string(vlans[s.key].id)
  storageAdapterIPInfo: map(nodes, n => {
    physicalNode: n.name
    ipv4Address: n.storage_ips[s.ipKey]
    subnetMask: parseCidr(vlans[s.key].subnet).netmask
  })
}]

var physicalNodes = map(nodes, n => {
  name: n.name
  ipv4Address: n.management_ip
})

var infrastructureNetwork = [
  {
    useDhcp: false
    subnetMask: managementCidr.netmask
    gateway: ip_plan.default_gateway
    ipPools: [
      {
        startingAddress: ip_plan.infrastructure_pool.start
        endingAddress: ip_plan.infrastructure_pool.end
      }
    ]
    dnsServers: ip_plan.dns_servers
    dnsServerConfig: 'UseDnsServer' // external DNS template value (Learn: "specify UseDnsServer")
    dnsZones: [
      {
        dnsZoneName: ip_plan.dns_zone
        dnsForwarder: []
      }
    ]
  }
]

var sbeConfigured = !empty(sbe)
var sbePartnerInfo = sbeConfigured ? {
  sbeDeploymentInfo: {
    version: sbe.?version ?? release.?sbe_version ?? ''
    family: sbe.?family ?? ''
    publisher: sbe.?publisher ?? ''
    sbeManifestSource: sbe.?manifest_source ?? ''
    sbeManifestCreationDate: sbe.?manifest_creation_date ?? ''
  }
  partnerProperties: []
  credentialList: []
} : null

// ------------------------------------------------------------------ existing resources (inputs, never created here)
resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' existing = [for n in nodes: {
  name: n.name
}]

resource witnessStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: witness.storage_account_name
}

// ------------------------------------------------------------------ Key Vault audit-log storage (design §9.2 st_diag)
module diagStorage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'cluster-deploy-diag-storage'
  params: {
    name: names.st_diag
    location: location
    tags: union(tags, { 'managed-by': 'bicep', purpose: 'key-vault-audit-logs' })
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    lock: {
      kind: 'CanNotDelete'
      name: 'lock-${names.st_diag}'
    }
  }
}

// ------------------------------------------------------------------ RBAC the deployment needs (quickstart parity)
resource hciRpRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assign_hci_rp_role) {
  name: guid(resourceGroup().id, azl_rp_app_object_id, roleIds.azureConnectedMachineResourceManager)
  properties: {
    principalId: azl_rp_app_object_id
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.azureConnectedMachineResourceManager)
  }
}

resource nodeDeviceManagementRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (n, i) in nodes: {
  name: guid(resourceGroup().id, n.name, roleIds.azureStackHciDeviceManagement)
  properties: {
    principalId: arcMachine[i].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.azureStackHciDeviceManagement)
  }
}]

resource nodeInfraVmsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (n, i) in nodes: {
  name: guid(resourceGroup().id, n.name, roleIds.azureStackHciConnectedInfraVMs)
  properties: {
    principalId: arcMachine[i].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.azureStackHciConnectedInfraVMs)
  }
}]

// Node identities get Secrets Officer + Certificates Officer on the CLUSTER VAULT ONLY (keyvault-and-secrets.md §4),
// and the vault audit log goes to st_diag. The vault lives in rg_sec (design §5.2 option A) -> cross-RG module.
module keyVaultAccess 'modules/key-vault-access.bicep' = {
  name: 'cluster-deploy-kv-access'
  scope: resourceGroup(names.rg_sec)
  params: {
    key_vault_name: kv_azl_name
    node_principal_ids: [for i in range(0, length(nodes)): arcMachine[i].identity.principalId]
    secrets_officer_role_id: roleIds.keyVaultSecretsOfficer
    certificates_officer_role_id: roleIds.keyVaultCertificatesOfficer
    diagnostic_storage_account_id: diagStorage.outputs.resourceId
    logs_retention_days: logs_retention_days
  }
}

// ------------------------------------------------------------------ Validate pass only: edge devices + cluster resource
resource edgeDevice 'Microsoft.AzureStackHCI/edgeDevices@2025-09-15-preview' = [for (n, i) in nodes: if (deployment_mode == 'Validate') {
  name: 'default'
  scope: arcMachine[i]
  kind: 'HCI'
  properties: {}
  dependsOn: [
    nodeDeviceManagementRole
  ]
}]

resource cluster 'Microsoft.AzureStackHCI/clusters@2025-09-15-preview' = if (deployment_mode == 'Validate') {
  name: cluster_name
  location: location
  tags: union(tags, { 'managed-by': 'bicep' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    secretsLocations: [
      {
        secretsType: 'BackupSecrets'
        secretsLocation: guardsOk ? keyVaultUri : fail(guardMessage)
      }
    ]
  }
  dependsOn: [
    edgeDevice
    keyVaultAccess
  ]
}

resource clusterRef 'Microsoft.AzureStackHCI/clusters@2025-09-15-preview' existing = {
  name: cluster_name
}

// ------------------------------------------------------------------ both passes: deployment settings
resource deploymentSettings 'Microsoft.AzureStackHCI/clusters/deploymentSettings@2025-09-15-preview' = {
  parent: clusterRef
  name: 'default'
  properties: {
    arcNodeResourceIds: [for i in range(0, length(nodes)): arcMachine[i].id]
    deploymentMode: guardsOk ? deployment_mode : fail(guardMessage)
    deploymentConfiguration: {
      version: '10.0.0.0'
      scaleUnits: [
        union({
          deploymentData: {
            securitySettings: {
              hvciProtection: true
              drtmProtection: true
              driftControlEnforced: security_settings.drift_control_enforced
              credentialGuardEnforced: security_settings.credential_guard_enforced
              smbSigningEnforced: security_settings.smb_signing_enforced
              smbClusterEncryption: security_settings.smb_cluster_encryption
              sideChannelMitigationEnforced: true
              bitlockerBootVolume: security_settings.bitlocker_boot_volume
              bitlockerDataVolumes: security_settings.bitlocker_data_volumes
              wdacEnforced: security_settings.wdac_enforced
            }
            observability: {
              streamingDataClient: observability.streaming_data_client
              euLocation: observability.eu_location
              episodicDataUpload: observability.episodic_data_upload
            }
            cluster: {
              name: cluster_name
              witnessType: 'Cloud'
              witnessPath: ''
              cloudAccountName: witness.storage_account_name
              azureServiceEndpoint: storageEndpointSuffix
            }
            storage: {
              configurationMode: storage_configuration_mode
            }
            namingPrefix: token
            infrastructureNetwork: infrastructureNetwork
            physicalNodes: physicalNodes
            hostNetwork: {
              intents: intentList
              storageNetworks: storageNetworkList
              storageConnectivitySwitchless: networking_type == 'switchlessMultiServerDeployment'
              enableStorageAutoIp: ip_plan.storage_auto_ip
            }
            secrets: [
              {
                secretName: witnessKeySecret
                eceSecretName: eceSecrets.witnessKey
                secretLocation: '${keyVaultUri}/secrets/${witnessKeySecret}'
              }
              {
                secretName: localAdminSecret
                eceSecretName: eceSecrets.localAdmin
                secretLocation: '${keyVaultUri}/secrets/${localAdminSecret}'
              }
            ]
            identityProvider: 'LocalIdentity'
            optionalServices: {
              customLocation: names.cl_azl
            }
          }
        }, sbeConfigured ? { sbePartnerInfo: sbePartnerInfo } : {})
      ]
    }
  }
  dependsOn: [
    cluster
    nodeInfraVmsRole
    hciRpRole
    witnessStorage
  ]
}

// ------------------------------------------------------------------ outputs (= solution.yml outputs = terraform/outputs.tf)
output cluster_id string = clusterRef.id
output cluster_name string = cluster_name
output deployment_settings_id string = deploymentSettings.id
output custom_location_name string = names.cl_azl
output custom_location_id string = resourceId('Microsoft.ExtendedLocation/customLocations', names.cl_azl)
output arc_node_resource_ids array = [for i in range(0, length(nodes)): arcMachine[i].id]
output key_vault_name string = kv_azl_name
output diagnostic_storage_account_name string = names.st_diag
output deployment_mode string = deployment_mode
// networking_pattern is recorded for the portal-equivalent README; the ARM resource derives the pattern from intentList.
output networking_pattern string = networking_pattern
