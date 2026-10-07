// EXAMPLE (all-zero GUIDs). Real file: main.generated.bicepparam (git-ignored).
using 'main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param defender_servers_plan = 'P2'
param enable_defender_keyvault = false
param enable_defender_storage = false
param names = {
  deployment_name: 'dep-iic-nic26-azl-defender-01'
}
