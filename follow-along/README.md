# Follow-along guide — Azure Local, Discovery to Day 2

_Generated from the demo-guide content by `npm run docs`. Mostly watch and read. Full follow-along only where no cluster is needed: the Surveyor assessment on the synthetic workbook and the Bicep what-if. Every other demo is a read-along with the repo path._

Session: Hybrid Cloud: Plan, Deploy, and Operate Azure Local from Discovery to Day 2. Thu 15 Oct 2026, 09:50 (W. Europe Time).

Replace the placeholders in the commands with your own values:

- `<sub>` — your Azure Local landing-zone subscription id
- `<rg>` — your resource group
- `<cluster>` — your cluster name
- `<node1>` — the first cluster node

## Follow along

### Workload assessment in Surveyor (RVTools route)

**Goal:** Import a synthetic RVTools workbook into Azure Local Surveyor and read the inventory totals.

**You need**

- A browser
- The synthetic workbook IIC-RVTools-demo.xlsx from the repo (src/assessment)
- No cluster required

**Steps**

1. **Open Surveyor and enter the target hardware.** Open Azure Local Surveyor, go to Workload Planning > Assess existing hardware, and enter the target nodes (CPU, RAM, drives). Do not enter the source VMware hosts.
   - You should see: The target hardware is saved in the project.
2. **Import the workbook.** Go to Workloads > Import RVTools and select the workbook. An import replaces existing inventory rows, so save any existing project first.
   - You should see: The preview reports 24 VMs, 3 skipped templates or placeholders and 2 powered-off VMs included.
3. **Use the inventory and read the totals.** Confirm Use this inventory. The dashboard shows allocated demand.
   - You should see: 72 vCPU, 160 GiB memory, 3 TiB consumed and 5.8 TiB provisioned storage.
4. **Review the two legacy VMs.** Open the two iic-legacy VMs. Decide whether to keep them in the estate and note that they have no performance history.
   - You should see: You can state which evidence is missing for each.

**Troubleshooting**

- Counts differ: check the workbook version and that you imported the vInfo tab from the supplied file.
- TiB and decimal TB are different units; compare like with like.

**Clean up**

- Save the project or discard it.

**In the repo:** `src/assessment/README.md`, `src/assessment/IIC-RVTools-demo.xlsx`

### Sizing and fit against two nodes

**Goal:** Read the sizing result for the synthetic estate.

**You need**

- The Surveyor project from the previous demo

**Steps**

1. **Open the fit and storage design.** Go to Fit & Recommendations, then Storage Design. Change the growth and the storage basis (provisioned or consumed) and observe the result.
   - You should see: Planned storage changes with the basis you choose; note decimal TB versus TiB.

**Clean up**

- Save or discard the project.

**In the repo:** `handouts/Azure_Local_Sizing_Guide.md`

### Cloud-driven deployment: the what-if

**Goal:** Generate and preview an Azure Local deployment without creating anything.

**You need**

- The repo
- Azure CLI with Bicep
- A subscription (the preview creates nothing)
- A copy of the example config with your values

**Steps**

1. **Prepare the config.** Copy the example environment file and replace the values with yours: names, nodes, IP pool, VLANs.

   ```powershell
   Copy-Item automation/shared/examples/environment.azure-local.example.yml environment/azure-local/environment.yml
   ```

   - You should see: The file validates: Get-NIC26Config -Scope azure-local returns without errors.
2. **Run the preview stage.** Run the Validate pass up to the Preview stage. It generates the parameters and runs a what-if.

   ```powershell
   ./automation/azure-local/cluster-deploy/scripts/Invoke-ClusterDeploy.ps1 -Pass Validate -Tool Bicep -Stage Preview
   ```

   - You should see: A what-if result is printed and no resources were created.
3. **Read what the what-if cannot see.** Compare the output with the Environment Checker results. Platform-side checks run only during the Validate pass in Azure.
   - You should see: You can list one check the what-if does not cover.

