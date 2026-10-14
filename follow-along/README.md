# Follow-along guide — Azure Local, Discovery to Day 2

_Generated from the demo-guide content by `npm run docs`. Mostly watch and read. Full follow-along only where no cluster is needed: the Surveyor assessment on the synthetic workbook, the Trailwright design record and its infrastructure.yml export, and the Bicep what-if. Every other demo is a read-along with the repo path._

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

### Sizing: it fits on paper, then take a node away

**Goal:** Size the synthetic estate plus the new AVD workloads, then see what the node-loss reserve does to the answer.

**You need**

- The Surveyor project from the previous demo
- The second input src/assessment/IIC-new-workloads.csv

**Steps**

1. **Add the new workloads.** Add the seven VMs from IIC-new-workloads.csv to the project next to the RVTools import (they are not in the workbook, so they are not counted twice).
   - You should see: The demand reads 31 VMs, 104 vCPU and 272 GiB.
2. **Size it, then take a node away.** Open Fit & Recommendations with the maintenance reserve off, then turn it on.
   - You should see: Off: it fits across both nodes. On: memory is short, because 272 GiB does not fit one 256 GiB node.
3. **Adjust it.** Try right-sizing (measured P95 instead of allocation), fewer VMs in the first wave, or more memory per node or a third node (Size from workloads). Then open Storage Design and change the storage basis (provisioned or consumed).
   - You should see: The plan fits with the reserve on; planned storage changes with the basis you choose (decimal TB versus TiB).

**Clean up**

- Save or discard the project.

**In the repo:** `handouts/Azure_Local_Sizing_Guide.md`

### Trailwright: the design record becomes infrastructure.yml

**Goal:** Open the IIC design record in Trailwright, let validation catch a bad value, fix it and export the infrastructure file.

**You need**

- A browser
- No cluster and no Azure subscription required
- The IIC Trailwright project from the repo (src/design/trailwright-iic-example.trailwright.json), the same file the presenter opens; or your own design values

**Steps**

1. **Open Trailwright and the IIC project.** Open Azure Local Trailwright (labs.hybridsolutions.cloud/azurelocal-trailwright) and open the IIC project file from the repo (src/design/trailwright-iic-example.trailwright.json). To use your own design instead, start a new project with a connected, hyperconverged deployment of two machines.
   - You should see: The project summary shows the IIC answers: nodes, storage, intents, identity, connectivity and landing zone.
2. **Shorten the management pool to five addresses.** In the management network step, change the end address so the IP pool holds only five addresses.
   - You should see: Validation reports that the pool needs at least six contiguous addresses and links the Microsoft Learn source.
3. **Fix the pool and check the design.** Widen the pool to six or more addresses (or restore the original end address), then review the network intents, identity and connectivity steps.
   - You should see: The validation summary has no errors.
4. **Export the infrastructure file.** Export infrastructure.yml (and, if you want, the Bicep parameter starting point) and open it in an editor.
   - You should see: Each design answer appears as a value in the file.

**Troubleshooting**

- A step is missing: it appears only when an earlier answer needs it; check the deployment type and storage connectivity answers.
- The export is a starting point: review every value before you use it with a deployment template.

**Clean up**

- Save the project file locally or discard it; nothing is stored in Azure.

**In the repo:** `src/design/trailwright-iic-example.trailwright.json`, `handouts/Planning_and_Design_Decisions.md`

### Cloud-driven deployment: the what-if

**Goal:** Generate and preview an Azure Local deployment without creating anything.

**You need**

- The repo
- PowerShell 7 with the Az.Accounts and Az.KeyVault modules
- Azure CLI with Bicep
- A subscription (the preview creates nothing)
- Copies of the two example environment files with your values

**Steps**

1. **Prepare the config.** Copy the two example environment files (shared values and Azure Local values) and replace the values with yours: names, nodes, IP pool, VLANs.

   ```powershell
   New-Item -ItemType Directory -Force environment/shared, environment/azure-local | Out-Null
   Copy-Item automation/shared/examples/environment.shared.example.yml environment/shared/environment.yml
   Copy-Item automation/shared/examples/environment.azure-local.example.yml environment/azure-local/environment.yml
   ```

   - You should see: Both files exist under environment/. Edit them before you go on.
