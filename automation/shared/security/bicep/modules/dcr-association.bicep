// Gap-fill: associates one Windows machine (Azure Arc machine or Azure VM) with the security data collection rule.
// The association is an extension resource on the machine, so it is deployed into the machine's own resource group.
targetScope = 'resourceGroup'

@description('Microsoft.HybridCompute/machines or Microsoft.Compute/virtualMachines (any casing).')
param machineType string

var isArc = toLower(machineType) == 'microsoft.hybridcompute/machines'
param machineName string
param associationName string
param dataCollectionRuleId string

resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' existing = if (isArc) {
  name: machineName
}

resource azureVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = if (!isArc) {
  name: machineName
}

resource arcAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (isArc) {
  name: associationName
  scope: arcMachine
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'Security events (Microsoft Sentinel, Windows Security Events via AMA). Deleting this association stops security event collection for this machine.'
  }
}

resource vmAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (!isArc) {
  name: associationName
  scope: azureVm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'Security events (Microsoft Sentinel, Windows Security Events via AMA). Deleting this association stops security event collection for this machine.'
  }
}
