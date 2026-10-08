# lz-azure-local — Azure Local landing zone

Implements design/azure-local/landing-zone.md §10 (stages S-1..S9) under the rules of automation/CONTRACT.md. Bicep is the demo path; Terraform is the parity path (D-025). Nothing in this folder deploys by itself: every script defaults to **what-if** and needs `-Execute` (owner approval) to change anything.

## What it deploys

| Stage | Design | Resources (names from the `names:` catalog in `solution.yml`) | Bicep | Terraform |
|---|---|---|---|---|
| S-1 Decommission | §10.2, P-10 | Removes the PREVIOUS deployment from the subscription — review run first, then only hash-verified, owner-approved items, layer by layer, with lock/Key Vault/resource-group safeguards and an audit file | `scripts/Remove-PreviousAzureLocalDeployment.ps1` | same |
| S0 Bootstrap | §10.2 | Providers + `AzureLocalZTP` feature, Entra groups, `rg_sec` + Terraform state storage `st_tfstate` | `scripts/Register-LzProviders.ps1`, `scripts/New-LzEntraGroups.ps1`, `bicep/bootstrap.bicep` | same scripts and the same bootstrap template (state storage is needed before the first `terraform init`) |
| S1 Governance | §2, §3 | 7 resource groups, allowed-locations (Deny), require-tag (Deny on RGs) and inherit-tag (Modify) assignments, activity-log DINE assignment + diagnostic setting, budget (50/80/100 % actual, 100 % forecast), Defender CSPM + Servers/KeyVault/Storage plan flags, initiative definition at MG scope | `main.bicep` S1 modules, `initiative.bicep` (MG scope) | `main.tf` |
| S2 Network | §4 | Spoke VNet + 5 subnets, 5 NSGs, route table (no routes, BGP propagation on), own `privatelink.vaultcore.azure.net` zone (P-11) linked to spoke + identity (+ AVD) **only with `enable_private_endpoints=true`** (off by default, D-029), optional Monitor zones, peerings: spoke<->hub (gateway transit), spoke->AVD, spoke<->identity and spoke<->management (P-13, behind flags) | `modules/network.bicep`, `modules/vnet-peering.bicep` | `s2-network.tf` |
| S3 Security | §5, §6, K-1..K-5 | Deployment identity, ops vault (purge protection off) and cluster vault (purge protection on), private endpoints + zone groups only with `enable_private_endpoints=true` (D-029: both vaults public by default), diagnostics, vault RBAC, deployment identity Contributor + constrained RBAC Administrator, readers group roles, PIM eligibilities (script by default) | `modules/security.bicep`, `role-assignment-sub.bicep`, `pim-eligibility*.bicep`, `scripts/Initialize-LzPim.ps1` | `s3-security.tf`, same script |
| S4 Monitoring | §7.1, §7.2 | Log Analytics (30 d, daily cap), action group (e-mail), DCE behind `enable_monitor_private_link` | `modules/monitoring.bicep` | `s4-monitoring.tf` |
| S5 Cluster prerequisites | §9, §6.2 | Witness storage (GPv2, LRS, shared key on, public on), optional voucher storage, RBAC on the cluster RG (lab-operators Owner, admins onboarding roles, Azure Local RP app) | `modules/cluster-prereqs.bicep` | `s5-cluster-prereqs.tf` |
| S6 BC/DR | §8 | Recovery Services vault (LRS, soft delete, identity), ASR cache storage, vault identity Contributor on the DR RG | `modules/bcdr.bicep` | `s6-bcdr.tf` |
| S7 Management | §3, MP-01..MP-04 | Private-only jump server `vm_jump` (WS2025 Azure Edition, Trusted launch, D4s_v5, 256 GiB data disk, AADLoginForWindows + AMA, no public IP) | `modules/management.bicep` | `s7-management.tf` (azapi, see parity gaps) |
| S8 Seeding + lock-down | §10.2 | Manual `Copy-DemoSecrets.ps1` on the jump server; then S3 re-applied with `kv_public_network_access.ops = Disabled` once DNS resolves privately | orchestrator | same |
| S9 Validation | §11.1 | Read-only checks with exit code | `scripts/Test-LandingZone.ps1` | same |

Shared platform resources (hub, identity and management VNets, DCs, Bastion, P2S) are **inputs**; the only changes to them are the peering resources listed above and the zone link on the identity VNet (LZ-04, P-13).

