// NIC 2026 - security baseline for ONE landing-zone subscription (design/shared/security-operations.md). Subscription scope.
// Run once per subscription by scripts/Invoke-SecurityBaseline.ps1 after workspace.bicep.
//   1. Microsoft Defender for Cloud plans and settings (production set; Learn: Manage system security with Defender for
//      Cloud on Azure Local, Enable the Defender for Servers plan, Defender CSPM, Defender for Storage).
//   2. Azure Policy assignments at subscription scope (P-06). The Microsoft cloud security benchmark is NOT assigned here:
//      Defender for Cloud already assigns it as SecurityCenterBuiltIn (ASC Default) and it carries the Azure Local checks.
//      Effects are chosen so nothing blocks the running build: Audit / DoNotEnforce for guardrails, Modify for tags,
//      DeployIfNotExists only for the security data path (activity log, AMA, security DCR association).
//   3. Exemptions: Azure Local machines are exempt from the per-machine AMA policy (agent comes from the cluster extension).
// Gap-fill: Microsoft.Security/* and Microsoft.Authorization/* have no AVM resource modules at subscription scope.
targetScope = 'subscription'

@description('Region for policy assignment identities.')
param location string
@description('Name prefix for every assignment, e.g. asg-<org>-<token>-sec.')
param assignmentPrefix string
@description('Exemption name prefix, e.g. exm-<org>-<token>-sec.')
param exemptionPrefix string

// ---- Defender for Cloud
param enableDefenderCspm bool = true
@allowed(['P1', 'P2', 'off'])
param defenderServersPlan string = 'P2'
param enableDefenderStorage bool = true
@description('On-upload malware scanning cap per storage account and month (GB); -1 = unlimited.')
param storageMalwareScanCapGb int = 100
param enableDefenderKeyVault bool = true
param enableDefenderArm bool = true
param enableAgentlessVmScanning bool = true
#disable-next-line no-unused-params
param enableFileIntegrityMonitoring bool = false

// ---- Policy
param allowedLocations array
@allowed(['Audit', 'Deny', 'Disabled'])
param allowedLocationsEffect string = 'Audit'
@description('Tag that every resource group must carry (assigned DoNotEnforce = audit-only rollout).')
param requiredResourceGroupTag string = 'project'
@description('Tags inherited from the resource group when a resource lacks them (Modify).')
param inheritTags array = []
@description('Security workspace resource ID (activity log destination).')
param workspaceId string
@description('Security data collection rule resource ID.')
param dcrId string
@description('Resource IDs of Azure Local machines in THIS subscription to exempt from the per-machine AMA policy.')
param amaExemptMachineIds array = []
param enforcementMode string = 'Default'

var policyDef = '/providers/Microsoft.Authorization/policyDefinitions/'
var builtIn = {
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
  allowedRgLocations: 'e765b5de-1225-4ba3-bd56-1ac6695af988'
  requireRgTag: '96670d01-0a4d-4649-9c89-2d3abc0a5025'
  inheritRgTag: 'ea3f2387-9b95-492a-a190-fcdc54f7b070'
  activityLogToLaw: '2465583e-4e78-4c15-b6be-a36cbc7c8b0f'
  dcrAssociation: 'eab1f514-22e3-42e3-9a1f-e1dc9199355c'
  amaArc: '94f686d6-9a24-4e19-91f1-de937dc171a4'
  amaVmSami: 'ca817e41-e85a-4783-bc7f-dc532d36235e'
}
// Built-in role definition GUIDs (platform constants) = each definition's roleDefinitionIds.
var roles = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  monitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  logAnalyticsContributor: '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  connectedMachineResourceAdmin: 'cd570a14-e51a-42ad-bac8-bafd67325302'
  virtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}
var wsSub = split(workspaceId, '/')[2]
var wsRg = split(workspaceId, '/')[4]
var meta = { category: 'NIC26 security baseline', assignedBy: 'automation/shared/security' }

// ================================================================ 1. Defender for Cloud
// Pricings are written one after another: parallel PUTs on Microsoft.Security/pricings conflict.
resource cspm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'CloudPosture'
  properties: enableDefenderCspm ? {
    pricingTier: 'Standard'
    extensions: [
      { name: 'AgentlessVmScanning', isEnabled: enableAgentlessVmScanning ? 'True' : 'False' }
      { name: 'SensitiveDataDiscovery', isEnabled: 'True' }
    ]
  } : {
    pricingTier: 'Free'
  }
}

resource servers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: defenderServersPlan == 'off' ? {
    pricingTier: 'Free'
  } : {
    pricingTier: 'Standard'
    subPlan: defenderServersPlan
    extensions: defenderServersPlan == 'P2' ? [
      { name: 'MdeDesignatedSubscription', isEnabled: 'False' }
      { name: 'AgentlessVmScanning', isEnabled: enableAgentlessVmScanning ? 'True' : 'False' }
      // FileIntegrityMonitoring is configured separately: the pricing extension needs a workspace AND a rule set (Rules);
      // left out here so the plan deploys cleanly (open item in design/shared/security-operations.md).
    ] : []
  }
  dependsOn: [cspm]
}

