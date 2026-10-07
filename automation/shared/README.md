# automation/shared — the foundation every solution builds on

Shared PowerShell module, JSON Schemas, example environment files and analyzer settings. Nothing here deploys anything; it loads configuration, validates it, generates names and writes the generated input files the Bicep / Terraform / Ansible tracks consume. Binding rules: `../CONTRACT.md`, `design/shared/naming-standard.md`, `design/shared/keyvault-and-secrets.md`.

## Tree

```text
shared/
├── README.md                                  this file
├── examples/
│   ├── environment.shared.example.yml         IIC values, all-zero GUIDs, placeholder shared-resource names
│   ├── environment.azure-local.example.yml
│   └── environment.avd.example.yml
├── schemas/                                   JSON Schema draft 2020-12; unknown keys rejected
│   ├── shared.environment.schema.json
│   ├── azure-local.environment.schema.json
│   ├── avd.environment.schema.json
│   └── solution.schema.json                   solution.yml manifest (CONTRACT.md section 2 and 10)
├── powershell/
│   ├── PSScriptAnalyzerSettings.psd1          repo analyzer settings (CONTRACT.md section 8)
│   └── NIC26.Automation/
│       ├── NIC26.Automation.psd1 / .psm1
│       ├── Public/   one exported function per file (10 functions)
│       ├── Private/  helpers, including the name registry
│       └── Tests/    Pester 5 suite + fixtures/solutions/lz-example
├── bicep/modules/                             gap-fill Bicep modules only (owned by the solution authors)
└── terraform/modules/                         gap-fill Terraform modules only
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| PowerShell | 7.4 or later | <https://aka.ms/powershell> |
| powershell-yaml | 0.4.x | `Install-PSResource powershell-yaml -Scope CurrentUser` (or `Install-Module powershell-yaml -Scope CurrentUser`). Required by `Get-NIC26Config`, `Get-NIC26SolutionManifest` and `ConvertTo-NIC26AnsibleVars`; third-party code is **not** vendored |
| Pester | 5.5 or later | `Install-PSResource Pester -Version '[5.5.0,6.0.0)' -Scope CurrentUser` (Windows ships Pester 3.4 which cannot run this suite) |
| PSScriptAnalyzer | 1.22 or later | `Install-PSResource PSScriptAnalyzer -Scope CurrentUser` |
| Az.Accounts + Az.KeyVault | current | `Install-PSResource Az.KeyVault -Scope CurrentUser`; only `Resolve-NIC26KeyVaultRef` needs them |
| Bicep CLI | 0.30 or later | `az bicep install` / `winget install Microsoft.Bicep` (solution gates) |
| Terraform | 1.9 or later | `winget install Hashicorp.Terraform` (solution gates) |
| Ansible, ansible-lint, Packer | — | **Not installed on the authoring machine.** On-box solutions document the exact commands and do not claim a pass; run them from WSL/Linux: `pipx install ansible ansible-lint`, `winget install Hashicorp.Packer` |

## Load the module

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force
Get-Command -Module NIC26.Automation
```

## Create your private environment files

Environment files hold real IDs and addresses (never secret values) and live under `environment/<scope>/`. Start from the examples:

```powershell
New-Item -ItemType Directory -Force environment\shared, environment\azure-local, environment\avd | Out-Null
Copy-Item automation\shared\examples\environment.shared.example.yml      environment\shared\environment.yml
Copy-Item automation\shared\examples\environment.azure-local.example.yml environment\azure-local\environment.yml
Copy-Item automation\shared\examples\environment.avd.example.yml         environment\avd\environment.yml
# edit the three files, then validate:
Get-NIC26Config -Scope azure-local | Out-Null
Get-NIC26Config -Scope avd | Out-Null
```

Rules the loader enforces:

