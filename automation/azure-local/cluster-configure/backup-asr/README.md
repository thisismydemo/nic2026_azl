# cluster-configure/backup-asr

Day-2 Ready 3.3: adds a Hyper-V-to-Azure **ASR replication policy** and an **Azure VM backup policy** to the existing Recovery Services vault (`rsv_azl`, created by `lz-azure-local`), plus scripts to enable replication, run a test failover and check readiness. It never creates or deletes the vault. Authored by gpt-6-sol via the HCS Foundry gateway; review is recorded in `design/shared/verification-log.md`.

Every operational script previews by default; pass `-Execute` to change anything.

## Order

1. `lz-azure-local` creates the vault, the ASR cache storage account, the post-failover group and the recovery and test networks.
2. `Invoke-BackupAsrConfigure.ps1 -Action Apply` (plan first, then `-Execute`; Bicep or Terraform) creates the two policies.
3. **Once**, on the Azure Local resource in the portal, run **Prepare infrastructure** (Capabilities, Disaster recovery). It installs the ASR agent on every node and creates the Hyper-V site; check that the protection-container mapping uses the replication policy from step 2.
4. `Enable-AsrReplication.ps1` (preview, then `-Execute`) enables replication for the tier-1 VMs.
5. `Invoke-AsrTestFailover.ps1 -Action Start`, validate the isolated VM, then `-Action Cleanup` (test failover is due by Oct 9).
6. `Enable-AzureVmBackup.ps1` for the Azure jump VM (and failed-over Azure VMs); `Test-BackupAsrReadiness.ps1` checks vault, policies, site, replication health and a jump-VM recovery point.

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
