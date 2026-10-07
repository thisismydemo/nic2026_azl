// Gap-fill (design §10.3: "action group AVM not confirmed"): ag-<org>-<token>-ops-<region>-01, design §7.2.
// E-mail to the owner list; the webhook receiver is a Day-2 addition (no placeholder URL is committed).
targetScope = 'resourceGroup'

param name string
param tags object
@description('E-mail recipients (budget_contact_emails).')
param emails array

resource ag 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(name, '-', ''), 12)
    enabled: true
    emailReceivers: [for (email, i) in emails: {
      name: 'owner-${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

output resourceId string = ag.id
