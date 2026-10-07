# Azure Local: Network ATC Design Guide

This handout helps attendees plan, deploy, and operate intent-based host networking for Azure Local.

**Status:** prepared 2026-10-06 against Microsoft Learn for the 2609 release family; where a behaviour depends on release or hardware the text says so. Network ATC is the full product name; Microsoft states it is not an acronym.

## What Network ATC does

Network ATC provides intent-based host networking for Azure Local 2311.2 or later.

- Specify one or more intents for network adapters.
- Intent types are management, compute, and storage.
- Network ATC deploys the configuration for those intents.
- It helps reduce deployment time, complexity, and errors.
- It deploys Microsoft-validated best practices.
- It keeps configuration consistent across the cluster.
- It eliminates configuration drift by remediating manual changes.
- For example, a changed jumbo-packet value is remediated back to the intended value.

Network ATC features include:

- Network symmetry checks for adapter make, model, and speed across nodes.
- Storage adapter configuration: physical adapter properties, Data Center Bridging (DCB), virtual switches only if needed with the required virtual adapters, VLANs, and automatic storage IP addresses.
- Cluster network naming by usage, such as `storage_compute(Storage_VLAN711)`.
- Live Migration guidelines for maximum simultaneous migrations, network, transport, and maximum SMB Direct bandwidth.
- Proxy configuration for all nodes.
- Scope detection on a cluster node, so `-ClusterName` is not needed.
- Windows Admin Center deployment integration.

## Terms

**Intent**
A definition of how physical adapters are used. An intent has:

- A friendly name.
- One or more physical adapters.
- One or more intent types.

An adapter can belong to only one intent. The number of adapters limits the number of intents.

**Intent types**

- **Management:** Adapters for management access to nodes. At most one intent.
- **Compute:** VM traffic to the physical network. Unlimited intents.
- **Storage:** SMB traffic, including Storage Spaces Direct. At most one intent.
- **Stretch:** Set up like storage, except that RDMA cannot be used. At most one intent.

**Override**
A customization of a default.

## Prerequisites

- Azure Local 2311.2 or later.
- Physical hosts certified for Azure Local.
- Adapters in an intent must be symmetric: same make, model, speed, and configuration.
- Those adapters must be present on every node; asymmetric adapters fail the intent deployment.
- Each physical adapter in an intent must have the same name on all nodes.
- Every adapter must show `Up` in `Get-NetAdapter`.
- Install the required features: Network ATC, Hyper-V, Failover Clustering, Data Center Bridging, and Failover cluster SMB Bandwidth (FS-SMBBW).

```powershell
Install-WindowsFeature -Name NetworkATC, Hyper-V, 'Failover-Clustering', 'Data-Center-Bridging', FS-SMBBW -IncludeManagementTools
```

- Install adapters in the same PCI slots on each host to ease automated naming.
- Configure physical switches before deployment: VLANs, MTU, and DCB.
- Running in VMs is for test and validation only; it needs an adapter override that disables NetworkDirect.

## Example intents

Two adapters per team are shown; more are possible.

**Fully converged**

```powershell
Add-NetIntent -Name ConvergedIntent -Management -Compute -Storage -AdapterName pNIC01, pNIC02
```

**Converged compute and storage with a separate management intent**

```powershell
Add-NetIntent -Name Mgmt -Management -AdapterName pNIC01, pNIC02
Add-NetIntent -Name Compute_Storage -Compute -Storage -AdapterName pNIC03, pNIC04
```

**Fully disaggregated**

```powershell
Add-NetIntent -Name Mgmt -Management -AdapterName pNIC01, pNIC02
Add-NetIntent -Name Compute -Compute -AdapterName pNIC03, pNIC04
Add-NetIntent -Name Storage -Storage -AdapterName pNIC05, pNIC06
```

**Storage only**

```powershell
Add-NetIntent -Name Storage -Storage -AdapterName pNIC05, pNIC06
```

The management and compute adapters are not managed in this layout.

**Compute and management**

```powershell
Add-NetIntent -Name Management_Compute -Management -Compute -AdapterName pNIC01, pNIC02
```

**Multiple compute intents (multiple switches)**

```powershell
Add-NetIntent -Name Compute1 -Compute -AdapterName pNIC03, pNIC04
Add-NetIntent -Name Compute2 -Compute -AdapterName pNIC05, pNIC06
```

Network ATC changes how you deploy host networking, not what you deploy. Use only Microsoft-supported scenarios.

## Defaults you inherit

**Storage VLANs**

When adapters connect to a physical switch, default storage VLANs are:

| Storage adapter | VLAN |
|---|---:|
| 1 | 711 |
| 2 | 712 |
| 3 | 713 |
| 4 | 714 |
| 5 | 715 |
| 6 | 716 |
| 7 | 717 |
| 8 | 718 |

- VLAN 719 is reserved for future use.
- The VLANs must be allowed on the physical switch.
- Switchless configurations do not need these VLANs.
- The management VLAN configured on management adapters is not modified.

**Automatic storage IP addressing**

- Addresses are uniform on all nodes.
- Network ATC checks that an address is not in use.
- Example pattern: adapter 1 on VLAN 711 uses `10.71.1.X`; adapter 2 on VLAN 712 uses `10.71.2.X`.
- Disable automatic generation with a storage override:

```powershell
$StorageOverride = New-NetIntentStorageOverrides
$StorageOverride.EnableAutomaticIPGeneration = $false
```

Pass `-StorageOverrides $StorageOverride` to `Add-NetIntent`.

**Cluster network settings**

