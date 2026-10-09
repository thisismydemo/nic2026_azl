# Azure Local: Deployment Guide

From a completed design package to a running cluster, deployed from the cloud with Local Identity and Azure Key Vault. The guide follows the order of work: gates, Azure foundation, site readiness, node registration, the two deployment passes, and validation.

**Status:** prepared 2026-10-06 against Microsoft Learn (2609 release family). Where a step depends on your release, hardware or tenant, the text says so. Preview features are labelled **preview**.

## Before you start

Deployment is the point at which every earlier decision becomes a value. Do not start until the planning gate in the planning handout is green and the deployment configuration file (the session repo uses `infrastructure.yml`) is populated.

### Deployment gate

Deployment starts only when all of the following are true:

- [ ] Landing zone resources exist and the required resource providers are registered (`Microsoft.Insights` is required; without it the diagnostic account and Key Vault audit logging fail validation)
- [ ] The deployment identity holds its roles (see Permissions)
- [ ] The Key Vault and the witness storage account exist (a witness storage account cannot be shared between systems in the current release)
- [ ] Firmware is at the baseline from the hardware decision
- [ ] Switches and firewall are configured and the Environment Checker passes
- [ ] The OS is installed on every node with a static IP, DNS, NTP and the local administrator account
- [ ] SSH is enabled on every node
- [ ] Every node is registered with Azure Arc and shows as ready

## Permissions

| Scope | Role | Why |
|---|---|---|
| Subscription | Contributor and User Access Administrator (for the person registering and deploying) | To Arc-enable the machines and assign roles |
| Registration resource group | Azure Connected Machine Onboarding; Azure Connected Machine Resource Administrator | Arc registration |
| Registration resource group | Azure Stack HCI Administrator; Reader | Deploying and managing the instance |
| Resource group | Key Vault Data Access Administrator; Key Vault Secrets Officer; Key Vault Contributor | Manage and write secrets in the deployment vault |
| Resource group | Storage Account Contributor | Create the storage accounts used by the deployment |

Once you select a subscription and deploy, the only way to change the subscription is to redeploy. For the template deployment, look up the object ID of the Azure Local resource provider's service principal in your tenant; it is unique per tenant.

## Step 1: Build the Azure foundation

Create, from code, the resources the design describes: resource groups; resource provider registrations; a Log Analytics workspace; a Key Vault; the witness storage account; the spoke network and its peering; tags and budgets. The session repo does this with Bicep so the same package runs again for a second site. Idempotent by design: running it twice changes nothing.

## Step 2: Make the site ready

- **Physical:** racked, powered and cabled to the port map; the out-of-band management network reachable.
- **Firmware:** BIOS, BMC, network adapters, drives and the OEM solution extension at the baseline; switch and firewall operating systems at the planned versions.
- **Network:** VLANs and MTU per design; data center bridging only where the RDMA mode requires it; LLDP enabled; firewall allow-list applied; DNS zone and NTP reachable. The management VLAN must be set on the physical adapters before Arc registration and cannot be changed after deployment.
- **Nodes:** OS installed from the chosen release; static IP address, gateway and DNS set (for example with SConfig); one local administrator account that is not the built-in Administrator, with identical credentials on every node and a password of at least 14 characters with lower case, upper case, a digit and a special character; SSH enabled.
- **Validate:** run the Environment Checker standalone for connectivity, hardware and OS readiness before anyone registers a node. It checks, among other things, ICMP from the management IP pool to the default gateway.

**IP planning rules (Microsoft Learn):** the management IP pool is at least six consecutive addresses on the nodes' subnet, outside the node addresses, with a gateway that reaches Azure; nothing in the infrastructure may use `10.96.0.0/12` or `10.244.0.0/16`; DNS servers used by the nodes and the Arc Resource Bridge cannot be changed after deployment.

### WinPE evidence and intended OS-disk handoff

Before provisioning, the requested workflow includes a non-destructive WinPE checkpoint. The tool is tentatively called Beacon; its exact repository/version, supported hardware/checks, networking and disk-discovery responsibilities, upload behavior and provisioning consumer must be verified before this workflow is treated as implemented.

- Review per-node networking/firewall probe results with collection time and the exact path tested. A successful probe does not establish every firewall rule or full site readiness.
- Verify the approved Azure Storage evidence destination, authentication and sanitized upload receipt. Keep credentials out of files, boot images, transcripts, screenshots and public examples; document actual failure handling.
- Match the intended OS media using node identity, disk serial or unique ID and controller/location against reviewed inventory. Pass the verified identity through the actual supported output format to the provisioning consumer.
- Stop when targets are ambiguous or evidence is missing. Never select a disk using disk number or capacity alone. The discovery checkpoint performs no destructive disk operation.

This is a planning and acceptance requirement. Exact tool support, upload and disk handoff remain unverified until the checks run and evidence is recorded; a presentation slide or simulated example is not runtime proof.