resource storage 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'StorageAccounts'
  properties: enableDefenderStorage ? {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
    extensions: [
      { name: 'OnUploadMalwareScanning', isEnabled: 'True', additionalExtensionProperties: { CapGBPerMonthPerStorageAccount: string(storageMalwareScanCapGb) } }
      { name: 'SensitiveDataDiscovery', isEnabled: 'True' }
    ]
  } : {
    pricingTier: 'Free'
  }
  dependsOn: [servers]
}

resource keyVaults 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'KeyVaults'
  properties: enableDefenderKeyVault ? { pricingTier: 'Standard', subPlan: 'PerKeyVault' } : { pricingTier: 'Free' }
  dependsOn: [storage]
}

resource arm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'Arm'
  properties: enableDefenderArm ? { pricingTier: 'Standard', subPlan: 'PerSubscription' } : { pricingTier: 'Free' }
  dependsOn: [keyVaults]
}

// Defender for Endpoint integration (unified solution) on; legacy Log Analytics agent auto-provisioning off (retired agent).
resource mde 'Microsoft.Security/settings@2022-05-01' = {
  name: 'WDATP'
  kind: 'DataExportSettings'
  properties: { enabled: true }
  dependsOn: [arm]
}

resource legacyAgent 'Microsoft.Security/autoProvisioningSettings@2017-08-01-preview' = {
  name: 'default'
  properties: { autoProvision: 'Off' }
  dependsOn: [mde]
}

// Vulnerability assessment for Azure VMs by Microsoft Defender Vulnerability Management (Plan 2 default).
// Learn (Azure Local): MDVM does not support Azure Local machines yet - that recommendation is a documented exclusion.
resource vaProvider 'Microsoft.Security/serverVulnerabilityAssessmentsSettings@2023-05-01' = if (defenderServersPlan != 'off') {
  name: 'AzureServersSetting'
  kind: 'AzureServersSetting'
  properties: { selectedProvider: 'MdeTvm' }
  dependsOn: [legacyAgent]
}

// ================================================================ 2. Azure Policy
module asgAllowedLocations 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-allowed-locations'
  params: {
    name: '${assignmentPrefix}-allowed-locations'
    displayName: 'NIC26 security - allowed locations (${allowedLocationsEffect})'
    assignmentDescription: 'Resources outside the approved regions are reported (effect parameter, not Deny, so nothing in the running build is blocked).'
    policyDefinitionId: '${policyDef}${builtIn.allowedLocations}'
    location: location
    identityType: 'None'
    enforcementMode: enforcementMode
    parameters: { listOfAllowedLocations: { value: allowedLocations }, effect: { value: allowedLocationsEffect } }
    metadata: meta
  }
}

module asgAllowedRgLocations 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-allowed-rg-locations'
  params: {
    name: '${assignmentPrefix}-allowed-rg-locations'
    displayName: 'NIC26 security - allowed resource group locations (${allowedLocationsEffect})'
    policyDefinitionId: '${policyDef}${builtIn.allowedRgLocations}'
    location: location
    identityType: 'None'
    enforcementMode: enforcementMode
    parameters: { listOfAllowedLocations: { value: allowedLocations }, effect: { value: allowedLocationsEffect } }
    metadata: meta
  }
}

module asgRequireRgTag 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-require-rg-tag'
  params: {
    name: '${assignmentPrefix}-require-rg-tag-${requiredResourceGroupTag}'
    displayName: 'NIC26 security - resource groups carry the ${requiredResourceGroupTag} tag (audit-only rollout)'
    assignmentDescription: 'Built-in Deny definition assigned with enforcement DoNotEnforce: compliance is reported, nothing is denied. Promote to Default after the event.'
    policyDefinitionId: '${policyDef}${builtIn.requireRgTag}'
    location: location
    identityType: 'None'
    enforcementMode: 'DoNotEnforce'
    parameters: { tagName: { value: requiredResourceGroupTag } }
    metadata: meta
    nonComplianceMessage: 'Resource groups must carry the ${requiredResourceGroupTag} tag.'
  }
}

module asgInheritTags 'modules/policy-assignment.bicep' = [
  for tag in inheritTags: {
    name: 'sec-asg-inherit-${tag}'
    params: {
      name: '${assignmentPrefix}-inherit-tag-${tag}'
      displayName: 'NIC26 security - inherit tag ${tag} from the resource group if missing'
      policyDefinitionId: '${policyDef}${builtIn.inheritRgTag}'
      location: location
      enforcementMode: enforcementMode
      parameters: { tagName: { value: tag } }
      roleDefinitionIds: [roles.contributor]
      metadata: meta
    }
  }
]

