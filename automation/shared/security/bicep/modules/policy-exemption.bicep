// Gap-fill: a policy exemption on one Azure Arc machine (resource scope). Used to exempt Azure Local machines from the
// "Configure Windows Arc-enabled machines to run Azure Monitor Agent" assignment: on Azure Local the agent is a
// customer-managed cluster extension installed cluster-aware through the cluster's Arc settings, not per machine
// (Learn: Azure Arc extension management on Azure Local).
targetScope = 'resourceGroup'

param machineName string
param exemptionName string
param policyAssignmentId string
param displayName string
param exemptionDescription string
@allowed(['Mitigated', 'Waiver'])
param category string = 'Mitigated'

resource machine 'Microsoft.HybridCompute/machines@2024-07-10' existing = {
  name: machineName
}

resource exemption 'Microsoft.Authorization/policyExemptions@2022-07-01-preview' = {
  name: exemptionName
  scope: machine
  properties: {
    policyAssignmentId: policyAssignmentId
    exemptionCategory: category
    displayName: displayName
    description: exemptionDescription
    assignmentScopeValidation: 'Default'
  }
}

output id string = exemption.id
