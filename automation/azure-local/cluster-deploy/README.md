# cluster-deploy — Validate and Deploy `nic26-clus01` from Azure (Local Identity + Key Vault)

Implements outline §2.4–2.6, landing-zone design §5.3 / §5.5 / §9.2, network design §4 / §6 (review R-03) and decisions D-008, D-019, D-024, D-025. Contract: automation/CONTRACT.md.

**What it does.** Two passes of one template at resource-group scope (`rg-iic-nic26-azl-eus-01`):

| Pass | Creates / does | Duration (Learn) |
|---|---|---|
| `Validate` | `Microsoft.AzureStackHCI/edgeDevices` (one per Arc node), the cluster resource (system-assigned identity, `secretsLocations` → cluster vault), the RBAC the deployment needs, the Key Vault audit-log storage account `stiicnic26diageus01` (locked), `deploymentSettings/default` with `deploymentMode=Validate` → remaining prerequisites + Environment Checker | about 10 min |
| `Deploy` | Re-PUTs `deploymentSettings/default` with `deploymentMode=Deploy` → cluster, S2D pool + infrastructure volume, Network ATC intents, Arc Resource Bridge, custom location `cl-iic-nic26-azl-eus-01`, Key Vault backup extension | 2.5–3 h ("Deploy Moc and ARB Stack" 40–45 min) |

Nothing here deploys by itself: `Invoke-ClusterDeploy.ps1` stops after what-if / plan unless `-Execute` is given (owner approval).

## Source of truth for the resource shapes

