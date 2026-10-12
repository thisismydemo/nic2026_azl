// NIC 2026 - security operations workspace (design/shared/security-operations.md). Resource-group scope.
// Log Analytics workspace onboarded to Microsoft Sentinel, the subscription-based Defender for Cloud connectors, the
// incident-creation rule for Defender for Cloud alerts, the security data collection rule (Windows Security Events via
// AMA, "Common" event set) with its associations, and the daily-cap safeguard alerts.
// Gap-fill (no AVM used): every resource is a native resource so the API versions are visible in one file.
// Learn: Onboard Microsoft Sentinel; Windows security event sets (Common); Ingest Defender for Cloud alerts to Sentinel;
// Set daily cap on Log Analytics workspace.
targetScope = 'resourceGroup'

@description('Region of the workspace and the DCR.')
param location string = resourceGroup().location
@description('Log Analytics workspace name, e.g. law-<org>-<token>-sec-<region>-01.')
param workspaceName string
@minValue(30)
@maxValue(730)
@description('Interactive retention in days. Microsoft Sentinel includes 90 days at no extra retention charge.')
param retentionInDays int = 90
@description('Daily cap in GB as a safeguard against ingestion spikes (Learn: not a cost-reduction tool). -1 = no cap.')
param dailyQuotaGb int = -1
@description('Security data collection rule name, e.g. dcr-<org>-<token>-sec-winevents-<region>-01.')
param dcrName string
@description('Association name written on every machine, e.g. dcra-<org>-<token>-sec-01.')
param dcrAssociationName string
@description('Resource IDs of Windows machines (Azure Arc machines or Azure VMs) to associate with the security DCR.')
param machineResourceIds array = []
@description('Subscription IDs whose Defender for Cloud alerts stream to this workspace (subscription-based connector).')
param defenderAlertSubscriptionIds array = []
@description('Action group resource ID for the daily-cap alerts (empty = alert rules without an action).')
param actionGroupId string = ''
@description('Name prefix for the two daily-cap alert rules, e.g. alert-<org>-<token>-sec.')
param alertNamePrefix string
param tags object = {}
@description('Windows Security event IDs to collect. Default = the "Common" set from Learn (Windows security event sets that can be sent to Microsoft Sentinel).')
param securityEventIds array = [
  1, 299, 300, 324, 340, 403, 404, 410, 411, 412, 413, 431, 500, 501, 1100, 1102, 1107, 1108, 4608, 4610, 4611, 4614, 4622
  4624, 4625, 4634, 4647, 4648, 4649, 4657, 4661, 4662, 4663, 4665, 4666, 4667, 4688, 4670, 4672, 4673, 4674, 4675, 4689
  4697, 4700, 4702, 4704, 4705, 4716, 4717, 4718, 4719, 4720, 4722, 4723, 4724, 4725, 4726, 4727, 4728, 4729, 4733, 4732
  4735, 4737, 4738, 4739, 4740, 4742, 4744, 4745, 4746, 4750, 4751, 4752, 4754, 4755, 4756, 4757, 4760, 4761, 4762, 4764
  4767, 4768, 4771, 4774, 4778, 4779, 4781, 4793, 4797, 4798, 4799, 4800, 4801, 4802, 4803, 4825, 4826, 4870, 4886, 4887
  4888, 4893, 4898, 4902, 4904, 4905, 4907, 4931, 4932, 4933, 4946, 4948, 4956, 4985, 5024, 5033, 5059, 5136, 5137, 5140
  5145, 5632, 6144, 6145, 6272, 6273, 6278, 6416, 6423, 6424, 8001, 8002, 8003, 8004, 8005, 8006, 8007, 8222, 26401, 30004
]

// XPath queries of at most 20 event IDs each (the Windows event query engine rejects very long OR chains).
var xPathChunk = 20
var securityXPathQueries = [
  for i in range(0, (length(securityEventIds) + xPathChunk - 1) / xPathChunk): 'Security!*[System[${join(map(take(skip(securityEventIds, i * xPathChunk), xPathChunk), id => '(EventID=${id})'), ' or ')}]]'
]

// ---------------------------------------------------------------- workspace + Sentinel
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    workspaceCapping: { dailyQuotaGb: dailyQuotaGb }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-09-01' = {
  name: 'default'
  scope: workspace
  properties: {}
}

