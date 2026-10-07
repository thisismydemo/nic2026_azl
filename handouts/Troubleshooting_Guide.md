# Azure Local: Troubleshooting Guide

Common deployment, Day-2 and fault symptoms with a likely cause and the action to take. Start with the cheapest read-only check, and change one thing at a time.

**Status:** prepared 2026-10-06 against Microsoft Learn (2609 release family). Where a cause depends on your release or hardware, the text says so. This guide does not replace support: collect diagnostics and escalate when the action column does not resolve the symptom.

## First checks

```powershell
Get-ClusterNode
Get-PhysicalDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus, Usage
Get-StorageJob
Get-VirtualDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus
Get-NetIntentStatus | Format-List Host, IntentName, ConfigurationStatus, ProvisioningStatus
Get-SolutionUpdateEnvironment
```

## Deployment validation failures

| Symptom | Likely cause | Action |
|---|---|---|
| Validation fails at the diagnostic account or Key Vault audit logging | `Microsoft.Insights` resource provider not registered | Register it on the subscription and run Validate again |
| Environment Checker fails outbound connectivity | Firewall allow-list incomplete, or rules applied after Arc registration | Open the endpoints for your chosen topology; rerun the checker |
| Environment Checker fails ICMP to the gateway | Gateway blocks ICMP from the management pool | Allow ICMP from the management subnet to the default gateway |
| Deployment or Arc Resource Bridge behaves oddly with addresses | Node, cluster, DNS, proxy or pool addresses fall in `10.96.0.0/12` or `10.244.0.0/16` | Re-plan addresses outside the reserved Kubernetes ranges; these ranges cannot be changed |
| Registration or deployment rejects the local administrator | The built-in Administrator account was used | Create a separate local administrator, identical on every node |
| Deployment fails on node addressing | Nodes use DHCP under Local Identity | Set static addresses, gateway and DNS on every node |
| Name resolution fails | DNS zone missing, no host records for nodes and the system, or DNS cannot reach the Arc endpoints | Create the zone and A records; check forwarding; note that DNS servers cannot be changed after deployment |
| Cannot select a witness storage account | The account is already used by another system | Use a separate storage account for each system |
| Arc gateway option missing or cannot be added | The gateway must be chosen at deployment of a new instance on 2506 or later | Plan it before registration; it cannot be enabled afterwards |
| Management VLAN wrong after registration | VLAN not set on the physical adapters before registration | Management VLAN cannot be changed after deployment; set it before registering; redeploy if necessary |
| Machines show Not validated or not ready | OS versions or adapter configurations differ between nodes | Make all nodes identical; reregister |
| Portal access to nodes fails | SSH not enabled on the nodes | Enable SSH for Arc-enabled servers on each node |

## Day-2 platform

| Symptom | Likely cause | Action |
|---|---|---|
| Insights shows a blank workbook | Configured under an hour ago, or the data collection rule lacks the required event channels or counters | Wait up to an hour, check the rule has the required channels and counters, then update Insights |
| Insights shows Needs update | The rule was changed, or a required counter or event was removed | Select Update in Insights to restore the required data sources |
| Update readiness reports Critical or Warning | A health check failed | Open the readiness details, follow the remediation link, then check again |
| Update stays Ready but never installs | Vendor validation of the new release is pending, or a readiness check fails | Confirm the release is available for your hardware; run `Start-SolutionUpdate -PrepareOnly` to see the checks |
| New feature release not offered | The hardware vendor has not yet validated it | Wait for the vendor sign-off; it can take a week or more |
| Policy shows non-compliant straight after assignment | Compliance evaluation is not instant | Start a compliance scan and wait for it to complete |
| Backup job fails | Source cannot reach the vault, or the protection route does not support the VM state | Check connectivity, then the support matrix of the backup solution you use: confirm that it protects Azure Local VMs at the host or guest level and which restore targets it offers (restoring to a different cluster brings the VM back unmanaged until it is re-registered) |
| Logical network VM has no IP | IP pool exhausted, or no static pool defined | Add an address range to the logical network |
| VM creation fails on a storage path | Not enough space at the storage path | Expand the volume or choose another path; never use the infrastructure volume |

## Faults

| Symptom | Likely cause | Action |
|---|---|---|
| A drive shows Retired or Lost Communication | Failed media, or the drive was taken offline | Replace the drive if failed; wait for the repair job; confirm volumes `Healthy` |
| Replacement drive is not added to the pool | AutoPool disabled | Enable AutoPool, or add the disk to the pool manually |
| Volumes stay Degraded | A repair job is still running or cannot run | Check `Get-StorageJob`; ensure enough reserve capacity; do not stack other changes |
| An intent shows a configuration status other than Success | A setting Network ATC owns was changed, or an adapter failed | Review `Get-NetIntentStatus` and the Network ATC admin event log; fix the intent, not the adapter; restart Network ATC on each node in turn if a procedure requires it |
| A node is down | Power, hardware or network | Restore through the management path; when it returns allow storage to resync |
| Cluster is offline on a two-node system | A node and the witness are both lost | Restore one of them; verify the witness storage account and its connectivity |
| An Azure Local VM shows disconnected from Azure | Arc connectivity lost | Restore outbound connectivity; the VM reconnects inside the Arc agent's 45-day window |

## Replication and migration

| Symptom | Likely cause | Action |
|---|---|---|
| Site Recovery replication unhealthy | Node cannot reach the service, or proxy TLS inspection blocks private endpoints | Check connectivity; bypass the proxy for the endpoint or disable inspection for it |
| Failed-back VM cannot be managed from Azure | It returned to a different cluster as an unmanaged VM | Register it on the new cluster and reconnect it to its Azure resource |
| Failover job cancelled and VM no longer replicates | A failover was cancelled in progress | Re-enable replication |
| Migrated VM has offline disks | SAN policy not set on the source | Bring disks online in the guest |
| Replication cannot start from VMware | BitLocker, shared disk, encrypted volume, or a missing VDDK package | Remove the blocker on the source; use a partner option if no VDDK is available |

## When to escalate

Collect and attach: the exact error text and time, the output of the first checks above, the readiness or health check details, the deployment correlation identifier, and the Azure Local version. Escalate when a repair job does not progress, when a node does not rejoin, when an update stops, or when a symptom needs a change you cannot reverse.
