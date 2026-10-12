// NIC 2026 — Day-2 Ready 3.5 Defender for Servers toggle (cluster-configure/defender), Bicep track. Subscription scope.
// Gap-fill: Microsoft.Security/pricings@2024-01-01 (no AVM module). Apply = defender_servers_plan; Remove = 'off' (Free).
// D-055 (12 Oct 2026): production stance - the full plan set is owned by automation/shared/security (both landing-zone
// subscriptions, Defender CSPM, Servers P2, Storage, Key Vault, Resource Manager). This Day-2 control writes the SAME
// values for the Azure Local subscription, so applying it never strips what the security baseline set.
targetScope = 'subscription'

#disable-next-line no-unused-params
param subscription_id string
@allowed(['P1', 'P2', 'off'])
param defender_servers_plan string = 'P2'
param enable_defender_keyvault bool = false
param enable_defender_storage bool = false
#disable-next-line no-unused-params
param names object

resource cspm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'CloudPosture'
  properties: {
    pricingTier: 'Standard'
    extensions: [
      { name: 'AgentlessVmScanning', isEnabled: 'True' }
      { name: 'SensitiveDataDiscovery', isEnabled: 'True' }
    ]
  }
}

resource servers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: defender_servers_plan == 'off' ? {
    pricingTier: 'Free'
  } : {
    pricingTier: 'Standard'
    subPlan: defender_servers_plan
    extensions: defender_servers_plan == 'P2' ? [
      { name: 'MdeDesignatedSubscription', isEnabled: 'False' }
      { name: 'AgentlessVmScanning', isEnabled: 'True' }
    ] : []
  }
  dependsOn: [cspm]
}

resource keyVaults 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'KeyVaults'
  properties: {
    pricingTier: enable_defender_keyvault ? 'Standard' : 'Free'
    subPlan: enable_defender_keyvault ? 'PerKeyVault' : null
  }
  dependsOn: [servers]
}

resource storageAccounts 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'StorageAccounts'
  properties: enable_defender_storage ? {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
    extensions: [
      { name: 'OnUploadMalwareScanning', isEnabled: 'True', additionalExtensionProperties: { CapGBPerMonthPerStorageAccount: '100' } }
      { name: 'SensitiveDataDiscovery', isEnabled: 'True' }
    ]
  } : {
    pricingTier: 'Free'
  }
  dependsOn: [keyVaults]
}

resource arm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'Arm'
  properties: { pricingTier: 'Standard', subPlan: 'PerSubscription' }
  dependsOn: [storageAccounts]
}

output servers_pricing_tier string = defender_servers_plan == 'off' ? 'Free' : 'Standard'
output servers_sub_plan string = defender_servers_plan == 'off' ? '' : defender_servers_plan