Learn: [Deploy using local identity with Key Vault via ARM template (azloc-2609)](https://learn.microsoft.com/azure/azure-local/deploy/deployment-local-identity-with-key-vault-template?view=azloc-2609) → quickstart `microsoft.azurestackhci/create-adless-cluster-external-dns-public-preview`. From that template (read 2026-10-03): `edgeDevices`, `clusters`, `clusters/deploymentSettings` at **api-version `2025-09-15-preview`**; `identityProvider: LocalIdentity`; `infrastructureNetwork[0].dnsServerConfig = UseDnsServer` and `dnsZones = [{ dnsZoneName, dnsForwarder: [] }]`; `secrets[]` = `{ secretName, eceSecretName, secretLocation }` with the **ECE names `LocalAdminCredential` and `WitnessStorageKey` only** (values `base64(user:password)` and `base64(key)`; Key Vault secret names `<cluster>-LocalAdminCredential`, `<cluster>-WitnessStorageKey`). Role assignments the quickstart creates: Azure Connected Machine Resource Manager → Azure Local RP app (RG); Azure Stack HCI Device Management, Azure Stack HCI Connected InfraVMs (RG) and Key Vault Secrets Officer + Certificates Officer → each node identity. Cluster resource and edge devices are created in the Validate pass only.

## AVM status

| Need | Bicep | Terraform |
|---|---|---|
| Cluster + deployment settings | `avm/res/azure-stack-hci/cluster` 0.6.0 exists but **requires `domainFqdn` / `domainOUPath`** and has no `identityProvider` / `dnsZones` → cannot express Local Identity. **Raw resources** (`bicep/main.bicep`) | `Azure/avm-res-azurestackhci-cluster` 2.0.2 requires `domain_fqdn`, `adou_path`, `deployment_user*`, `service_principal_*`, has no Validate/Deploy selector and creates its own vault/witness by default (LZ-05 conflict) → **azapi** against the same types (`terraform/main.tf`) |
| Audit-log storage account | `avm/res/storage/storage-account:0.33.1` (confirmed, pinned) | gap-fill `azurerm_storage_account` + `azurerm_management_lock` (same shape) |
| Role assignments, diagnostic setting | raw `Microsoft.Authorization/roleAssignments@2022-04-01`, `Microsoft.Insights/diagnosticSettings@2021-05-01-preview` | `azurerm_role_assignment`, `azurerm_monitor_diagnostic_setting` |

**Parity gaps.** (1) The Bicep track creates the cluster resource and edge devices only when `deployment_mode = Validate` (quickstart behaviour); Terraform keeps them in state across both passes with `ignore_changes = [body]`, so the Deploy pass never re-PUTs them — same effect, different mechanism. (2) `terraform apply` blocks for the whole Deploy pass (azapi timeout 4 h) while the Bicep path submits with `--no-wait` and polls. (3) Storage account: AVM in Bicep, native in Terraform.

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

## Inputs → template mapping (from `environment/azure-local/*.yml`)

| Template field | Input | Value in this design |
|---|---|---|
| `networkingType` / `networkingPattern` | `networking_type`, `networking_pattern` | `switchedMultiServerDeployment`, **`custom`** (three intents; `hyperConverged` = one converged intent, R-03) |
| `intentList` | `intents[]` | Management (`NIC1`,`NIC2`), Compute (`SLOT 3 Port 1`,`SLOT 6 Port 2`), Storage (`SLOT 3 Port 2`,`SLOT 6 Port 1`); jumbo 9014 and RDMA on Storage only; QoS 3/7/50 % from `qos`; `networkDirectTechnology` = **`rdma_protocol` (string, empty = Network ATC detection)** |
| `storageNetworkList` | `vlans.storage_a/.storage_b`, `nodes[].storage_ips` | VLAN 711 → 172.30.71.x, VLAN 712 → 172.30.72.x, `enableStorageAutoIp=false` |
| management VLAN | — | **untagged**: no VLAN ID is declared on the Management intent (network-design §2.6, LOM ports are access VLAN 100) |
| `infrastructureNetwork` | `ip_plan` | pool .20–.29, gateway .1, DNS = existing DCs, zone `nic26.iic.local`, `UseDnsServer` |
| `physicalNodesSettings` / `arcNodeResourceIds` | `nodes[]` | derived: `Microsoft.HybridCompute/machines/<node>` in the same resource group |
| `keyVaultName` | `kv_azl_name` (= `names.kv_azl`) | cluster vault in `rg-iic-nic26-azl-sec-eus-01` (design §5.2 option A; **(verify)** that Validate accepts a vault outside the deployment RG — fallback B = same name in `rg_azl`) |
| `clusterWitnessStorageAccountName` | `witness.storage_account_name` | `stiicnic26witeus01` (landing-zone S5) |
| `diagnosticStorageAccountName` / `logsRetentionInDays` | `names.st_diag`, `logs_retention_days` | created here, `CanNotDelete` lock |
| `securityLevel` …`wdacEnforced` | `security_settings` | Recommended = all enforced |
| `configurationMode` | `storage_configuration_mode` | `InfraOnly` — workload volumes/storage paths are Day-2 (`cluster-configure/platform`) |
| `customLocation` | `names.cl_azl` | `cl-iic-nic26-azl-eus-01` |
| `hciResourceProviderObjectID` | `azl_rp_app_object_id` | tenant-specific object ID (O6) |
| `sbe*` | `sbe` (optional) | empty by default; the deployment downloads the OEM's Solution Builder Extension (SBE) |

Inputs added beyond design §10.6 / the schema (manifest marks them `added:`): `rdma_protocol`, `networking_type`, `networking_pattern`, `local_admin_secret_name`, `witness_key_secret_name`, `sbe`, `security_settings`, `observability`, `storage_configuration_mode`, `logs_retention_days`, `assign_hci_rp_role`, `deployment_mode` (run-time only).

## Secrets (the only two surfaces)

`scripts/Set-ClusterDeploymentSecrets.ps1` runs **on the Windows jump server under the operator's sign-in**: reads the local administrator username/password references (`identity.local_admin_*_secret`, ops vault) and the witness key (`Get-AzStorageAccountKey`) in memory, writes `<cluster>-LocalAdminCredential` and `<cluster>-WitnessStorageKey` to the cluster vault, verifies by name/version only. Values never reach logs, files, state or outputs; the IaC gets the vault name. Keep the cluster vault `PublicNetworkAccess = Enabled` through both passes (design §5.3).

## Run

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force
cd .\automation\azure-local\cluster-deploy\scripts
.\Invoke-ClusterDeploy.ps1 -Pass Validate                        # Generate + build + what-if, changes nothing
.\Set-ClusterDeploymentSecrets.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -Execute   # jump server
.\Invoke-ClusterDeploy.ps1 -Pass Validate -Execute               # ~10 min, polls deploymentSettings.reportedProperties
.\Invoke-ClusterDeploy.ps1 -Pass Deploy -Execute                 # 2.5–3 h, same polling (bounded, retried)
.\Test-ClusterPostDeployment.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -OutputJson .\post-deployment.json
.\Set-ClusterVaultPublicAccess.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -CheckFromNode -Execute   # §5.3 phase flag; refuses to disable public access unless enable_private_endpoints is true (D-029)
# Terraform parity: add -Tool Terraform -BackendConfig <environment\azure-local\backend.cluster-deploy.hcl>
```

`Test-ClusterPostDeployment.ps1` is read-only: cluster resource Succeeded/Connected, Deploy status Success, `identityProvider = LocalIdentity`, Arc machines Connected with the required extensions (incl. `AzureEdgeAKVBackupForWindows`), custom location, Arc Resource Bridge `Running`, witness account, cluster vault secrets by **name** (ECE + backed-up BitLocker/RecoveryAdmin), node identities' vault roles; over WinRM from the jump server: nodes Up, cloud witness Online, S2D Healthy, `Get-NetIntentStatus` Success, RDMA/jumbo on storage only, **WORKGROUP + `ADAware = 2`**, live-migration network selection (R-03).

Input validation runs before Azure context checks: `nodes` must be a nonempty array of objects with nonblank, case-insensitively unique string names and no surrounding whitespace. Empty or malformed lists cannot skip node checks and produce a passing report. The helper accepts a generic node count; the lab's configured two-node requirement must still be verified against both actual machines.

## Portal-equivalent steps (for the recorded first run)

1. Azure portal → **Azure Local** → **Create** → resource group `rg-iic-nic26-azl-eus-01`, instance name `nic26-clus01`, region East US, select both Arc machines.
2. **Networking**: *Custom configuration* (three intents), `switched` storage; intents and adapters as above; storage network VLANs 711/712 with the explicit 172.30.71.x/72.x addresses (Storage Auto IP off); **Zone name** `nic26.iic.local`; DNS servers = the existing domain controllers; management pool 192.168.100.20–.29, gateway .1; management VLAN ID left **empty** (untagged).
3. **Management**: **Local Identity with Azure Key Vault** → existing vault `kv-iic-nic26-azl-eus-01`; cloud witness `stiicnic26witeus01`; local administrator credential (identical on both nodes).
4. **Security**: Recommended. **Advanced**: create only the infrastructure volume (InfraOnly). **Tags**: the seven required tags.
5. **Validation** (≈10 min) → **Review + create** → **Deploy** (2.5–3 h) → verify (`Test-ClusterPostDeployment.ps1`).

The template path is the same deployment; it exists for repeatability and the second site (outline §2.4).

## Design inconsistencies found (not edited; for the design owners)

- Landing-zone §5.5, keyvault-and-secrets.md §3 and the environment example (`secret_refs.arb_application_secret: keyvault://…/DefaultARBApplication`) list **`DefaultARBApplication`** as a deployment-time secret. The Local Identity external-DNS template at 2609 writes only `LocalAdminCredential` and `WitnessStorageKey`; `DefaultARBApplication` belongs to the service-principal path. The environment example's `witness.storage_key_secret: keyvault://kv-iic-nic26-azl-eus-01/WitnessStorageKey` also uses the bare ECE name while the quickstart stores it as `<cluster>-WitnessStorageKey`; this solution exposes `witness_key_secret_name` / `local_admin_secret_name` to pin whichever the owner decides.
- Landing-zone §9.2 says the diagnostics storage account is "created by the cluster deployment": with a custom template (vault pre-exists) **this solution** creates it; the name `stiicnic26diageus01` is reserved in the lz catalog as `st_diag`.
- The landing-zone `solution.yml` does not pass `Get-NIC26SolutionManifest` (flow-YAML descriptions containing `: `, catalog keys `fixed/exempt/reserved/from/to/parent`, `law` purpose `""`, types `tfstate`/`container` not in the registry). This solution's manifest validates; the lz owner should align theirs or the schema.
- Build runbook 3.7 names a management logical network `lnet-iic-nic26-mgmt-eus` (VLAN 100) while network-design §4.4 defines logical networks for 110/120 only; the platform creates its own infrastructure logical network (`<cluster>-InfraLNET`).

## (verify) list

Validate accepts a vault in another resource group (design §5.2) · `rdma_protocol` empty is accepted by Validate for some adapters (otherwise set `RoCEv2` or `iWARP` from your NIC model) · role ID `c99c945f-8bd1-4fb1-a903-01460aae6068` is the hyphenated "Azure Stack HCI Connected InfraVMs" built-in role (the quickstart quotes it unhyphenated) · the `edgeDevices` PUT with `properties: {}` validates both nodes (quickstart behaviour) · `Get-NetAdapterAdvancedProperty -DisplayName 'Jumbo Packet'` naming on your drivers.

## Tests and gates

`Invoke-Pester .\tests` (manifest/converters, outputs parity, script hygiene incl. "refuses Deploy without -Execute", `-Tag Gate` runs `az bicep build` and `terraform validate`, identifier sweep). PSScriptAnalyzer: `Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings ..\..\shared\powershell\PSScriptAnalyzerSettings.psd1`.

Destroy: **none** — decommissioning a cluster is the owner-approved runbook (P-10).

## Secrets: rotation and re-runs

- `Set-ClusterDeploymentSecrets.ps1` keeps existing secrets. After a **storage account key rotation** the stored witness key is stale and the deployment would fail with it: re-run with `-Execute -Overwrite` to write a new version.
- A read failure (403, throttling, vault firewall) stops the script; only a confirmed not-found counts as "absent". The vault's public access stays enabled (D-029: no private endpoints; the lock-down step refuses to run).
- Secrets carry the five tags (`owner` and `project` from the shared tags, `rotation-days = 90`, `managed-by`, `lifecycle`) and a 90-day expiry; the platform reads them during deployment, so an expired secret only blocks a re-run until it is rewritten.
- The local administrator username must not contain `:` (the platform format is `base64(user:password)`).

## Pass safety (review R-33)

- `Invoke-ClusterDeploy.ps1 -Execute` submits in **Incremental** mode on purpose: the Deploy pass leaves the edge devices and the cluster out of its template, so a Complete-mode deployment would try to delete what the Validate pass created.
- Before it submits, the script reads both ECE secrets' metadata (never the values) and refuses one that is missing, disabled or expires before the pass can finish (timeout plus 30 minutes).
- The status it waits for is only accepted once the ARM deployment of **this** submission (a record stamped after the submit time; the deployment name is reused per pass) has succeeded. A `validationStatus` or `deploymentStatus` left from an earlier run is never read as the result.
- A failed Deploy is **not** automatically safe to re-run with the same PUT: check the cluster's Deployments blade and the step statuses first, and use the documented retry for the preview rather than deleting `deploymentSettings`, the edge devices or the cluster.
- The node identities hold Key Vault Secrets Officer and Certificates Officer on the **cluster vault only** (quickstart parity). Whether Key Vault Secrets User would be enough for Local Identity backup and rotation is unverified: keep unrelated secrets out of that vault until it is confirmed.
- The witness storage account keeps shared-key access (the cloud witness needs it). Disable anonymous blob access, restrict public network access to the required networks only after testing witness health, and use a dedicated account.