## Step 3: Install the OS and register the nodes

**Supported route:** install the Azure Stack HCI OS on each node from the release media, then register each node with Azure Arc using the Configurator app or the registration script. Choose the registration variant that matches your outbound design: without proxy, with proxy, or with the Arc gateway (the Arc gateway must be chosen now; it cannot be enabled after deployment).

**Preview alternative:** simplified machine provisioning mounts a maintenance-environment ISO through the BMC virtual media, uses an ownership voucher per node, and lets Azure install the OS and connect Arc. It is a **preview**, supported only on listed hardware, and its limitations (for example regarding the Arc gateway) must be checked against your version. The session's exact hardware/release/connectivity support review and execution evidence remain pending; do not treat an unsupported lab path as a deployment recommendation or claim a successful deployment without evidence.

Verify before moving on: every node appears in the registration resource group as an Arc machine, ready for deployment, and all machines run the same OS version with the same network adapter configuration.

## Step 4: Deploy from Azure

Deployment runs in two passes of the same definition.

| Pass | What it does | Typical duration |
|---|---|---|
| **Validate** | Creates the remaining prerequisite resources, runs the Environment Checker and the deployment validation | About 10 minutes |
| **Deploy** | Builds the cluster, the storage pool and infrastructure volume, applies the network intents, deploys the Arc Resource Bridge and management stack (40 to 45 minutes on its own), creates the custom location and writes secrets to Key Vault | 2.5 to 3 hours |

Use the portal wizard for the first deployment and the Resource Manager template for repeats (Microsoft recommends this order). In the portal: Azure Local, Create instance; choose subscription, resource group, instance name and region; choose **Standard** or **Rack aware**; choose the identity provider **Local Identity with Azure Key Vault**; add the machines.

### Local Identity bootstrap

No Active Directory prerequisites were built. The deployment trusts the local administrator and backs secrets up to Key Vault. In the wizard:

1. **Networking:** enter the zone name (the cluster's DNS namespace) and the DNS server details. With an existing DNS server, create host (A) records for each node and one for the system, using the first address of the management range. The internal DNS option is a **preview** and is for cluster infrastructure only, not for workload DNS.
2. **Management:** select Local Identity with Azure Key Vault and an existing or new vault. One vault per cluster.
3. **Security:** the recommended security level enforces the platform security settings and drift control.
4. **Advanced:** choose how to create workload volumes; creating only the infrastructure volume and building workload volumes afterwards keeps Day 2 reproducible.

### One configuration file drives both routes

In the session repo the path is: deployment configuration file, then a parameter generator, then the Bicep or template package. Cluster name, nodes, identity provider (`LocalIdentity`), Key Vault, witness, intents and VLANs, management IP pool, security level and tags all come from it. The resource shapes follow the quickstart template for Local Identity with Key Vault; template parameters include `identityProvider`, `securityLevel`, `arcNodeResourceIds`, `hciResourceProviderObjectID` and the infrastructure network block.

### Preview what will change

Run a what-if of the template against the target resource group. It is read-only. State what it cannot validate: platform-side checks, the Environment Checker, and anything created during the Validate pass.

## Step 5: Verify the network intents

The intents from the design are applied by the deployment and enforced afterwards. Check on a node:

```powershell
Get-NetIntentStatus | Format-List Host, IntentName, ConfigurationStatus, ProvisioningStatus
```

`ConfigurationStatus` must be `Success` for every intent on every node. Also confirm the virtual switches, RDMA and data center bridging settings on the storage adapters, jumbo frames, and the storage VLANs.

## Step 6: Post-deployment tasks and validation

Finish the platform:

- Confirm quorum with the cloud witness.
- Review the storage pool; create workload volumes and storage paths. Do not place workloads on the infrastructure volume.
- Download VM images and create logical networks for the workload VLANs; add network security groups where the design calls for them.
- Verify the Arc Resource Bridge and the custom location.

### Validation board

| Check | Expected |
|---|---|
| Nodes | Up |
| Witness | Online |
| Storage | Healthy, no faults |
| Network intents | Success |
| Arc Resource Bridge | Running |
| Custom location | Present |
| Arc extensions | Present on every node |
| Identity | Identity mode is Local Identity; nodes are in a workgroup; secrets are present in the vault |

The session repo includes a read-only post-deployment test that checks these items.

## What deployment does not give you

A healthy deployment is not a Day-2-ready platform. Monitoring, update management, backup, access, security and governance are not configured yet. See the Day-2 readiness checklist and the operations runbook.

## Common deployment failures

See the troubleshooting guide for symptoms, causes and actions. The most frequent: a missing `Microsoft.Insights` registration, address ranges overlapping the reserved Kubernetes ranges, a built-in Administrator account used as the local administrator, DHCP-addressed nodes under Local Identity, a witness storage account reused by another system, and firewall rules missing before Arc registration.
