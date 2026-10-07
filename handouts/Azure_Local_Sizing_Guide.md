# Azure Local: Sizing Guide

Use this handout to structure an Azure Local sizing model and prepare it for hardware-provider validation.

**Status:** prepared 2026-10-06 against Microsoft Learn for the 2609 release family; limits change by release, so confirm them for yours.

## The sizing flow

1. Establish workload demand.
2. Choose storage resiliency.
3. Reserve capacity for repair.
4. Validate N+1 maintenance headroom.
5. Account for growth.
6. Validate candidate hardware with the hardware provider.

Build the model from the number and size of VMs, vCPU count and memory, storage capacity, IOPS and throughput, and expected growth. Include capacity for platform services, storage resiliency, maintenance and failure conditions.

Use the Azure Local sizer to model normal demand, failover demand, update operations and growth, and use an OEM-specific sizing tool as well when one exists. Review the output with the hardware provider or integrator. Do not rely only on an N+1 or N+2 label: validate that the surviving machines meet workload targets in each intended condition.

## Know your demand

Profile representative workloads rather than adding up allocations, and keep allocated values separate from measured values. An inventory alone does not establish application dependencies or performance; record missing evidence as an assumption, not as a fact.

Define performance targets for normal demand, peak demand, maintenance and intended failure conditions.

| Session example estate (synthetic) | Value |
|---|---:|
| VMs | 24 |
| vCPU | 72 |
| Memory | 160 GiB |
| Consumed storage | About 3 TiB |
| Provisioned storage | 5.8 TiB |

Templates and the vCLS placeholder are excluded from this example.

## Compute and memory

Reserve at least one machine's worth of CPU and memory across the instance for N+1. This headroom lets solution updates drain and restart each node one at a time without workload downtime. Validate the failure state with CPU and memory overcommit taken into account.

For volumes that must stay online when two machines fail at once, plan for all of these:

- At least four machines.
- A cluster witness.
- A symmetrical storage layout.
- Three-way mirroring.
- N+2 compute reserve.

In a three-machine instance, two unavailable machines make the storage pool lose quorum and the virtual disks inaccessible, even if compute capacity remains.

The Arc resource bridge VM needs at least 4 vCPU, 8 GB memory and 200 GB disk; more may be needed, so check the product documentation. GPUs are optional, up to 192 GB of GPU memory per machine.

## Storage: resiliency

| Servers | Choice | Efficiency | Tolerates |
|---|---|---:|---|
| Two | Two-way mirror | 50 percent | One hardware failure at a time: a server or a drive |
| Two | Nested two-way mirror | 25 percent | Two hardware failures at a time: two drives, or a server and a drive on the remaining server |
| Two | Nested mirror-accelerated parity | About 35 to 40 percent | Two hardware failures at a time: two drives, or a server and a drive on the remaining server |
| Three | Three-way mirror | 33.3 percent | At least two hardware problems at a time |
| Four or more | Three-way mirror | 33.3 percent | At least two hardware problems at a time |
| Four or more | Dual parity | 50 percent at four servers, 66.7 percent at seven, up to 80 percent | The same fault tolerance as three-way mirror |
| Four or more | Mirror-accelerated parity | Depends on the mix of mirror and parity | Confirm the intended failure conditions with the hardware provider |

Microsoft recommends nested resiliency for production two-server clusters. With three servers, two unavailable servers lose pool quorum. Rack-aware clusters require rack-level nested mirroring and support only two-way or four-way mirror volumes. In a two-machine cloud deployment, the Express storage configuration creates two-way mirrored thin volumes. Which resiliency you can choose is independent of drive type.

Performance considerations:

- Mirror is fastest; use it for latency-sensitive or random-IOPS workloads such as databases and performance-sensitive VMs.
- Dual parity suits infrequently written or cold data, and some VDI or file-serving workloads at your discretion. It raises CPU use and write latency.
- Mirror-accelerated parity suits large sequential writes. Size the mirror portion so one burst fits: for 100 GB ingested daily, use a 150 to 200 GB mirror portion and put the rest in parity. An abrupt write slowdown partway through ingestion means the mirror portion is too small.

Drive tiers:

- With two drive types, the faster provides cache and the slower provides capacity, automatically.
- With NVMe, SSD and HDD, only NVMe caches. Each volume can sit on SSD, on HDD, or span both.
- Use the SSD tier for the most performance-sensitive workloads.

## Storage: volumes and reserve

ReFS is recommended; use NTFS if a feature you need is not supported by ReFS. Volumes with different filesystems can coexist.