## Configuration reference

Nothing environment-specific is hard-coded. Every value comes from one of these places; set yours before the first run.

| What | Where to set it | Notes |
|---|---|---|
| Subscription, tenant, regions, address plan, tags, owners | `environment/shared/environment.yml` and `environment/azure-local/environment.yml` (copy from `automation/shared/examples/environment.*.example.yml`) | The examples carry the placeholder organisation (IIC) and documentation-style values; replace all of them. |
| Organisation, lab token, region short code used in every generated name | `org`, `token`, `location_short` in the environment file | Fallbacks if absent: the `NIC26_ORG`, `NIC26_TOKEN`, `NIC26_REGION` environment variables, then `automation/shared/powershell/NIC26.Automation/NamingDefaults.psd1` (example values `iic`, `nic26`, `eus`). |
| Key Vault secret names | `secret_name_prefix` (pattern `<org>-<token>-`) and the `*_secret` inputs, as `keyvault://<vault>/<secret>` references | Secret values are never in a file; they are resolved in memory at run time. |
| Names of resources | The `names:` catalog in each `solution.yml`, resolved by `New-NIC26ResourceName` | Names shown in the documentation are the resolved example names for org `iic`, token `nic26`, region `eus`; yours follow your values. |
| Local-admin user created on the jump server | `-JumpAdminUsername` on `Invoke-LzAzureLocalDeploy.ps1` (default `jumpadmin`; pass the name an earlier run used to keep it) | Its password is generated, stored in the ops vault and never shown. |
| Regions where a preview feature is offered | `-SupportedProvisioningRegions` on `Test-ProvisioningPrerequisites.ps1` | Default is the documented region list; update it when Microsoft Learn changes. |
| Demo users and the sign-in domain | `Demo users` and `tenant_domain` in the environment file | Examples use `contoso.com`. |

## Inputs and outputs

Both tracks declare exactly the manifest inputs (`tests/outputs-parity.Tests.ps1` enforces it). Regenerate this table from the manifest with:

```powershell
Import-Module ..\..\shared\powershell\NIC26.Automation
(Get-NIC26SolutionManifest -Path .\solution.yml).inputs | Select-Object name, type, required, default, source | Format-Table
```

| Input | Type | Default | Notes |
|---|---|---|---|
| `tenant_id`, `subscription_id`, `location`, `org`, `token`, `region_short`, `tags` | string / map | — | Placement (§10.6). Bicep aborts if `subscription_id`/`tenant_id` differ from the deployment context |
| `management_group_id` | string | `""` | Initiative definition stored here (LZ-01); empty skips it |
| `central_log_analytics_workspace_id`, `deploy_platform_scope_items` | str / bool | `""`, `false` | Workload landing zone only: an empty `deploy_platform_scope_items` leaves subscription policy and Defender, the activity-log export, the management-group initiative and the peerings on platform-owned VNets to their owners; a central workspace ID replaces the workload workspace. See landing-zone-placement.md. |
| `budget_monthly_amount`, `budget_contact_emails` | int / list | — (0 skips the budget) | §2.5 |
| `defender_servers_plan`, `enable_defender_keyvault`, `enable_defender_storage` | string / bool | `off` / false / false | §7.3 (P2 is set in Day-2 Ready) |
| `spoke_address_space`, `subnet_*_prefix` (5), `dns_servers` | string / list | — | §4.1 |
| `hub_vnet_id`, `hub_resource_group_name`, `hub_subscription_id`, `bastion_subnet_prefix`, `p2s_client_pool`, `identity_spoke_vnet_id`, `management_spoke_vnet_id`, `onprem_prefixes`, `avd_spoke_vnet_id` | string / list | `avd_spoke_vnet_id = ""` | Shared estate, referenced only. **Leave `avd_spoke_vnet_id` empty**: `lz-avd` creates both sides of the Azure Local to AVD spoke peering, and Azure allows one peering per VNet pair |
| `identity_spoke_prefix`, `management_spoke_prefix`, `avd_spoke_prefix` | string | — / — / `""` | **added**: NSG sources (§4.6 names them; §10.6 had no prefix variables) |
| `enable_identity_peering`, `enable_management_peering` | bool | false | **added** (P-13): the two shared-side peerings need owner change approval |
| `enable_private_endpoints` | bool | false | D-029: no private endpoints; vaults public, no privatelink zones, S8 lock-down skipped |
| `enable_monitor_private_link`, `privatelink_vaultcore_zone_id` | bool / string | false / `""` | §4.5; only used when `enable_private_endpoints` is true; empty zone ID = own zone (P-11) |
| `group_object_ids` | map | — | From `New-LzEntraGroups.ps1` (S0) |
| `pim_max_activation_hours`, `manage_pim_in_iac` | int / bool | 8 / false | PIM is a script by default (requests are not re-runnable in IaC) |
| `kv_soft_delete_days`, `kv_public_network_access`, `azl_rp_app_object_id` | int / map / string | 7 / — / — | §5, §6.2 |
| `law_retention_days`, `law_daily_cap_gb` | int | 30 / 2 | §7.1 |
| `enable_voucher_storage`, `rsv_storage_redundancy` | bool / string | false / LocallyRedundant | §9.2, §8.2 |
| `enable_jump_server`, `jump_vm_size`, `jump_data_disk_gb`, `jump_private_ip`, `jump_encryption_at_host` | bool / string / int / string / bool | true / Standard_D4s_v4 / 256 / `""` / false | MP-02; the last three are **added** |
| `jump_admin_username_secret`, `jump_admin_password_secret` | secret-ref | — | `keyvault://` names only |
| `jump_admin_username`, `jump_admin_password` | secret-ref (generated) | — | **run-time secure parameters**, supplied in memory by the orchestrator, never in a parameter file |
| `enabled_stages`, `names` | list / map | all / generated | **added** orchestration input; name catalog (contract §10) |

