# Azure Local: Day-2 Operations Runbook

The recurring operations for a running Azure Local instance: cluster updates, fault diagnosis, capacity management and the virtual machine lifecycle. Each procedure states its inputs, the steps, the evidence that proves it worked, and when to stop and escalate.

**Status:** prepared 2026-10-06 against Microsoft Learn (2609 release family). Commands are shown for orientation; run them with the account and context your environment requires, and test them on a non-production instance first. **Verify** items depend on your release and hardware.

## Principles

- **Read before you change.** Every procedure starts with a health check and ends with evidence.
- **One fault at a time.** Never stack a second change on a cluster that has an unresolved fault.
- **Recovery is proven, not assumed.** A cleared alert is not recovery. Recovery is the repair finished and redundancy restored.
- **Two update planes, two owners.** The cluster platform and the guest operating systems are updated by different tools.

## 1. Cluster updates

**What is updated:** the solution as one update train: the operating system, agents and services, and the OEM solution extension (drivers and firmware), orchestrated by Lifecycle Manager. **Cadence:** monthly quality updates, quarterly baseline updates, hotfixes as needed, and vendor extension updates. Stay within six months of the most recent release to remain supported. Feature releases can arrive about a week after Microsoft's release because the hardware vendor validates them.

**Inputs:** a maintenance window; a healthy cluster; a plan for what you do if the update fails (stop, collect the diagnostics and escalate; **verify** which recovery options exist for your release before the window).

| Step | Portal | PowerShell on a node, as the deployment user |
|---|---|---|
| 1. Confirm version and health | Update Manager, Azure Local | `Get-SolutionUpdateEnvironment` and check `CurrentVersion` and `HealthState` |
| 2. Discover | Update Manager shows Updates available | `Get-SolutionUpdate \| Where-Object State -like 'Ready*'` |
| 3. Prepare (recommended) | Select Prepare to download and run readiness checks | `Get-SolutionUpdate -Id <id> \| Start-SolutionUpdate -PrepareOnly` |
| 4. Fix readiness failures | Check readiness, follow the remediation links | Read `HealthCheckResult`, follow `Remediation` |
| 5. Install | Install now | `Get-SolutionUpdate -Id <id> \| Start-SolutionUpdate` |
| 6. Verify | History shows success | `Get-SolutionUpdateEnvironment` shows the new version |
| 7. Hardware | Included when the solution extension is part of the train | Apply any separate vendor update through the vendor's supported route |

Expected duration: about 17 minutes of health checks and about 4 hours to install on one node, about 22 minutes and about 6 hours on four nodes. Content, load and hardware change this. Third-party tools for installing updates are not supported.

**Stop and escalate when:** health checks report Critical findings you cannot remediate from the links; an update stays in progress with no change for a long period; any node does not rejoin.

## 2. Fault diagnosis

Every fault uses the same five steps: **symptom, signal, differential diagnosis, action, recovery evidence.**

### 2.1 Drive failure

| | |
|---|---|
| **Symptom** | A drive alert, a pool or volume in a Warning or Degraded state |
| **Signal** | Azure Monitor alert; physical disk `HealthStatus` or `OperationalStatus` |
| **Diagnosis** | Is the drive failed media, lost communication, or an administrative action? Is a repair job already running? Is another fault present? |
| **Action** | Storage Spaces Direct retires and evacuates a failed drive automatically; replace the drive physically; if the new drive is not added, check whether AutoPool is enabled |
| **Recovery evidence** | The storage repair job finished, all volumes are `Healthy`, redundancy is restored |

```powershell
Get-PhysicalDisk | Format-Table FriendlyName, SerialNumber, HealthStatus, OperationalStatus, Usage
Get-StorageJob
Get-VirtualDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus
# AutoPool setting (when a replacement drive is not pooled)
Get-StorageSubsystem Cluster* | Get-StorageHealthSetting | Select-Object "System.Storage.PhysicalDisk.AutoPool.Enabled"
```

