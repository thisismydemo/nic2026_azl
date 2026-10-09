# Azure Local: Planning and Design Decisions

How to plan an Azure Local deployment so that Deploy is an input file, not a discovery exercise. Each decision below follows the same shape: the question, the options, the pros and cons, the decision made for the example customer (IIC), and where the decision is recorded.

**Status:** prepared 2026-10-06 against Microsoft Learn for the 2609 release family. Where a choice depends on your release, region, hardware or tenant, the text says so. Preview features are labelled **preview** and are not a deployment recommendation.

## How to use this guide

1. Work through the decisions in order; each one feeds the next.
2. Record every decision in a decision log (identifier, question, decision, date, owner).
3. Put every resulting value in one deployment configuration file (the session repo uses `environment/azure-local/environment.yml`, copied from an example file; the session also shows the `infrastructure.yml` design export). Nothing is typed by hand at deployment time.
4. Do not start Deploy until the planning gate at the end of this guide is green.

## Whole-site discovery before purchasing or deploying

Start with existing equipment versus a new purchase. Both routes need a verified site design; an inventory of the cluster nodes alone is insufficient. Keep raw inventory and complete configuration exports protected and private, and share only reviewed sanitized examples.

| Evidence | What to record and review |
|---|---|
| Every server | Model, serial/service tag, CPU/memory, firmware/BMC, NIC models and ports, per-port MAC addresses and link capabilities, drives/capacity/serials, controllers, boot media and intended OS disk; reconcile labels and cabling |
| Fabric and boundaries | ToR and OOB switches, firewall devices, uplinks and software; management, compute, storage and OOB paths, gateways, routing, DNS/NTP, egress and return paths |
| Complete configuration | Full sanitized switch/firewall exports covering VLANs/subnets, port membership, tagged/untagged settings, trunks, MTU, routing, ACLs, NAT and required endpoints; compare observed configuration with design and record discrepancies |
| Tool provenance | Exact source/version, dependencies, access requirements, collection time, missing fields and supported vendor/model/firmware; verify available vendor management endpoints and schemas rather than assuming uniform support |
| Design handoff | Review OEM JSON field mapping into the approved infrastructure YAML; preserve approved choices and flag missing or contradictory evidence rather than blindly overwriting values |

Explicitly decide whether management and compute share a VLAN, use separate VLANs on shared adapters, or use dedicated adapters. VLAN isolation and physical convergence are separate choices. Map the approved choice and physical port/MAC evidence into Network ATC intents, including the storage/RDMA switch requirements.

Select supported inventory and OS-provisioning tools for your hardware vendor and release, then record their versions and validate the collected evidence. A successfully tested networking/firewall path proves that path at that time; it does not prove every rule or full site readiness. Before OS installation, positively identify the approved boot disk and preserve every device outside the approved scope.

## Decision 1: Release

| | |
|---|---|
| **Question** | Which Azure Local release do we size, build and support against? |
| **Options** | The latest release at build time; the release named in an earlier planning document; a pinned older release |
| **Pros and cons** | Latest: current features and fixes, longest support window, but your hardware vendor must have validated it. Pinned older: stable for change control, but you must stay within six months of the most recent release to remain supported |
| **Decision (IIC)** | The latest supported release at build time. A planning figure such as "2604" means "whatever is current when you deploy" |
| **Record** | Decision log and the version manifest: planning baseline, actual release, template and API versions, preview features used, git tag, last validation date |

Facts to design around (Microsoft Learn): Microsoft ships monthly quality updates, quarterly baseline updates and hotfixes as needed, plus solution builder extension updates from your hardware vendor. Feature releases can appear a week or more after Microsoft's release because the vendor validates them first. Keep the system within six months of the most recent release. The OEM solution extension must support the release you choose.

## Decision 2: Hardware

| | |
|---|---|
| **Question** | What do we buy, and who owns the firmware problem? |
| **Options** | Premier Solution; Integrated System; validated node; disaggregated, SAN-attached (documented for the 2609 release family without a preview label: Fibre Channel or iSCSI storage, one to 64 machines) |
| **Pros and cons** | Premier Solution: highest partner integration and validation, single support path, firmware managed through the solution extension. Integrated System: validated hardware with more deployment, update and support responsibility on you. Validated node: flexible sizing, you assemble the support model. Disaggregated: reuse existing SAN storage, different failure domains and a separate operating model |
| **Decision (IIC)** | A validated integrated system from the Azure Local catalog: two nodes with all-flash NVMe, one GPU per node |
| **Record** | Bill of materials and the firmware baseline to reach before the OS is installed (BIOS, BMC, network adapters, drives, solution extension) |

