# Network ATC Design Guide - Azure Local

## Network ATC Overview

**Network ATC** (Automatic To Configurate) is Azure Local's declarative networking framework that:
- Abstracts infrastructure networking complexity
- Enables intent-based configuration
- Automates configuration of switching, clustering, and workload networks
- Reduces human error and validation work

Instead of manually configuring VLANs, switch ports, and NIC teaming, you declare what you *want* (the intent), and Network ATC implements it.

## Network Intents

**Intent** = Declarative statement of what the network should do.

### Standard Intents

#### 1. Compute Intent
**Purpose:** VMs and workloads

```
Intent Name: Compute
Description: "Virtual machine workload traffic"
  ├─ Management: 1 Gbps (optional)
  ├─ SMB: 10 Gbps (if clustered storage)
  └─ Workload: 10 Gbps or higher
```

#### 2. Storage Intent
**Purpose:** VM storage and cluster communication

```
Intent Name: Storage
Description: "Cluster shared volume and VM storage traffic"
  ├─ SMB: Dual 10 Gbps NICs (for redundancy and performance)
  └─ RDMA: Optional (ROCE v2 for ultra-low latency)
```

#### 3. Management Intent
**Purpose:** Out-of-band management and monitoring

```
Intent Name: Management
Description: "Cluster management and monitoring"
  ├─ Traffic: Management protocols (WMI, WinRM, etc.)
  └─ NIC: 1 Gbps sufficient
```

## Intent Configuration Steps

### Step 1: Identify Available NICs

**On each cluster node:**
```
Get-NetAdapter -Physical | Select-Object Name, InterfaceAlias, Status, Speed
```

**Example output:**
```
Ethernet 1 (10 Gbps) → Intent assignment?
Ethernet 2 (10 Gbps) → Intent assignment?
Ethernet 3 (10 Gbps) → Intent assignment?
Ethernet 4 (1 Gbps)  → Management?
```

### Step 2: Define Intents

**Compute Intent:**
```
- Name: Compute
- Adapters: Ethernet 1, Ethernet 2
- Traffic: VM workload
- Redundancy: NIC Teaming (Load Balancing)
```

**Storage Intent:**
```
- Name: Storage
- Adapters: Ethernet 3 (dedicated for CSV/SMB)
- Traffic: Cluster communication, VM storage
- Redundancy: Single adapter (can add second for HA)
```

**Management Intent:**
```
- Name: Management
- Adapters: Ethernet 4
- Traffic: Management, monitoring
- VLAN: Optional (management VLAN)
```

### Step 3: Configure Intent (Bicep Example)

```bicep
resource networkIntent 'Microsoft.AzureStackHCI/clusters/networkIntents@2024-01-01' = {
  name: 'compute'
  properties: {
    description: 'Compute workload traffic'
    intent: [
      {
        name: 'Compute'
        isEnabled: true
        adapterNames: ['Ethernet1', 'Ethernet2']
        trafficType: ['Compute']
        overrideVirtualSwitchConfiguration: false
        overrideQosPolicy: false
      }
    ]
  }
}

resource storageIntent 'Microsoft.AzureStackHCI/clusters/networkIntents@2024-01-01' = {
  name: 'storage'
  properties: {
    intent: [
      {
        name: 'Storage'
        isEnabled: true
        adapterNames: ['Ethernet3']
        trafficType: ['Storage']
      }
    ]
  }
}
```

### Step 4: Validate Configuration

Network ATC validates:
- Adapter counts are sufficient
- Speed matches intent (10 Gbps for storage, etc.)
- No conflicts (adapters assigned to multiple intents)
- VLANs are correctly configured

```powershell
# Validate network intent
Get-AzStackHciNetworkIntent -ResourceGroupName <rg> -ClusterName <cluster>

# Check status
Get-AzStackHciNetworkIntentStatus -ResourceGroupName <rg> -ClusterName <cluster>
```

## Topology Patterns

### Pattern 1: Single 10 Gbps NIC (Minimal)

```
┌─────────────────┐
│  Cluster Node   │
├─────────────────┤
│ Ethernet 1: 10G │ ← Compute + Storage (converged)
│ Ethernet 2: 1G  │ ← Management
└─────────────────┘

Pros: Cost-effective, simple
Cons: No redundancy, performance bottleneck for storage
```

**Network Intent Configuration:**
```
Compute Intent: Ethernet 1
Storage Intent: Ethernet 1 (same as compute)
Management Intent: Ethernet 2
```

### Pattern 2: Converged (Compute + Storage on same NICs)

