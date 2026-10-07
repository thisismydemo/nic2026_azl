// Gap-fill (design §10.3: "DCE AVM not confirmed"): dce-<org>-<token>-azl-<region>-01, deployed only when
// enable_monitor_private_link = true (design §7.2). The Insights DCR is created in Day-2 Ready, never here.
targetScope = 'resourceGroup'

param name string
param location string
param tags object

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: name
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

output resourceId string = dce.id
