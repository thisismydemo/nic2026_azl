# Azure Local: Azure Site Recovery Failover Procedures

Replicating Azure Local virtual machines to Azure with Azure Site Recovery, and running the planned failover, test failover, commit, re-protect and failback procedures.

**Status:** prepared 2026-10-06 against Microsoft Learn (2609 release family). **Important:** the Azure Site Recovery extension for Azure Local that automates deployment is documented as a **preview** and applicable to test environments. For production, configure Site Recovery manually with the **Hyper-V to Azure disaster recovery** option on the cluster. Confirm the current status when you design, and state it in your design record.

## When to use it

| Need | Use |
|---|---|
| Recovery of data or a VM within hours, point in time | Backup |
| Continuity within minutes for business-critical VMs | Azure Site Recovery to Azure |
| Continuity to a second Azure Local cluster | Hyper-V Replica |

Site Recovery can reach a recovery point objective as low as 30 seconds for Hyper-V sources. Backup and replication do different jobs and neither replaces the other. Failover is never automatic: you start it from the portal or with PowerShell.

## The supported chain

Name the chain in your design record: **source platform** (Azure Local VM, Hyper-V site on the cluster) **to replication path** (the Azure Site Recovery provider and Recovery Services agent on each node, over the internet) **to Azure target** (a storage account, a post-failover resource group and an Azure virtual network).

| VM type | Failover | Failback |
|---|---|---|
| Windows generation 1 and 2 | To Azure | To the same or an alternate host |
| Linux generation 1 and 2 | To Azure | To the same or an alternate host |

Limits to check against the Hyper-V to Azure support matrix: BitLocker must be disabled before replication; shared cluster disks, encrypted disks and SMB 3.0 guest storage are not supported; Trusted Launch and confidential VM security types are not supported as targets.

## Prerequisites

- The cluster has internet access for replication and is registered with Azure Arc.
- Owner permission on the Recovery Services vault (to assign permissions to the managed identity) and read and write permission on the Azure Local resource and its children.
- Connectivity: Site Recovery private endpoints are not routed through the Arc gateway; either disable TLS inspection on the enterprise proxy for them or add them to the proxy bypass list.
- An Azure target network and subnet for failed-over VMs, and a test network for test failover.
- Capacity planned with the Site Recovery capacity planner.

## Procedure 1: Prepare infrastructure

1. In the Azure portal, open the Azure Local resource and start disaster recovery.
2. Create or select the Recovery Services vault, a Hyper-V site on the Azure Local resource and a replication policy.
3. Select **Prepare infrastructure**. The portal creates a resource group with a storage account, the vault and the policy; downloads the Site Recovery agent to each node; registers the nodes with the service; and associates the policy with the Hyper-V site. This can take several minutes per node.

Evidence: the Hyper-V site shows the nodes registered and connected in the vault.

## Procedure 2: Enable replication

1. From the vault, select **Replicate**, then **Hyper-V machines to Azure**.
2. Choose the Hyper-V site on the Azure Local resource as the source.
3. Choose the subscription, the post-failover resource group, the Resource Manager deployment model, and managed disks for storage. Choose the Azure network now or later.
4. Select the VMs, the operating system disk and data disks, and the replication policy.
5. Review and enable replication.

Evidence: the replicated item shows initial replication complete, replication health healthy and a recent recovery point. Set the target network and size under Compute and Network.

## Procedure 3: Test failover (quarterly)

A test failover creates a VM in Azure on an isolated network without affecting production or replication.

1. Open the replicated item and select **Test failover**; pick the latest recovery point and the test network.
2. Validate the application in Azure, not just that the VM booted.
3. Clean up the test failover.

Evidence: application checks passed, test VM cleaned up, the result recorded.

## Procedure 4: Planned failover to Azure

Use it for maintenance, hardware replacement or a controlled move. It gracefully shuts down the source VM so that pending writes are committed to disk and the final changes replicate, which prevents data loss. The no-loss result depends on that final synchronization completing.

1. Verify replication health, the target network and the recovery plan; confirm there are no snapshots on the VM.
2. Select **Failover**; choose the latest recovery point; choose to shut down the machine first.
3. Follow the job. After the first stage, the replica VM appears in Azure. Do not cancel a failover in progress: cancelling stops it and the VM does not replicate again.
4. Validate the application, the target network and the source state.
5. **Commit** the failover. Committing deletes the available recovery points.

**State plainly what a running job proves.** A VM appearing in Azure is not the proof. Application-level validation, the target network, the source state and the path to commit, re-protect and fail back are.

Failover duration varies with VM size and the hydration process; allow for it in the change window, and do not promise completion inside a fixed short window.

## Procedure 5: Re-protect and fail back

1. When the on-premises cluster is healthy, **re-protect** the Azure VM so it replicates back to the cluster. Make sure the on-premises VM is turned off and has no snapshots; do not turn it on during failback.
2. Start a **planned failover from Azure to on-premises**. Choose Minimize downtime (synchronize before failover) or Full download (faster, more downtime, use after a long time in Azure or if the on-premises VM was deleted).
3. After synchronization, complete the failover, check the VM, then **commit**.
4. **Reverse replicate** so the VM again replicates to Azure.

If the original cluster is unavailable, register another Azure Local cluster to the Site Recovery Hyper-V site and fail back there. The VM returns as an **unmanaged VM**: its services run, but it cannot be managed from Azure until it is registered on the new cluster and reconnected to its Azure resource (with the new resource group, custom location, storage path and logical network). Failing back to the same cluster restores the Azure connection within the Arc agent's 45-day reconnection window.

## Caveats to put in the design record

- Arc extensions are not visible or manageable on the Azure VM while it runs in Azure.
- Guest Configuration policies do not run while the machine is in Azure.
- Log data is associated with the Azure VM while it runs there; search by computer name to see all of it.
- Do not install the Azure VM Guest Agent on a machine that may return on-premises. If you must, disable extension management on it.
- If you delete an Azure Local VM after a failover, you must intervene manually to manage it again.

## Recovery plans

Group the VMs of an application into a recovery plan with boot order. Test the plan, not just single VMs, and rehearse it on the schedule your continuity requirements set.

## Checklist before you rely on it

- [ ] Replication health is healthy and the recovery point is recent
- [ ] A test failover completed in the last quarter, with application validation
- [ ] The Azure target network, DNS and access are ready
- [ ] The failback path is documented, including the unmanaged-VM case
- [ ] The preview or production status of the integration is recorded
