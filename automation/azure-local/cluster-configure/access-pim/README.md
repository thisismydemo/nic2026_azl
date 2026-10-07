# cluster-configure/access-pim — RBAC with Entra PIM (outline §3.4)

Design §6.2 / §6.3: eligible, not standing, privileged access. This solution owns the **Azure Local role eligibilities** for the IIC groups at the landing-zone subscription (the landing zone's `Initialize-LzPim.ps1` owns the lab-operators Owner row and the deployment-user Key Vault/Storage rows; both scripts are idempotent, so the overlap on the Azure Local rows is harmless):

| Group | Eligible roles |
|---|---|
| `grp-iic-nic26-azl-admins` | Azure Stack HCI Administrator, Reader |
| `grp-iic-nic26-azl-operators` | Azure Stack HCI VM Contributor, Reader |

| Track | Resource | Idempotent re-run | Remove |
|---|---|---|---|
| **Az (default)** `Invoke-PimEligibility.ps1` | `New-AzRoleEligibilityScheduleRequest` | yes (`Get-AzRoleEligibilitySchedule` first) | `AdminRemove` with `TargetRoleEligibilityScheduleId` |
| Bicep (subscription scope) | gap-fill `Microsoft.Authorization/roleEligibilityScheduleRequests@2022-04-01-preview` | **no** — a request is one-shot (RoleAssignmentExists on re-deploy); take-home parity only | delegates to the Az path |
| Terraform | `azurerm_pim_eligible_role_assignment` | yes (state) | `terraform destroy` |

`Request-PimActivation.ps1` is the live beat: under the **IIC demo user's** sign-in it self-activates the eligible role with a justification and `PT1H`; MFA and the 8 h cap come from the role settings (one-time step, portal/Graph, owned by the landing zone). The PIM audit entry is shown afterwards. Licensing: PIM needs Entra ID P2 / Governance for the activating users. **Checked 5 Oct 2026:** the tenant holds one `AAD_PREMIUM_P2` licence and it is assigned to nobody, so assign it to the activating demo user before rehearsal; the fallback is time-bound active assignments (landing-zone §11.3).

```powershell
cd .\automation\azure-local\cluster-configure\access-pim\scripts
.\Invoke-PimEligibility.ps1 -Action Apply -Execute
.\Invoke-PimEligibility.ps1 -Action Remove -Execute                      # before the session
.\Request-PimActivation.ps1 -SubscriptionId <id> -Role 'Azure Stack HCI Administrator' -Justification 'NIC 2026: node repair' -Execute   # as the demo user
```

State: `..\..\scripts\Get-Day2ControlState.ps1` → control `access-pim` (Applied = an eligibility schedule exists for every row).
