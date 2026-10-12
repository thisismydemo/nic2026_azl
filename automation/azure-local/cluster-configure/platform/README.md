# cluster-configure/platform — workload platform (outline §3.6)

Logical networks for the workload VLANs, marketplace VM images, storage paths on the workload volumes and an optional Azure Local NSG — the targets that Azure Migrate (§3B), the AVD session hosts and the VM-lifecycle demo (§4.4) use. Implements outline §2.6 / §3.6, network-design §4.4, build runbook 3.6–3.8.

| Item | Bicep | Terraform | Remove |
|---|---|---|---|
| Logical networks `lnet-iic-nic26-compute-vlan110-eus` (VLAN 110), `lnet-iic-nic26-avd-vlan120-eus` (120), static pools .20–.99 | `avm/res/azure-stack-hci/logical-network:0.3.1` | `Azure/avm-res-azurestackhci-logicalnetwork` 2.0.0 | DELETE `logicalNetworks` (after images/storage paths) |
| Images `img-iic-nic26-win11-avd-25h2` (microsoftwindowsdesktop / office-365 / win11-25h2-avd-m365), `img-iic-nic26-ws2025-dc` (microsoftwindowsserver / windowsserver / 2025-datacenter-azure-edition) | `avm/res/azure-stack-hci/marketplace-gallery-image:0.1.0` | gap-fill azapi `marketplaceGalleryImages@2025-04-01-preview` (no TF AVM module) | DELETE |
| Storage paths `sp-nic26-m2-vmstore-01` → `C:\ClusterStorage\csv-nic26-m2-vmstore-01\vms` | gap-fill `storageContainers@2025-02-01-preview` (no AVM) | azapi, same type | DELETE (must be empty) |
| NSG `nsg-iic-nic26-azl-compute-eus-01` (flag `enable_network_security_group`, default off) | gap-fill `networkSecurityGroups@2025-02-01-preview` | azapi | DELETE |
| Volumes `csv-nic26-m2-vmstore-01` (two-way mirror, 2 TiB, thin, ReFS/CSVFS) | `scripts/New-ClusterWorkloadVolume.ps1` (WinRM `New-Volume`; no ARM surface) | same script | **not removed** (data loss = owner runbook) |

Marketplace publisher/offer/SKU values are from [Create Azure Local VM image using Azure Marketplace images (azloc-2609)](https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-image-azure-marketplace?view=azloc-2609); prerequisites there: `Microsoft.EdgeMarketplace` registered and the Azure Local RP app holding *Azure Connected Machine Resource Manager* on the resource group (landing zone S5). The tier-1 ASR VM must be created as a standard (non-Trusted-launch) VM (landing-zone §8.3).

## Live build path on this cluster (12 Oct 2026): CLI scripts

The live build uses `az stack-hci-vm` per resource (Azure PowerShell is out of scope for Azure Local VM resources on this build, and a whole-module Bicep apply would re-send logical-network DNS, a known issue). Each script reads only `environment/azure-local/environment.yml` and `environment/shared/environment.yml` and is idempotent:

| Script | Creates | Notes |
|---|---|---|
| `scripts/New-StoragePathCli.ps1` | storage paths (`storage.storage_paths`) | folder must exist first |
| `scripts/New-VmImageCli.ps1` | VM images (`vm_images`): `marketplace` (publisher/offer/sku) and `gallery-version` (Azure Compute Gallery version → temporary TrustedLaunch managed disk in the gallery's resource group → read SAS → `image create --image-path`, via `avd/images/azure-local/scripts/Import-AzureLocalImage.ps1`) | every image on `sp-nic26-m2-images-01`; tags merged with `az tag update` after create (`image update` fails on this build); `-Wait` polls to Succeeded; `-RecreateFailed` replaces a Failed image |
| `../sdn-network/scripts/Invoke-SdnNetworkCli.ps1` | logical networks, NSGs | DNS never re-sent |

```powershell
.\New-VmImageCli.ps1 -WhatIf
.\New-VmImageCli.ps1 -Wait -LogFile .\image.log      # marketplace download ~10 min on this cluster; gallery import longer
```

Learn: [Marketplace images](https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-image-azure-marketplace?view=azloc-2609), [Azure Compute Gallery images](https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-image-azure-compute-gallery?view=azloc-2609).

## Run

```powershell
cd .\automation\azure-local\cluster-configure\platform\scripts
.\New-ClusterWorkloadVolume.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -Execute   # jump server, once
.\Invoke-PlatformConfigure.ps1 -Action Apply            # what-if
.\Invoke-PlatformConfigure.ps1 -Action Apply -Execute
.\Invoke-PlatformConfigure.ps1 -Action Remove -Execute  # live replay (D-014): then Apply again on stage
# parity: -Tool Terraform -BackendConfig <environment\azure-local\backend.cluster-configure-platform.hcl>
```

State for the demo script: `..\..\scripts\Get-Day2ControlState.ps1` → control `platform` (Applied when every logical network, image and storage path exists and the images report `Available`; Partial while an image is still downloading).

Inputs added beyond the schema: `vm_switch_name` (**(verify)** with `Get-VMSwitch` on the cluster — Network ATC names the compute switch `ConvergedSwitch(compute)` for a dedicated Compute intent), `marketplace_images` (safe catalogue default), `enable_network_security_group`. Parity gap: Bicep uses the AVM image module, Terraform azapi (same resource shape). The `ipPools` item shape (`name`, `ipPoolType: vm`, `start`, `end`) follows the AVM module type `poolType`.

Design note: the deployment creates its own infrastructure logical network, so no management logical network is created here. Logical network names carry the VLAN (`lnet-<org>-<token>-<purpose>-vlan<id>-<region>`, naming standard).