// Workspace audit log to itself (who queried what), as the landing-zone workspaces do.
resource workspaceAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${workspaceName}'
  scope: workspace
  properties: {
    workspaceId: workspace.id
    logs: [{ category: 'Audit', enabled: true }]
  }
}

// ---------------------------------------------------------------- Defender for Cloud alerts -> Sentinel
// Subscription-based connector: the tenant-based one needs the Defender XDR integration (not licensed in this tenant).
resource defenderConnectors 'Microsoft.SecurityInsights/dataConnectors@2024-09-01' = [
  for subId in defenderAlertSubscriptionIds: {
    name: guid(workspace.id, 'AzureSecurityCenter', subId)
    scope: workspace
    kind: 'AzureSecurityCenter'
    properties: {
      subscriptionId: subId
      dataTypes: { alerts: { state: 'Enabled' } }
    }
    dependsOn: [sentinel]
  }
]

resource defenderIncidents 'Microsoft.SecurityInsights/alertRules@2024-09-01' = {
  name: guid(workspace.id, 'MicrosoftSecurityIncidentCreation', 'Azure Security Center')
  scope: workspace
  kind: 'MicrosoftSecurityIncidentCreation'
  properties: {
    displayName: 'Create incidents based on Microsoft Defender for Cloud alerts'
    description: 'Creates a Microsoft Sentinel incident for every Defender for Cloud alert of severity Low or higher.'
    enabled: true
    productFilter: 'Azure Security Center'
    severitiesFilter: ['High', 'Medium', 'Low']
  }
  dependsOn: [sentinel]
}

// ---------------------------------------------------------------- Windows Security Events via AMA
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Windows Security Events via AMA (Microsoft Sentinel), Common event set, to the security workspace.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'securityEventsCommon'
          streams: ['Microsoft-SecurityEvent']
          xPathQueries: securityXPathQueries
        }
      ]
    }
    destinations: {
      logAnalytics: [
        { name: 'securityWorkspace', workspaceResourceId: workspace.id }
      ]
    }
    dataFlows: [
      { streams: ['Microsoft-SecurityEvent'], destinations: ['securityWorkspace'] }
    ]
  }
  dependsOn: [sentinel]
}

module associations 'modules/dcr-association.bicep' = [
  for (machineId, i) in machineResourceIds: {
    name: 'dcra-sec-${i}-${uniqueString(machineId)}'
    scope: resourceGroup(split(machineId, '/')[2], split(machineId, '/')[4])
    params: {
      machineType: '${split(machineId, '/')[6]}/${split(machineId, '/')[7]}'
      machineName: last(split(machineId, '/'))
      associationName: dcrAssociationName
      dataCollectionRuleId: dcr.id
    }
  }
]

// ---------------------------------------------------------------- daily-cap safeguard alerts (Learn: daily cap + 90 % alert)
var alertActions = empty(actionGroupId) ? {} : { actionGroups: [actionGroupId] }

resource capReached 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (dailyQuotaGb > 0) {
  name: '${alertNamePrefix}-dailycap-${location}-01'
  location: location
  tags: tags
  properties: {
    displayName: 'Security workspace daily cap reached'
    description: 'The daily cap of ${workspaceName} was reached; security data collection is stopped until the reset hour.'
    severity: 1
    enabled: true
    scopes: [workspace.id]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: '_LogOperation | where Category =~ "Ingestion" | where Detail contains "OverQuota"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: alertActions
  }
}

resource capWarning 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (dailyQuotaGb > 0) {
  name: '${alertNamePrefix}-ingest90-${location}-01'
  location: location
  tags: tags
  properties: {
    displayName: 'Security workspace ingestion above 90 % of the daily cap'
    description: 'Billable ingestion today passed 90 % of the ${dailyQuotaGb} GB daily cap of ${workspaceName}.'
    severity: 2
    enabled: true
    scopes: [workspace.id]
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: 'Usage | where TimeGenerated > startofday(now()) | where IsBillable == true | summarize GB = sum(Quantity) / 1000.0 | where GB > ${dailyQuotaGb} * 0.9'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: alertActions
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output dcrId string = dcr.id
output xPathQueryCount int = length(securityXPathQueries)
