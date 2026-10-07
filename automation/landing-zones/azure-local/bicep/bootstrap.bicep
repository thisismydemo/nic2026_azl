// Stage S0 Bootstrap (design §10.2): the security resource group and the Terraform state storage account
// st<org><token>tfstate<region>01 (blob versioning on, soft delete on, shared-key access DISABLED - Entra auth; design §9.2).
// Run once by Invoke-LzAzureLocalDeploy.ps1 -Stage S0 before either IaC track. Entra groups, provider registration
// and PIM role settings are scripts (Register-LzProviders.ps1, New-LzEntraGroups.ps1, Initialize-LzPim.ps1).
// AVM: resources/resource-group 0.4.4, storage/storage-account 0.33.1.
targetScope = 'subscription'

param names object
param location string
param tags object

module rgSec 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-sec'
  params: {
    name: names.rg_sec
    location: location
    tags: tags
  }
}

module tfstate 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-tfstate'
  scope: resourceGroup(names.rg_sec)
  dependsOn: [rgSec]
  params: {
    name: names.st_tfstate
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Allow' }
    blobServices: {
      isVersioningEnabled: true
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 14
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 14
      containers: [{ name: names.tfstate_container, publicAccess: 'None' }]
    }
  }
}

output securityResourceGroupName string = rgSec.outputs.name
output tfstateStorageAccountId string = tfstate.outputs.resourceId
output tfstateStorageAccountName string = tfstate.outputs.name