On a two-node, two-way-mirror cluster one fault leaves no redundancy until the repair completes. Reserve capacity (section 3) allows an immediate in-place repair before the drive is replaced.

### 2.2 Network intent drift

| | |
|---|---|
| **Symptom** | An intent shows `ConfigurationStatus` other than `Success`, or a drift alert |
| **Signal** | `Get-NetIntentStatus`; Network ATC admin event log; Monitor alert |
| **Diagnosis** | Which setting differs from the intent, and who changed it? Network ATC owns the adapter properties it manages |
| **Action** | Let Network ATC remediate; if it does not converge, review the event log and follow the documented procedure for the change you need |
| **Recovery evidence** | Every intent reports `Success` on every node |

```powershell
Get-NetIntentStatus | Format-List Host, IntentName, ConfigurationStatus, ProvisioningStatus
```

Configuration drift is a fault. The fix is to change the intent, not the adapter.

### 2.3 Node failure

| | |
|---|---|
| **Symptom** | A node is down; VMs restart on the surviving node; an alert fires |
| **Signal** | Cluster node state; Monitor alert; VM state |
| **Diagnosis** | Is it the node, its network, or its power? Is the witness reachable? On two nodes, one node plus the witness keeps quorum; losing both a node and the witness takes the cluster offline |
| **Action** | Restore the node through the hardware management path; do not stack another change; when the node returns, let storage resync |
| **Recovery evidence** | The node is `Up`, storage repair finished, volumes healthy, VMs on their intended owners |

## 3. Capacity management

**What "full" means:** on a two-way mirror, usable capacity is about half of raw, and a node loss must still leave room for the VMs and the repair.

1. Compute the healthy-state usage and the usage with one node unavailable. The second number is the one that limits you.
2. Keep reserve capacity: leave unallocated pool capacity equal to one capacity drive per server, up to four (this is free space, not spare drives), so a failed drive can repair in place.
3. Decide with numbers. If an additional workload breaks the node-loss reserve, reject it or expand first; record the trigger for expansion.
4. Expansion: adding a node changes resiliency options and the network intents; plan it as a change, not an event. Rack Aware clusters expand in pairs.

```powershell
Get-StoragePool -IsPrimordial $false | Format-List FriendlyName, Size, AllocatedSize
Get-VirtualDisk | Format-Table FriendlyName, Size, FootprintOnPool
```

## 4. Virtual machine lifecycle through Azure Arc

Day 2 for workloads is Azure, not a console session. Create, govern and delete virtual machines from Azure, so that RBAC, policy, monitoring and update management apply.

**Prerequisites:** an image (from the marketplace, a storage account, or a local share), a logical network, a custom location, and a storage path on a workload volume (never the infrastructure volume).

```azurecli
az stack-hci-vm create --name <vm> --resource-group <rg> --custom-location <custom location id> \
  --image <image name> --admin-username <admin> --admin-password <from a secure prompt> \
  --nics <nic name> --storage-path-id <storage path id>
```

| Step | Check |
|---|---|
| Create | The VM lists as Succeeded under Azure Local virtual machines |
| Govern | Tags set; policy compliance evaluated; the VM appears in Update Manager and monitoring scopes |
| Protect | A backup policy is assigned; replication enabled if the tier requires it |
| Delete | Remove associated resources, then the VM; deleting an Azure Local VM after a failover to Azure needs manual clean-up |

A VM disconnected from Azure Arc can be reconnected within the Arc agent's 45-day window.

## 5. Routine schedule

| Cadence | Task |
|---|---|
| Daily | Review Monitor alerts and the Insights health view |
| Weekly | Check backup jobs and replication health; review policy compliance |
| Monthly | Review and apply the quality update in the maintenance window |
| Quarterly | Apply the baseline update; run a DR test failover; review capacity and expansion triggers; check certificate and secret expiry (the local administrator account and secrets are yours to rotate) |
| After any change | Re-run the readiness checks |