Recommended volume plan:

- At least one volume per server, to spread ownership.
- At most 64 volumes per cluster.
- At most 64 TB per volume.
- If a backup solution relies on VSS and the Volsnap provider, keep volumes to 10 TB. Solutions that use the Hyper-V RCT API, ReFS block cloning or native SQL backup APIs perform well to 32 TB and beyond.

A volume's size is its usable capacity. Its footprint is the physical capacity it occupies in the pool and depends on resiliency: a three-way mirror volume's footprint is three times its size. All footprints must fit in the pool.

Reserve capacity by leaving unallocated pool capacity equal to one capacity drive per server, up to four drives. The reserve lets volumes repair in place and in parallel after a drive failure, before the failed drive is replaced. For 1 TB capacity drives:

| Servers | Reserve |
|---:|---:|
| 2 | 2 TB |
| 3 | 3 TB |
| 4 or more | 4 TB |

With NVMe, SSD and HDD, reserve one SSD plus one HDD per server, up to four of each.

## Worked example

Microsoft's example uses decimal units. Four servers each have sixteen 2 TB capacity drives, so the pool is 4 × 16 × 2 TB = 128 TB. Reserve four drives (8 TB), which leaves 128 − 8 = 120 TB for volume footprints.

- Two 12 TB three-way mirror volumes at 33.3 percent efficiency occupy 36 TB each.
- Two 12 TB dual-parity volumes at 50 percent efficiency (four servers) occupy 24 TB each.
- Total: 36 + 36 + 24 + 24 = 120 TB, which fits exactly.

Windows shows binary units: a 2 TB drive appears as 1.82 TiB and the 128 TB pool as 116.41 TiB.

For the session estate, the arithmetic from the efficiency figures is:

| Data | Two-way mirror (50 percent) | Nested two-way mirror (25 percent) |
|---|---:|---:|
| About 3 TiB consumed | About 6 TiB of physical footprint | About 12 TiB |
| 5.8 TiB provisioned | About 11.6 TiB | About 23.2 TiB |

These figures are before the reserve. Microsoft recommends nested resiliency for a production two-node cluster, so the right-hand column is the one that applies in production. Check the resulting hardware fit with the sizer.

## Limits and minimums

Confirm limits against the release you deploy.

| Scope | Limit or requirement |
|---|---|
| Hyperconverged instance | 1 to 16 machines |
| Switchless storage | Supported for 1 to 4 machines; four or more machines with storage need physical switches with RDMA; scaling a switchless deployment out later needs a physical switch and manual cabling changes |
| Disaggregated instance (external Fibre Channel or iSCSI SAN) | 1 to 64 machines, 1 to 8 racks, up to 16 machines per rack |
| Disaggregated, per system | 4 PB storage, 400 TB per machine, 64 volumes, 64 TB volume size |
| Per host | 512 logical processors, 24 TB RAM, 2,048 virtual processors |

Per-machine minimums:

- 32 GB RAM with ECC.
- A 64-bit processor with second-level address translation, with Intel VT or AMD-V turned on.
- TPM 2.0 present and turned on, and Secure Boot turned on.
- A boot drive of at least 200 GB; 400 GB or more is recommended for large-memory machines above 768 GB.
- For hyperconverged, at least two data disks per server, each at least 500 GB, and at least two network adapters.
- At deployment, drives must match across servers in number, type, capacity, performance and firmware, and machines must be the same model, manufacturer, processor type and network adapters.

Hardware must come from the Azure Local catalog. The solution categories are Premier Solutions, Integrated Systems and Validated Nodes.

## Common mistakes

- Sizing from allocated instead of measured numbers.
- Forgetting reserve capacity.
- Ignoring the footprint multiplier.
- Leaving no N+1 compute headroom, which blocks rolling updates.
- Treating storage redundancy as backup.
- Assuming a three-node cluster survives two node failures.
- Planning to scale a switchless cluster out later.
- Mixing drive types or models across servers.
- Exceeding 10 TB volumes with a VSS-based backup.

## Sizing checklist

- [ ] The demand profile uses measured values and records assumptions.
- [ ] Resiliency is chosen per volume type.
- [ ] Reserve capacity is subtracted.
- [ ] Volume footprints fit in the pool.
- [ ] N+1 or N+2 compute is validated with overcommit.
- [ ] Limits are checked for the release.
- [ ] Machine minimums are met.
- [ ] Sizer output is reviewed with the hardware provider.
- [ ] Growth and procurement lead time are recorded.
- [ ] The backup volume-size limit is checked.