| Setting | Default |
|---|---|
| `EnableNetworkNaming` | `true` |
| `EnableLiveMigrationNetworkSelection` | `true` |
| `EnableVirtualMachineMigrationPerformance` | `true` |
| `VirtualMachineMigrationPerformanceOption` | Calculated: SMB, TCP, or compression |
| `MaximumVirtualMachineMigrations` | `1`; allowed range is 1 to 10 |
| `MaximumSMBMigrationBandwidthInGbps` | Calculated |

**Default DCB**

| Traffic | Priority | Bandwidth |
|---|---:|---|
| Cluster heartbeat | 7 | 2 percent if one or more adapters are 10 Gbps or less; 1 percent if more than 10 Gbps |
| SMB_Direct RDMA storage | 3 | 50 percent |
| All other traffic | 0 | Remainder |

The same DCB configuration must be on the physical network. Microsoft recommends using the defaults.

## Overrides

List the available override cmdlets:

```powershell
Get-Command -Noun NetIntent*Over* -Module NetworkATC
```

Change storage VLANs and the management VLAN:

```powershell
Add-NetIntent -Name MyIntent -StorageVLANs 101, 102 -ManagementVLAN 10
```

Set a QoS override and check the traffic classes:

```powershell
$QosOverride = New-NetIntentQosPolicyOverrides
$QosOverride.BandwidthPercentage_SMB = 25
Set-NetIntent -Name Cluster_ComputeStorage -QosPolicyOverrides $QosOverride
Get-NetQosTrafficClass -Cimsession (Get-ClusterNode).Name | Select PSComputerName, Name, Priority, Bandwidth
```

Set and verify a global cluster override:

```powershell
$clusterOverride = New-NetIntentGlobalClusterOverrides
Set-NetIntent -GlobalClusterOverrides $clusterOverride
Get-NetIntentStatus -Globaloverrides
```

Set a global proxy override; proxy configuration is not tied to an intent:

```powershell
$ProxyOverride = New-NetIntentGlobalProxyOverrides -ProxyServer https://proxy.example.com:3128 -ProxyBypass *.example.com
Set-NetIntent -GlobalProxyOverride $ProxyOverride
```

For VM testing, disable NetworkDirect with an adapter override:

```powershell
$AdapterOverride = New-NetIntentAdapterPropertyOverrides
$AdapterOverride.NetworkDirect = 0
Add-NetIntent -Name MyIntent -AdapterName vmNIC01, vmNIC02 -Management -Compute -Storage -AdapterPropertyOverrides $AdapterOverride
```

Overrides can change only what the OS allows. For example, SR-IOV on a virtual switch cannot be changed after deployment.

## Operate

View intents and status:

```powershell
Get-NetIntent
Get-NetIntentStatus | Format-Table IntentName, Host, ProvisioningStatus, ConfigurationStatus
Get-Command -ModuleName NetworkATC
```

**Add a node**

- Each node needs identically named adapters.
- Run `Add-ClusterNode`, then check `Get-NetIntentStatus`.
- A missing adapter on the new node reports `PhysicalAdapterNotFound`.

**Change adapters in an intent**

```powershell
Update-NetIntentAdapter -Name Cluster_Compute -AdapterName pNIC01,pNIC02,pNIC03,pNIC04
```

**Retry an intent after fixing a cause**

```powershell
Set-NetIntentRetryState -ClusterName CLUSTER01 -Name Cluster_ComputeStorage -NodeName Node01
```

Network ATC remediates drift automatically. Check the Network ATC event log.

**Remove an intent**

`Remove-NetIntent` removes the intent but does **not** delete the virtual switches or the DCB and QoS configuration it created. Clean them up yourself, and only on a system you mean to reset. In the first command, replace `MyIntent` with the intent name:

```powershell
Remove-VMSwitch -Name "*MyIntent*" -Force
Get-NetQosTrafficClass | Remove-NetQosTrafficClass
Get-NetQosPolicy | Remove-NetQosPolicy -Confirm:$false
Get-NetQosFlowControl | Disable-NetQosFlowControl
```

## Troubleshooting

| Error from `Get-NetIntentStatus` | Cause | Fix |
|---|---|---|
| `AdapterBindingConflict` | An adapter is bound to an existing virtual switch that conflicts with the one Network ATC deploys, or is bound to the component without a switch. | Remove the conflicting virtual switch, or disable the `vms_pp` component (unbind the adapter), then run `Set-NetIntentRetryState`. |
| `ConflictingTrafficClass` | A traffic class already exists, for example one named SMB, and conflicts. | Clear the existing DCB configuration using the three `Get-NetQos` cleanup commands above, then run `Set-NetIntentRetryState`. |
| `RDMANotOperational` | Inbox driver (not supported), SR-IOV disabled in BIOS, or RDMA disabled in BIOS. | Update the driver; enable SR-IOV and RDMA in the BIOS. |
| `InvalidIsolationID` | RoCE with an overridden VLAN outside 1 to 4094; RoCE needs a nonzero VLAN for PFC markings. | Use the default VLANs, a valid VLAN through `-StorageVLANs`, or let iWARP be chosen if the adapter supports it by removing the override that forces RoCE. |
| `PhysicalAdapterNotFound` | A node lacks an adapter present on the others. | Install or rename the adapter so names match. |

## Planning checklist

- [ ] Intent layout chosen and written down.
- [ ] Adapter names and PCI slots are identical on all nodes.
- [ ] Adapter symmetry is confirmed.
- [ ] Switch VLANs, MTU, and DCB are configured before deployment.
- [ ] Storage VLANs (defaults or overrides) are allowed on the switches.
- [ ] RDMA protocol (iWARP or RoCE) is known per adapter, with DCB if RoCE.
- [ ] Any override is documented with its reason.
- [ ] Verification plan: `Get-NetIntentStatus` reports success for provisioning and configuration on every node.
