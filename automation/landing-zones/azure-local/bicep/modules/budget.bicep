// Gap-fill (design §10.3 lists no confirmed AVM budget module): subscription budget, design §2.5.
// Alerts at 50/80/100 % actual and 100 % forecast to the contact e-mails and the ops action group.
targetScope = 'subscription'

@description('Budget name from the catalog (budget_azl).')
param name string
@description('Monthly amount.')
param amount int
@description('Contact e-mails.')
param contact_emails array
@description('Action group resource ID for the notifications.')
param action_group_id string
@description('First day of the current month (budgets must start on the first of a month, not in the past). Defaults to utcNow.')
param start_date string = utcNow('yyyy-MM-01')

var notification = {
  enabled: true
  operator: 'GreaterThan'
  contactEmails: contact_emails
  contactGroups: [action_group_id]
  thresholdType: 'Actual'
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: start_date
    }
    notifications: {
      actual50: union(notification, { threshold: 50 })
      actual80: union(notification, { threshold: 80 })
      actual100: union(notification, { threshold: 100 })
      forecast100: union(notification, { threshold: 100, thresholdType: 'Forecasted' })
    }
  }
}

output budgetId string = budget.id
