# Azure Local: Sizing Guide

## Executive Summary

Azure Local is edge infrastructure running Hyper-V on specially validated hardware. This guide helps you:
1. Assess your workload
2. Size the cluster
3. Choose hardware
4. Plan topology

## Workload Assessment

Use [Azure Local Surveyor](https://azurelocal.cloud/azurelocal-surveyor/) for workload assessment and sizing. Collect VMware inventory using RVTools or Azure Migrate; discovery provides the inputs, while Surveyor evaluates the hardware fit.

The [Surveyor planning guide](https://azurelocal.cloud/azurelocal-surveyor/docs/guide/planning-areas.html) documents RVTools workbook (`.xlsx`) and `vInfo` CSV imports. If collecting with Azure Migrate, map the inventory into Surveyor's workload inputs; do not assume a native Migrate importer. Review workload inclusion, units, allocation versus measured demand, growth and maintenance reserve.

For existing equipment, use **Workload Planning > Assess existing hardware**, then review **Fit & Recommendations**, **Storage Design**, and **Reports & Exports**. Save the project and export the report. Aggregate fit does not validate application dependencies, VM placement, storage performance, networking or OEM support.

Before sizing, understand your workload:

**Questions to ask:**
- How many VMs will run on Azure Local?
- What are typical CPU, memory, storage needs per VM?
- What's the peak concurrent workload?
- Do you need high availability (multi-node cluster)?
- GPU workloads? Specialized hardware?

### Workload Profiling Template

```
Workload Name: __________
Number of VMs: __________
Avg CPU per VM: __________ vCPUs
Peak CPU per VM: __________ vCPUs
Avg Memory per VM: __________ GB
Peak Memory per VM: __________ GB
Storage per VM: __________ GB (OS + data)
GPU? (Y/N): __________
  If yes, GPU model: __________
High Availability? (Y/N): __________
```

## Azure Local Hardware Sizing

### Compute Requirements

**Formula:**
```
Total CPU cores needed = (Number of VMs × Peak CPU) ÷ CPU overhead ratio (typically 0.8)
Total Memory needed = (Number of VMs × Peak Memory) × 1.2 (20% headroom)
```

**Example: 50 VMs, 4 vCPU each, 8 GB memory**
```
CPU: (50 × 4) ÷ 0.8 = 250 physical cores → 2-3 sockets @ 16-20 cores
Memory: (50 × 8) × 1.2 = 480 GB → 6-8 DIMMs @ 64 GB each
```

### Storage Requirements

**Formula:**
```
Total Storage = (Num VMs × Storage per VM) + 30% overhead
= (50 VMs × 200 GB) × 1.3 = ~13 TB usable
```

**Common Azure Local Storage Options:**
- **SSD** = Ultra-high performance, expensive, small (2-4 TB)
- **NVMe** = High performance, moderate cost (10-20 TB)
- **SATA SSD** = Good performance, cost-effective (20-50 TB)
- **SATA HDD** = High capacity, slow (100+ TB)

**Recommendation:**
- Mix NVMe/SSD for working set
- SATA for archived/backup data
- Hybrid for best cost/performance

### Network Requirements

**Bandwidth Planning:**
```
Per-VM network: 100 Mbps (conservative)
Total = 50 VMs × 100 Mbps = 5 Gbps needed
```

**Interface Count:**
- Cluster communication: 1x 10 Gbps NIC minimum
- VM workload: 1x 10 Gbps NIC
- Management/IPMI: 1x 1 Gbps NIC

**Total: 3x 10 Gbps NICs per node (for 2+ node cluster)**

## Cluster Topology Options

### Single-Node Cluster
```
1 server, all workload
├─ Advantages: Low cost, simple
└─ Disadvantages: No HA, single point of failure
```

**When to use:** Dev/test, non-critical workloads, proof-of-concept

### 2-Node Cluster (Minimal HA)
```
2 servers, quorum via cloud witness
├─ Advantages: Basic high availability, reasonable cost
└─ Disadvantages: Limited capacity, quorum dependency on Azure
```

**When to use:** Small production workloads, cost-conscious

### 3-Node Cluster (Recommended HA)
```
3 servers, local quorum
├─ Advantages: True HA, survives 1 node failure
└─ Disadvantages: Higher cost (3x hardware)
```

**When to use:** Production deployments, uptime critical

### 4+ Node Cluster (Large Scale)
```
4+ servers, multiple availability groups
├─ Advantages: High availability, scalability, maintenance without downtime
└─ Disadvantages: Expensive, complex
```

**When to use:** Large deployments (100+ VMs), strict SLA

## Hardware Validation

Azure Local requires **validated hardware**. Microsoft maintains a list at:
- https://learn.microsoft.com/azure/azure-local/hardware

**Validated solutions include:**
- Dell PowerEdge (XE series)
- HP ProLiant (XL, Synergy series)
- Lenovo ThinkSystem (SR series)
- Others (check compatibility matrix)

### Premier vs. Standard

**Premier Partnerships:**
- Tighter integration with Microsoft
- Priority support
- Pre-validated configurations
- Higher cost, but simplified procurement

**Validated Solutions:**
- Meets hardware requirements
- Not necessarily Premier partnership
- More flexible, cost-effective
- Requires more validation work

**Disaggregated (Bring Your Own Hardware):**
- Use existing hardware if compatible
- Most cost-effective, most complex
- Requires careful validation

## Capacity Planning Calculator

```
--- INPUT ---
Number of target VMs:           _____
Avg CPU per VM (vCPUs):         _____
Peak Memory per VM (GB):        _____
Avg Storage per VM (GB):        _____
Number of cluster nodes:        _____
HA requirement? (Yes/No):       _____

--- OUTPUT ---
Total CPU cores needed:         [calculated]
Total Physical Memory needed:   [calculated]
Total Storage needed:           [calculated]
Per-Node CPU:                   [calculated]
Per-Node Memory:                [calculated]
Per-Node Storage:               [calculated]
Recommended Server Size:        [calculated]

--- RECOMMENDATION ---
[Hardware tier and rationale]
```

## Sizing Examples

### Small Deployment (Dev/Test)
```
Workload: 10 VMs, 4 vCPU, 16 GB memory each
Peak: 8 VMs concurrent

CPU Needed: (8 × 4) ÷ 0.85 = 38 physical cores
Memory Needed: (8 × 16) × 1.2 = 154 GB

Cluster Recommendation: 1-node (dev) or 2-node (test HA)
Hardware: Single PowerEdge XE8640 or similar
├─ 4-socket, 28 cores/socket = 112 cores ✓
├─ 2-3 TB memory ✓
└─ 20 TB NVMe/SSD ✓
```

### Medium Deployment (Production)
```
Workload: 50 VMs, 8 vCPU, 32 GB memory each
Peak: 40 VMs concurrent

CPU Needed: (40 × 8) ÷ 0.85 = 376 physical cores
Memory Needed: (40 × 32) × 1.2 = 1.54 TB

Cluster Recommendation: 3-node for HA
Hardware: 3x PowerEdge XE8640
├─ 4-socket, 28 cores/socket = 112 cores per node
├─ Per-node: 512 GB memory (total: 1.5 TB) ✓
└─ Per-node: 20 TB NVMe (total: 60 TB) ✓
```

### Large Deployment (Enterprise)
```
Workload: 200 VMs, 16 vCPU, 64 GB memory each
Peak: 150 VMs concurrent

CPU Needed: (150 × 16) ÷ 0.85 = 2,824 physical cores
Memory Needed: (150 × 64) × 1.2 = 11.5 TB

Cluster Recommendation: 4-node for HA + expansion
Hardware: 4x PowerEdge XE9680
├─ 8-socket, 32 cores/socket = 256 cores per node
├─ Per-node: 3 TB memory (total: 12 TB) ✓
└─ Per-node: 40 TB NVMe (total: 160 TB) ✓
```

## Cost Estimation

### Hardware Costs (2024 Estimates)

| Server Type | CPU | Memory | Storage | Est. Cost |
|-------------|-----|--------|---------|-----------|
| XE8640 (2U, 4-socket) | 112 cores | 2-3 TB | 20-40 TB | $80-120K |
| XE9680 (3U, 8-socket) | 256 cores | 3-6 TB | 40-80 TB | $150-200K |

### Total Cost of Ownership (3-year)

```
Hardware: $X
Maintenance (3 years @ 4-5%/year): $0.12-0.15X
Power/Cooling (3 years @ $3-5/kW/year): $0.1-0.15X
Network/Storage (ancillary): $0.1-0.2X
---
Total: $1.42-1.65X
```

**Example: 3-node cluster**
```
Hardware: 3 × $100K = $300K
3-year TCO: ~$450-500K
Cost per VM (50 VMs): ~$9-10K/VM over 3 years
```

## Network Planning

### Cluster Network (CSVv2)
- 10 Gbps minimum
- Dedicated VLAN recommended
- Low-latency, high-reliability link

### Management Network
- 1 Gbps sufficient
- Can be shared with corporate network

### Workload Network
- 10 Gbps recommended
- Depends on VM traffic patterns
- Can be segmented by VLAN

### Example Network Topology
```
Each cluster node:
├─ Management: 1x 1 GbE (to corp network)
├─ Cluster: 1x 10 GbE (to cluster network)
└─ Workload: 1x 10 GbE (to workload network)

Top-of-rack switch requirements:
├─ Uplink: 2x 40 GbE or 4x 10 GbE
├─ VLANs: Management, Cluster, Workload (minimum)
└─ Redundancy: Active/active or active/passive
```

## Validation Checklist

Before purchasing hardware:

- [ ] Workload profile documented (CPU, memory, storage needs)
- [ ] Cluster topology decided (1, 2, 3, or 4+ nodes)
- [ ] Hardware selected from Azure Local validated list
- [ ] Hardware specs exceed calculated requirements by 20%+
- [ ] Network infrastructure planned (switches, VLANs, bandwidth)
- [ ] Power/cooling capacity confirmed
- [ ] Support/warranty model chosen
- [ ] Budget approval obtained
- [ ] Timeline for deployment finalized

## Next Steps

1. Use this guide to size your workload
2. Reference **Network_ATC_Design.md** for network planning
3. Review **Day2_Operations_Runbook.md** for operational planning
4. Contact Azure Local sales for hardware recommendations
5. Request trial/POC if new to Azure Local

