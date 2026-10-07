// Built-in Azure Policy definition IDs used by this landing zone (design §2.4, §7.4).
// Platform constants (identical in every tenant); part of the documented GUID allow-list.
// Test-LandingZone.ps1 check "policy-map" verifies each ID resolves to the expected display name.
@export()
var builtInPolicies = {
  // "Allowed locations" — Deny
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
  // "Require a tag on resource groups" — Deny (parameter tagName)
  requireTagOnResourceGroups: '96670d01-0a4d-4649-9c89-2d3abc0a5025'
  // "Inherit a tag from the resource group if missing" — Modify (parameter tagName)
  inheritTagFromResourceGroupIfMissing: 'ea3f2387-9b95-492a-a190-fcdc54f7b070'
  // "Configure Azure Activity logs to stream to specified Log Analytics workspace" — DeployIfNotExists
  activityLogToLogAnalytics: '2465583e-4e78-4c15-b6be-a36cbc7c8b0f'
  // Initiative members (design §7.4; assigned in Day-2 Ready, defined here)
  // "Configure Windows Arc-enabled machines to run Azure Monitor Agent" — DeployIfNotExists
  amaOnArcWindows: '94f686d6-9a24-4e19-91f1-de937dc171a4'
  // "Configure periodic checking for missing system updates on azure Arc-enabled servers" — Modify
  periodicAssessmentOnArc: 'bfea026e-043f-4ff4-9d1b-bf301ca7ff46'
  // "Configure Azure Defender for servers to be enabled" — DeployIfNotExists
  defenderForServersEnabled: '8e86a5b6-b9bd-49d1-8e21-4bb8a0862222'
}