Outputs (handoff contract, §10.6/§10.2 plus a few IDs the AVD landing zone and the deploy solution consume): `cluster_resource_group_name`, `witness_storage_account_name`, `witness_storage_account_id`, `kv_ops_id`, `kv_ops_uri`, `kv_azl_id`, `kv_azl_uri`, `log_analytics_workspace_id`, `action_group_id`, `recovery_vault_id`, `dr_resource_group_name`, `asr_subnet_id`, `asr_test_subnet_id`, `deploy_identity_principal_id`, `deploy_identity_id`, `spoke_vnet_id`, `pe_subnet_id`, `jump_subnet_id`, `private_dns_zone_vaultcore_id`, `security_resource_group_name`, `network_resource_group_name`, `monitoring_resource_group_name`, `asr_cache_storage_account_name`, `jump_vm_id`.

## AVM modules (pinned 2026-10-03, resolved from the public registries)

| Component | Bicep `br/public:` | Terraform `Azure/` |
|---|---|---|
| Resource groups | `avm/res/resources/resource-group:0.4.4` | gap-fill `azurerm_resource_group` (design §10.3) |
| VNet + subnets | `avm/res/network/virtual-network:0.10.2` | `avm-res-network-virtualnetwork/azurerm 0.22.2` |
| NSGs | `avm/res/network/network-security-group:0.5.3` | gap-fill `azurerm_network_security_group` |
| Route table | `avm/res/network/route-table:0.5.0` | `avm-res-network-routetable/azurerm 0.5.0` |
| Private DNS zones + links | `avm/res/network/private-dns-zone:0.8.1` | gap-fill `azurerm_private_dns_zone(_virtual_network_link)` |
| Key Vaults (+ private endpoints via the module) | `avm/res/key-vault/vault:0.14.2` | `avm-res-keyvault-vault/azurerm 0.11.0` |
| Log Analytics | `avm/res/operational-insights/workspace:0.16.1` | `avm-res-operationalinsights-workspace/azurerm 0.5.1` |
| Storage accounts | `avm/res/storage/storage-account:0.33.1` | `avm-res-storage-storageaccount/azurerm 0.10.0` |
| Recovery Services vault | `avm/res/recovery-services/vault:0.13.2` | `avm-res-recoveryservices-vault/azurerm 1.3.2` |
| Jump server | `avm/res/compute/virtual-machine:0.22.3` | azapi `Microsoft.Compute/virtualMachines@2024-07-01` + `azurerm_network_interface` / `azurerm_virtual_machine_extension` (see parity gaps) |

Providers: `azurerm >= 4.81.0, < 5.0.0` (the window the pinned AVM modules accept — keyvault 0.11.0 needs >= 4.81, workspace 0.5.1 needs < 5.0), `azapi ~> 2.12`, `random ~> 3.9`, `time ~> 0.14`; Terraform >= 1.11 (ephemeral variables + write-only `sensitive_body`).