Start from an exact SKU in the Azure Local catalog and ask the hardware provider to validate the final configuration against workload, failure-state, support and lifecycle requirements. The solution categories in the catalog today are Premier Solutions, Integrated Systems and Validated Nodes; names change over time, so confirm them in the catalog when you design.

**Decision matrix to complete per option:** eligibility, who owns support and firmware, storage architecture, failure domains, expansion path, cost implications.

## Decision 3: Topology and quorum

| | |
|---|---|
| **Question** | How many nodes, switched or switchless storage, and when do racks become fault domains? |
| **Options** | Two nodes, switched storage; two nodes, switchless; three or more nodes; Rack Aware cluster |
| **Decision (IIC)** | Two nodes, switched storage, cloud witness |

Quorum facts (Microsoft Learn): with two nodes a witness is required. Two nodes plus a witness survive one node failure; they cannot survive a second failure. If a node and then the witness are lost (or both at once), the cluster has one vote of three and goes offline. Use a cloud witness when you have internet access, and a file share witness otherwise. In the current release a witness storage account cannot be shared between systems.

Trade-off to state to the customer: on two nodes, volumes use a two-way mirror, so one fault leaves zero redundancy until the repair finishes.

### Rack Aware cluster (not chosen here)

A Rack Aware cluster places nodes in two physical racks, each acting as a local availability zone, in two rooms or buildings.

| Requirement | Value |
|---|---|
| Deployment | New deployments only; a standard cluster cannot be converted |
| Zones | Two zones, equal machine counts, maximum four machines per zone |
| Drives | All-flash (NVMe or SSD) |
| Latency | 1 ms or less round trip between racks |
| Storage network | A dedicated storage network intent with enough bandwidth for synchronous replication |
| Volumes | Two-way or four-way mirror only; no three-way mirror |
| Expansion | Add nodes in pairs; a 1+1 cluster cannot be expanded in this release |
| Readiness | Run the LLDP network validator before deployment; LLDP must be enabled on all switch ports to the nodes |

Why it is not chosen for IIC: it needs two rooms or racks with the required latency and bandwidth, and the two-node demo cluster does not prove that topology.

## Decision 4: Connectivity and egress

| | |
|---|---|
| **Question** | How do the nodes, the Arc Resource Bridge and the VMs reach Azure, and how many firewall holes does that cost? |

| Option | Endpoints on the firewall | Notes |
|---|---|---|
| Direct outbound | More than 100 FQDNs | Simplest to build, largest allow-list |
| Enterprise proxy | Same list | TLS inspection must be disabled for the required endpoints |
| **Arc gateway** | Roughly 23 to fewer than 30 | Tunnels supported HTTPS traffic; **new deployments on 2506 or later only; it cannot be enabled after deployment** |
| Proxy plus Arc gateway | Fewest | Recommended for new production deployments on a public path |
| Private path | Arc gateway plus a firewall explicit proxy over ExpressRoute or site-to-site VPN | Requires Azure Local 2608 or later; earlier releases do not support it |
| Disconnected operations | n/a | For air-gapped sites |

Constraints that shape the decision (Microsoft Learn): HTTP traffic is never tunneled through the Arc gateway; OEM and third-party endpoints are not covered by it; Azure Arc Private Link is not supported for Azure Local infrastructure, so Arc registration uses public Arc endpoints; private endpoint addresses must stay outside `10.96.0.0/12` and `10.244.0.0/16`; keep Key Vault and the witness storage account publicly reachable until deployment completes, then restrict them. Firewall rules must be in place before Arc registration; validate them with the Environment Checker.

**Keep three things apart in your design document:** the production recommendation (Arc gateway or proxy plus Arc gateway), any constraint of a preview feature you use, and any lab workaround.

**Decision (IIC):** direct egress with the full allow-list and no Arc gateway, because the lab used the simplified machine provisioning preview, which was checked not to work with the Arc gateway at the version used. The lesson: choose the Arc gateway during planning, because it cannot be added later.

Also decide here: DNS zone and NTP; a management IP pool of at least six consecutive addresses; static node addressing; and the endpoint allow-list for every service the design uses later (Monitor, Update, Backup, Site Recovery, Migrate, Key Vault, witness storage).

## Decision 5: Network design

| | |
|---|---|
| **Question** | How do the node ports become a supported network? |
| **Options** | Three intents (management, compute, storage) or converged management plus compute; switched or switchless storage; one storage VLAN per adapter |
| **Decision (IIC)** | Three intents; dedicated management, compute and two storage VLANs; jumbo frames on storage; a per-node port map; switch configuration generated from the design |

