// NIC 2026 — Day-2 Ready 3.5 Defender for Servers toggle (cluster-configure/defender), Bicep track. Subscription scope.
// Gap-fill: Microsoft.Security/pricings@2024-01-01 (no AVM module; same resource and api-version as the landing zone's
// defender-pricing module, which sets CSPM at build time). Apply = defender_servers_plan; Remove = 'off' (Free).
targetScope = 'subscription'

#disable-next-line no-unused-params
param subscription_id string
@allowed(['P1', 'P2', 'off'])
param defender_servers_plan string = 'P2'
param enable_defender_keyvault bool = false
param enable_defender_storage bool = false
#disable-next-line no-unused-params
param names object

resource servers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: defender_servers_plan == 'off' ? {
    pricingTier: 'Free'
  } : {
    pricingTier: 'Standard'
    subPlan: defender_servers_plan
  }
}

resource keyVaults 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'KeyVaults'
  properties: {
    pricingTier: enable_defender_keyvault ? 'Standard' : 'Free'
  }
  dependsOn: [servers]
}

resource storageAccounts 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'StorageAccounts'
  properties: enable_defender_storage ? {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
  } : {
    pricingTier: 'Free'
  }
  dependsOn: [keyVaults]
}

output servers_pricing_tier string = defender_servers_plan == 'off' ? 'Free' : 'Standard'
output servers_sub_plan string = defender_servers_plan == 'off' ? '' : defender_servers_plan