2. **Check the config.** Load the automation module and read the Azure Local scope back.

   ```powershell
   Import-Module ./automation/shared/powershell/NIC26.Automation/NIC26.Automation.psd1
   Get-NIC26Config -Scope azure-local | Out-Null
   ```

   - You should see: The command returns without errors.
3. **Sign in.** The what-if runs against your subscription and creates nothing. The script reads through Az PowerShell and runs the what-if with the Azure CLI, so sign in to both.

   ```powershell
   Connect-AzAccount -Subscription <sub>
   az login
   az account set --subscription <sub>
   ```

   - You should see: Get-AzContext and az account show both name your subscription.
4. **Run the validate pass as a dry run.** Run the Validate pass without -Execute. It generates the parameter files, builds the templates and runs a what-if.

   ```powershell
   ./automation/azure-local/cluster-deploy/scripts/Invoke-ClusterDeploy.ps1 -Pass Validate -Tool Bicep
   ```

   - You should see: The template build passes and a what-if result is printed; no resources were created.
5. **Read what the what-if cannot see.** Compare the output with the Environment Checker results. Platform-side checks run only during the Validate pass in Azure.
   - You should see: You can list one check the what-if does not cover.

**Troubleshooting**

- Missing providers: register the resource providers listed in the landing-zone README first.
- Input file not found: run the script without -Stage, so the Generate stage writes the parameter files first.
- az exited with code 1 or No Az context: sign in with az login and Connect-AzAccount.

**Clean up**

- None; nothing was created.

**In the repo:** `automation/azure-local/cluster-deploy/README.md`, `automation/azure-local/cluster-deploy/bicep`

## Read along

### Azure Migrate discovery (animation)

**Goal:** Understand the Azure Migrate discovery route to Azure Local.

**Steps**