Facts (Microsoft Learn): RDMA is required for the storage traffic of multi-node clusters. For each adapter it is either iWARP (data center bridging optional) or RoCE (data center bridging required, configured identically on every port and switch). The management VLAN ID and the management IP pool cannot be changed after deployment; if you use a management VLAN, set it on the physical adapters before Arc registration (untagged management needs no adapter VLAN setting). Do not place any infrastructure IP, DNS server or proxy in `10.96.0.0/12` or `10.244.0.0/16`.

IP count for a two-node switched pattern without SDN: 7 management IPs required (one per host, one for the cluster, three for the Arc Resource Bridge management stack, one for the VM update role) plus 4 storage IPs, 11 in total; one more if you use an optional OEM VM. Plan the management pool as at least six consecutive addresses on the nodes' subnet, outside the node addresses, to cover the cluster IP and the infrastructure services.

## Decision 6: Identity and access

| | |
|---|---|
| **Question** | What does the cluster trust, and what breaks when that service is down? |
| **Options** | Local Identity with Azure Key Vault; Active Directory; hybrid |
| **Decision (IIC)** | Local Identity with Key Vault |

What Local Identity requires (Microsoft Learn): a non-built-in local administrator with identical credentials on every node, static IP addresses (no DHCP for the nodes), a DNS server with a correctly configured zone (an internal DNS option is available as a **preview**), SSH enabled on each node for portal access, and one Key Vault per cluster for BitLocker keys and the recovery administrator. No OU, pre-created objects or domain join. Windows Admin Center is not supported with this model; use PowerShell, the portal and Azure Monitor.

People and automation access: Entra groups for operators, engineers and administrators; Azure RBAC for deployment and operations; Privileged Identity Management for eligible, not standing, access; the deployment identity with only the roles it needs; Conditional Access that must not block service principals or the deployment.

## Decision 7: Landing zone and naming

| | |
|---|---|
| **Question** | Where does the cluster live in Azure, who pays, and what governs it? |
| **Options** | Full Cloud Adoption Framework landing zone (management group hierarchy, subscription per landing zone); simplified (one subscription, resource-group scope) |
| **Decision (IIC)** | A dedicated Azure Local landing-zone subscription under the customer landing-zones management group |

The landing zone must contain, before Deploy: resource groups, registered resource providers (including `Microsoft.Insights`, without which diagnostic and Key Vault audit logging fails validation), a Log Analytics workspace, a Key Vault, a witness storage account, a spoke network peered to the hub, tags and a policy scope, and budgets. Choose a supported region; the cluster transfers little data, so proximity matters less than policy and cost.

**Naming standard** (example for IIC): `<type>-iic-<site>-<purpose>-<region>-<nn>`, for example `rg-iic-site01-azl-eus-01`. Decide the site token and the region abbreviation once; the same standard applies to every resource.

## Decision 8: Business continuity and operations requirements

| | |
|---|---|
| **Question** | What does the customer lose when a node, a volume or the whole site fails, and how fast must it return? |
| **Options** | Backup only; backup plus Azure Site Recovery to Azure; Hyper-V Replica to a second cluster; none |
| **Decision (IIC)** | Backup for all tiers; Site Recovery to Azure for tier-1 workloads with a quarterly test failover |

Facts: backup is recovery in hours and replication is continuity in minutes; neither replaces the other. Site Recovery can reach a recovery point objective as low as 30 seconds. The Site Recovery extension for Azure Local is documented as **preview and for test environments**; for production, configure Site Recovery manually with the Hyper-V to Azure option. Confirm the status on the day you design. Restoring or failing back an Azure Local VM to a different cluster returns it as an unmanaged VM until it is re-registered.

Operations requirements to decide now and build later: monitoring scope and cost ceiling, maintenance windows for guests and for the cluster, the security baseline and policy scope, the support model and escalation, and which team owns which update plane.

## The planning gate

Deploy starts only when every item exists:

- [ ] Discovery questionnaire complete
- [ ] Workload inventory and sizing, with missing evidence recorded as assumptions
- [ ] Release decision and version manifest
- [ ] Hardware decision, bill of materials and firmware baseline
- [ ] Topology and quorum decision
- [ ] Site assessment and per-node cabling and port map
- [ ] Connectivity design: outbound topology, allow-list, proxy, DNS and NTP, IP plan
- [ ] Network design: VLANs, intents, switch configurations
- [ ] Identity and access design
- [ ] Landing zone design and naming standard
- [ ] Business continuity plan: backup, DR, recovery point and recovery time objectives
- [ ] Operations requirements
- [ ] High-level and low-level design and decision records
- [ ] Deployment configuration file populated and reviewed
