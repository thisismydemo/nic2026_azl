# Azure Local, discovery to Day 2: deployment automation

Automation that deploys the Azure Local session's cluster and its Day-2 configuration. Every value comes from a parameter, a `solution.yml` input or your environment files; nothing in the code is tied to a tenant, subscription, site or piece of hardware. Bicep and Terraform are kept in parity; PowerShell does orchestration and validation.

## Map

```text
automation/
├── shared/                          NIC26.Automation module (config loader, naming, converters, Key Vault resolver), JSON Schemas, examples
├── landing-zones/azure-local/       subscription foundation, spoke network, vaults, Log Analytics, Recovery Services vault, witness storage, jump server
├── azure-local/
│   ├── cluster-deploy/              Validate and Deploy of the cluster (Bicep or Terraform plus scripts)
│   └── cluster-configure/*/         Day-2 ready: Insights, Update Manager, Defender, backup and Site Recovery, access (PIM), logical networks, images, policy
└── demo/{azure-local,shared}/       Day-2 readiness gate, cluster and update dashboards, reversible faults with undo, Site Recovery start and status
```

## Run order

| # | Stage | Folder |
|---|---|---|
| 1 | Prerequisites: resource providers, Terraform state storage | `landing-zones/azure-local/scripts` |
| 2 | Landing zone | `landing-zones/azure-local` |
| 3 | Cluster: validate, then deploy | `azure-local/cluster-deploy` |
| 4 | Day-2 configuration | `azure-local/cluster-configure/*` |
| 5 | Readiness gate and operations helpers | `demo/azure-local` |

For every solution the loop is the same:

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force
$cfg = Get-NIC26Config -Scope azure-local            # validates environment/<scope>/*.yml against the schemas
ConvertTo-NIC26BicepParam -Solution <solution folder or name> -Config $cfg -Execute
ConvertTo-NIC26TfVars     -Solution <solution folder or name> -Config $cfg -Execute
# then the solution's own README: what-if or plan, review, deploy with -Execute, run its tests
```

## Your configuration

Copy the files in `shared/examples/` to `environment/shared/environment.yml` and `environment/azure-local/environment.yml` and replace every value (tenant, subscriptions, address plan, node names and addresses, VLANs, intents). Secret values never go in a file: fields that need one hold `keyvault://<vault>/<secret>` references that are resolved in memory. The naming defaults (organisation, token, region) come from `shared/powershell/NIC26.Automation/NamingDefaults.psd1`, the `NIC26_ORG`, `NIC26_TOKEN` and `NIC26_REGION` variables, or your environment file; set your own. `landing-zones/azure-local/README.md` and `azure-local/cluster-deploy/README.md` have the full configuration references.

## Prerequisites

PowerShell 7.4+, `powershell-yaml`, Az PowerShell, Azure CLI with Bicep, Terraform 1.9+, Pester 5.5+ and PSScriptAnalyzer. A Windows machine inside the network that can reach the cluster nodes for the remoting-based scripts. Owner or equivalent rights on the target subscription; each solution README lists what it needs.

## Safety

Anything that changes state needs `-Execute`; destructive actions default to `-WhatIf`. Fault helpers refuse to run unless the cluster is healthy, print their undo command first and record a lock. Site Recovery for Azure Local is a preview integration in some releases: read the README of `cluster-configure/backup-asr` before relying on it.

## Tests

Run each suite in its own PowerShell session: suites that load the real Az modules change what later suites in the same session can mock.

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path .\automation\shared\powershell\NIC26.Automation\Tests -Output Detailed
Invoke-Pester -Path .\automation\landing-zones\azure-local\tests -Output Detailed
Invoke-Pester -Path .\automation\azure-local -Output Detailed
Invoke-Pester -Path .\automation\demo\azure-local\tests -Output Detailed
Invoke-Pester -Path .\automation\demo\shared\tests -Output Detailed
```

## Example names and values

The example files use neutral values: private-range addresses and VLAN IDs that belong to no real site. `iic` (a fictional organisation) and `nic26` (the module prefix) are deliberate example names. Replace every value in your own copies of the `*.example.*` files before you deploy; keep the examples themselves unchanged.
