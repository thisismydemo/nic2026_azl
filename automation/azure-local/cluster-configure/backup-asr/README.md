# cluster-configure/backup-asr

Day-2 Ready 3.3: adds a Hyper-V-to-Azure **ASR replication policy** and an **Azure VM backup policy** to the existing Recovery Services vault (`rsv_azl`, created by `lz-azure-local`), plus scripts to enable replication, run a test failover and check readiness. It never creates or deletes the vault. Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`.

Every operational script previews by default; pass `-Execute` to change anything.

## Order

1. `lz-azure-local` creates the vault, the ASR cache storage account, the post-failover group and the recovery and test networks.
2. `Invoke-BackupAsrConfigure.ps1 -Action Apply` (plan first, then `-Execute`; Bicep or Terraform) creates the two policies.
3. **Once**, prepare the infrastructure: `Invoke-AsrFromEnvironment.ps1 -Action Prepare` (preview, then `-Execute`) runs `Install-AsrInfrastructure.ps1`, the scripted equivalent of the portal's **Prepare infrastructure** (Capabilities, Disaster recovery): vault extended information, the Hyper-V site `asr.hyperv_site_name`, `Site Recovery Contributor` on the vault for the Azure Local cluster resource's system-assigned identity (the extension's `RegisterAsr.ps1` fetches the vault credentials with the cluster identity, not the node identities), the `ASRExtension` cluster extension (publisher `Microsoft.SiteRecovery.Dra`, type `Windows`, Learn: *Azure Arc extension management on Azure Local*) on every node, and the policy mapped to the site. Run `-Action NodeState` before (no pending reboot) and after (LastBootUpTime unchanged): Learn documents no node restart for this install.
4. `Invoke-AsrFromEnvironment.ps1 -Action Enable` (preview, then `-Execute`) runs `Enable-AsrReplication.ps1` for `asr.protected_vms`: managed disks with the cache account, failover size, project tags on the Azure VM, NICs and disks, and the test network = the recovery VNet with the NSG-isolated test subnet on the primary NIC (without it Site Recovery would pick the subnet named like the recovery subnet). `-Action WaitProtected` waits for initial replication; `-Action RecoveryPlan` creates `asr.recovery_plan_name`.
5. `-Action TestFailover -Execute`, `-Action Verify` (power state, subnet, tags; `-BootScreenshotPath` for the boot screen), then `-Action Cleanup -Execute`. `-Action Status` is read-only at any time.
6. `Enable-AzureVmBackup.ps1` for the Azure jump VM (and failed-over Azure VMs); `Test-BackupAsrReadiness.ps1` checks vault, policies, site, replication health and a jump-VM recovery point.

## As built 12 Oct 2026

- Policies applied (`Invoke-BackupAsrConfigure.ps1 -Action Apply -Execute`): `bkp-iic-nic26-tier1-eus-01` (Enhanced, daily, 30 days) and `asrpol-iic-nic26-tier1-eus-01` in `rsv-iic-nic26-azl-eus-01`. The solution's name catalog now lists the landing-zone names it works in (`rg_bcdr`, `rsv_azl`, `asrpol_tier1`, `bkp_tier1`); without them the converter emitted only `deployment_name` and every script failed.
- Azure VMs to protect come from `backup_azure_vms` in environment/azure-local: the Entra Connect sync server is protected (initial backup started 12 Oct). Run: `$i = Get-Content ..	erraform	erraform.generated.tfvars.json | ConvertFrom-Json; .\Enable-AzureVmBackup.ps1 -SubscriptionId $i.subscription_id -VaultResourceGroup $i.names.rg_bcdr -VaultName $i.names.rsv_azl -PolicyName $i.names.bkp_tier1 -VmResourceGroup $i.backup_azure_vms[0].resource_group -VmName $i.backup_azure_vms.name -RunInitialBackup -Execute`.
- ASR replication was **blocked** on 12 Oct (T-5.5.3): Prepare infrastructure installs the ASR agent on every node (owner go needed), and the Azure Local VMs are Trusted launch, which ASR does not support. Owner decision 13 Oct: build it live (next section).

## As built 13 Oct 2026 (owner decision "Build it live", T-5.5.3)

- Source VM `vm-iic-nic26-app-azl-03` (`nic26-app-03`) built by `automation/demo/azure-local/scripts/New-IicWorkloadVm.ps1 -Stage Vm` with the new `security_type: Standard` (no Trusted launch, secure boot and vTPM off): Windows Server 2025 Datacenter: Azure Edition, 2 vCPU, 8 GB, `lnet-iic-nic26-app-vlan2217-eus` (static IP from the pool), `sp-nic26-m2-vmstore-01`, tags `project=nic26`, `workload=iic`, `tier=app`, `purpose=asr-demo`. Created 12:37-12:43 UTC (5 min 41 s). Arc guest management *AwaitingConnection* (F-1, no DHCP gateway): replication is host-side and does not need the guest network; in Azure the failed-over NIC takes its gateway from the VNet.
- Nodes checked read-only (`Get-AsrNodeState.ps1`, 12:4x UTC): no pending reboot on either node, Hyper-V management service running, no ASR services yet.
- `Install-AsrInfrastructure.ps1 -Execute` was **stopped by the session's permission classifier** before any change (no site, role or extension created): it needs the owner's explicit go for installing the Site Recovery agent on both nodes and granting the node identities a role on the vault.
- `Set-AzRecoveryServicesAsrVaultContext` fails with a null reference while the vault has no extended information (`ResourceExtendedInfoNotFound`): Prepare now creates it first, as the portal does.

## Constraints

- **Trusted launch Azure Local VMs are not supported by Azure Site Recovery**; the replicated VM must be a standard VM.
- While a VM runs in Azure after a failover, Arc extensions, Guest Configuration and monitoring attach to the Azure VM, not the Arc resource. Do not install the Azure VM agent on a VM that will fail back.
- The OS disk is taken from the protectable item's disk list (the first disk marked OS, else the first disk): verify at the first run.

## Decision taken

The examples use Azure Backup. The documented route for Azure Local VMs needs an agent-based, guest-level component; it is covered in the session discussion, not automated here. This solution automates the vault policy and Azure VM backup only, and it does not claim to back up Azure Local guests.

## Not scripted

Planned and unplanned failover are the live closing demo and stay owner-driven (`demo/azure-local`). The recovery plan (`rp_tier1`) is created in the portal until its steps are agreed.

## Notes from review

- In the portal's **Prepare infrastructure** step choose the **existing** replication policy created here (the policy is attached to the Hyper-V site there; creating a policy does not create the container mapping). `Enable-AsrReplication.ps1` stops with a clear message when no mapping uses the policy.
- The protectable item reports its own OS and OS-disk name; the script uses those and refuses to guess. A VM that is already replicating is reconciled: the test network is set when it differs.
- `Enable-AzureVmBackup.ps1` skips a VM already on the requested policy; a VM on another policy is only moved with `-ReassignPolicy` (retention can change).
- `-Action Remove` deletes the two policies and the service refuses to delete a policy that still protects items: disable the protection first (an explicit, owner-approved step; backup data is never deleted by this solution).