- every `*.yml` in a folder is deep-merged in file-name order (later files win), so you can split `10-network.yml`, `20-identity.yml`;
- `environment/shared` is always loaded first, then the scope folder; `values` is the merge (scope wins) the converters read;
- the merged result must validate against `automation/shared/schemas/<scope>.environment.schema.json` — unknown keys, malformed GUIDs/CIDRs/IDs and plaintext in secret fields are rejected with the JSON pointer of the offending key;
- secret fields accept only `keyvault://<vault>/<secret>` (pattern `^keyvault://[a-z0-9-]{3,24}/[A-Za-z0-9-]+$`);
- pre-existing shared resources are referenced only through these files (`hub_vnet_id`, `vpn_gateway_id`, `identity_dc_ips`, ...); the examples use IIC placeholder names and all-zero GUIDs and are the only variant that may be committed.

## Functions (exact signatures)

```powershell
Get-NIC26Config -Scope <shared|azure-local|avd> [-Path <dir>] [-SharedPath <dir>] [-SchemaRoot <dir>]
Get-NIC26SolutionManifest -Path <solution folder | solution.yml>
New-NIC26ResourceName -Type <abbr> [-Purpose <string>] [-Instance <1-99>] [-Region eus] [-Org iic] [-Token nic26] [-Suffix <string>]
Test-NIC26ResourceName -Name <string> -Type <abbr> [-Token nic26] [-Detailed]
ConvertTo-NIC26BicepParam   -Solution <folder|name> -Config <object> [-OutFile <path>] [-Execute] [-WhatIf]
ConvertTo-NIC26TfVars       -Solution <folder|name> -Config <object> [-OutFile <path>] [-Execute] [-WhatIf]
ConvertTo-NIC26AnsibleVars  -Solution <folder|name> -Config <object> [-OutFile <path>] [-Execute] [-WhatIf]
Resolve-NIC26KeyVaultRef -Ref keyvault://<vault>/<secret> [-AsPlainText] [-MaxMinutes 5]
Invoke-NIC26WithRetry -ScriptBlock <sb> [-MaxMinutes 5] [-InitialSeconds 2] [-MaxDelaySeconds 60] [-RetryOn <regex>] [-Activity <label>] [-ArgumentList <object[]>]
Invoke-NIC26ArmDeployment -SubscriptionId <id> -Name <deployment> -Location <region> -TemplateFile <main.bicep|json> -ParameterFile <json> [-ParameterOverrides @{...}] [-Preview]
Write-NIC26Log -Message <string> [-Level Debug|Verbose|Info|Warning|Error] [-Sensitive] [-Source <label>] [-LogFile <path>]
```

### Names

`New-NIC26ResourceName` is the only place a name is built. The registry (`Private\Get-NIC26NameRegistry.ps1`) is a table; add a type by adding one entry.

**Organisation, lab token and region.** No code carries them. A caller passes `-Org`, `-Token`, `-Region`; the name catalog takes them from `org`, `token`, `location_short` in the environment file; anything still missing comes from the `NIC26_ORG`, `NIC26_TOKEN` and `NIC26_REGION` environment variables, then from `powershell\NIC26.Automation\NamingDefaults.psd1` (example values `iic`, `nic26`, `eus`; edit it for your own environment). The examples below use those example values. Examples:

| Call | Result |
|---|---|
| `New-NIC26ResourceName -Type rg -Purpose azl-net` | `rg-iic-nic26-azl-net-eus-01` |
| `New-NIC26ResourceName -Type st -Purpose fslogix` | `stiicnic26fslogixeus01` (hyphens stripped, 3–24, lowercase alnum) |
| `New-NIC26ResourceName -Type kv -Purpose ops` | `kv-iic-nic26-ops-eus-01` (3–24, no consecutive hyphens) |
| `New-NIC26ResourceName -Type law` / `-Type gal` / `-Type vdws` | `law-iic-nic26-eus-01` / `galiicnic26eus01` / `vdws-iic-nic26-eus-01` (singletons, purpose optional) |
| `New-NIC26ResourceName -Type sessionhost -Purpose az -Instance 2` | `nic26-avd-az02` (NetBIOS ≤ 15) |
| `New-NIC26ResourceName -Type node -Instance 2` / `-Type clus` / `-Type jmp` | `nic26-01-n02` / `nic26-clus01` / `nic26-jmp-01` |
| `New-NIC26ResourceName -Type vlan -Purpose mgmt -Suffix 100` | `nic26-mgmt-100` |
| `New-NIC26ResourceName -Type peer -Purpose vnet-iic-nic26-avd-eus-01 -Suffix hub` | `peer-vnet-iic-nic26-avd-eus-01-to-hub` |
| `New-NIC26ResourceName -Type vmazl -Purpose avd` | `vm-iic-nic26-avd-azl-01` (Azure Local VM resource name) |

