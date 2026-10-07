// EXAMPLE (all-zero GUIDs). Real file: main.generated.bicepparam (git-ignored).
using 'main.bicep'

param subscription_id = '00000000-0000-0000-0000-000000000000'
param group_object_ids = {
  lab_operators: '00000000-0000-0000-0000-000000000000'
  azl_admins: '00000000-0000-0000-0000-000000000000'
  azl_operators: '00000000-0000-0000-0000-000000000000'
  azl_readers: '00000000-0000-0000-0000-000000000000'
}
param pim_max_activation_hours = 8
param pim_assignments = [
  { group: 'azl_admins', role: 'Azure Stack HCI Administrator' }
  { group: 'azl_admins', role: 'Reader' }
  { group: 'azl_operators', role: 'Azure Stack HCI VM Contributor' }
  { group: 'azl_operators', role: 'Reader' }
]
param names = { deployment_name: 'dep-iic-nic26-azl-access-pim-01' }