### Gap-fill modules (`bicep/modules/`, written here because `automation/shared` is owned by the shared-module agent)

| Module | Why gap-fill |
|---|---|
| `user-assigned-identity.bicep` | design §10.3 lists no confirmed AVM (registry has `avm/res/managed-identity/user-assigned-identity:0.6.0`, recorded as upgrade option) |
| `budget.bicep` | no confirmed AVM (`avm/res/consumption/budget:0.3.8` exists) |
| `action-group.bicep`, `data-collection-endpoint.bicep` | no confirmed AVM (`avm/res/insights/action-group:0.8.0`, `avm/res/insights/data-collection-endpoint:0.5.1` exist) |
| `governance-policy.bicep`, `policy-initiative.bicep`, `policy-definitions.bicep` | no AVM for policy assignments/sets (registry 404) |
| `role-assignment-sub.bicep`, `role-assignment-rg.bicep`, `built-in-roles.bicep` | no AVM for standalone role assignments at subscription/RG scope |
| `pim-eligibility.bicep`, `pim-eligibility-rg.bicep` | no AVM for `roleEligibilityScheduleRequests` |
| `defender-pricing.bicep` | no AVM resource module for `Microsoft.Security/pricings` (only the `avm/ptn/security/security-center` pattern) |
| `activity-log-diagnostics.bicep` | subscription-scope diagnostic setting |
| `vnet-peering.bicep` | peerings kept outside the VNet module to order VNet -> remote side -> local side across subscriptions |

Terraform gap-fill resources: `azurerm_resource_group`, `azurerm_network_security_group`, `azurerm_private_dns_zone*`, `azurerm_virtual_network_peering` (aliased providers for the hub/identity/management sides), `azurerm_user_assigned_identity`, `azurerm_role_assignment`, `azurerm_pim_eligible_role_assignment`, `azurerm_consumption_budget_subscription`, `azurerm_subscription_policy_assignment`, `azurerm_policy_set_definition`, `azurerm_security_center_subscription_pricing`, `azurerm_monitor_action_group`, `azurerm_monitor_data_collection_endpoint`, `azurerm_monitor_diagnostic_setting`, `azapi_resource` (VM).

## Parity gaps

