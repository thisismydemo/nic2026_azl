// Gap-fill (design §10.3): Microsoft Defender for Cloud plans, design §7.3.
// Foundational CSPM (CloudPosture Free) at landing-zone build; Defender for Servers P1/P2 is reversible
// (Day-2 Ready sets defender_servers_plan = P2, the live replay sets it back to off).
targetScope = 'subscription'

@allowed(['P1', 'P2', 'off'])
param defender_servers_plan string
param enable_defender_keyvault bool
param enable_defender_storage bool

resource cspm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'CloudPosture'
  properties: {
    pricingTier: 'Free'
  }
}

resource servers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: defender_servers_plan == 'off' ? {
    pricingTier: 'Free'
  } : {
    pricingTier: 'Standard'
    subPlan: defender_servers_plan
  }
  dependsOn: [cspm]
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
