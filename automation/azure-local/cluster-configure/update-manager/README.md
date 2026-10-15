# cluster-configure/update-manager — Azure Update Manager for the guest OS (outline §3.2)

Two update planes, two owners: Lifecycle Manager updates the cluster (outline §4.1, recorded); **Azure Update Manager patches the guest OS of the Azure Local VMs**, which are Arc machines. This solution creates the maintenance configuration `mc-iic-nic26-azl-eus-01` (InGuestPatch, window from outline §1.11, user-managed patch mode) and a **subscription-level dynamic scope** `mc-iic-nic26-azl-dynscope-eus-01` that selects machines by tag (`dynamic_scope_tags`; for example `workload` in `iic`, `sofs-fslogix`, operator All) so new VMs are covered automatically. Periodic assessment is set by `scripts/Set-PeriodicAssessment.ps1` (and enforced by the policy initiative where the security track assigns it).

| Track | Maintenance configuration | Dynamic scope |
|---|---|---|
| Bicep (subscription scope) | `avm/res/maintenance/maintenance-configuration:0.4.0` in `rg_mon` | gap-fill `Microsoft.Maintenance/configurationAssignments@2023-04-01` with `filter` (the AVM `configuration-assignment` module is resource-group scoped) |
| Terraform | `azurerm_maintenance_configuration` (gap-fill; TF AVM 0.1.0 not adopted) | `azurerm_maintenance_assignment_dynamic_scope` |

## As built 12 Oct 2026 (T-5.4.2)

- **Live:** `mc-iic-nic26-azl-eus-01` (InGuestPatch, Sunday 02:00-05:00 Eastern, **first window Sunday 18 Oct 2026**, after the event: nothing is patched or rebooted before 16 Oct; reboot IfRequired; Critical, Security, UpdateRollup, Definition) and the dynamic scope `mc-iic-nic26-azl-dynscope-eus-01` (location `global`; Windows; Arc machines and Azure VMs tagged `workload` = `iic` or `sofs-fslogix`, the Windows Server Azure Local VMs). `microsoft.hybridcompute/machines` was accepted, so the (verify) below is closed.
- **Not in scope on purpose:** the cluster nodes (Arc machines with `AzureEdgeLifecycleManager`, updated through solution updates, kept manual; the OEM solution extension update deferred); the Windows 11 AVD session hosts (AUM does not support client OS; Intune/WUfB, AVD design §10); the jump server (owner: do not touch).
- **Periodic assessment:** `scripts/Set-PeriodicAssessment.ps1 -Execute` sets `assessmentMode = AutomaticByPlatform` (assessment every 24 h, nothing installed) on the machines in `assessment_scope_tags` (adds `workload = identity`, the Entra Connect sync server) and skips any Azure Local node. Azure VMs normally also get `bypassPlatformSafetyChecksOnUserSchedule = true` (the schedule-patching prerequisite), **but a hotpatch VM refuses it** (HTTP 400: hotpatch requires the platform safety checks), so the sync server keeps hotpatch with platform orchestration and is left out of the dynamic scope. Event risk: October is a hotpatch baseline month, so the platform may reboot the sync server once after Patch Tuesday (13 Oct); Entra Connect sync pauses for minutes only. Azure Local VMs that are still being built (guest agent not reporting the OS) are skipped; re-run the script after each VM build.

**(verify)** `filter.resourceTypes` spelling for Arc machines (`microsoft.hybridcompute/machines`; the portal shows "Arc-enabled servers") — Learn's template reference does not enumerate the values; confirm on the first apply and adjust in both tracks. The Arc machines need no patch-orchestration prerequisite (Learn: Manage a dynamic scope).

Inputs added beyond the schema: `maintenance_window` (`start_date_time`, `duration`, `time_zone`, `recur_every`), `patch_classifications`, `reboot_setting`, `dynamic_scope_tags`, `dynamic_scope_os_types`. The example window is a value, not a tenant secret; set the real window in the private environment file.

## Run

