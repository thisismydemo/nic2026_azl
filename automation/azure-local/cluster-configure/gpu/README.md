# cluster-configure/gpu — GPU by Discrete Device Assignment (DDA)

Prepares the cluster's GPUs for DDA, attaches one GPU to the Azure Local VMs listed in `gpu.vms`, and installs the guest driver and the Azure Virtual Desktop GPU policies. Design: gpu-design.md. Values: the `gpu` block in `environment/azure-local/*.yml` (schema `automation/shared/schemas/azure-local.environment.schema.json`).

| Script | Where it runs | What it does |
|---|---|---|
| `scripts/Initialize-GpuHost.ps1` | jump server (WinRM to the nodes) | Learn *Prepare GPUs for Azure Local* (DDA): gates, drain one node, disable + dismount the GPU, NVIDIA mitigation INF (SHA-256 checked), resume, wait for storage repair, next node; `Sync-AzureStackHci` at the end. Plan by default; `-Mode Check`; `-Execute` |
| `scripts/Set-VmGpuAssignment.ps1` | jump server (Azure CLI `stack-hci-vm`) | `az stack-hci-vm gpu attach --gpu-dda-count 1` / `detach` / check, VM stopped and restarted around the change. Plan by default; `-Execute` |
| `scripts/Install-GuestGpuDriver.ps1` | inside the GPU VM (Windows PowerShell 5.1, elevated) | NVIDIA data center driver (signature checked, silent), AVD policies: hardware graphics adapter, AVC 444, AVC hardware encoding |

## Run

```powershell
cd .\automation\azure-local\cluster-configure\gpu\scripts
.\Initialize-GpuHost.ps1 -Mode Check
.\Initialize-GpuHost.ps1 -Execute                      # both nodes, one at a time
.\Set-VmGpuAssignment.ps1 -Action Check
.\Set-VmGpuAssignment.ps1 -Execute                     # after the AVD track created the VM
# inside the VM (values from gpu.guest_driver):
.\Install-GuestGpuDriver.ps1 -DriverUrl <https url> -DriverVersion <version> -Restart
```

Remove: `Set-VmGpuAssignment.ps1 -Action Detach -Execute`. The host prep is left in place (a dismounted GPU with the mitigation INF is the supported DDA state); to give the GPU back to the host, `Mount-VMHostAssignableDevice -LocationPath <path>` on a drained node.

Tests: `Invoke-Pester .\tests` (static: parse, StrictMode, no environment values, plan default, gates, CLI attach, guest policies).
