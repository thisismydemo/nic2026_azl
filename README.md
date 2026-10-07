# Hybrid Cloud: Plan, Deploy, and Operate Azure Local from Discovery to Day 2

This repository accompanies a session in three phases. Plan and Discover covers workload assessment with Azure Local Surveyor and RVTools or Azure Migrate, sizing, topology, Network ATC design and identity strategy (Local Identity with Key Vault). Deploy and Day-2 Ready covers cloud-driven deployment with Bicep, Network ATC, post-deployment validation, Azure Monitor, Update Manager, backup, RBAC with PIM and Azure Policy. Day 2 Operations covers lifecycle updates, fault diagnosis, capacity, VM lifecycle through Arc and a planned Azure Site Recovery failover.

The session and this repository target the current Azure Local release, the 2609 release family.

## Session

| | |
|---|---|
| Conference | NIC 2026 |
| Date and time | Thursday 15 October 2026, 09:50 (W. Europe Time) |
| Length | 60 minutes |
| Level | 400 |
| Speaker | Kristopher Turner |
| Release | Azure Local 2609 release family |

## Start here

1. Open the [follow-along site](https://thisismydemo.github.io/nic2026_azl/) (it goes live once GitHub Pages is switched on for this repository), or read [follow-along/README.md](follow-along/README.md). The session is mostly watch and read. You can follow along fully for the Surveyor assessment on the synthetic workbook and for the Bicep what-if; neither needs a cluster.
2. Read the guides and runbooks in [handouts/](handouts/).
3. Read [automation/README.md](automation/README.md) for the run order, configuration and tests of the deployment automation.

## What is in this repository

| Path | What it holds |
|---|---|
| `presentation/Azure_Local_Discovery_to_Day2_NIC2026.pptx` | The deck |
| `handouts/` | `Azure_Local_Sizing_Guide.md`, `Planning_and_Design_Decisions.md`, `Network_ATC_Design.md`, `Deployment_Guide.md`, `Day2_Readiness_Checklist.md`, `Day2_Operations_Runbook.md`, `ASR_Failover_Procedures.md`, `Azure_Migrate_to_Azure_Local.md`, `Troubleshooting_Guide.md` |
| `src/assessment/` | `IIC-RVTools-demo.xlsx`, a synthetic RVTools workbook, and its README |
| `follow-along/README.md` | The attendee guide in Markdown |
| `follow-along-site/` | Source of the follow-along site |
| `automation/shared/` | The `NIC26.Automation` PowerShell module (config loader, naming, converters, Key Vault resolver), JSON Schemas and example environment files |
| `automation/landing-zones/azure-local/` | Subscription foundation, spoke network, vaults, Log Analytics, Recovery Services vault, witness storage and jump server |
| `automation/azure-local/cluster-deploy/` | Validate and deploy the cluster, with Bicep or Terraform plus scripts |
| `automation/azure-local/cluster-configure/` | Day-2 configuration: monitoring, Update Manager, Defender, backup and Site Recovery, access with PIM, platform, policy |
| `automation/demo/` | Readiness gate, cluster and update dashboards, reversible faults with undo, Site Recovery helpers |

Bicep and Terraform are kept in parity; PowerShell orchestrates.

## What is tested and what is not

The code is tested with Pester (using mocks), by compiling the Bicep and by validating the Terraform. It has not yet been run end to end against a tenant or cluster from this repository: treat the first deployment as a test and use a lab. Site Recovery for Azure Local is a preview integration in some releases. The fault helpers change a live cluster; use a lab. Everything is variable-driven, and the example files hold neutral placeholder values that you replace with your own.

## Prerequisites

- PowerShell 7.4 or later, Az PowerShell, Azure CLI with Bicep, Terraform 1.9 or later, Pester 5.5 or later
- An Azure subscription with Owner-level rights
- For the cluster, a Windows machine that can reach the nodes

## Security

Secrets never go in files; use Key Vault references only. Report a suspected vulnerability or leaked secret privately through the repository's Security tab (see [SECURITY.md](SECURITY.md)), and never in a public issue.

## License

MIT. See [LICENSE](LICENSE).

## Feedback

Open an issue for content questions.