```powershell
cd .\automation\azure-local\cluster-configure\update-manager\scripts
.\Invoke-UpdateManagerConfigure.ps1 -Action Apply            # what-if
.\Invoke-UpdateManagerConfigure.ps1 -Action Apply -Execute
.\Invoke-UpdateManagerConfigure.ps1 -Action Remove -Execute  # live replay: delete, then Apply on stage; AUM machines view shows the scope
```

State: `..\scripts\Get-Day2ControlState.ps1` → control `update-manager` (Applied = configuration and dynamic scope exist and point at each other).

## Start date (review R-35)

Azure Update Manager accepts a maintenance-window start of **today or later**. `Invoke-UpdateManagerConfigure.ps1 -Action Apply` refuses, before any Azure call, when `maintenance_window.start_date_time` is before today (in the window's time zone). A live replay (Remove, then Apply on stage) therefore needs the start date moved to the day of the session or later in `environment/azure-local` first.

## Cluster solution update with additional content (OEM SBE) — `scripts/Invoke-SolutionUpdate.ps1` (T-5.3.14)

The cluster nodes are updated by Lifecycle Manager, not by Azure Update Manager. When an update reports **`AdditionalContentRequired`** (an OEM Solution Builder Extension whose payload is downloaded from the hardware vendor), this script runs the Microsoft Learn procedure [Update Azure Local by using PowerShell](https://learn.microsoft.com/azure/azure-local/update/update-via-powershell-23h2) end to end, rerunnably:

| Stage | Learn step | What it does |
|---|---|---|
| `State` (default) | 1, 2 | `Get-SolutionUpdateEnvironment`, the target update and the gates (nodes Up, no storage job, virtual disks Healthy, environment health) |
| `Import` | 3 | Checks the XML signature of the discovery and inventory files (and with `-VerifyPayload` every payload file against the signed SHA-256 list), copies the three files to the import folder on the infrastructure volume (skips files with the same hash), `Add-SolutionUpdate -SourceFolder`, waits for `Ready` |
| `Check` | 4 | `Start-SolutionUpdate -PrepareOnly`, waits for `ReadyToInstall`, prints any non-success readiness check with its remediation |
| `Start` | 5, 6 | Drain mode on the AVD session host of every DDA GPU VM (`gpu.vms`), stop that VM (`az stack-hci-vm stop`; DDA VMs cannot live-migrate and would block the node drain), `Start-SolutionUpdate`, then monitors the update state and the deepest running step of `Get-SolutionUpdateRun` from the monitor node (falls back to the other node during reboots) until `Installed`; on failure prints the failing step and error and stops (resume after fixing the documented cause = run `Start` again, Learn step 7) |
| `Post` | 8 | Secure Boot, BIOS and node state per node, starts the GPU VMs (`az stack-hci-vm start --no-wait`, waits on the host; with `-HostStartFallback` starts the clustered VM role on the host when the Azure start does not arrive, as seen once after the 12 Oct run), checks the DDA device location path against `gpu.hosts`, re-enables new sessions and waits for `Available`, prints the new versions |

Inputs: `solution_update` in `environment/azure-local/solution-update.yml` (package folder on the jump server, import folder, package type and version, monitor node, AVD host pool of the GPU VMs) plus `gpu.vms`, `nodes` and the node credential reference. Nothing changes without `-Execute`.

```powershell
.\Invoke-SolutionUpdate.ps1                                    # state + gates
.\Invoke-SolutionUpdate.ps1 -Stage Import -Execute -VerifyPayload
.\Invoke-SolutionUpdate.ps1 -Stage Check -Execute
.\Invoke-SolutionUpdate.ps1 -Stage Start -Execute              # long-running: rolling reboot of every node
.\Invoke-SolutionUpdate.ps1 -Stage Post -Execute
```

As run on nic26-clus01, 12 Oct 2026 (R-387): import 13:05-13:10, readiness 13:13-13:27, install 13:32-15:25 UTC (1 h 53 min, both nodes rebooted once), post checks clean. `Start-SolutionUpdate` asks for confirmation; the script passes `-Confirm:$false` because nobody can answer a prompt over remoting (`-Execute` is the confirmation).