Type abbreviations: `rg vnet snet peer nsg rt pip nic pep link kv st law dcr dce dcra ag alert rsv bkp asrpol id init pol asg mc gal imgdef it vdws vdpool vdag vdscaling vm vmazl osdisk datadisk vhd cl arb lnet img dep budget rp dnspr spn role grp secret clus node bmc sw fw og jmp netbios sessionhost vlan vsw sp csv share` plus the validate-only exempt types `pdnszone fixedsubnet imgver tfstate container`. Aliases: `vnetpeering|peering -> peer`, `pdns -> pdnszone`, `computername -> netbios`. Violations throw with the rule and the computed length. `Test-NIC26ResourceName -Detailed` returns the reasons.

### Converters (how every solution gets its inputs)

Each solution's `solution.yml` declares its `inputs` (canonical snake_case names from the design variables tables) and a `names` catalog. The converters emit **only** those inputs plus the resolved `names` object, fail when a required input is missing, type-check values, and refuse to emit a `secret-ref` input as anything but the `keyvault://` string. By default they return the generated text (preview); `-Execute` writes the file (`-WhatIf` works):

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force

# Azure Local landing zone
$cfg = Get-NIC26Config -Scope azure-local
ConvertTo-NIC26BicepParam -Solution .\automation\landing-zones\azure-local -Config $cfg -Execute   # -> bicep\main.generated.bicepparam
ConvertTo-NIC26TfVars     -Solution .\automation\landing-zones\azure-local -Config $cfg -Execute   # -> terraform\terraform.generated.tfvars.json

# AVD landing zone (solution names are also accepted; they are searched under automation\)
$cfg = Get-NIC26Config -Scope avd
ConvertTo-NIC26BicepParam  -Solution lz-avd -Config $cfg -Execute
ConvertTo-NIC26TfVars      -Solution lz-avd -Config $cfg -Execute
ConvertTo-NIC26AnsibleVars -Solution session-hosts-hybrid -Config $cfg -Execute                      # -> ansible\group_vars\generated.yml

