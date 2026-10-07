// Entry point for the compliance-baseline initiative DEFINITION at management-group scope (design §2.3 LZ-01, §7.4).
// Run by Invoke-LzAzureLocalDeploy.ps1 in stage S1 when management_group_id is set:
//   New-AzManagementGroupDeployment -ManagementGroupId <management_group_id> -Location <location> -TemplateFile initiative.bicep ...
// The ASSIGNMENT (asg-<org>-<token>-hybrid-baseline, subscription scope) is Day-2 Ready, not this landing zone.
targetScope = 'managementGroup'

param names object
param location string
param subscription_id string

module initiative 'modules/policy-initiative.bicep' = {
  name: 'policy-initiative'
  params: {
    names: names
    allowed_locations: [location, 'global']
    log_analytics_workspace_id: resourceId(subscription_id, names.rg_mon, 'Microsoft.OperationalInsights/workspaces', names.law)
  }
}

output initiative_id string = initiative.outputs.initiativeId
