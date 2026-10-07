// Stage S5 Cluster prerequisites (design §9.1, §9.2, §6.2): cloud witness storage account, optional voucher
// storage account, RBAC on the cluster resource group. The witness KEY is never read here: the deploy solution's
// generator script writes WitnessStorageKey into the cluster vault at deployment time (design §5.5, O3).
// AVM: storage/storage-account 0.33.1.
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param log_analytics_workspace_id string
param enable_voucher_storage bool
param group_object_ids object
param azl_rp_app_object_id string

var blobDiagnostics = {
  diagnosticSettings: [
    {
      workspaceResourceId: log_analytics_workspace_id
      logCategoriesAndGroups: [{ category: 'StorageRead' }, { category: 'StorageWrite' }, { category: 'StorageDelete' }]
      metricCategories: [{ category: 'Transaction' }]
    }
  ]
}

// Cloud witness: GPv2, Standard_LRS, public access on, shared key on, TLS 1.2, no blob public access (design §9.1).
module witness 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-witness'
  params: {
    name: names.st_witness
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    blobServices: blobDiagnostics
    diagnosticSettings: [
      { workspaceResourceId: log_analytics_workspace_id, metricCategories: [{ category: 'Transaction' }] }
    ]
  }
}

module voucher 'br/public:avm/res/storage/storage-account:0.33.1' = if (enable_voucher_storage) {
  name: 'st-voucher'
  params: {
    name: names.st_voucher
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    blobServices: blobDiagnostics
  }
}

// Active assignments on the cluster resource group (design §6.2). PIM-eligible ones are in pim-eligibility-rg.bicep / Initialize-LzPim.ps1.
module rgRbac 'role-assignment-rg.bicep' = {
  name: 'rbac-rg-azl'
  params: {
    assignments: [
      { principalId: group_object_ids.grp_lab_operators, principalType: 'Group', role: 'Owner', description: 'Build window: simplified provisioning and Arc onboarding need Owner on the provisioning resource group; convert to eligible after Day-2 Ready' }
      { principalId: group_object_ids.grp_azl_admins, principalType: 'Group', role: 'AzureConnectedMachineOnboarding' }
      { principalId: group_object_ids.grp_azl_admins, principalType: 'Group', role: 'AzureConnectedMachineResourceAdministrator' }
      { principalId: azl_rp_app_object_id, principalType: 'ServicePrincipal', role: 'AzureConnectedMachineResourceManager', description: 'Azure Local resource provider first-party application (Marketplace image download)' }
    ]
  }
}

output witnessStorageAccountId string = witness.outputs.resourceId
output witnessStorageAccountName string = witness.outputs.name