# Preview without writing:
ConvertTo-NIC26BicepParam -Solution lz-avd -Config $cfg
```

Then deploy with the generated file (the deploy step itself belongs to the solution and sits behind its own `-Execute`):

```powershell
az deployment sub what-if --location $cfg.values.location --template-file .\bicep\main.bicep --parameters .\bicep\main.generated.bicepparam
terraform init -backend=false; terraform plan -var-file=terraform.generated.tfvars.json
```

Lookup rules: an input is read from the top-level key of the merged config with the same name; a manifest input may carry `path: secret_refs.jump_admin_password` to pick a nested key. Optional inputs use `default` or are omitted; `source: generated` inputs (registration tokens, run-time secrets, the `names` object) are **never emitted** and never fail. A short alias table (`Private\Get-NIC26InputAliasMap.ps1`) maps design synonyms to the schema key when no `path` is given: `region_short -> location_short`, `lab_token -> token`, `p2s_pool -> p2s_client_pool`, `identity_spoke_prefix -> identity_spoke_address_space`, `management_spoke_prefix -> management_spoke_address_space`, `avd_spoke_prefix -> avd_vnet_prefix`, `key_vault_ops_name -> kv_ops_name`.

Names-catalog entry shapes (`solution.schema.json` `nameSpec`):

| Shape | Result |
|---|---|
| `{ type: rg, purpose: azl-net }` (+ `instance`, `region`, `suffix`, `org`) | generated, e.g. `rg-iic-nic26-azl-net-eus-01` |
| `{ type: law, purpose: "" }` or `{ type: gal }` | lab-wide singleton: `law-iic-nic26-eus-01`, `galiicnic26eus01` |
| `{ type: peer, from: spoke_vnet, to: hub }` (`vnetpeering`/`peering` accepted) | `peer-<resolved from>-to-<resolved to>`; `from`/`to` are catalog keys or literals |
| `{ type: nic, parent: vm_jump }` / `osdisk` / `datadisk` / `vhd` / `bmc` | `nic-vm-iic-nic26-jump-eus-01-01`, `osdisk-vm-...`; `parent` is the VM/node catalog key |
| `{ type: netbios, purpose: jmp }` | computer name `nic26-jmp-01` (<= 15); session hosts use `sessionhost` |
| `{ type: pdns, fixed: privatelink.vaultcore.azure.net, exempt: true }` (`pdnszone`, `fixedsubnet`, `imgver`, `tfstate`, `container`) | passed through after `Test-NIC26ResourceName`; exempt from the `nic26` rule |
| `{ fixed: <value>, exempt: true }` with an unknown type | passed through with a character check only (use sparingly) |
| `{ ..., reserved: true }` | metadata only (named here, created by a later solution); resolved normally | Bicep receives `param <name>` with the manifest's exact snake_case name and `param names object`; Terraform receives the same keys plus `names` (`map(string)`) and a `_generated` marker (declare `variable "_generated" { type = any; default = null }` or ignore the warning); Ansible receives `group_vars/generated.yml` with the same keys.

### Secrets

`Resolve-NIC26KeyVaultRef` reads a `keyvault://` reference under the operator's own `Connect-AzAccount` context, returns a `SecureString` (or a string with `-AsPlainText`), retries 403/RBAC propagation with bounded backoff (≤ 5 min), never logs or writes the value, and **refuses to run while `Start-Transcript` is active**. It must run on the Windows jump server (SecureString is not a protection elsewhere). IaC never receives a secret value: no `getSecret`, no `data "azurerm_key_vault_secret"`. `Write-NIC26Log -Sensitive` writes only a redaction marker.

## Quality gates (run from the repo root)

```powershell
Import-Module .\automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 -Force
Invoke-ScriptAnalyzer -Path .\automation\shared\powershell -Recurse -Settings .\automation\shared\powershell\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\automation\shared\powershell\NIC26.Automation\Tests -Output Detailed   # unit + Integration.Solutions.Tests.ps1 (every solution.yml under automation\)
foreach ($s in 'shared','azure-local','avd') {
  $json = ConvertFrom-Yaml (Get-Content ".\automation\shared\examples\environment.$s.example.yml" -Raw) -Ordered | ConvertTo-Json -Depth 100
  Test-Json -Json $json -SchemaFile ".\automation\shared\schemas\$s.environment.schema.json"
}
```

## Conventions

| Convention | Rule |
|---|---|
| Canonical names | snake_case, taken from the design variables tables; the schemas are the authority. Chosen where the designs disagree: `location_short` (not `region_short`), `token` (not `lab_token`), `p2s_client_pool` (not `p2s_pool`), `identity_dc_ips` + `dns_servers` |
| Secrets | `keyvault://<vault>/<secret>` strings only; values resolved at run time in memory; `Start-Transcript` forbidden around resolution. `secret_name_prefix` (shared) holds the HCS `<org>-<env>-` prefix: examples carry the IIC placeholder `iic-nic26-`, the registered prefix lives only in the private environment file |
| Generated files | `*.generated.*` (git-ignored in `automation/.gitignore`), header comment / `_generated` key, UTF-8 without BOM, LF |
| Scripts | PowerShell 7, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, comment-based help, `SupportsShouldProcess` where state changes, `-Execute` to write/deploy |
| Logging | `Write-NIC26Log` (Information stream, no `Write-Host`); names, IDs and counts only |
| Retry | `Invoke-NIC26WithRetry` after role assignments; bounded exponential backoff ≤ 5 min |
| Names | `New-NIC26ResourceName` only; every generated name contains `nic26` unless the type is exempt (`pdnszone`, `fixedsubnet`, `imgver`); pre-existing shared resources keep their names and arrive as inputs |
| Examples | IIC values, all-zero GUIDs, RFC 1918 lab plan, no identifiers from the reference environment (tested by the Pester hygiene sweep) |
