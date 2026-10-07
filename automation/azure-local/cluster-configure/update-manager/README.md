# cluster-configure/update-manager — Azure Update Manager for the guest OS (outline §3.2)

Two update planes, two owners: Lifecycle Manager updates the cluster (outline §4.1, recorded); **Azure Update Manager patches the guest OS of the Azure Local VMs**, which are Arc machines. This solution creates the maintenance configuration `mc-iic-nic26-azl-eus-01` (InGuestPatch, window from outline §1.11, user-managed patch mode) and a **subscription-level dynamic scope** `mc-iic-nic26-azl-dynscope-eus-01` that selects Arc machines by tag (`workload = azure-local`, operator All) so new VMs are covered automatically. Periodic assessment on the Arc machines is enforced by the policy initiative (`cluster-configure/policy`).

| Track | Maintenance configuration | Dynamic scope |
|---|---|---|
| Bicep (subscription scope) | `avm/res/maintenance/maintenance-configuration:0.4.0` in `rg_mon` | gap-fill `Microsoft.Maintenance/configurationAssignments@2023-04-01` with `filter` (the AVM `configuration-assignment` module is resource-group scoped) |
| Terraform | `azurerm_maintenance_configuration` (gap-fill; TF AVM 0.1.0 not adopted) | `azurerm_maintenance_assignment_dynamic_scope` |

**(verify)** `filter.resourceTypes` spelling for Arc machines (`microsoft.hybridcompute/machines`; the portal shows "Arc-enabled servers") — Learn's template reference does not enumerate the values; confirm on the first apply and adjust in both tracks. The Arc machines need no patch-orchestration prerequisite (Learn: Manage a dynamic scope).

Inputs added beyond the schema: `maintenance_window` (`start_date_time`, `duration`, `time_zone`, `recur_every`), `patch_classifications`, `reboot_setting`, `dynamic_scope_tags`, `dynamic_scope_os_types`. The example window is a value, not a tenant secret; set the real window in the private environment file.

## Run

```powershell
cd .\automation\azure-local\cluster-configure\update-manager\scripts
.\Invoke-UpdateManagerConfigure.ps1 -Action Apply            # what-if
.\Invoke-UpdateManagerConfigure.ps1 -Action Apply -Execute
.\Invoke-UpdateManagerConfigure.ps1 -Action Remove -Execute  # live replay: delete, then Apply on stage; AUM machines view shows the scope
```

State: `..\..\scripts\Get-Day2ControlState.ps1` → control `update-manager` (Applied = configuration and dynamic scope exist and point at each other).

## Start date (review R-35)

Azure Update Manager accepts a maintenance-window start of **today or later**. `Invoke-UpdateManagerConfigure.ps1 -Action Apply` refuses, before any Azure call, when `maintenance_window.start_date_time` is before today (in the window's time zone). A live replay (Remove, then Apply on stage) therefore needs the start date moved to the day of the session or later in `environment/azure-local` first.