**Troubleshooting**

- Missing providers: register the resource providers listed in the landing-zone README first.

**Clean up**

- None; nothing was created.

**In the repo:** `automation/azure-local/cluster-deploy/README.md`, `automation/azure-local/cluster-deploy/bicep`

## Read along

### Azure Migrate discovery (recorded)

**Goal:** Understand the Azure Migrate discovery route.

**In the repo:** `handouts/Azure_Migrate_to_Azure_Local.md`

### Network ATC intent design on one screen

**Goal:** Read the intent design.

**In the repo:** `handouts/Network_ATC_Design.md`, `handouts/Planning_and_Design_Decisions.md`

### Simplified machine provisioning (preview, recorded)

**Goal:** Understand the flow and its limits.

**In the repo:** `handouts/Deployment_Guide.md`

### Network ATC intents on the running cluster

**Goal:** Know what to check on your own cluster.

**Steps**

1. **Read the intent status.** On a cluster node run the read-only checks.

   ```powershell
   Get-NetIntentStatus | Select-Object IntentName, Host, ConfigurationStatus, ProvisioningStatus
   ```

   - You should see: ConfigurationStatus Success and ProvisioningStatus Completed for every intent on every node.

**In the repo:** `handouts/Network_ATC_Design.md`

### Post-deployment validation, then the readiness gate in red

**Goal:** Understand the two gates.

**In the repo:** `automation/demo/azure-local/scripts/Test-Day2Readiness.ps1`, `handouts/Day2_Operations_Runbook.md`

### Monitoring: Insights and the cost-conscious DCR

**Goal:** Read the monitoring artefacts.

**In the repo:** `automation/azure-local/cluster-configure/monitoring`

### Update management: the maintenance configuration

**Goal:** Read the maintenance configuration templates.

**In the repo:** `automation/azure-local/cluster-configure/update-manager`

### Backup and DR setup

**Goal:** Read the backup and Site Recovery configuration.

**In the repo:** `automation/azure-local/cluster-configure/backup-asr`

### RBAC with Entra PIM

**Goal:** Read the PIM configuration.

**In the repo:** `automation/azure-local/cluster-configure/access-pim`

### Security and governance baseline

**Goal:** Read the policy initiative.

**In the repo:** `automation/azure-local/cluster-configure/policy`

### Acceptance: the readiness gate, red to green

**Goal:** Understand the evidence states.

**In the repo:** `automation/demo/azure-local/scripts/Test-Day2Readiness.ps1`

### Azure Migrate: VMware to Azure Local (recorded)

**Goal:** Read the migration guide.

**In the repo:** `handouts/Azure_Migrate_to_Azure_Local.md`

### Lifecycle Manager: readiness and history

**Goal:** Understand the update flow.

**In the repo:** `handouts/Day2_Operations_Runbook.md`

### Capacity: a decision, not a chart

**Goal:** Read the capacity method.

**In the repo:** `handouts/Azure_Local_Sizing_Guide.md`

### VM lifecycle through Arc

**Goal:** Read the VM lifecycle steps.

**In the repo:** `handouts/Day2_Operations_Runbook.md`

### Planned ASR failover to Azure: start and result

**Goal:** Read the Site Recovery procedure.

**In the repo:** `automation/azure-local/cluster-configure/backup-asr`

## Watch only

### Fault 1: drive failure (software-induced, live)

**Goal:** Faults are run only on the lab cluster.

**In the repo:** `automation/demo/azure-local/scripts/Invoke-DriveFault.ps1`

### Fault 2: Network ATC intent drift (live)

**Goal:** Faults are run only on the lab cluster.

**In the repo:** `automation/demo/azure-local/scripts/Invoke-IntentDrift.ps1`

### Fault 3: node failure (recorded incident, live commentary)

**Goal:** Not run outside the lab.