1. **Read the overview and prerequisites.** Read the Azure Migrate overview for VMware to Azure Local (https://learn.microsoft.com/azure/azure-local/migrate/migration-azure-migrate-vmware-overview) and the prerequisites (https://learn.microsoft.com/azure/azure-local/migrate/migrate-vmware-prerequisites): the Azure Migrate project is created in the Azure portal, and the Azure Local instance needs a logical network and a storage path.
   - You should see: You can list the source-side and target-side prerequisites.
2. **Read the discovery steps.** Read Step 1 of 'Discover and replicate VMware VMs' (https://learn.microsoft.com/azure/azure-local/migrate/migrate-vmware-replicate): project key, source appliance, VDDK 8.0.x, vCenter credentials, onboarding to Azure Local, Start discovery.
   - You should see: You know why agentless dependency analysis is switched off on this route.

**In the repo:** `handouts/Azure_Migrate_to_Azure_Local.md`

### Whole-site fabric evidence and Network ATC intent design

**Goal:** Trace reviewed whole-site evidence into the approved intent design without overwriting decisions.

**In the repo:** `handouts/Planning_and_Design_Decisions.md`, `handouts/Network_ATC_Design.md`

### Beacon: the pre-deployment check before any OS (recorded)

**Goal:** Understand what a pre-deployment check covers before any OS is installed.

**In the repo:** `handouts/Deployment_Guide.md`

### Two routes: ZTP simplified provisioning (recorded) and the route B build plan (live)

**Goal:** Compare the two provisioning routes and what each needs before the cloud deployment.

**In the repo:** `handouts/Deployment_Guide.md`

### Sonar: the recorded real deployment, replayed step by step beside the time-lapse

**Goal:** See what a cloud deployment of Azure Local does step by step, replayed from a recording, and where its logs are.

**In the repo:** `automation/azure-local/cluster-deploy/README.md`

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

### Security baseline as production: Policy, Defender for Cloud and Sentinel

**Goal:** Read the policy initiative.

**In the repo:** `automation/shared/security`, `automation/azure-local/cluster-configure/policy`

### Workload platform: SDN enabled by Arc, six logical networks and their NSGs

**Goal:** Read how logical networks and network security groups are defined for each workload tier on an Azure Local instance with SDN enabled by Azure Arc.

**In the repo:** `automation/azure-local/cluster-configure`

### Acceptance: the readiness gate, red to green

**Goal:** Understand the evidence states.

**In the repo:** `automation/demo/azure-local/scripts/Test-Day2Readiness.ps1`

### Azure Migrate: VMware to Azure Local (animation)

**Goal:** Read the migration procedure end to end.

**Steps**

1. **Replicate.** Read Steps 2 and 3 of 'Discover and replicate VMware VMs' (https://learn.microsoft.com/azure/azure-local/migrate/migrate-vmware-replicate): target appliance, replicate (up to 10 VMs per batch; logical network, storage path, VHDX), seed disks, Ready to migrate.
   - You should see: You know what the storage account holds (metadata only) and where the disk data goes.
2. **Migrate, verify, complete.** Read 'Migrate VMware VMs to Azure Local' (https://learn.microsoft.com/azure/azure-local/migrate/migrate-vmware-migrate): migrate with the source shut down, verify in the portal and the guest, Complete migration, clean up, enable guest management.
   - You should see: You can say why Complete migration matters (seed disks and replication state).
3. **Check the limits.** Read the migration FAQ (https://learn.microsoft.com/azure/azure-local/migrate/migrate-faq): batches, boot type, static IPs, Arc agent reuse. Hyper-V sources follow the same pattern as a preview (https://learn.microsoft.com/azure/azure-local/migrate/migration-azure-migrate-overview).
   - You should see: You know which source VMs need preparation (BitLocker, shared disks, Linux integration services).

**In the repo:** `handouts/Azure_Migrate_to_Azure_Local.md`

### Lifecycle Manager: readiness and history

**Goal:** Understand the update flow.

**In the repo:** `handouts/Day2_Operations_Runbook.md`

### Signal to diagnosis: the Observability Agent investigates the drive fault (preview)

**Goal:** Investigate an Azure Monitor alert with the Azure Copilot Observability Agent (preview) in your own subscription.

**You need**

- Access to Azure Copilot in your tenant
- An Azure Monitor workspace associated with the subscription (it holds the issues)
- Issue Contributor, Monitoring Contributor or Contributor on that workspace to save an issue
- A fired Azure Monitor alert in a region where the agent is available

**Steps**

1. **Start an investigation from an alert.** Open a fired alert in Azure Monitor > Alerts and select Investigate. Confirm the scope the agent proposes.
   - You should see: The agent reports its plan, then findings, hypotheses ruled out and next steps.
2. **Keep the result.** Select Create issue to save the investigation as an Azure Monitor issue in your Azure Monitor workspace.
   - You should see: The issue is listed under Monitor > Issues with the investigation attached.

**Troubleshooting**

- Asked for an Azure Monitor workspace: associate the subscription with one (once per subscription).
- No Investigate action: check that your account has Azure Copilot access.

**Clean up**

- Close or delete test issues; chat and investigations are billed per use.

### Fault 3: node failure (animation)

**Goal:** Read what a node failure does on a two-node instance and how to prove recovery.

**Steps**

1. **Quorum.** Read 'Understanding cluster and pool quorum' (https://learn.microsoft.com/windows-server/storage/storage-spaces/quorum): two nodes with a witness survive one node failure, not a second.
   - You should see: You can say why a two-node instance needs a witness.
2. **VMs and GPUs.** Read 'Virtual machine resiliency for Azure Local' (https://learn.microsoft.com/azure/azure-local/manage/disaster-recovery-vm-resiliency) and the DDA note in 'Use GPUs with clustered VMs' (https://learn.microsoft.com/windows-server/virtualization/hyper-v/deploy/use-gpu-with-clustered-vm).
   - You should see: You know why a node failure restarts VMs instead of live-migrating them, and where a DDA VM can restart.
3. **Storage resync and the checks.** Read 'Understand and monitor storage resync' (https://learn.microsoft.com/windows-server/storage/storage-spaces/understand-storage-resync) and the resume and resync steps of 'Failover cluster maintenance procedures' (https://learn.microsoft.com/azure/azure-local/manage/maintain-servers).
   - You should see: You can name the commands that prove recovery: Get-StorageJob empty, Get-VirtualDisk Healthy.

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

