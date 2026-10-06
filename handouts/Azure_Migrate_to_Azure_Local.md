# Migrating VMware Workloads to Azure Local with Azure Migrate

Discovery, replication, test migration and cutover for moving VMware virtual machines to an Azure Local instance with Azure Migrate. The assessment that feeds it (inventory, sizing, waves) is covered in the sizing guide.

**Status:** prepared 2026-10-06 against Microsoft Learn (2609 release family). Migration of **VMware** VMs is documented without a preview label; migration of **Hyper-V** VMs to Azure Local is a **preview**. **Verify** both on the day you plan, because status and limits change.

## What you need in place

| Component | Requirement |
|---|---|
| Target | An Azure Local instance (2311.2 or later; the migration articles apply to 2503 and later), deployed, registered and validated; its custom location noted; a storage path and a logical network for the migrated VMs |
| Source | vCenter Server and ESXi 8.0, 7, 6.7 or 6.5 |
| Source appliance | A Windows Server 2022 VM on the VMware side with at least 16 GB memory, 80 GB disk and 8 vCPUs |
| Target appliance | A Windows Server 2022 VM on Azure Local |
| Network | The source environment must be able to open a network connection to the target Azure Local instance, on the same network or over a VPN |
| Appliances and registration | Each appliance registers to the Azure Migrate project; use a separate Microsoft Entra application per appliance if you use preconfigured applications |

Firewall ports (Microsoft Learn): on the source side 443 (Azure Migrate services and vCenter), 902 (replication from ESXi snapshots), 445 (SMB between source and target appliance), 3389 and 44368 (appliance access); on the target side 445, 5985 and 5986 (WinRM from the appliance to the host), 3389 and 44368. Allow the Azure Migrate URLs and `*.siterecovery.azure.com`.

**VDDK:** Azure Migrate does not provide the VMware VDDK packages and access to them can be restricted. If a supported VDDK package is not available to your organization, use a partner migration option instead.

## Prepare the source VMs

- Bring all disks online and persist drive letters (configure the SAN policy), or the disks come up offline after migration.
- Disable BitLocker on Windows VMs; encrypted disks and volumes are not supported.
- Remove shared disks; they are not supported.
- Linux VMs: make sure the Hyper-V Linux Integration Services are in the init image so the VM boots on Azure Local.
- Check Secure Boot on UEFI VMs; the setting is preserved. If you change it, allow up to 30 minutes for discovery to see the change.
- If a VM already has the Azure Connected Machine agent, decide whether to reuse its Arc resource (keep the agent) or uninstall the agent before replication.
- Snapshot-based backup of the source VMs must not run during replication cycles.
- The boot type is preserved: BIOS VMs become Hyper-V generation 1 VMs and UEFI VMs become generation 2. Note the generation 1 limitations in the Azure Local VM management documentation.

## Plan the waves

1. Start from the assessment: complexity score, dependencies, recovery objectives and owners per workload.
2. Group VMs that depend on each other in one wave; one wave is one change window.
3. Select up to 10 machines at a time for replication; add further machines in batches of 10. One appliance replicates 52 disks in parallel, so large waves queue.
4. Record the missing evidence. Aggregate fit and an inventory export do not establish application dependencies; obtain them from dependency analysis or the application owner and record anything else as an assumption.

## Run a migration

| Step | Action | Evidence |
|---|---|---|
| 1 | Create the Azure Migrate project; deploy the source appliance; discover | VMs listed with sizes |
| 2 | Deploy the target appliance on the Azure Local instance | Appliance shows connected |
| 3 | Replicate: choose the target logical network and storage path for each VM | Replication status healthy |
| 4 | Test migration, then clean up the test | Test VM boots, network and application checks pass |
| 5 | Migrate: stop the source, final sync, start the target | VM shows as an Azure Local VM enabled by Azure Arc |
| 6 | Verify in the guest and the application | Application owner sign-off |
| 7 | Complete migration | Replication disabled; the migration resource is marked migrated |

To migrate the same source VM again later, complete the migration on the migrated resource first; that clears the state and allows replication to be enabled again.

**Rollback:** the source VM is the rollback. Keep it powered off, not deleted, until the verification window closes.

## After the cutover

A migrated VM is an Azure Local VM managed through Azure Arc. Bring it inside the Day-2 scope: monitoring, update management, backup, access control and the governance baseline. Tag it so dynamic scopes and policy pick it up. Confirm it is protected before the source VM is retired.

## Common problems

| Symptom | Cause | Action |
|---|---|---|
| Disks offline after migration | SAN policy not set on the source | Bring disks online in the guest; set the SAN policy on the remaining sources |
| Linux VM does not boot | Hyper-V drivers missing from the init image | Rebuild the init image with Hyper-V drivers on the source |
| Replication stalls | Source snapshot backup running, or port 902 blocked | Reschedule backup; check ports |
| Cannot select the VM for replication | BitLocker enabled, shared disk, or encrypted volume | Remove the blocker on the source |
| Migrated VM has no network | Logical network or IP pool not prepared | Create the logical network and pool before replication |

## Migrating from Hyper-V (preview)

The same pattern applies with a Hyper-V source: Windows Server 2012 R2 to 2022 hosts are discovered, and the Hyper-V generation is preserved. This route is a **preview**; do not plan production waves on it without confirming its status.
