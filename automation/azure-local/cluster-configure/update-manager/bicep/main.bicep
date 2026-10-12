// NIC 2026 — Day-2 Ready 3.2 update management (cluster-configure/update-manager), Bicep track. Subscription scope,
// because a dynamic-scope configuration assignment is a subscription-level resource (Learn: Manage a dynamic scope).
// AVM: avm/res/maintenance/maintenance-configuration:0.4.0 (confirmed on MCR 2026-10-03).
// Gap-fill: Microsoft.Maintenance/configurationAssignments@2023-04-01 at subscription scope with a filter (the AVM
// configuration-assignment module is resource-group scoped).
targetScope = 'subscription'

#disable-next-line no-unused-params
param subscription_id string
param location string
param tags object
param maintenance_window object = {
  start_date_time: '2026-10-05 02:00'
  duration: '03:00'
  time_zone: 'W. Europe Standard Time'
  recur_every: 'Week Sunday'
}
param patch_classifications array = ['Critical', 'Security', 'UpdateRollup', 'Definition']
@allowed(['IfRequired', 'Never', 'Always'])
param reboot_setting string = 'IfRequired'
param dynamic_scope_tags object = { workload: ['azure-local'] }
param dynamic_scope_os_types array = ['Windows', 'Linux']
@description('Resource types the dynamic scope selects: Arc-enabled servers (Azure Local VMs) and, when listed, Azure VMs.')
param dynamic_scope_resource_types array = ['microsoft.hybridcompute/machines']
@description('Periodic-assessment selection, used by scripts/Set-PeriodicAssessment.ps1 (declared here because the converters render every input).')
#disable-next-line no-unused-params
param assessment_scope_tags object = {}
param names object

var allTags = union(tags, { 'managed-by': 'bicep' })

module maintenanceConfiguration 'br/public:avm/res/maintenance/maintenance-configuration:0.4.0' = {
  name: 'update-manager-mc'
  scope: resourceGroup(names.rg_mon)
  params: {
    name: names.mc_azl
    location: location
    tags: allTags
    maintenanceScope: 'InGuestPatch'
    visibility: 'Custom'
    extensionProperties: {
      InGuestPatchMode: 'User'
    }
    maintenanceWindow: {
      startDateTime: maintenance_window.start_date_time
      duration: maintenance_window.duration
      timeZone: maintenance_window.time_zone
      recurEvery: maintenance_window.recur_every
      expirationDateTime: null
    }
    installPatches: {
      rebootSetting: reboot_setting
      windowsParameters: {
        classificationsToInclude: patch_classifications
        kbNumbersToExclude: []
        kbNumbersToInclude: []
      }
      linuxParameters: {
        classificationsToInclude: ['Critical', 'Security']
        packageNameMasksToExclude: []
        packageNameMasksToInclude: []
      }
    }
  }
}

// Dynamic scope: Arc machines in this subscription carrying the selected tags (outline §3.2 "dynamic scope by tag").
resource dynamicScope 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
  name: names.mc_azl_dynscope
  // A subscription-level dynamic scope is a global resource ("Region not supported eastus" on the 12 Oct apply).
  location: 'global'
  properties: {
    maintenanceConfigurationId: maintenanceConfiguration.outputs.resourceId
    resourceId: subscription().id
    filter: {
      resourceTypes: dynamic_scope_resource_types // microsoft.hybridcompute/machines accepted on the 12 Oct apply
      osTypes: dynamic_scope_os_types
      locations: []
      resourceGroups: []
      tagSettings: {
        filterOperator: 'All'
        tags: dynamic_scope_tags
      }
    }
  }
}

output maintenance_configuration_id string = maintenanceConfiguration.outputs.resourceId
output dynamic_scope_assignment_id string = dynamicScope.id