module asgActivityLog 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-activity-log'
  params: {
    name: '${assignmentPrefix}-activity-log'
    displayName: 'NIC26 security - Azure Activity log to the security workspace (Sentinel Azure Activity connector)'
    policyDefinitionId: '${policyDef}${builtIn.activityLogToLaw}'
    location: location
    enforcementMode: enforcementMode
    parameters: { logAnalytics: { value: workspaceId }, logsEnabled: { value: 'True' } }
    roleDefinitionIds: [roles.monitoringContributor, roles.logAnalyticsContributor]
    metadata: meta
  }
}

module asgDcrAssociation 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-dcr-association'
  params: {
    name: '${assignmentPrefix}-dcr-assoc'
    displayName: 'NIC26 security - Windows machines associated with the security DCR (Windows Security Events via AMA)'
    policyDefinitionId: '${policyDef}${builtIn.dcrAssociation}'
    location: location
    enforcementMode: enforcementMode
    parameters: {
      dcrResourceId: { value: dcrId }
      resourceType: { value: 'Microsoft.Insights/dataCollectionRules' }
      scopeToSupportedImages: { value: false }
    }
    roleDefinitionIds: [roles.monitoringContributor, roles.logAnalyticsContributor]
    metadata: meta
  }
}

module asgAmaArc 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-ama-arc'
  params: {
    name: '${assignmentPrefix}-ama-arc'
    displayName: 'NIC26 security - Azure Monitor Agent on Windows Arc-enabled machines (Azure Local machines exempt)'
    policyDefinitionId: '${policyDef}${builtIn.amaArc}'
    location: location
    enforcementMode: enforcementMode
    roleDefinitionIds: [roles.connectedMachineResourceAdmin]
    metadata: meta
  }
}

module asgAmaVm 'modules/policy-assignment.bicep' = {
  name: 'sec-asg-ama-vm'
  params: {
    name: '${assignmentPrefix}-ama-vm'
    displayName: 'NIC26 security - Azure Monitor Agent on Windows Azure VMs (system-assigned identity)'
    policyDefinitionId: '${policyDef}${builtIn.amaVmSami}'
    location: location
    enforcementMode: enforcementMode
    parameters: { scopeToSupportedImages: { value: false } }
    roleDefinitionIds: [roles.virtualMachineContributor]
    metadata: meta
  }
}

// Cross-scope grants on the security workspace's resource group: the activity-log and DCR-association identities
// write settings that point at a workspace / DCR that may live in another subscription.
module wsGrantActivity 'modules/rg-role-assignment.bicep' = {
  name: 'sec-ra-ws-activity-${uniqueString(subscription().id)}'
  scope: resourceGroup(wsSub, wsRg)
  params: {
    principalId: asgActivityLog.outputs.principalId
    roleDefinitionIds: [roles.logAnalyticsContributor]
    descriptionText: 'Activity-log policy identity of ${subscription().displayName}'
  }
}

module wsGrantDcr 'modules/rg-role-assignment.bicep' = {
  name: 'sec-ra-ws-dcr-${uniqueString(subscription().id)}'
  scope: resourceGroup(wsSub, wsRg)
  params: {
    principalId: asgDcrAssociation.outputs.principalId
    roleDefinitionIds: [roles.monitoringContributor]
    descriptionText: 'DCR-association policy identity of ${subscription().displayName}'
  }
}

// ================================================================ 3. Exemptions
module amaExemptions 'modules/policy-exemption.bicep' = [
  for (machineId, i) in amaExemptMachineIds: {
    name: 'sec-exm-ama-${i}-${uniqueString(machineId)}'
    scope: resourceGroup(split(machineId, '/')[4])
    params: {
      machineName: last(split(machineId, '/'))
      exemptionName: '${exemptionPrefix}-ama-arc-${last(split(machineId, '/'))}'
      policyAssignmentId: asgAmaArc.outputs.id
      displayName: 'Azure Local machine - AMA is a cluster extension'
      exemptionDescription: 'On Azure Local the Azure Monitor Agent is installed cluster-aware through the cluster Arc settings (Insights), not per machine. Learn: Azure Arc extension management on Azure Local.'
      category: 'Mitigated'
    }
  }
]

output assignmentIds object = {
  allowedLocations: asgAllowedLocations.outputs.id
  allowedRgLocations: asgAllowedRgLocations.outputs.id
  requireRgTag: asgRequireRgTag.outputs.id
  activityLog: asgActivityLog.outputs.id
  dcrAssociation: asgDcrAssociation.outputs.id
  amaArc: asgAmaArc.outputs.id
  amaVm: asgAmaVm.outputs.id
}
output inheritTagAssignmentIds array = [for (tag, i) in inheritTags: asgInheritTags[i].outputs.id]
