# Azure Local: Day-2 Readiness Checklist

The line between a deployed cluster and an operable platform. Use this checklist as the acceptance gate before handing the cluster to operations. Each control implements a requirement from the planning phase and reports an evidence state, not just a colour.

**Status:** prepared 2026-10-06. **Verify** items depend on your release and tenant. The matching read-only readiness script in the session repo (`src/scripts/`) runs these checks in one pass.

## Two gates, not one

| Gate | Question | Passed when |
|---|---|---|
| **Platform validation** (end of deployment) | Is the cluster healthy? | Nodes up, witness online, storage healthy, intents successful, Arc Resource Bridge running, custom location present |
| **Operational acceptance** (this checklist) | Can operations own it? | Every control below is Verified, or Not applicable with a recorded reason |

A cluster can pass the first and fail the second. That is expected, and it is the reason this gate exists.

## Evidence states

Every control reports exactly one state:

| State | Meaning |
|---|---|
| Configured | The setting exists; nothing proves it works yet |
| Pending evidence | Waiting for something that cannot be instant (policy evaluation, first telemetry, a completed backup job) |
| Verified | The evidence exists and is timestamped |
| Failed | The control is broken |
| Not applicable | With the reason written down |

The gate never forces a control green. Pending evidence is a legitimate state at handover, with an owner and a date.

## Controls

| # | Control | Requirement it implements | Evidence that makes it Verified |
|---|---|---|---|
| 1 | Insights enabled with the cluster data collection rule | Monitoring scope and cost ceiling | Insights shows Configured; the Azure Monitor Agent is on every node; data is flowing (allow up to an hour for first data) |
| 2 | Alert rules and action group | Faults are observable | Rules exist for node down, storage health, network intent drift, capacity; a test alert reached the action group |
| 3 | VM monitoring data collection rule | Workload visibility | VM Insights data from at least one workload VM |
| 4 | Update management for guests | Maintenance windows | A maintenance configuration exists with a dynamic scope by tag; machines appear in the Update Manager machines view |
| 5 | Cluster update readiness | Cluster lifecycle | The update environment reports a healthy state and update history is readable |
| 6 | Backup | Recovery within hours | A policy is assigned, a backup job completed, recovery points exist, and a restore was tested |
| 7 | Site Recovery | Continuity within minutes (tier 1) | Replication healthy, a test failover completed, a recovery plan exists |
| 8 | Privileged access | Eligible, not standing | Roles are assigned as eligible in PIM; an activation produced an audit entry; effective scope checked |
| 9 | Defender for Cloud | Security baseline | The plan is enabled on the landing zone; secure score visible |
| 10 | Azure Policy baseline | Governance | The initiative is assigned at the landing-zone scope; a compliance scan completed (evaluation is not instant) |
| 11 | Node security baseline | Platform security | Security level and drift control as set at deployment; verified by the post-deployment test |
| 12 | Workload platform | Targets for VMs and migration | Images are Available; logical networks and IP pools exist; storage paths exist on workload volumes, not on the infrastructure volume |
| 13 | Tags and naming | Operability | Required tags present; names follow the standard |
| 14 | Documentation | Handover | Runbooks, contact paths and decision log delivered |

## Acceptance criteria before handover

- [ ] No health faults on the cluster
- [ ] RDMA and data center bridging operational where required
- [ ] Live migration and node failover meet the agreed targets
- [ ] Monitoring, update management, backup, access and governance in place
- [ ] Secure score at the agreed target
- [ ] Backup restore validated
- [ ] DR test failover completed
- [ ] Every Pending evidence item has an owner and a date

## Running the checks by hand

```powershell
# Cluster, storage and network health
Get-ClusterNode
Get-StoragePool -IsPrimordial $false | Format-Table FriendlyName, HealthStatus, OperationalStatus
Get-PhysicalDisk | Where-Object HealthStatus -ne 'Healthy'
Get-StorageJob
Get-NetIntentStatus | Format-List Host, IntentName, ConfigurationStatus, ProvisioningStatus

# Cluster update environment
Get-SolutionUpdateEnvironment
Get-SolutionUpdate | Format-Table DisplayName, State, Version
```

## Reversible by design

Build each control so it can be removed and re-applied from code. That is how a team proves the platform is reproducible, and how a rehearsal restores a known state. Keep backup data, replication, privileged-access eligibility and the workload platform out of any reset, because other work depends on them.