```
┌────────────────────┐
│  Cluster Node      │
├────────────────────┤
│ Ethernet 1: 10G    │ ─┐
│ Ethernet 2: 10G    │ ─┼─ Compute + Storage (dual NIC for redundancy)
│ Ethernet 3: 1G     │ ─┴─ Management
└────────────────────┘

Pros: Simpler configuration, good redundancy
Cons: Storage and compute share bandwidth
```

**Network Intent Configuration:**
```
Compute Intent: Ethernet 1, Ethernet 2 (NIC Team)
Storage Intent: Ethernet 1, Ethernet 2 (same team, separate traffic class)
Management Intent: Ethernet 3
```

### Pattern 3: Segregated (Separate NICs for Compute, Storage, Management)

```
┌──────────────────────┐
│  Cluster Node        │
├──────────────────────┤
│ Ethernet 1: 10G      │ ─ Compute workloads
│ Ethernet 2: 10G      │ ─ Storage / Cluster CSV
│ Ethernet 3: 10G      │ ─ Storage redundancy (optional)
│ Ethernet 4: 1G       │ ─ Management
└──────────────────────┘

Pros: Best performance, clear separation
Cons: More NICs required, higher cost
```

**Network Intent Configuration:**
```
Compute Intent: Ethernet 1, Ethernet 2
Storage Intent: Ethernet 3 (optionally Ethernet 2 as backup)
Management Intent: Ethernet 4
```

### Pattern 4: Rack-Aware Cluster (Multi-Rack Deployment)

```
Rack A                    Rack B                    Rack C
┌────────────────┐      ┌────────────────┐      ┌────────────────┐
│ Node 1 (10Gbps)│      │ Node 2 (10Gbps)│      │ Node 3 (10Gbps)│
│ + Management   │      │ + Management   │      │ + Management   │
└────────────────┘      └────────────────┘      └────────────────┘
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │
                    Cluster communication
                        (10 Gbps mesh)

Network ATC ensures:
- Compute traffic distributed across racks
- Storage traffic redundant across racks
- Management has independent path
```

## VLAN Configuration (Optional)

If your network uses VLANs:

```bicep
// Compute VLAN
{
  VlanID: 100
  AdapterName: "Ethernet1"
  AdapterNameResourceId: "..."
  IntentName: "Compute"
}

// Storage VLAN
{
  VlanID: 200
  AdapterName: "Ethernet3"
  IntentName: "Storage"
}

// Management VLAN
{
  VlanID: 300
  AdapterName: "Ethernet4"
  IntentName: "Management"
}
```

## QoS (Quality of Service) Configuration

Network ATC can enforce QoS policies for each intent:

```bicep
// Guarantee minimum bandwidth for Storage (critical)
{
  name: "Storage"
  trafficType: ["Storage"]
  qosPolicy: {
    minimumBandwidthPercentage: 30  // Guarantee 30% of total NIC bandwidth
    maximumBandwidthPercentage: 100  // Can use up to 100%
    priority: 7                      // High priority (0-7 scale)
  }
}

// Limit Management to not starve storage/compute
{
  name: "Management"
  trafficType: ["Management"]
  qosPolicy: {
    minimumBandwidthPercentage: 10
    maximumBandwidthPercentage: 30  // Cap at 30% max
    priority: 0                      // Low priority
  }
}
```

## Validation Checklist

Before deploying Network ATC:

- [ ] Physical NICs identified on all cluster nodes
- [ ] NIC speed matches expected (10 Gbps for storage, etc.)
- [ ] NICs not shared with host OS critical functions
- [ ] VLANs planned (if needed)
- [ ] QoS policies documented
- [ ] Network switches configured for teaming/LACP if needed
- [ ] Test ping between nodes via each intent

## Troubleshooting

### Issue: Network Intent Validation Fails

**Cause:** Adapter configuration mismatch or insufficient NICs

**Resolution:**
```powershell
Get-AzStackHciNetworkIntent -Debug
  # Check actual vs. required NIC count
  # Verify NIC speed
  # Check for driver issues
```

### Issue: Poor Storage Performance

**Cause:** Storage traffic mixed with compute, insufficient bandwidth

**Resolution:**
1. Verify Storage intent has dedicated NIC
2. Check QoS policy (ensure Storage has priority)
3. Verify network switch supports required bandwidth
4. Check for network loops or misconfigurations

### Issue: Management Connectivity Lost During Compute Surge

**Cause:** Compute traffic starving management

**Resolution:**
1. Verify Management has separate NIC
2. Enable QoS with minimum bandwidth guarantee
3. Monitor bandwidth utilization
4. Consider upgrading management NIC to 10 Gbps

## Next Steps

1. Document physical NIC inventory for your cluster
2. Decide intent topology (converged vs. segregated)
3. Define VLAN plan if needed
4. Configure Network ATC intents in your Bicep deployment
5. Validate configuration before go-live

