# automation/shared/security — Azure Policy, Defender for Cloud and Microsoft Sentinel

The security baseline for the two landing-zone subscriptions (Azure Local and AVD), run as production. Design: `design/shared/security-operations.md`. Rerunnable: every stage is a Bicep deployment of the same template or an idempotent PUT.

| File | Scope | What it deploys |
|---|---|---|
| `bicep/workspace.bicep` | resource group (security RG of the workspace subscription) | Log Analytics workspace, Microsoft Sentinel onboarding, subscription-based Defender for Cloud connectors, incident creation for Defender for Cloud alerts, security DCR (Windows Security Events via AMA, Learn *Common* event set) and its associations, daily-cap safeguard alerts |
| `bicep/subscription.bicep` | subscription (run once per subscription) | Defender plans (Defender CSPM, Servers Plan 2, Storage, Key Vault, Resource Manager), MDE integration, legacy agent auto-provisioning off, MDVM; policy assignments with managed identities and role assignments; AMA exemptions for Azure Local machines |
| `bicep/modules/*.bicep` | gap-fill | policy assignment, cross-RG role assignment, exemption, DCR association |
| `scripts/Invoke-SecurityBaseline.ps1` | runner | Stages `Workspace`, `Subscriptions`, `Entra` (tenant diagnostic setting), `Content` (content hub solutions and starter analytics rules), `Remediate` (remediation tasks only where resources are non-compliant), `ReadBack` (JSON report) |
| `tests/security.Tests.ps1` | Pester 5 | static gates (Bicep builds, GUID allow-list, non-blocking effects, Common event set, example validates) |

## Inputs

- `environment/shared/environment.yml` — subscriptions, region, base tags.
- `environment/shared/security/security.yml` — everything else (schema `automation/shared/schemas/security.environment.schema.json`, example `automation/shared/examples/environment.security.example.yml`). It lives in its own folder because `Get-NIC26Config` merges every `*.yml` directly in `environment/shared` into the shared schema.

## Run

```powershell
cd .\automation\shared\security\scripts
.\Invoke-SecurityBaseline.ps1                                   # what-if for every stage (default)
.\Invoke-SecurityBaseline.ps1 -Execute -StartComplianceScan     # deploy, then start an on-demand compliance scan
.\Invoke-SecurityBaseline.ps1 -Stage Remediate -Execute         # after the scan: remediation tasks
.\Invoke-SecurityBaseline.ps1 -Stage ReadBack -ReadBackPath .\security-readback.json
```

Permissions: Owner (or Contributor + User Access Administrator + Security Admin) on each subscription; the `Entra` stage needs Security Administrator or Global Administrator in Microsoft Entra ID; the `Content` stage needs Microsoft Sentinel Contributor on the workspace.

## Effects and why nothing blocks a running build

| Assignment | Effect | Note |
|---|---|---|
| Allowed locations / allowed resource group locations | Audit (effect parameter) | Reports, never denies |
| Resource groups carry `project` | built-in Deny assigned **DoNotEnforce** | Audit-only rollout; promote after the event |
| Inherit `project`, `environment`, `workload`, `managed-by` from the resource group | Modify | Adds missing tags only |
| Azure Activity log to the security workspace | DeployIfNotExists | Also the Sentinel *Azure Activity* connector |
| Windows machines associated with the security DCR | DeployIfNotExists | Security events for Sentinel |
| AMA on Windows Arc machines | DeployIfNotExists | Azure Local machines exempt (agent is a cluster extension) |
| AMA on Windows Azure VMs (system-assigned identity) | DeployIfNotExists | |

The Microsoft cloud security benchmark is not assigned here: Defender for Cloud assigns it as `SecurityCenterBuiltIn`, and it carries the Azure Local checks (Secured-core, WDAC, data at rest, data in transit).