1. **Jump-server password handling.** Bicep passes it as a `@secure()` parameter (never in deployment history). The azurerm VM resource in the pinned provider line has no write-only password argument, so Terraform creates the VM with `azapi_resource` and `sensitive_body` (write-only): the ephemeral `jump_admin_username/password` never reach plan or state. This is a different resource type, not a different resource.
2. **PIM eligibility in IaC** (`manage_pim_in_iac = true`): Bicep submits `roleEligibilityScheduleRequests` (one-shot; re-deploying an existing eligibility fails), Terraform uses `azurerm_pim_eligible_role_assignment` (re-runnable). Default for both tracks is `scripts/Initialize-LzPim.ps1`.
3. **Initiative definition.** Bicep needs a separate MG-scope entry point (`initiative.bicep`, run by the orchestrator); Terraform defines it inline. Both contain only the built-in members of design §7.4; the two custom Azure Local Insights definitions and the Key Vault backup-extension audit are imported in Day-2 Ready.
4. **Policy assignments per tag** are named `<catalog name>-<index>` in both tracks (the built-in definitions take one tag each) — a documented deviation from "IaC never builds a name".
5. **Peerings** use a raw resource in both tracks instead of the AVM VNet module's peering children (ordering across subscriptions). Terraform names the hub side with the catalog like Bicep.
6. **Private DNS zone links on a reused shared zone** are not created by either track (the zone owner's change); with `privatelink_vaultcore_zone_id = ""` (P-11 default) the lab's own zone and its links are created.

## How to run

```powershell
Import-Module ..\..\shared\powershell\NIC26.Automation
$cfg = Get-NIC26Config -Scope azure-local                        # validates environment/azure-local/*.yml
ConvertTo-NIC26BicepParam -Solution . -Config $cfg -Execute      # -> bicep/main.generated.bicepparam (git-ignored)
ConvertTo-NIC26TfVars     -Solution . -Config $cfg -Execute      # -> terraform/terraform.generated.tfvars.json

.\scripts\Invoke-LzAzureLocalDeploy.ps1 -Config $cfg                       # WHAT-IF of S0..S9 (default, Bicep)
.\scripts\Invoke-LzAzureLocalDeploy.ps1 -Config $cfg -Tool Terraform -BackendConfig ..\..\..\environment\azure-local\tf-backend.hcl
.\scripts\Invoke-LzAzureLocalDeploy.ps1 -Config $cfg -Stage S0 -Execute    # owner approval first
.\scripts\Invoke-LzAzureLocalDeploy.ps1 -Config $cfg -Stage S1,S4,S2,S3,S5,S6,S7 -Execute
.\scripts\Test-LandingZone.ps1 -Config $cfg -ExpectDnsPrivate              # S9, read-only, exit code = failed checks
.\scripts\Install-JumpTools.ps1 -Only git, terraform                        # plan only (default); add -Execute in an elevated session on the jump server
.\scripts\Install-JumpTools.ps1 -Execute                                    # install every pinned tool machine-wide; versions are in scripts\jump-tools.versions.psd1
```

S-1 (decommission) is never in the default stage set. `.\scripts\Remove-PreviousAzureLocalDeployment.ps1 -SubscriptionId <id>` (review run) enumerates every resource of that subscription — ordered dependency layers, unknown types in layer 800 with a blocker note, resource groups in layer 999 — inspects locks, Key Vault soft-delete/purge-protection state and Arc extensions, and writes the candidate file (generated timestamp + SHA-256 of the item list) plus an audit JSON. The owner sets `approved: true` per item (`removeLock: true`, `acknowledgePermanent: true` where flagged). `-Execute -ConfirmDeleteList <edited file>` re-validates the file (same subscription, same hash as the live enumeration, < 24 h unless `-AllowStaleList`, objects only — a bare ID is not an approval), re-checks every item live, deletes layer by layer, polls until each resource is gone (`-DeleteTimeoutMinutes`), stops at the first failure (`-ContinueOnError`), never removes a lock unless `-RemoveLocks` + `removeLock: true` (restored if the delete fails), purges vaults only with `-PurgeKeyVaults` when purge protection is off, and deletes resource groups only in a second phase (`-DeleteEmptyResourceGroups`, verified empty). `-WhatIf` on an `-Execute` run validates everything and deletes nothing. Every run writes `decommission-audit-<utc>.generated.json`.

The orchestrator generates the jump-server local-admin credential on the first S7 `-Execute`, writes it to the ops vault (`<secret_name_prefix>jump-local-admin-*`) and hands it to the deployment in memory; it must run on Windows (the jump server for every later stage, K-8). `Start-Transcript` is refused.

## How to destroy

`.\scripts\New-LzTeardownPlan.ps1 -Config $cfg` writes the ordered plan (S9..S1, design §10.4) without deleting anything; `-Execute` performs it: management RG, BC/DR (vault must be empty), witness (only when no cluster exists; lock removed), monitoring, ops vault deleted **and purged**, cluster vault deleted (purge after the 7-day retention), remote-side peerings on the shared VNets, network RG, policy assignments, budget, DR RG. The security RG is kept until the cluster vault can be purged (`-IncludeSecurityResourceGroup` overrides). Copied credentials are rotated in their source systems at lab close (manual, listed in the plan).

## Manual steps

PIM role settings (8 h, MFA, justification) and a test activation; owner change approval and rights for the hub, identity and management peerings and the identity zone link; DC conditional forwarders `vault.azure.net` -> `168.63.129.16` (P-07); P2S profile re-import with the DC DNS servers after every peering change (C-06); `Copy-DemoSecrets.ps1` on the jump server (S8); HCS env-name registry PR for `tp`/`nic26` before the first secret; Day-2 Ready: initiative assignment, Defender for Servers P2, Insights DCR, maintenance configuration, ASR/backup policies.

## Tests and gates

`Invoke-Pester .\tests` runs: `Scripts.Tests.ps1` (what-if defaults, delete refused without the approved list, never outside the subscription, no credential output), `bicep-build.Tests.ps1`, `terraform-validate.Tests.ps1`, `outputs-parity.Tests.ps1` (outputs, inputs, name catalog, example coverage), `secrets-sweep.Tests.ps1` (GUID / IP / vendor-name / token sweep per contract §8 with the documented allow-list: all-zero and single-digit test GUIDs, the built-in role/policy constants in `bicep/modules/built-in-roles.bicep` and `policy-definitions.bicep`, documentation IP ranges, `168.63.129.16`). PSScriptAnalyzer uses `automation/shared/powershell/PSScriptAnalyzerSettings.psd1`.

## Design links

§2 governance, §3 resource groups, §4 network, §5 Key Vaults (keyvault-and-secrets.md), §6 identity, §7 monitoring, §8 BC/DR, §9 storage, §10 implementation sequence, §11 validation; naming-standard.md; decisions.md P-10, P-11, P-13; management-plane.md MP-01..MP-05; connectivity.md C-02, C-06.

## Operational limits (review R-34)

- **Budget:** it sends notifications at 50/80/100 % actual and 100 % forecast; it stops nothing. Delete the lab (the teardown plan) or deallocate the VMs yourself; deallocation does not stop disks, Bastion, storage, logging or Site Recovery charges. The Bicep start date defaults to the first of the current month at deploy time; Learn allows a start date in the current month only, so a redeploy in a later month moves it (the Terraform track keeps the first value). If Azure rejects the update, delete the budget with owner approval and redeploy.
- **Recovery vault diagnostics** use two settings, as Learn requires: Azure Diagnostics mode for the legacy categories and resource-specific mode only for `AzureSiteRecoveryJobs` and `ASRReplicatedItems`. Sending the legacy ones resource-specific would stop that data.
- **Jump server:** it is the one place every secret is resolved, so it concentrates risk. Keep individual Entra accounts with MFA, treat the local administrator as break-glass (alert on use, rotate after use, destroy at teardown), keep a tested rebuild procedure, and give its managed identity only the vault roles it needs.
- **Public endpoints** (workspace, recovery vault, ASR cache account with shared key) are accepted for a short-lived, non-sensitive lab with least-privilege RBAC and MFA. Disable anonymous blob access (already off), never output account keys, and test replication before tightening the cache account's network rules.

### Windows App package pin and provisioning

Windows App uses a directly downloaded, signed x64 MSIX rather than an unversioned Store install. The version and SHA-256 of the main package and all three framework packages are in `scripts/jump-tools.versions.psd1`. The installer acquires dependencies through Microsoft's documented `winget download` route; it validates every hash, signature and manifest identity before changing package state. The official direct-download link and Store catalog can change: different bytes fail closed and require a reviewed pin update. Downloaded packages are retained in a uniquely named temporary staging directory for troubleshooting.

Windows App inventory requires elevation for online DISM and all-user framework queries, including a plan-only run selecting this tool. The success check requires the exact main provisioning identity and the pinned framework inventory. Provisioning is intended for new profiles; it does not register the app for every existing profile or prove that a user can launch and sign in. Existing-profile registration, a fresh-profile launch, optional WebView2 functionality, Store licensing/connectivity and automatic-update behavior remain live acceptance checks in T-3.1.3b. Do not treat a successful download, current-user package or inventory entry as proof of these checks.

Microsoft sources: [Windows App dependency acquisition](https://learn.microsoft.com/en-us/windows-app/troubleshoot-basic), [Windows App release history](https://learn.microsoft.com/en-us/windows-app/whats-new).

### Azure CLI extension scope

Extensions use `az extension add --system` and the trusted Windows MSI CLI system directory. Inventory rejects a same-version extension reported from a user profile or an unexpected directory. The execution wrapper temporarily selects the trusted system directory and restores the previous process setting even on failure; it does not relocate `AZURE_CONFIG_DIR` or share authentication caches. A user extension can shadow the system copy; a shadowed bootstrap inventory remains noncompliant, and actual presenter-profile command resolution still needs live verification. The resolver supports the Windows MSI `wbin/az.cmd` layout and fails closed for an unrecognized or user-profile CLI installation.

Bicep now uses the pinned standalone x64 Microsoft binary in the protected Program Files JumpTools/Bicep directory. Both download and copied target must match the SHA-256, Microsoft signer and version before machine PATH and AZURE_BICEP_USE_BINARY_FROM_PATH=true are set. Directory and file permissions allow ordinary users to read/execute and administrators/System to write; target reparse points are rejected. Inventory requires the explicit binary and machine settings, not a same-version user-profile CLI copy. The current installer process receives the path/setting immediately; other profiles need a fresh sign-in and live Azure CLI command-resolution verification. AZURE_CONFIG_DIR remains per-user. This structural check does not prove cross-profile runtime acceptance. The WSL scope decision in R-160 remains open. See [Microsoft's system extension option](https://learn.microsoft.com/en-us/cli/azure/extension?view=azure-cli-latest#az-extension-add).
