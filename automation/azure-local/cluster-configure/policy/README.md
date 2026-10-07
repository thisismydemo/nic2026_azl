# cluster-configure/policy — governance baseline assignment (outline §3.5)

Design §2.3 / §7.4: the initiative `init-iic-nic26-hybrid-baseline` is **defined** by `lz-azure-local` (`bicep/initiative.bicep`, management-group scope) and **assigned here** at subscription scope as `asg-iic-nic26-hybrid-baseline` with a system-assigned remediation identity (Log Analytics Contributor, Monitoring Contributor, Guest Configuration Resource Contributor, Security Admin, Contributor — the roles the member DeployIfNotExists definitions need). The three definitions the landing zone left out are created and assigned here:

| Definition (subscription scope) | Source | Effect |
|---|---|---|
| `pol-iic-nic26-azl-insights-ama` → `asg-iic-nic26-azl-insights-ama` | Learn *Enable Insights at scale using Azure policies* — AMA extension on `Microsoft.AzureStackHCI/clusters/arcSettings` | DeployIfNotExists |
| `pol-iic-nic26-azl-insights-dcra` → `asg-iic-nic26-azl-insights-dcra` | same article — DCR association on each node (`dcrResourceId` = `dcr-iic-nic26-azl-insights-eus-01`) | DeployIfNotExists |
| `pol-iic-nic26-akv-backup-ext` → `asg-iic-nic26-akv-backup-ext` | custom audit: `AzureEdgeAKVBackupForWindows` (publisher `Microsoft.Edge.Backup`, type `AKVBackupForWindows`) present on Arc machines (D-008) | AuditIfNotExists |

| Track | Assignments | Definitions |
|---|---|---|
| Bicep (subscription scope) | gap-fill `modules/policy-assignment.bicep` (AVM `ptn/authorization/policy-assignment` is management-group scoped only) | gap-fill `Microsoft.Authorization/policyDefinitions@2023-04-01` |
| Terraform | `azurerm_subscription_policy_assignment` + `azurerm_role_assignment` | `azurerm_policy_definition` |

**Remove** (`-Action Remove` or `-Remove`) deletes the four assignments (sweeping their identities' role assignments) and the three custom definitions; the initiative definition is never touched. `-StartComplianceScan` runs `Start-AzPolicyComplianceScan` after Apply (compliance is not instant — the live beat shows the scan starting). Pre-check (landing-zone §11.1): nothing in the initiative may deny what the cluster needs; the baseline is assigned only after deployment for that reason (design §2.4).

```powershell
cd .\automation\azure-local\cluster-configure\policy\scripts
.\Invoke-PolicyBaseline.ps1 -Action Apply -Execute -StartComplianceScan
.\Invoke-PolicyBaseline.ps1 -Remove -Execute        # before the session; Apply again live
```

State: `..\..\scripts\Get-Day2ControlState.ps1` → control `policy` (Applied = all four assignments exist; evidence includes the compliance summary when available).

## Interplay with the Defender control (review R-38)

The baseline initiative contains the built-in "Configure Azure Defender for servers to be enabled" definition. Assigning the baseline live therefore tends to switch Defender for Servers on again (after evaluation and remediation) even when the separate Day-2 Defender control was removed first. For the replay, assign the baseline and apply the Defender control in the order the outline shows, and expect the policy to enable the plan on its own schedule rather than instantly.